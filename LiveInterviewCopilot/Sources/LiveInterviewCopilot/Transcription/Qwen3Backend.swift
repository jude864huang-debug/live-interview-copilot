import Foundation

struct Qwen3RuntimeStatus: Equatable, Sendable {
    let executablePath: String?
    let modelPath: String?

    var isReady: Bool { executablePath != nil && modelPath != nil }

    var message: String {
        switch (executablePath, modelPath) {
        case (.some, .some): "Qwen3-ASR 0.6B 本地兜底可用"
        case (.none, .some): "未找到 mlx-qwen3-asr 可执行文件"
        case (.some, .none): "未找到 Qwen3-ASR 0.6B 本地模型"
        case (.none, .none): "未找到 mlx-qwen3-asr 和 Qwen3-ASR 0.6B 本地模型"
        }
    }
}

struct Qwen3RuntimeConfiguration: Equatable, Sendable {
    let executablePath: String?
    let modelPath: String?

    var status: Qwen3RuntimeStatus {
        Qwen3RuntimeStatus(executablePath: executablePath, modelPath: modelPath)
    }

    static func discover(
        executableOverride: String? = nil,
        modelOverride: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Qwen3RuntimeConfiguration {
        Qwen3RuntimeConfiguration(
            executablePath: discoverExecutable(
                override: executableOverride,
                environment: environment,
                fileManager: fileManager
            ),
            modelPath: discoverModel(override: modelOverride, fileManager: fileManager)
        )
    }

    private static func discoverExecutable(
        override: String?,
        environment: [String: String],
        fileManager: FileManager
    ) -> String? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let override = normalizedOverride(override) { candidates.append(override) }
        candidates.append("\(home)/venvs/qwen-asr/bin/mlx-qwen3-asr")
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                "\($0)/mlx-qwen3-asr"
            })
        }
        return candidates.lazy
            .map { NSString(string: $0).expandingTildeInPath }
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    private static func discoverModel(override: String?, fileManager: FileManager) -> String? {
        if let override = normalizedOverride(override) {
            let expanded = NSString(string: override).expandingTildeInPath
            if fileManager.fileExists(atPath: expanded) { return expanded }
        }

        let snapshots = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--Qwen--Qwen3-ASR-0.6B/snapshots", isDirectory: true)
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return candidates.compactMap { url -> (URL, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  values.isDirectory == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.lastPathComponent > rhs.0.lastPathComponent : lhs.1 > rhs.1
        }
        .first?.0.path
    }

    private static func normalizedOverride(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// Reuses the user's existing MLX Qwen3-ASR installation through its loopback-only
/// OpenAI-compatible server. The model stays resident across segments.
final class Qwen3Backend: TranscriptionBackend, @unchecked Sendable {
    let displayName = "Qwen3 ASR 0.6B"
    let runtimeConfiguration: Qwen3RuntimeConfiguration
    private let preparedLock = NSLock()
    private var isPrepared = false

    init(
        executablePath: String? = nil,
        modelPath: String? = nil
    ) {
        self.runtimeConfiguration = .discover(
            executableOverride: executablePath,
            modelOverride: modelPath
        )
    }

    func checkStatus() -> BackendStatus {
        runtimeConfiguration.status.isReady
            ? .ready
            : .error(reason: runtimeConfiguration.status.message)
    }

    func prepare(
        onStatus: @Sendable (String) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard runtimeConfiguration.status.isReady else {
            throw MLXQwenError.runtimeMissing(runtimeConfiguration.status.message)
        }
        onStatus("Starting local MLX Qwen3 ASR…")
        try await MLXQwenService.shared.prepare(configuration: runtimeConfiguration)
        preparedLock.withLock { isPrepared = true }
        onProgress(1)
        onStatus("Local MLX Qwen3 ASR ready")
    }

    func transcribe(
        _ samples: [Float],
        locale: Locale,
        previousContext: String? = nil
    ) async throws -> String {
        guard preparedLock.withLock({ isPrepared }) else {
            throw TranscriptionBackendError.notPrepared
        }
        return try await MLXQwenService.shared.transcribe(
            samples,
            previousContext: previousContext,
            configuration: runtimeConfiguration
        )
    }
}

/// Whole-turn fallback for the manual interview pipeline. It deliberately does
/// not expose partials: Tencent remains the only realtime recognizer.
actor QwenInterviewASRFallback {
    let runtimeConfiguration: Qwen3RuntimeConfiguration

    init(executablePath: String? = nil, modelPath: String? = nil) {
        self.runtimeConfiguration = .discover(
            executableOverride: executablePath,
            modelOverride: modelPath
        )
    }

    func runtimeStatus() -> Qwen3RuntimeStatus {
        runtimeConfiguration.status
    }

    func prewarm() async throws {
        guard runtimeConfiguration.status.isReady else {
            throw InterviewASRError.localRuntimeUnavailable(runtimeConfiguration.status.message)
        }
        do {
            try await MLXQwenService.shared.prepare(configuration: runtimeConfiguration)
        } catch {
            throw InterviewASRError.localRuntimeUnavailable(error.localizedDescription)
        }
    }

    func transcribe(samples: [Float], previousContext: String? = nil) async throws -> String {
        guard runtimeConfiguration.status.isReady else {
            throw InterviewASRError.localRuntimeUnavailable(runtimeConfiguration.status.message)
        }
        do {
            return try await MLXQwenService.shared.transcribe(
                samples,
                previousContext: previousContext,
                configuration: runtimeConfiguration
            )
        } catch {
            throw InterviewASRError.localRuntimeUnavailable(error.localizedDescription)
        }
    }

    /// Stops only a server process that LiveInterviewCopilot launched. An already-running
    /// user-managed loopback server is never terminated.
    func stop() async {
        await MLXQwenService.shared.stopIfOwned()
    }
}

private enum MLXQwenError: LocalizedError {
    case runtimeMissing(String)
    case serverStartFailed
    case invalidResponse
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing(let message): message
        case .serverStartFailed: "Local MLX Qwen3 ASR did not become ready in time."
        case .invalidResponse: "Local MLX Qwen3 ASR returned an invalid response."
        case .requestFailed(let status, let message): "Local MLX Qwen3 ASR failed (HTTP \(status)): \(message)"
        }
    }
}

