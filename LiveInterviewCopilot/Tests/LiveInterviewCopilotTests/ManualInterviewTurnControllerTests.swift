import Foundation
import XCTest
@testable import LiveInterviewCopilotKit

final class ManualInterviewTurnControllerTests: XCTestCase {
    func testWaitsForFirstActiveAudioBeforeConnectingTencent() async throws {
        let factory = TurnSessionFactory()
        let callbacks = TurnCallbackRecorder()
        let controller = makeController(factory: factory, callbacks: callbacks)

        await controller.start()
        try await waitUntil { await factory.sessionCount == 1 }
        let initialConnectCount = await factory.connectCount(at: 0)
        let initialStatuses = await callbacks.statuses
        XCTAssertEqual(initialConnectCount, 0)
        XCTAssertTrue(initialStatuses.contains { $0.contains("收到后自动连接") })

        await controller.ingest(audioChunk(duration: 0.4), sourceRole: .interviewer)
        try await waitUntil {
            let connectCount = await factory.connectCount(at: 0)
            let appendCount = await factory.appendedCount(at: 0)
            return connectCount == 1 && appendCount == 1
        }
        await controller.stop()
    }

    func testIdleTimeoutReconnectsOnNextAudioAndKeepsExistingPartial() async throws {
        let factory = TurnSessionFactory()
        let callbacks = TurnCallbackRecorder()
        let controller = makeController(factory: factory, callbacks: callbacks)
        let chunk = audioChunk(duration: 0.4)

        await controller.start()
        await controller.ingest(chunk, sourceRole: .interviewer)
        try await waitUntil { await factory.appendedCount(at: 0) == 1 }
        await factory.emit(.partial("请介绍你的项目"), at: 0)
        try await waitUntil { await callbacks.lastPartial == "请介绍你的项目" }

        await factory.emit(
            .recoverableError(.serviceError(code: 4_008, message: "音频分片等待超时")),
            at: 0
        )
        try await waitUntil {
            await callbacks.statuses.contains { $0.contains("下一帧音频后自动重连") }
        }

        await controller.ingest(chunk, sourceRole: .interviewer)
        try await waitUntil {
            let sessionCount = await factory.sessionCount
            let appendCount = await factory.appendedCount(at: 1)
            return sessionCount == 2 && appendCount == 1
        }
        await factory.emit(.partial("以及你做了哪些关键决策"), at: 1)
        try await waitUntil {
            await callbacks.lastPartial == "请介绍你的项目，以及你做了哪些关键决策"
        }

        let roles = await factory.roles
        XCTAssertEqual(roles, [.interviewer, .interviewer])
        await controller.stop()
    }

    func testAlternatesRolesAndRoutesOnlyActiveAudioWithSystemPreRoll() async throws {
        let factory = TurnSessionFactory()
        let callbacks = TurnCallbackRecorder()
        let controller = makeController(factory: factory, callbacks: callbacks)
        let chunk = audioChunk(duration: 0.4)

        await controller.start()
        try await waitUntil { await factory.sessionCount == 1 }

        await controller.ingest(chunk, sourceRole: .interviewer)
        await controller.ingest(chunk, sourceRole: .candidate)
        try await waitUntil { await factory.appendedCount(at: 0) == 1 }
        await controller.commitActiveTurn()

        try await waitUntil {
            let sessionCount = await factory.sessionCount
            let finalCount = await callbacks.finalCount
            return sessionCount == 2 && finalCount == 1
        }
        let firstRoles = await factory.roles
        let firstAppendCount = await factory.appendedCount(at: 0)
        XCTAssertEqual(firstRoles, [.interviewer, .candidate])
        XCTAssertEqual(firstAppendCount, 1, "inactive mic audio must not be uploaded")

        await controller.ingest(chunk, sourceRole: .candidate)
        await controller.ingest(chunk, sourceRole: .interviewer) // retained as system pre-roll
        try await waitUntil { await factory.appendedCount(at: 1) == 1 }
        let candidateSpeechStartedCount = await callbacks.candidateSpeechStartedCount
        XCTAssertEqual(candidateSpeechStartedCount, 1)
        await controller.commitActiveTurn()

        try await waitUntil {
            let sessionCount = await factory.sessionCount
            let appendCount = await factory.appendedCount(at: 2)
            let finalCount = await callbacks.finalCount
            return sessionCount == 3 && appendCount == 1 && finalCount == 2
        }
        let allRoles = await factory.roles
        let finalRoles = await callbacks.finalRoles
        let interviewerCommitCount = await callbacks.interviewerCommitCount
        XCTAssertEqual(allRoles, [.interviewer, .candidate, .interviewer])
        XCTAssertEqual(finalRoles, [.interviewer, .candidate])
        XCTAssertEqual(interviewerCommitCount, 1)

        await controller.stop()
    }

