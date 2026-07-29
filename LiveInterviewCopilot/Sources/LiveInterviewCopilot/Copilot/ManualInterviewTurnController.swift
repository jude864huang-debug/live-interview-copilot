import Foundation

enum ManualInterviewTurnState: String, Codable, Sendable {
    case idle
    case listeningInterviewer
    case finalizingInterviewer
    case listeningCandidate
    case finalizingCandidate
    case fallbackTranscribing
    case failed

    var activeRole: InterviewRole? {
        switch self {
        case .listeningInterviewer, .finalizingInterviewer: .interviewer
        case .listeningCandidate, .finalizingCandidate: .candidate
        default: nil
        }
    }
}

struct ManualInterviewASRResult: Sendable, Equatable {
    let boundaryID: UUID
    let role: InterviewRole
    let text: String
    let startedAt: Date
    let provider: InterviewASRProvider
    let durationMilliseconds: Int
    let fallbackUsed: Bool
    let isLowConfidence: Bool
    let revision: Int
}

struct ManualInterviewTurnCallbacks: Sendable {
    let onState: @Sendable (ManualInterviewTurnState, InterviewRole?) async -> Void
    let onPartial: @Sendable (InterviewRole, String) async -> Void
    let onInterviewerCommit: @Sendable (UUID, Int, String) async -> Void
    let onCandidateSpeechStarted: @Sendable () async -> Void
    let onFinal: @Sendable (ManualInterviewASRResult) async -> Void
    let onStatus: @Sendable (String) async -> Void
    let onPendingSegment: @Sendable (InterviewRole?, String?) async -> Void

    init(
        onState: @escaping @Sendable (ManualInterviewTurnState, InterviewRole?) async -> Void = { _, _ in },
        onPartial: @escaping @Sendable (InterviewRole, String) async -> Void = { _, _ in },
        onInterviewerCommit: @escaping @Sendable (UUID, Int, String) async -> Void = { _, _, _ in },
        onCandidateSpeechStarted: @escaping @Sendable () async -> Void = {},
        onFinal: @escaping @Sendable (ManualInterviewASRResult) async -> Void = { _ in },
        onStatus: @escaping @Sendable (String) async -> Void = { _ in },
        onPendingSegment: @escaping @Sendable (InterviewRole?, String?) async -> Void = { _, _ in }
    ) {
        self.onState = onState
        self.onPartial = onPartial
        self.onInterviewerCommit = onInterviewerCommit
        self.onCandidateSpeechStarted = onCandidateSpeechStarted
        self.onFinal = onFinal
        self.onStatus = onStatus
        self.onPendingSegment = onPendingSegment
    }
}

