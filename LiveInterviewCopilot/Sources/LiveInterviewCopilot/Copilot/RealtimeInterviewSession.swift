import Foundation

enum RealtimeInterviewRole: String, Sendable {
    case interviewer = "INTERVIEWER"
    case candidate = "CANDIDATE"
}

enum RealtimeInterviewState: String, Sendable {
    case disconnected
    case connecting
    case ready
    case listening
    case generating
    case degraded
}

struct RealtimeInterviewCallbacks: Sendable {
    let onState: @Sendable (RealtimeInterviewState) async -> Void
    let onTranscript: @Sendable (RealtimeInterviewRole, String, Bool) async -> Void
    let onCue: @Sendable (InterviewCue, Int) async -> Void
    let onError: @Sendable (String) async -> Void
}

actor RealtimeInterviewSession {
    private let model: String
    private let apiKey: String
    private let instructions: String
    private let callbacks: RealtimeInterviewCallbacks
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connected = false

    private var activeRole: RealtimeInterviewRole?
    private var silenceDuration: TimeInterval = 0
    private var interviewerOverlapDuration: TimeInterval = 0
    private var pendingInterviewerAudio: [Data] = []
    private var pendingCommittedRoles: [RealtimeInterviewRole] = []
    private var roleByItemID: [String: RealtimeInterviewRole] = [:]
    private var delayedInterviewerResponseItems: Set<String> = []
    private var pendingDelayedInterviewerCommit = false
    private var activeAudibleDuration: TimeInterval = 0
    private var activeResponseID: String?
    private var responseInFlight = false
    private var responseStartedAt: Date?
    private var responseArguments = ""
    private var responseText = ""

    private let speechThreshold: Float = 0.006
    private let endpointSilence: TimeInterval = 0.6
    private let fullInterruptionDuration: TimeInterval = 0.8

    init(
        model: String,
        apiKey: String,
        instructions: String,
        callbacks: RealtimeInterviewCallbacks,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.model = model
        self.apiKey = apiKey
        self.instructions = instructions
        self.callbacks = callbacks
        self.session = session
    }

    func connect() async throws {
        guard !connected else { return }
        await callbacks.onState(.connecting)
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        connected = true
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        try await send(sessionUpdateEvent())
        await callbacks.onState(.ready)
    }

    func ingest(_ chunk: RealtimeAudioChunk, role: RealtimeInterviewRole) async {
        do {
            if !connected { try await connect() }
            let audible = chunk.rms >= speechThreshold

            guard let activeRole else {
                if audible {
                    if role == .candidate { try await cancelResponse() }
                    await startTurn(role: role)
                    activeAudibleDuration = chunk.duration
                    try await append(chunk.pcm16)
                }
                return
            }

            if role == activeRole {
                try await append(chunk.pcm16)
                if audible {
                    silenceDuration = 0
                    activeAudibleDuration += chunk.duration
                } else {
                    silenceDuration += chunk.duration
                    if silenceDuration >= endpointSilence { try await commitActiveTurn() }
                }
                return
            }

            guard audible else { return }
            switch (activeRole, role) {
            case (.candidate, .interviewer):
                interviewerOverlapDuration += chunk.duration
                pendingInterviewerAudio.append(chunk.pcm16)
                if interviewerOverlapDuration >= fullInterruptionDuration {
                    let bufferedAudio = pendingInterviewerAudio
                    let bufferedDuration = interviewerOverlapDuration
                    try await commitActiveTurn()
                    await startTurn(role: .interviewer)
                    activeAudibleDuration = bufferedDuration
                    for audio in bufferedAudio { try await append(audio) }
                    pendingInterviewerAudio.removeAll()
                }
            case (.interviewer, .candidate):
                try await cancelResponse()
                try await commitActiveTurn()
                await startTurn(role: .candidate)
                activeAudibleDuration = chunk.duration
                try await append(chunk.pcm16)
            default:
                break
            }
        } catch {
            await fail(error)
        }
    }

    func forceCommit() async {
        do { try await commitActiveTurn() } catch { await fail(error) }
    }

    func cancelResponse() async throws {
        guard responseInFlight || activeResponseID != nil else { return }
        try await send(["type": "response.cancel"])
        activeResponseID = nil
        responseInFlight = false
        responseArguments = ""
        responseText = ""
        await callbacks.onState(.listening)
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        connected = false
        activeRole = nil
        await callbacks.onState(.disconnected)
    }

    private func startTurn(role: RealtimeInterviewRole) async {
        activeRole = role
        silenceDuration = 0
        interviewerOverlapDuration = 0
        pendingInterviewerAudio.removeAll()
        activeAudibleDuration = 0
        do {
            try await send([
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [[
                        "type": "input_text",
                        "text": "NEXT_AUDIO_ROLE: \(role.rawValue)",
                    ]],
                ],
            ])
            await callbacks.onState(.listening)
        } catch { await fail(error) }
    }

    private func append(_ data: Data) async throws {
        try await send([
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ])
    }

    private func commitActiveTurn() async throws {
        guard let role = activeRole else { return }
        activeRole = nil
        silenceDuration = 0
        interviewerOverlapDuration = 0
        pendingCommittedRoles.append(role)
        try await send(["type": "input_audio_buffer.commit"])
        if role == .interviewer {
            if activeAudibleDuration >= 0.9 {
                try await startResponse()
            } else {
                pendingDelayedInterviewerCommit = true
            }
        }
        activeAudibleDuration = 0
    }

    private func startResponse() async throws {
        try await cancelResponse()
        responseStartedAt = .now
        responseArguments = ""
        responseText = ""
        try await send([
            "type": "response.create",
            "response": [
                "output_modalities": ["text"],
                "tool_choice": "required",
                "max_output_tokens": 450,
                "instructions": "只回答最近一段标记为 INTERVIEWER 的问题。调用 display_interview_cue；候选人事实必须引用面试简报来源编号。",
            ],
        ])
        responseInFlight = true
        await callbacks.onState(.generating)
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                await handle(event)
            } catch {
                if !Task.isCancelled { await fail(error) }
                break
            }
        }
    }

    private func handle(_ event: [String: Any]) async {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "input_audio_buffer.committed":
            if let itemID = event["item_id"] as? String, !pendingCommittedRoles.isEmpty {
                let role = pendingCommittedRoles.removeFirst()
                roleByItemID[itemID] = role
                if role == .interviewer, pendingDelayedInterviewerCommit {
                    delayedInterviewerResponseItems.insert(itemID)
                    pendingDelayedInterviewerCommit = false
                }
            }
        case "conversation.item.input_audio_transcription.delta":
            if let itemID = event["item_id"] as? String,
               let role = roleByItemID[itemID], let delta = event["delta"] as? String {
                await callbacks.onTranscript(role, delta, false)
            }
        case "conversation.item.input_audio_transcription.completed":
            if let itemID = event["item_id"] as? String,
               let role = roleByItemID[itemID], let transcript = event["transcript"] as? String {
                await callbacks.onTranscript(role, transcript, true)
                if role == .interviewer, delayedInterviewerResponseItems.remove(itemID) != nil,
                   !Self.isBackchannel(transcript) {
                    do { try await startResponse() } catch { await fail(error) }
                }
            }
        case "response.created":
            activeResponseID = (event["response"] as? [String: Any])?["id"] as? String
        case "response.function_call_arguments.delta":
            responseArguments += event["delta"] as? String ?? ""
        case "response.function_call_arguments.done":
            if let arguments = event["arguments"] as? String { responseArguments = arguments }
            await finishCueIfPossible()
        case "response.output_text.delta":
            responseText += event["delta"] as? String ?? ""
        case "response.output_text.done":
            if let text = event["text"] as? String { responseText = text }
            await finishCueIfPossible()
        case "response.done":
            await finishCueIfPossible()
            activeResponseID = nil
            responseInFlight = false
        case "error":
            let error = event["error"] as? [String: Any]
            await callbacks.onError(error?["message"] as? String ?? "Realtime API error")
        default:
            break
        }
    }

    private func finishCueIfPossible() async {
        let raw = responseArguments.isEmpty ? responseText : responseArguments
        guard let data = raw.data(using: .utf8),
              let cue = try? JSONDecoder().decode(InterviewCue.self, from: data) else { return }
        let duration = Int(Date().timeIntervalSince(responseStartedAt ?? .now) * 1_000)
        responseArguments = ""
        responseText = ""
        await callbacks.onCue(cue, duration)
        await callbacks.onState(.ready)
    }

    private func fail(_ error: Error) async {
        connected = false
        await callbacks.onState(.degraded)
        await callbacks.onError(error.localizedDescription)
    }

    private func send(_ object: [String: Any]) async throws {
        guard let socket else { throw URLError(.notConnectedToInternet) }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.data(data))
    }

    private func sessionUpdateEvent() -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "output_modalities": ["text"],
                "instructions": instructions,
                "reasoning": ["effort": "low"],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": ["model": "gpt-realtime-whisper", "delay": "low"],
                        "turn_detection": NSNull(),
                    ],
                ],
                "tools": [[
                    "type": "function",
                    "name": "display_interview_cue",
                    "description": "Display a concise, source-grounded interview answer cue.",
                    "parameters": Self.cueSchema(),
                ]],
                "tool_choice": "auto",
                "max_output_tokens": 450,
            ],
        ]
    }

    private static func cueSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["questionSummary", "questionType", "isFollowUp", "directOpening", "framework", "talkingPoints", "evidenceAnchors", "missingFacts", "clarifyingQuestion", "likelyFollowUps", "confidence"],
            "properties": [
                "questionSummary": ["type": "string"],
                "questionType": ["type": "string", "enum": InterviewQuestionType.allCases.map(\.rawValue)],
                "isFollowUp": ["type": "boolean"],
                "directOpening": ["type": "string"],
                "framework": ["type": "string"],
                "talkingPoints": ["type": "array", "items": ["type": "string"]],
                "evidenceAnchors": ["type": "array", "items": ["type": "object", "additionalProperties": false, "required": ["cue", "sourceIDs"], "properties": ["cue": ["type": "string"], "sourceIDs": ["type": "array", "items": ["type": "string"]]]]],
                "missingFacts": ["type": "array", "items": ["type": "string"]],
                "clarifyingQuestion": ["type": ["string", "null"]],
                "likelyFollowUps": ["type": "array", "items": ["type": "string"]],
                "confidence": ["type": "string", "enum": ["high", "medium", "low", "unknown"]],
            ],
        ]
    }

    private static func isBackchannel(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["嗯", "好的", "好", "明白", "可以", "okay", "ok", "right", "got it", "sure", "thank you", "thanks"].contains(normalized)
    }
}