    func testTencentFailureRunsLocalFallbackOnlyOnce() async throws {
        let factory = TurnSessionFactory(finishBehavior: .failure(.connectionFailed))
        let callbacks = TurnCallbackRecorder()
        let fallback = FallbackRecorder(text: "本地完整转写")
        let controller = ManualInterviewTurnController(
            sessionFactory: { role, boundaryID in
                await factory.makeSession(role: role, boundaryID: boundaryID)
            },
            fallbackTranscriber: { samples, context in
                try await fallback.transcribe(samples: samples, context: context)
            },
            callbacks: Self.callbackSet(callbacks),
            minimumCommitDuration: 0.3,
            commitDebounce: 0
        )

        await controller.start()
        await controller.ingest(audioChunk(duration: 0.4), sourceRole: .interviewer)
        await controller.commitActiveTurn()

        try await waitUntil { await callbacks.finalCount == 1 }
        let firstFallbackCount = await fallback.callCount
        let firstResult = await callbacks.finals.first
        let states = await callbacks.states
        XCTAssertEqual(firstFallbackCount, 1)
        let result = try XCTUnwrap(firstResult)
        XCTAssertEqual(result.text, "本地完整转写")
        XCTAssertEqual(result.provider, .qwenLocalFallback)
        XCTAssertTrue(result.fallbackUsed)
        XCTAssertTrue(states.contains(.fallbackTranscribing))

        try? await Task.sleep(nanoseconds: 30_000_000)
        let finalFallbackCount = await fallback.callCount
        XCTAssertEqual(finalFallbackCount, 1)
        await controller.stop()
    }

    func testRejectsTooShortManualCommitWithoutSwitchingRole() async throws {
        let factory = TurnSessionFactory()
        let callbacks = TurnCallbackRecorder()
        let controller = makeController(factory: factory, callbacks: callbacks)

        await controller.start()
        await controller.ingest(audioChunk(duration: 0.1), sourceRole: .interviewer)
        await controller.commitActiveTurn()

        try await waitUntil { await callbacks.statuses.contains { $0.contains("没有检测到") } }
        let roles = await factory.roles
        let activeRole = await callbacks.lastActiveRole
        let finals = await callbacks.finals
        XCTAssertEqual(roles, [.interviewer])
        XCTAssertEqual(activeRole, .interviewer)
        XCTAssertTrue(finals.isEmpty)
        await controller.stop()
    }

    func testForceRolePreservesStablePartialAsTemporarySegment() async throws {
        let factory = TurnSessionFactory()
        let callbacks = TurnCallbackRecorder()
        let controller = makeController(factory: factory, callbacks: callbacks)

        await controller.start()
        try await waitUntil { await factory.sessionCount == 1 }
        await factory.emit(.partial("尚未提交的问题片段"), at: 0)
        try await waitUntil { await callbacks.lastPartial == "尚未提交的问题片段" }

        await controller.forceRole(.candidate)

        try await waitUntil { await callbacks.pendingText == "尚未提交的问题片段" }
        let pendingRole = await callbacks.pendingRole
        let activeRole = await callbacks.lastActiveRole
        let finals = await callbacks.finals
        XCTAssertEqual(pendingRole, .interviewer)
        XCTAssertEqual(activeRole, .candidate)
        XCTAssertTrue(finals.isEmpty)
        await controller.stop()
    }