/// Routes the two capture channels into one manually selected role. Tencent
/// receives only the active role; inactive system audio is retained for a short
/// in-memory pre-roll so an interviewer interruption does not lose its opening.
actor ManualInterviewTurnController {
    typealias SessionFactory = @Sendable (
        _ role: InterviewRole,
        _ boundaryID: UUID
    ) async throws -> any StreamingInterviewASRSession
    typealias FallbackTranscriber = @Sendable (
        _ samples: [Float],
        _ previousContext: String?
    ) async throws -> String

    private struct Segment {
        let id: UUID
        let role: InterviewRole
        let revision: Int
        let startedAt: Date
        var committedAt: Date? = nil
        var session: (any StreamingInterviewASRSession)?
        var eventTask: Task<Void, Never>?
        var connectionTask: Task<Void, Never>?
        var isConnected = false
        var pendingChunks: [InterviewAudioChunk] = []
        var audioPCM16 = Data()
        var audioDuration: TimeInterval = 0
        var stablePartial = ""
        var transcriptPrefix = ""
        var transportError: Error?
        var reconnectNotBefore = Date.distantPast
        var fallbackAttempted = false
        var fallbackAvailable = true
        var didSignalCandidateSpeech = false
        var completed = false
    }

    private struct PendingSegment: Sendable {
        let role: InterviewRole
        let text: String
        let expiresAt: Date
    }

    private let sessionFactory: SessionFactory
    private let fallbackTranscriber: FallbackTranscriber
    private let callbacks: ManualInterviewTurnCallbacks
    private let preRollDuration: TimeInterval
    private let maximumFallbackDuration: TimeInterval
    private let minimumCommitDuration: TimeInterval
    private let commitDebounce: TimeInterval

    private var state: ManualInterviewTurnState = .idle
    private var activeRole: InterviewRole = .interviewer
    private var activeSegmentID: UUID?
    private var segments: [UUID: Segment] = [:]
    private var systemPreRoll: [InterviewAudioChunk] = []
    private var systemPreRollSeconds: TimeInterval = 0
    private var pendingSegment: PendingSegment?
    private var revision = 0
    private var lastCommitAt = Date.distantPast
    private var isRunning = false

    init(
        sessionFactory: @escaping SessionFactory,
        fallbackTranscriber: @escaping FallbackTranscriber,
        callbacks: ManualInterviewTurnCallbacks,
        preRollDuration: TimeInterval = 1.5,
        maximumFallbackDuration: TimeInterval = 15 * 60,
        minimumCommitDuration: TimeInterval = 0.3,
        commitDebounce: TimeInterval = 0.35
    ) {
        self.sessionFactory = sessionFactory
        self.fallbackTranscriber = fallbackTranscriber
        self.callbacks = callbacks
        self.preRollDuration = preRollDuration
        self.maximumFallbackDuration = maximumFallbackDuration
        self.minimumCommitDuration = minimumCommitDuration
        self.commitDebounce = commitDebounce
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        state = .listeningInterviewer
        activeRole = .interviewer
        systemPreRoll.removeAll(keepingCapacity: true)
        systemPreRollSeconds = 0
        await callbacks.onState(state, activeRole)
        await openSegment(role: .interviewer, preRoll: [])
    }

    func ingest(_ chunk: InterviewAudioChunk, sourceRole: InterviewRole) async {
        guard chunk.sampleRate == InterviewAudioChunk.targetSampleRate,
              !chunk.pcm16.isEmpty else { return }
        if !isRunning { await start() }
        guard isRunning else { return }

        guard sourceRole == activeRole else {
            if sourceRole == .interviewer, activeRole == .candidate {
                appendSystemPreRoll(chunk)
            }
            return
        }
        guard let id = activeSegmentID, var segment = segments[id] else { return }

        segment.audioDuration += chunk.duration
        let shouldSignalCandidateSpeech = segment.role == .candidate
            && !segment.didSignalCandidateSpeech
            && chunk.rms >= 0.008
        if shouldSignalCandidateSpeech {
            segment.didSignalCandidateSpeech = true
        }
        if segment.fallbackAvailable {
            if segment.audioDuration <= maximumFallbackDuration {
                segment.audioPCM16.append(chunk.pcm16)
            } else {
                segment.audioPCM16.removeAll(keepingCapacity: false)
                segment.fallbackAvailable = false
                await callbacks.onStatus("本段超过 15 分钟；腾讯识别继续，但本地音频兜底已停用。")
            }
        }

        if segment.isConnected, let session = segment.session {
            segments[id] = segment
            do {
                try await session.appendAudio(chunk)
            } catch {
                await markTransportFailure(error, segmentID: id, replaying: chunk)
            }
        } else if segment.transportError == nil {
            enqueuePending(chunk, in: &segment)
            segments[id] = segment
            startConnectionIfNeeded(id)
        } else if shouldReconnectWhenAudioReturns(segment.transportError) {
            enqueuePending(chunk, in: &segment)
            segments[id] = segment
            if Date() >= segment.reconnectNotBefore {
                await recreateSessionAndConnect(id)
            }
        } else {
            // Once this round's Tencent transport has failed we do not retry it.
            // The bounded PCM16 fallback buffer above is the only audio copy kept.
            segment.pendingChunks.removeAll(keepingCapacity: false)
            segments[id] = segment
        }
        if shouldSignalCandidateSpeech {
            await callbacks.onCandidateSpeechStarted()
        }
    }

    func commitActiveTurn() async {
        guard isRunning else {
            await callbacks.onStatus("面试音频会话尚未开始。")
            return
        }
        guard let id = activeSegmentID, var segment = segments[id] else {
            guard activeRole == .candidate else {
                await callbacks.onStatus("当前面试官片段不可提交，请继续播放问题或手动切换角色。")
                return
            }
            await callbacks.onStatus("候选人回答已保存，正在切回面试官。")
            await advanceToNextRole(after: .candidate)
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastCommitAt) >= commitDebounce else { return }
        let hasCapturedContent = segment.audioDuration >= minimumCommitDuration
            || !segment.stablePartial.isEmpty
        guard hasCapturedContent || segment.role == .candidate else {
            await callbacks.onStatus("这一段还没有检测到可提交的语音。")
            return
        }
        lastCommitAt = now
        segment.committedAt = now
        segments[id] = segment

        let committedRole = segment.role
        state = committedRole == .interviewer ? .finalizingInterviewer : .finalizingCandidate
        await callbacks.onState(state, committedRole)
        if committedRole == .interviewer {
            await callbacks.onInterviewerCommit(segment.id, segment.revision, segment.stablePartial)
        }

        if !hasCapturedContent {
            segment.eventTask?.cancel()
            segment.connectionTask?.cancel()
            await segment.session?.cancel()
            await segment.session?.disconnect()
            segments.removeValue(forKey: id)
            await callbacks.onStatus("候选人轮已结束；关麦期间没有新增转写。")
        }

        await advanceToNextRole(after: committedRole)

        if hasCapturedContent {
            Task { [weak self] in await self?.finalizeSegment(id) }
        }
    }

    private func advanceToNextRole(after committedRole: InterviewRole) async {
        activeSegmentID = nil
        activeRole = committedRole == .interviewer ? .candidate : .interviewer
        state = activeRole == .interviewer ? .listeningInterviewer : .listeningCandidate
        let preRoll = activeRole == .interviewer ? systemPreRoll : []
        systemPreRoll.removeAll(keepingCapacity: true)
        systemPreRollSeconds = 0
        await callbacks.onPartial(activeRole, "")
        await callbacks.onState(state, activeRole)
        await openSegment(role: activeRole, preRoll: preRoll)
    }

    func forceRole(_ role: InterviewRole) async {
        if !isRunning { await start() }
        guard role != activeRole else { return }

        if let id = activeSegmentID, let segment = segments.removeValue(forKey: id) {
            segment.eventTask?.cancel()
            segment.connectionTask?.cancel()
            await segment.session?.cancel()
            await segment.session?.disconnect()
            let text = segment.stablePartial.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                pendingSegment = PendingSegment(role: segment.role, text: text, expiresAt: Date().addingTimeInterval(30))
                await callbacks.onPendingSegment(segment.role, text)
            }
        }

        activeSegmentID = nil
        activeRole = role
        state = role == .interviewer ? .listeningInterviewer : .listeningCandidate
        let preRoll = role == .interviewer ? systemPreRoll : []
        systemPreRoll.removeAll(keepingCapacity: true)
        systemPreRollSeconds = 0
        await callbacks.onPartial(role, "")
        await callbacks.onState(state, role)
        await openSegment(role: role, preRoll: preRoll)
    }

    func restorePendingSegment() async {
        guard let pending = pendingSegment else { return }
        pendingSegment = nil
        guard pending.expiresAt > Date() else {
            await callbacks.onPendingSegment(nil, nil)
            return
        }
        await callbacks.onPendingSegment(pending.role, pending.text)
    }

    func clearPendingSegment() async {
        pendingSegment = nil
        await callbacks.onPendingSegment(nil, nil)
    }

    func stop() async {
        isRunning = false
        activeSegmentID = nil
        let activeSegments = Array(segments.values)
        segments.removeAll()
        systemPreRoll.removeAll()
        systemPreRollSeconds = 0
        pendingSegment = nil
        for segment in activeSegments {
            segment.eventTask?.cancel()
            segment.connectionTask?.cancel()
            await segment.session?.cancel()
            await segment.session?.disconnect()
        }
        state = .idle
        await callbacks.onPartial(activeRole, "")
        await callbacks.onPendingSegment(nil, nil)
        await callbacks.onState(.idle, nil)
    }

    private func openSegment(role: InterviewRole, preRoll: [InterviewAudioChunk]) async {
        guard isRunning else { return }
        revision += 1
        let id = UUID()
        let session: (any StreamingInterviewASRSession)?
        var factoryError: Error?
        do {
            session = try await sessionFactory(role, id)
        } catch {
            session = nil
            factoryError = error
        }

        var segment = Segment(
            id: id,
            role: role,
            revision: revision,
            startedAt: Date(),
            session: session,
            transportError: factoryError
        )
        for chunk in preRoll {
            segment.audioDuration += chunk.duration
            segment.audioPCM16.append(chunk.pcm16)
            segment.pendingChunks.append(chunk)
        }
        segments[id] = segment
        activeSegmentID = id

        guard let session else {
            await callbacks.onStatus(factoryError?.localizedDescription ?? "腾讯云 ASR 尚未配置。")
            return
        }
        let eventTask = Task { [weak self] in
            for await event in session.events {
                guard !Task.isCancelled else { return }
                await self?.handle(event, segmentID: id)
            }
        }
        segments[id]?.eventTask = eventTask
        if preRoll.isEmpty {
            await callbacks.onStatus(
                role == .interviewer
                    ? "等待面试官系统音频；收到后自动连接腾讯云 ASR"
                    : "等待候选人麦克风音频；收到后自动连接腾讯云 ASR"
            )
        } else {
            startConnectionIfNeeded(id)
        }
    }

    private func startConnectionIfNeeded(_ id: UUID) {
        guard let segment = segments[id],
              !segment.completed,
              !segment.isConnected,
              segment.transportError == nil,
              segment.session != nil,
              segment.connectionTask == nil else { return }
        let connectionTask = Task { [weak self] in
            guard let self else { return }
            await self.connectSegment(id)
        }
        segments[id]?.connectionTask = connectionTask
    }

    private func connectSegment(_ id: UUID) async {
        guard let session = segments[id]?.session else { return }
        do {
            try await session.connect()
            guard var segment = segments[id], !segment.completed else { return }
            segment.isConnected = true
            segment.connectionTask = nil
            let queued = segment.pendingChunks
            segment.pendingChunks.removeAll(keepingCapacity: true)
            segments[id] = segment
            for chunk in queued {
                try await session.appendAudio(chunk)
            }
            await callbacks.onStatus("腾讯云实时 ASR 已连接")
        } catch {
            await markTransportFailure(error, segmentID: id)
        }
    }

    private func finalizeSegment(_ id: UUID) async {
        let connectionTask = segments[id]?.connectionTask
        await connectionTask?.value
        guard let segment = segments[id], !segment.completed else { return }
        if segment.transportError == nil, let session = segment.session {
            do {
                let text = try await session.finishSegment(timeout: .seconds(2))
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await completeSegment(id, text: text, provider: .tencentStreaming, fallbackUsed: false)
                    return
                }
            } catch {
                if var latest = segments[id] {
                    latest.transportError = error
                    segments[id] = latest
                }
            }
        }
        await runFallback(for: id)
    }

    private func runFallback(for id: UUID) async {
        guard var segment = segments[id], !segment.completed, !segment.fallbackAttempted else { return }
        segment.fallbackAttempted = true
        segments[id] = segment

        guard segment.fallbackAvailable, !segment.audioPCM16.isEmpty else {
            let partial = segment.stablePartial.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                await completeSegment(
                    id,
                    text: partial,
                    provider: .tencentStreaming,
                    fallbackUsed: false,
                    isLowConfidence: true
                )
            } else {
                await failSegment(id, message: "腾讯云识别失败，且本段没有可用于本地兜底的音频。")
            }
            return
        }

        await callbacks.onState(.fallbackTranscribing, activeRole)
        await callbacks.onStatus("正在使用 Qwen 本地慢速兜底…")
        let samples = InterviewAudioChunk.pcm16(segment.audioPCM16).samples
        do {
            let text = try await fallbackTranscriber(samples, segment.stablePartial)
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                await completeSegment(id, text: cleaned, provider: .qwenLocalFallback, fallbackUsed: true)
                return
            }
        } catch {
            await callbacks.onStatus(error.localizedDescription)
        }

        let partial = segment.stablePartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty {
            await completeSegment(
                id,
                text: partial,
                provider: .tencentStreaming,
                fallbackUsed: false,
                isLowConfidence: true
            )
        } else {
            await failSegment(id, message: "腾讯云和 Qwen 本地兜底均未返回文字。")
        }
    }

    private func handle(_ event: InterviewASREvent, segmentID id: UUID) async {
        guard var segment = segments[id], !segment.completed else { return }
        switch event {
        case .connected:
            await callbacks.onStatus("腾讯云实时 ASR 已连接")
        case .partial(let text):
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            let shouldSignalCandidateSpeech = segment.role == .candidate
                && !segment.didSignalCandidateSpeech
            if shouldSignalCandidateSpeech {
                segment.didSignalCandidateSpeech = true
            }
            segment.stablePartial = Self.joinTranscript(segment.transcriptPrefix, cleaned)
            segments[id] = segment
            if shouldSignalCandidateSpeech {
                await callbacks.onCandidateSpeechStarted()
            }
            if id == activeSegmentID { await callbacks.onPartial(segment.role, segment.stablePartial) }
        case .final(let text):
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            await completeSegment(
                id,
                text: Self.joinTranscript(segment.transcriptPrefix, cleaned),
                provider: .tencentStreaming,
                fallbackUsed: false
            )
        case .recoverableError(let error), .fatalError(let error):
            await markTransportFailure(error, segmentID: id)
        }
    }

    private func markTransportFailure(
        _ error: Error,
        segmentID id: UUID,
        replaying chunk: InterviewAudioChunk? = nil
    ) async {
        guard var segment = segments[id], !segment.completed else { return }
        if let chunk { enqueuePending(chunk, in: &segment) }

        let canResume = id == activeSegmentID
            && segment.committedAt == nil
            && shouldReconnectWhenAudioReturns(error)
        guard canResume else {
            segment.transportError = error
            segment.isConnected = false
            segment.connectionTask = nil
            segments[id] = segment
            await callbacks.onStatus(error.localizedDescription)
            return
        }

        let oldSession = segment.session
        segment.transcriptPrefix = segment.stablePartial
        segment.transportError = error
        segment.isConnected = false
        segment.session = nil
        segment.eventTask = nil
        segment.connectionTask = nil
        segment.reconnectNotBefore = Date().addingTimeInterval(reconnectDelay(for: error))
        segments[id] = segment
        await oldSession?.disconnect()
        await callbacks.onStatus("腾讯云 ASR 空闲连接已关闭；收到下一帧音频后自动重连")
    }

    private func recreateSessionAndConnect(_ id: UUID) async {
        guard let current = segments[id],
              id == activeSegmentID,
              current.committedAt == nil,
              shouldReconnectWhenAudioReturns(current.transportError),
              current.connectionTask == nil else { return }
        do {
            let session = try await sessionFactory(current.role, current.id)
            guard var latest = segments[id],
                  id == activeSegmentID,
                  !latest.completed,
                  latest.committedAt == nil else {
                await session.disconnect()
                return
            }
            latest.session = session
            latest.transportError = nil
            latest.reconnectNotBefore = .distantPast
            segments[id] = latest
            let eventTask = Task { [weak self] in
                for await event in session.events {
                    guard !Task.isCancelled else { return }
                    await self?.handle(event, segmentID: id)
                }
            }
            segments[id]?.eventTask = eventTask
            await callbacks.onStatus("检测到新的音频，正在重新连接腾讯云 ASR…")
            startConnectionIfNeeded(id)
        } catch {
            guard var latest = segments[id], !latest.completed else { return }
            latest.transportError = error
            latest.reconnectNotBefore = Date().addingTimeInterval(1)
            segments[id] = latest
            await callbacks.onStatus("腾讯云 ASR 重连失败；收到后续音频时会再次尝试")
        }
    }

    private func shouldReconnectWhenAudioReturns(_ error: Error?) -> Bool {
        guard let error = error as? InterviewASRError else { return false }
        switch error {
        case .connectionFailed, .connectionClosed:
            return true
        case .serviceError(let code, _):
            return code == 4_008 || code == 4_009
        default:
            return false
        }
    }

    private func reconnectDelay(for error: Error) -> TimeInterval {
        guard let error = error as? InterviewASRError else { return 1 }
        switch error {
        case .serviceError(let code, _):
            return code == 4_008 || code == 4_009 ? 0 : 1
        case .connectionClosed:
            return 0
        default:
            return 1
        }
    }

    private func enqueuePending(_ chunk: InterviewAudioChunk, in segment: inout Segment) {
        segment.pendingChunks.append(chunk)
        var duration = segment.pendingChunks.reduce(0) { $0 + $1.duration }
        while duration > 5, !segment.pendingChunks.isEmpty {
            duration -= segment.pendingChunks.removeFirst().duration
        }
    }

    private static func joinTranscript(_ prefix: String, _ latest: String) -> String {
        let left = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty, !left.hasSuffix(right) else { return left }
        if right.hasPrefix(left) { return right }
        let separator = left.last?.isASCII == true && right.first?.isASCII == true ? " " : "，"
        return left + separator + right
    }

    private func completeSegment(
        _ id: UUID,
        text: String,
        provider: InterviewASRProvider,
        fallbackUsed: Bool,
        isLowConfidence: Bool = false
    ) async {
        guard var segment = segments[id], !segment.completed else { return }
        segment.completed = true
        segments[id] = segment
        let result = ManualInterviewASRResult(
            boundaryID: segment.id,
            role: segment.role,
            text: text,
            startedAt: segment.startedAt,
            provider: provider,
            durationMilliseconds: Int(
                Date().timeIntervalSince(segment.committedAt ?? segment.startedAt) * 1_000
            ),
            fallbackUsed: fallbackUsed,
            isLowConfidence: isLowConfidence,
            revision: segment.revision
        )
        segment.eventTask?.cancel()
        segment.connectionTask?.cancel()
        await segment.session?.disconnect()
        segments.removeValue(forKey: id)
        await callbacks.onFinal(result)
        let status = if isLowConfidence {
            "腾讯 final 与 Qwen 均失败，已低置信度保存稳定 partial"
        } else if fallbackUsed {
            "Qwen 本地慢速兜底已完成"
        } else {
            "腾讯云 ASR 已完成"
        }
        await callbacks.onStatus(status)
        if isRunning {
            state = activeRole == .interviewer ? .listeningInterviewer : .listeningCandidate
            await callbacks.onState(state, activeRole)
        }
    }

    private func failSegment(_ id: UUID, message: String) async {
        guard let segment = segments.removeValue(forKey: id) else { return }
        segment.eventTask?.cancel()
        segment.connectionTask?.cancel()
        await segment.session?.disconnect()
        await callbacks.onStatus(message)
        if isRunning {
            state = activeRole == .interviewer ? .listeningInterviewer : .listeningCandidate
            await callbacks.onState(state, activeRole)
        } else {
            state = .failed
            await callbacks.onState(.failed, nil)
        }
    }

    private func appendSystemPreRoll(_ chunk: InterviewAudioChunk) {
        systemPreRoll.append(chunk)
        systemPreRollSeconds += chunk.duration
        while systemPreRollSeconds > preRollDuration, !systemPreRoll.isEmpty {
            systemPreRollSeconds -= systemPreRoll.removeFirst().duration
        }
    }
}
