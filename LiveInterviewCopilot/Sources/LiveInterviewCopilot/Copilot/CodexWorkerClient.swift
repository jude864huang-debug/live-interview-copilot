import Foundation

struct CopilotWorkerResult: Sendable {
    let response: String
    let transport: String?
    let firstDeltaMilliseconds: Int?
    let prewarmReadyAtStart: Bool
    let prewarmDurationAtStartMilliseconds: Int?
    let prewarmTransportAtStart: String?
}

struct CodexPrewarmSnapshot: Sendable {
    let isReady: Bool
    let durationMilliseconds: Int?
    let transport: String?
}

actor CodexWorkerClient {
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputBuffer = Data()
    private var continuations: [UUID: CheckedContinuation<CopilotWorkerResult, Error>] = [:]
    private var deltaHandlers: [UUID: @Sendable (String) -> Void] = [:]
    private var requestStartedAt: [UUID: Date] = [:]
    private var firstDeltaMilliseconds: [UUID: Int] = [:]
    private var prewarmAtRequestStart: [UUID: CodexPrewarmSnapshot] = [:]
    private var cancelledIDs: Set<UUID> = []
    private var prewarmStartedAt: Date?
    private var completedPrewarm: CodexPrewarmSnapshot?
    private let workerPath: URL?

    init(workerPath: URL? = CodexWorkerClient.resolveWorkerPath()) {
        self.workerPath = workerPath
    }

    deinit {
        process?.terminate()
    }

    func prewarm() async {
        let id = UUID()
        let startedAt = Date()
        prewarmStartedAt = startedAt
        do {
            try ensureStarted()
            requestStartedAt[id] = startedAt
            prewarmAtRequestStart[id] = prewarmSnapshot()
            let result: CopilotWorkerResult = try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
                do {
                    try send(.prewarm(id: id))
                } catch {
                    continuations.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
            completedPrewarm = CodexPrewarmSnapshot(
                isReady: true,
                durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                transport: result.transport
            )
        } catch {
            // The worker keeps its SDK fallback available when app-server
            // initialization fails, so prewarming must never block app launch.
            Log.suggestionEngine.debug("Codex prewarm deferred: \(error.localizedDescription, privacy: .public)")
        }
    }

    func prewarmSnapshot() -> CodexPrewarmSnapshot {
        if let completedPrewarm { return completedPrewarm }
        let elapsed = prewarmStartedAt.map { Int(Date().timeIntervalSince($0) * 1_000) }
        return CodexPrewarmSnapshot(isReady: false, durationMilliseconds: elapsed, transport: nil)
    }

    func generate(
        _ request: CopilotGenerationRequest,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> CopilotWorkerResult {
        try ensureStarted()
        requestStartedAt[request.id] = Date()
        prewarmAtRequestStart[request.id] = prewarmSnapshot()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[request.id] = continuation
                deltaHandlers[request.id] = onDelta
                do {
                    try send(.generate(request))
                } catch {
                    continuations.removeValue(forKey: request.id)
                    deltaHandlers.removeValue(forKey: request.id)
                    requestStartedAt.removeValue(forKey: request.id)
                    firstDeltaMilliseconds.removeValue(forKey: request.id)
                    prewarmAtRequestStart.removeValue(forKey: request.id)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: request.id) }
        }
    }

    func cancel(id: UUID) {
        cancelledIDs.insert(id)
        deltaHandlers.removeValue(forKey: id)
        requestStartedAt.removeValue(forKey: id)
        firstDeltaMilliseconds.removeValue(forKey: id)
        prewarmAtRequestStart.removeValue(forKey: id)
        if let continuation = continuations.removeValue(forKey: id) {
            continuation.resume(throwing: CopilotError.cancelled)
        }
        try? send(.cancel(id: id))
    }

    func stop() {
        process?.terminate()
        process = nil
        inputHandle = nil
        failAll(CopilotError.workerUnavailable("Worker stopped."))
    }

    private func ensureStarted() throws {
        if process?.isRunning == true { return }
        guard let workerPath else {
            throw CopilotError.workerUnavailable(
                "Set COPILOT_WORKER_PATH or place codex-worker.mjs in the app Resources directory."
            )
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let node = Self.nodeExecutable()
        process.executableURL = node
        process.arguments = node.path == "/usr/bin/env" ? ["node", workerPath.path] : [workerPath.path]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = workerPath.deletingLastPathComponent()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consume(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else { return }
            Log.suggestionEngine.error("Codex worker: \(message, privacy: .private)")
        }
        process.terminationHandler = { [weak self] process in
            Task {
                await self?.workerExited(code: process.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            throw CopilotError.workerUnavailable(error.localizedDescription)
        }
        self.process = process
        self.inputHandle = stdinPipe.fileHandleForWriting
    }

    private func send(_ message: CopilotWorkerMessage) throws {
        guard let inputHandle else { throw CopilotError.workerUnavailable("Worker input is closed.") }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var data = try encoder.encode(message)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let event = try JSONDecoder.worker.decode(CopilotWorkerEvent.self, from: Data(line))
                handle(event)
            } catch {
                Log.suggestionEngine.error("Invalid Codex worker event: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handle(_ event: CopilotWorkerEvent) {
        if cancelledIDs.remove(event.id) != nil { return }
        if event.event == "delta", let delta = event.delta {
            if firstDeltaMilliseconds[event.id] == nil, let startedAt = requestStartedAt[event.id] {
                firstDeltaMilliseconds[event.id] = Int(Date().timeIntervalSince(startedAt) * 1_000)
            }
            deltaHandlers[event.id]?(delta)
            return
        }
        guard event.event == "completed" || event.event == "failed" else { return }
        deltaHandlers.removeValue(forKey: event.id)
        requestStartedAt.removeValue(forKey: event.id)
        let firstDelta = firstDeltaMilliseconds.removeValue(forKey: event.id)
        let prewarm = prewarmAtRequestStart.removeValue(forKey: event.id)
            ?? CodexPrewarmSnapshot(isReady: false, durationMilliseconds: nil, transport: nil)
        guard let continuation = continuations.removeValue(forKey: event.id) else { return }
        if event.event == "completed", let response = event.response {
            continuation.resume(returning: CopilotWorkerResult(
                response: response,
                transport: event.transport,
                firstDeltaMilliseconds: firstDelta,
                prewarmReadyAtStart: prewarm.isReady,
                prewarmDurationAtStartMilliseconds: prewarm.durationMilliseconds,
                prewarmTransportAtStart: prewarm.transport
            ))
        } else {
            continuation.resume(throwing: CopilotError.workerUnavailable(event.error ?? "Unknown worker error."))
        }
    }

    private func workerExited(code: Int32) {
        process = nil
        inputHandle = nil
        outputBuffer.removeAll(keepingCapacity: true)
        failAll(CopilotError.workerUnavailable("Worker exited with code \(code)."))
    }

    private func failAll(_ error: Error) {
        let pending = continuations.values
        continuations.removeAll()
        deltaHandlers.removeAll()
        requestStartedAt.removeAll()
        firstDeltaMilliseconds.removeAll()
        prewarmAtRequestStart.removeAll()
        for continuation in pending { continuation.resume(throwing: error) }
    }

    nonisolated private static func resolveWorkerPath() -> URL? {
        if let configured = ProcessInfo.processInfo.environment["COPILOT_WORKER_PATH"] {
            return URL(fileURLWithPath: configured)
        }
        if let bundled = Bundle.main.url(forResource: "codex-worker", withExtension: "mjs") {
            return bundled
        }
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("../worker/codex-worker.mjs"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("worker/codex-worker.mjs"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("../../worker/codex-worker.mjs"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.standardizedFileURL.path) }?.standardizedFileURL
    }

    nonisolated private static func nodeExecutable() -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("node"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        if let path = candidates.first(where: FileManager.default.fileExists(atPath:) ) {
            return URL(fileURLWithPath: path)
        }
        let nvmRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), let executable = versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            .map({ $0.appendingPathComponent("bin/node") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return executable
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }
}

private extension JSONDecoder {
    static var worker: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