    func testCandidatePartialSignalsAnswerStartEvenWithoutRMSThreshold() async throws {
        let factory = TurnSessionFactory()
        let callbacks = TurnCallbackRecorder()
        let controller = makeController(factory: factory, callbacks: callbacks)

        await controller.start()
        await controller.ingest(audioChunk(duration: 0.4), sourceRole: .interviewer)
        await controller.commitActiveTurn()
        try await waitUntil { await factory.sessionCount == 2 }

        await factory.emit(.partial("我会先明确业务目标"), at: 1)
        try await waitUntil { await callbacks.candidateSpeechStartedCount == 1 }
        await factory.emit(.partial("我会先明确业务目标和指标"), at: 1)
        try? await Task.sleep(nanoseconds: 30_000_000)

        let signalCount = await callbacks.candidateSpeechStartedCount
        XCTAssertEqual(signalCount, 1)
        await controller.stop()
    }

    func testCandidateTurnCanFinishAfterMicrophoneIsMutedBeforeAudioArrives() async throws {
        let factory = TurnSessionFactory()
        let callbacks = TurnCallbackRecorder()
        let controller = makeController(factory: factory, callbacks: callbacks)

        await controller.start()
        await controller.ingest(audioChunk(duration: 0.4), sourceRole: .interviewer)
        await controller.commitActiveTurn()
        try await waitUntil { await factory.sessionCount == 2 }

        // Muting LiveInterviewCopilot stops mic chunks. Finishing the candidate turn must
        // still switch back to the interviewer instead of silently rejecting it.
        await controller.commitActiveTurn()

        try await waitUntil { await factory.sessionCount == 3 }
        let activeRole = await callbacks.lastActiveRole
        let statuses = await callbacks.statuses
        XCTAssertEqual(activeRole, .interviewer)
        XCTAssertTrue(statuses.contains { $0.contains("关麦期间没有新增转写") })
        await controller.stop()
    }

    func testCandidateCommitRecoversIfStreamingSessionAlreadyFinalized() async throws {
        let factory = TurnSessionFactory()
        let callbacks = TurnCallbackRecorder()
        let controller = makeController(factory: factory, callbacks: callbacks)

        await controller.start()
        await controller.ingest(audioChunk(duration: 0.4), sourceRole: .interviewer)
        await controller.commitActiveTurn()
        try await waitUntil { await factory.sessionCount == 2 }

        await controller.ingest(audioChunk(duration: 0.4), sourceRole: .candidate)
        await factory.emit(.final("候选人回答"), at: 1)
        try await waitUntil { await callbacks.finalRoles.contains(.candidate) }

        await controller.commitActiveTurn()

        try await waitUntil { await factory.sessionCount == 3 }
        let activeRole = await callbacks.lastActiveRole
        XCTAssertEqual(activeRole, .interviewer)
        await controller.stop()
    }

    private func makeController(
        factory: TurnSessionFactory,
        callbacks: TurnCallbackRecorder
    ) -> ManualInterviewTurnController {
        ManualInterviewTurnController(
            sessionFactory: { role, boundaryID in
                await factory.makeSession(role: role, boundaryID: boundaryID)
            },
            fallbackTranscriber: { _, _ in "unused fallback" },
            callbacks: Self.callbackSet(callbacks),
            minimumCommitDuration: 0.3,
            commitDebounce: 0
        )
    }

    private static func callbackSet(_ recorder: TurnCallbackRecorder) -> ManualInterviewTurnCallbacks {
        ManualInterviewTurnCallbacks(
            onState: { state, role in await recorder.record(state: state, role: role) },
            onPartial: { role, text in await recorder.recordPartial(role: role, text: text) },
            onInterviewerCommit: { _, _, text in await recorder.recordInterviewerCommit(text) },
            onCandidateSpeechStarted: { await recorder.recordCandidateSpeechStarted() },
            onFinal: { result in await recorder.recordFinal(result) },
            onStatus: { status in await recorder.recordStatus(status) },
            onPendingSegment: { role, text in await recorder.recordPending(role: role, text: text) }
        )
    }