private actor MLXQwenService {
    static let shared = MLXQwenService()

    private let port = 18_765
    private let localKey = "liveinterviewcopilot-local-loopback"
    private var process: Process?
    private var isReady = false

    func prepare(configuration: Qwen3RuntimeConfiguration) async throws {
        guard let executablePath = configuration.executablePath,
              let modelPath = configuration.modelPath else {
            throw MLXQwenError.runtimeMissing(configuration.status.message)
        }
        if isReady, await healthCheck() { return }
        if await healthCheck() {
            isReady = true
            return
        }

        if let process, process.isRunning {
            process.terminate()
        }
        self.process = nil
        isReady = false

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "serve", "--host", "127.0.0.1", "--port", String(port),
            "--api-key", localKey, "--model", modelPath,
            "--rate-limit", "600", "--max-queue-depth", "4",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw MLXQwenError.serverStartFailed
        }
        self.process = process

        for _ in 0..<180 {
            if await healthCheck() {
                isReady = true
                return
            }
            if !process.isRunning { break }
            try await Task.sleep(for: .seconds(1))
        }
        if process.isRunning { process.terminate() }
        self.process = nil
        throw MLXQwenError.serverStartFailed
    }

    func transcribe(
        _ samples: [Float],
        previousContext: String?,
        configuration: Qwen3RuntimeConfiguration
    ) async throws -> String {
        guard !samples.isEmpty else { return "" }
        try await prepare(configuration: configuration)
        let boundary = "LiveInterviewCopilot-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipartField(name: "model", value: "Qwen/Qwen3-ASR-0.6B", boundary: boundary)
        if let context = previousContext?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
            body.appendMultipartField(name: "prompt", value: context, boundary: boundary)
        }
        body.appendMultipartFile(
            name: "file",
            filename: "segment.wav",
            contentType: "audio/wav",
            data: WAVEncoder.encode(samples: samples, sampleRate: 16_000),
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(localKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MLXQwenError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let fullMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw MLXQwenError.requestFailed(http.statusCode, String(fullMessage.prefix(300)))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { throw MLXQwenError.invalidResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stopIfOwned() {
        guard let process else { return }
        if process.isRunning { process.terminate() }
        self.process = nil
        isReady = false
    }

    private func healthCheck() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}

private extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        boundary: String
    ) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