    private func audioChunk(duration: TimeInterval) -> InterviewAudioChunk {
        let sampleCount = max(1, Int(Double(InterviewAudioChunk.targetSampleRate) * duration))
        return InterviewAudioChunk(
            pcm16: Data(repeating: 1, count: sampleCount * 2),
            samples: [Float](repeating: 0.1, count: sampleCount),
            duration: duration,
            rms: 0.1
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for asynchronous state")
    }
}

private enum MockFinishBehavior: Sendable {
    case text(String)
    case failure(InterviewASRError)
}

private actor TurnSessionProbe {
    private(set) var appendedChunks: [InterviewAudioChunk] = []
    private(set) var connectCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private(set) var disconnectCount = 0
    let finishBehavior: MockFinishBehavior

    init(finishBehavior: MockFinishBehavior) {
        self.finishBehavior = finishBehavior
    }

    func connect() { connectCount += 1 }
    func append(_ chunk: InterviewAudioChunk) { appendedChunks.append(chunk) }
    func cancel() { cancelCount += 1 }
    func disconnect() { disconnectCount += 1 }

    func finish() throws -> String {
        finishCount += 1
        switch finishBehavior {
        case .text(let value): return value
        case .failure(let error): throw error
        }
    }
}

private final class MockTurnASRSession: StreamingInterviewASRSession, @unchecked Sendable {
    let events: AsyncStream<InterviewASREvent>
    let probe: TurnSessionProbe
    private let continuation: AsyncStream<InterviewASREvent>.Continuation

    init(probe: TurnSessionProbe) {
        self.probe = probe
        let (stream, continuation) = AsyncStream.makeStream(of: InterviewASREvent.self)
        self.events = stream
        self.continuation = continuation
    }

    func connect() async throws { await probe.connect() }
    func appendAudio(_ chunk: InterviewAudioChunk) async throws { await probe.append(chunk) }
    func finishSegment(timeout: Duration) async throws -> String { try await probe.finish() }
    func cancel() async {
        await probe.cancel()
        continuation.finish()
    }
    func disconnect() async {
        await probe.disconnect()
        continuation.finish()
    }
    func emit(_ event: InterviewASREvent) { continuation.yield(event) }
}

private actor TurnSessionFactory {
    private let finishBehavior: MockFinishBehavior
    private var sessions: [MockTurnASRSession] = []
    private(set) var roles: [InterviewRole] = []

    init(finishBehavior: MockFinishBehavior = .text("腾讯最终转写")) {
        self.finishBehavior = finishBehavior
    }

    var sessionCount: Int { sessions.count }

    func makeSession(role: InterviewRole, boundaryID: UUID) -> any StreamingInterviewASRSession {
        let session = MockTurnASRSession(probe: TurnSessionProbe(finishBehavior: finishBehavior))
        roles.append(role)
        sessions.append(session)
        return session
    }

    func appendedCount(at index: Int) async -> Int {
        guard sessions.indices.contains(index) else { return 0 }
        return await sessions[index].probe.appendedChunks.count
    }

    func connectCount(at index: Int) async -> Int {
        guard sessions.indices.contains(index) else { return 0 }
        return await sessions[index].probe.connectCount
    }

    func emit(_ event: InterviewASREvent, at index: Int) {
        guard sessions.indices.contains(index) else { return }
        sessions[index].emit(event)
    }
}

private actor TurnCallbackRecorder {
    private(set) var states: [ManualInterviewTurnState] = []
    private(set) var finals: [ManualInterviewASRResult] = []
    private(set) var statuses: [String] = []
    private(set) var interviewerCommitCount = 0
    private(set) var candidateSpeechStartedCount = 0
    private(set) var lastActiveRole: InterviewRole?
    private(set) var lastPartial = ""
    private(set) var pendingRole: InterviewRole?
    private(set) var pendingText: String?

    var finalCount: Int { finals.count }
    var finalRoles: [InterviewRole] { finals.map(\.role) }

    func record(state: ManualInterviewTurnState, role: InterviewRole?) {
        states.append(state)
        lastActiveRole = role
    }

    func recordPartial(role: InterviewRole, text: String) {
        lastPartial = text
    }

    func recordInterviewerCommit(_ text: String) {
        interviewerCommitCount += 1
    }

    func recordCandidateSpeechStarted() {
        candidateSpeechStartedCount += 1
    }

    func recordFinal(_ result: ManualInterviewASRResult) {
        finals.append(result)
    }

    func recordStatus(_ status: String) {
        statuses.append(status)
    }

    func recordPending(role: InterviewRole?, text: String?) {
        pendingRole = role
        pendingText = text
    }
}

private actor FallbackRecorder {
    private(set) var callCount = 0
    let text: String

    init(text: String) { self.text = text }

    func transcribe(samples: [Float], context: String?) throws -> String {
        callCount += 1
        return text
    }
}
