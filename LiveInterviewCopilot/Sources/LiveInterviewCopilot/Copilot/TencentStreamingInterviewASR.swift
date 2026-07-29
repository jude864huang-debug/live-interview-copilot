import CryptoKit
import Foundation
import os

enum TencentAccountAppIDResolver {
    private static let host = "cam.tencentcloudapi.com"
    private static let service = "cam"
    private static let action = "GetUserAppId"
    private static let version = "2019-01-16"

    static func resolve(
        secretID: String,
        secretKey: String,
        timestamp: Date = Date(),
        urlSession: URLSession = URLSession(configuration: .ephemeral)
    ) async throws -> String {
        let request = try signedRequest(
            secretID: secretID,
            secretKey: secretKey,
            timestamp: timestamp
        )
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw TencentAccountLookupError.networkFailure
        }

        let envelope: TencentAccountLookupEnvelope
        do {
            envelope = try JSONDecoder().decode(TencentAccountLookupEnvelope.self, from: data)
        } catch {
            throw TencentAccountLookupError.invalidResponse
        }
        if let error = envelope.response.error {
            throw TencentAccountLookupError.apiError(code: error.code, message: error.message)
        }
        guard let appID = envelope.response.appID, appID > 0 else {
            throw TencentAccountLookupError.invalidResponse
        }
        return String(appID)
    }

    static func signedRequest(
        secretID: String,
        secretKey: String,
        timestamp: Date
    ) throws -> URLRequest {
        let trimmedID = secretID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedKey.isEmpty else {
            throw TencentAccountLookupError.missingCredentials
        }
        guard let url = URL(string: "https://\(host)") else {
            throw TencentAccountLookupError.invalidResponse
        }

        let payload = Data("{}".utf8)
        let contentType = "application/json; charset=utf-8"
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\n"
        let signedHeaders = "content-type;host"
        let canonicalRequest = [
            "POST",
            "/",
            "",
            canonicalHeaders,
            signedHeaders,
            sha256Hex(payload),
        ].joined(separator: "\n")

        let epoch = Int(timestamp.timeIntervalSince1970)
        let date = utcDate(timestamp)
        let credentialScope = "\(date)/\(service)/tc3_request"
        let stringToSign = [
            "TC3-HMAC-SHA256",
            String(epoch),
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let secretDate = hmacSHA256(
            key: Data("TC3\(trimmedKey)".utf8),
            message: Data(date.utf8)
        )
        let secretService = hmacSHA256(key: secretDate, message: Data(service.utf8))
        let secretSigning = hmacSHA256(key: secretService, message: Data("tc3_request".utf8))
        let signature = hmacSHA256(key: secretSigning, message: Data(stringToSign.utf8)).hexString
        let authorization = "TC3-HMAC-SHA256 Credential=\(trimmedID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue(String(epoch), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(version, forHTTPHeaderField: "X-TC-Version")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    private static func utcDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexString
    }

    private static func hmacSHA256(key: Data, message: Data) -> Data {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: key)
        )
        return Data(authenticationCode)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private struct TencentAccountLookupEnvelope: Decodable {
    struct Response: Decodable {
        struct APIError: Decodable {
            let code: String
            let message: String

            enum CodingKeys: String, CodingKey {
                case code = "Code"
                case message = "Message"
            }
        }

        let appID: Int?
        let error: APIError?

        enum CodingKeys: String, CodingKey {
            case appID = "AppId"
            case error = "Error"
        }
    }

    let response: Response

    enum CodingKeys: String, CodingKey {
        case response = "Response"
    }
}

enum TencentAccountLookupError: LocalizedError {
    case missingCredentials
    case networkFailure
    case invalidResponse
    case apiError(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "请先填写 SecretID 和 SecretKey。"
        case .networkFailure:
            "无法连接腾讯云账号接口，请检查网络后重试。"
        case .invalidResponse:
            "腾讯云未返回有效 APPID。"
        case let .apiError(code, message):
            "腾讯云查询失败（\(code)）：\(message)"
        }
    }
}

struct TencentASRCredentials: Equatable, Sendable {
    let appID: String
    let secretID: String
    let secretKey: String

    var isComplete: Bool {
        !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    fileprivate func redact(_ message: String) -> String {
        [secretID, secretKey].filter { !$0.isEmpty }.reduce(message) { value, secret in
            value.replacingOccurrences(of: secret, with: "••••")
        }
    }
}

struct TencentASRConfiguration: Sendable {
    /// Tencent's standard Mandarin realtime engine. Unlike `16k_zh_en`, this
    /// engine is eligible for the standard realtime-ASR free quota. Keep this
    /// as the cost-safe default; interview hotwords provide limited support for
    /// English product and company terminology.
    static let defaultEngineModel = "16k_zh"

    let credentials: TencentASRCredentials
    let engineModel: String
    let hotwords: [InterviewHotword]
    let connectionTimeout: Duration

    init(
        credentials: TencentASRCredentials,
        engineModel: String = defaultEngineModel,
        hotwords: [InterviewHotword] = [],
        connectionTimeout: Duration = .seconds(10)
    ) {
        self.credentials = credentials
        self.engineModel = engineModel
        self.hotwords = Array(hotwords.prefix(128))
        self.connectionTimeout = connectionTimeout
    }
}

/// Tencent's websocket signing algorithm is intentionally isolated so it can
/// be verified with fixed timestamps and non-secret fixtures. Callers must not
/// log the returned URL because it contains SecretID and a short-lived signature.
enum TencentASRRequestSigner {
    static let host = "asr.cloud.tencent.com"
    static let pathPrefix = "/asr/v2/"

    static func signedURL(
        configuration: TencentASRConfiguration,
        voiceID: String,
        timestamp: Int = Int(Date().timeIntervalSince1970),
        nonce: Int = Int.random(in: 1...9_999_999_999)
    ) throws -> URL {
        let credentials = configuration.credentials
        guard credentials.isComplete else { throw InterviewASRError.missingCredentials }
        guard credentials.appID.allSatisfy(\.isNumber) else {
            throw InterviewASRError.invalidConfiguration("AppID 应为纯数字")
        }
        guard !voiceID.isEmpty, voiceID.count <= 128 else {
            throw InterviewASRError.invalidConfiguration("voice_id 长度必须为 1–128")
        }
        guard !configuration.engineModel.isEmpty else {
            throw InterviewASRError.invalidConfiguration("识别模型不能为空")
        }

        var parameters = unsignedParameters(
            configuration: configuration,
            voiceID: voiceID,
            timestamp: timestamp,
            nonce: nonce
        )
        let source = signatureSource(appID: credentials.appID, parameters: parameters)
        let key = SymmetricKey(data: Data(credentials.secretKey.utf8))
        let authenticationCode = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(source.utf8),
            using: key
        )
        parameters["signature"] = Data(authenticationCode).base64EncodedString()

        let query = parameters.keys.sorted().map { name in
            "\(percentEncode(name))=\(percentEncode(parameters[name] ?? ""))"
        }.joined(separator: "&")
        guard let url = URL(string: "wss://\(host)\(pathPrefix)\(credentials.appID)?\(query)") else {
            throw InterviewASRError.invalidConfiguration("无法生成连接地址")
        }
        return url
    }

    static func unsignedParameters(
        configuration: TencentASRConfiguration,
        voiceID: String,
        timestamp: Int,
        nonce: Int
    ) -> [String: String] {
        var parameters = [
            "engine_model_type": configuration.engineModel,
            "expired": String(timestamp + 3_600),
            "filter_dirty": "0",
            "filter_modal": "0",
            "filter_punc": "0",
            "needvad": "0",
            "nonce": String(nonce),
            "secretid": configuration.credentials.secretID,
            "timestamp": String(timestamp),
            "voice_format": "1",
            "voice_id": voiceID,
        ]
        if let hotwordList = InterviewHotwordExtractor.tencentParameterValue(configuration.hotwords) {
            parameters["hotword_list"] = hotwordList
        }
        return parameters
    }

    static func signatureSource(appID: String, parameters: [String: String]) -> String {
        let query = parameters.keys.sorted().map { "\($0)=\(parameters[$0] ?? "")" }.joined(separator: "&")
        return "\(host)\(pathPrefix)\(appID)?\(query)"
    }

    private static func percentEncode(_ value: String) -> String {
        let hexadecimal = Array("0123456789ABCDEF".utf8)
        var output = [UInt8]()
        output.reserveCapacity(value.utf8.count * 3)
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                output.append(byte)
            default:
                output.append(0x25)
                output.append(hexadecimal[Int(byte >> 4)])
                output.append(hexadecimal[Int(byte & 0x0F)])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}

struct TencentASRMessage: Decodable, Equatable, Sendable {
    struct Result: Decodable, Equatable, Sendable {
        let sliceType: Int
        let index: Int
        let voiceText: String

        enum CodingKeys: String, CodingKey {
            case sliceType = "slice_type"
            case index
            case voiceText = "voice_text_str"
        }
    }

    let code: Int
    let message: String?
    let result: Result?
    let isFinal: Int?

    enum CodingKeys: String, CodingKey {
        case code, message, result
        case isFinal = "final"
    }
}

enum TencentASRMessageParser {
    static func parse(_ data: Data) throws -> TencentASRMessage {
        do {
            return try JSONDecoder().decode(TencentASRMessage.self, from: data)
        } catch {
            throw InterviewASRError.invalidResponse
        }
    }
}

enum TencentASRConnectionTester {
    /// Performs only the signed websocket handshake. No audio or knowledge
    /// package content is sent, and the signed URL is never returned to UI code.
    static func test(configuration: TencentASRConfiguration) async throws {
        let session = TencentStreamingInterviewASRSession(configuration: configuration)
        do {
            try await session.connect()
            await session.disconnect()
        } catch {
            await session.disconnect()
            throw error
        }
    }
}

actor TencentStreamingInterviewASRSession: StreamingInterviewASRSession {
    /// 40 ms at 16 kHz, mono PCM16: 16_000 * 0.04 * 2 bytes.
    static let packetByteCount = 1_280

    nonisolated let events: AsyncStream<InterviewASREvent>

    private enum State: Equatable {
        case idle
        case connecting
        case connected
        case finishing
        case finished
        case cancelled
    }

    private let configuration: TencentASRConfiguration
    private let urlSession: URLSession
    private let eventContinuation: AsyncStream<InterviewASREvent>.Continuation

    private var state: State = .idle
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var finalTimeoutTask: Task<Void, Never>?
    private var connectionWaiters: [CheckedContinuation<Void, Error>] = []
    private var finalWaiters: [CheckedContinuation<String, Error>] = []
    private var sendDrainWaiters: [CheckedContinuation<Void, Error>] = []
    private var pendingAudio = Data()
    private var queuedPackets: [Data] = []
    private var sendTask: Task<Void, Never>?
    private var stableSegments: [Int: String] = [:]
    private var unstableSegments: [Int: String] = [:]
    private var finalText: String?
    private var terminalError: InterviewASRError?

    init(
        configuration: TencentASRConfiguration,
        urlSession: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        let (stream, continuation) = AsyncStream.makeStream(of: InterviewASREvent.self)
        self.events = stream
        self.eventContinuation = continuation
    }

    func connect() async throws {
        switch state {
        case .connected, .finishing:
            return
        case .connecting:
            try await awaitConnection()
            return
        case .finished:
            throw terminalError ?? InterviewASRError.connectionClosed
        case .cancelled:
            throw InterviewASRError.cancelled
        case .idle:
            break
        }

        let voiceID = UUID().uuidString.lowercased()
        let url = try TencentASRRequestSigner.signedURL(
            configuration: configuration,
            voiceID: voiceID
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let task = urlSession.webSocketTask(with: request)
        socket = task
        state = .connecting
        task.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        connectionTimeoutTask = Task { [weak self, timeout = configuration.connectionTimeout] in
            do {
                try await Task.sleep(for: timeout)
                await self?.expireConnection()
            } catch {}
        }

        try await awaitConnection()
    }

    func appendAudio(_ chunk: InterviewAudioChunk) async throws {
        guard chunk.sampleRate == InterviewAudioChunk.targetSampleRate else {
            throw InterviewASRError.invalidAudio("需要 16 kHz 单声道 PCM")
        }
        guard chunk.pcm16.count.isMultiple(of: 2) else {
            throw InterviewASRError.invalidAudio("PCM16 字节数必须为偶数")
        }
        if state == .idle { try await connect() }
        guard state == .connected else {
            throw terminalError ?? (state == .cancelled ? .cancelled : .connectionClosed)
        }

        pendingAudio.append(chunk.pcm16)
        while pendingAudio.count >= Self.packetByteCount {
            queuedPackets.append(Data(pendingAudio.prefix(Self.packetByteCount)))
            pendingAudio.removeFirst(Self.packetByteCount)
        }
        startSendLoopIfNeeded()
        if let terminalError { throw terminalError }
    }

    func finishSegment(timeout: Duration = .seconds(2)) async throws -> String {
        if let finalText { return finalText }
        if let terminalError { throw terminalError }
        if state == .idle { try await connect() }
        if state == .connecting { try await awaitConnection() }
        guard state == .connected else {
            throw state == .cancelled ? InterviewASRError.cancelled : InterviewASRError.connectionClosed
        }
        state = .finishing

        do {
            if !pendingAudio.isEmpty {
                queuedPackets.append(pendingAudio)
                pendingAudio.removeAll(keepingCapacity: false)
            }
            startSendLoopIfNeeded()
            try await waitForSendDrain()
            if let finalText { return finalText }
            if let terminalError { throw terminalError }
            try await socket?.send(.string(#"{"type":"end"}"#))
        } catch {
            let mapped = terminalError ?? transportError(error)
            terminate(with: mapped)
            throw mapped
        }

        if let finalText { return finalText }
        if let terminalError { throw terminalError }
        finalTimeoutTask?.cancel()
        finalTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                await self?.expireFinal()
            } catch {}
        }
        return try await withCheckedThrowingContinuation { continuation in
            finalWaiters.append(continuation)
        }
    }

    func latestTranscript() -> String {
        assembledTranscript()
    }

    func cancel() async {
        closeWithoutEvent(error: .cancelled)
    }

    func disconnect() async {
        closeWithoutEvent(error: .cancelled)
    }

    private func awaitConnection() async throws {
        if state == .connected || state == .finishing { return }
        if let terminalError { throw terminalError }
        try await withCheckedThrowingContinuation { continuation in
            connectionWaiters.append(continuation)
        }
    }

    private func startSendLoopIfNeeded() {
        guard sendTask == nil, !queuedPackets.isEmpty else { return }
        sendTask = Task { [weak self] in
            guard let self else { return }
            await self.drainAudioPackets()
        }
    }

    /// Tencent limits clients to at most three seconds of audio per wall-clock
    /// second. A 16 ms gap sends 40 ms frames at 2.5x while catching up a
    /// pre-roll, then naturally falls back to realtime as live frames arrive.
    private func drainAudioPackets() async {
        while !Task.isCancelled, state == .connected || state == .finishing {
            guard !queuedPackets.isEmpty else { break }
            let packet = queuedPackets.removeFirst()
            do {
                try await socket?.send(.data(packet))
            } catch {
                let mapped = transportError(error)
                sendTask = nil
                terminate(with: mapped)
                return
            }
            if !queuedPackets.isEmpty {
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    break
                }
            }
        }
        sendTask = nil
        if queuedPackets.isEmpty {
            resumeSendDrainWaiters()
        } else if let terminalError {
            resumeSendDrainWaiters(throwing: terminalError)
        }
    }

    private func waitForSendDrain() async throws {
        if queuedPackets.isEmpty, sendTask == nil { return }
        if let terminalError { throw terminalError }
        try await withCheckedThrowingContinuation { continuation in
            sendDrainWaiters.append(continuation)
        }
    }

    private func resumeSendDrainWaiters(throwing error: InterviewASRError? = nil) {
        let waiters = sendDrainWaiters
        sendDrainWaiters.removeAll()
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) }
            else { waiter.resume() }
        }
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
                let response = try TencentASRMessageParser.parse(data)
                handle(response)
                if response.isFinal == 1 || response.code != 0 { return }
            } catch {
                guard state != .cancelled, state != .finished else { return }
                let mapped = (error as? InterviewASRError) ?? transportError(error)
                terminate(with: mapped)
                return
            }
        }
    }

    private func handle(_ response: TencentASRMessage) {
        guard response.code == 0 else {
            // Keep diagnostics useful without logging the signed URL, account
            // credentials, service message, audio, transcript or hotword text.
            Log.interviewASR.error(
                "Tencent service error code=\(response.code, privacy: .public) model=\(self.configuration.engineModel, privacy: .public) hotwordCount=\(self.configuration.hotwords.count, privacy: .public)"
            )
            let error: InterviewASRError
            if response.code == 4_002 {
                error = .authenticationFailed
            } else {
                let message = configuration.credentials.redact(response.message ?? serviceMessage(response.code))
                error = .serviceError(code: response.code, message: message)
            }
            terminate(with: error)
            return
        }

        if state == .connecting {
            state = .connected
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            let waiters = connectionWaiters
            connectionWaiters.removeAll()
            waiters.forEach { $0.resume() }
            eventContinuation.yield(.connected)
        }

        if let result = response.result {
            let text = result.voiceText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch result.sliceType {
            case 2:
                stableSegments[result.index] = text
                unstableSegments.removeValue(forKey: result.index)
            default:
                unstableSegments[result.index] = text
            }
            eventContinuation.yield(.partial(assembledTranscript()))
        }

        if response.isFinal == 1 {
            complete(with: assembledTranscript())
        }
    }

    private func assembledTranscript() -> String {
        let keys = Set(stableSegments.keys).union(unstableSegments.keys).sorted()
        let segments: [String] = keys.compactMap { index -> String? in
            let text = stableSegments[index] ?? unstableSegments[index]
            guard let text, !text.isEmpty else { return nil }
            return text
        }
        return segments.reduce(into: "") { output, segment in
            if output.last?.isASCII == true, segment.first?.isASCII == true, !output.hasSuffix(" ") {
                output += " "
            }
            output += segment
        }
    }

    private func complete(with text: String) {
        guard state != .finished, state != .cancelled else { return }
        state = .finished
        finalText = text
        connectionTimeoutTask?.cancel()
        finalTimeoutTask?.cancel()
        sendTask?.cancel()
        connectionTimeoutTask = nil
        finalTimeoutTask = nil
        sendTask = nil
        queuedPackets.removeAll(keepingCapacity: false)
        pendingAudio.removeAll(keepingCapacity: false)
        resumeSendDrainWaiters()

        let connection = connectionWaiters
        connectionWaiters.removeAll()
        connection.forEach { $0.resume() }
        let final = finalWaiters
        finalWaiters.removeAll()
        final.forEach { $0.resume(returning: text) }
        eventContinuation.yield(.final(text))
        eventContinuation.finish()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func terminate(with error: InterviewASRError) {
        guard state != .finished, state != .cancelled else { return }
        state = .finished
        terminalError = error
        connectionTimeoutTask?.cancel()
        finalTimeoutTask?.cancel()
        sendTask?.cancel()
        connectionTimeoutTask = nil
        finalTimeoutTask = nil
        sendTask = nil
        queuedPackets.removeAll(keepingCapacity: false)
        pendingAudio.removeAll(keepingCapacity: false)
        resumeSendDrainWaiters(throwing: error)

        let connection = connectionWaiters
        connectionWaiters.removeAll()
        connection.forEach { $0.resume(throwing: error) }
        let final = finalWaiters
        finalWaiters.removeAll()
        final.forEach { $0.resume(throwing: error) }
        eventContinuation.yield(error.isRecoverable ? .recoverableError(error) : .fatalError(error))
        eventContinuation.finish()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        receiveTask?.cancel()
        receiveTask = nil
    }

    private func closeWithoutEvent(error: InterviewASRError) {
        guard state != .cancelled else { return }
        state = .cancelled
        terminalError = error
        connectionTimeoutTask?.cancel()
        finalTimeoutTask?.cancel()
        sendTask?.cancel()
        connectionTimeoutTask = nil
        finalTimeoutTask = nil
        sendTask = nil
        queuedPackets.removeAll(keepingCapacity: false)
        pendingAudio.removeAll(keepingCapacity: false)
        resumeSendDrainWaiters(throwing: error)

        let connection = connectionWaiters
        connectionWaiters.removeAll()
        connection.forEach { $0.resume(throwing: error) }
        let final = finalWaiters
        finalWaiters.removeAll()
        final.forEach { $0.resume(throwing: error) }
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        receiveTask?.cancel()
        receiveTask = nil
        eventContinuation.finish()
    }

    private func expireConnection() {
        guard state == .connecting else { return }
        terminate(with: .connectionFailed)
    }

    private func expireFinal() {
        guard state == .finishing else { return }
        terminate(with: .finalTimeout)
    }

    private func transportError(_ error: Error) -> InterviewASRError {
        if let error = error as? InterviewASRError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return state == .cancelled ? .cancelled : .connectionClosed
        }
        // Never surface URLSession's complete NSError because its userInfo may
        // contain the signed request URL and SecretID.
        return .connectionFailed
    }

    private func serviceMessage(_ code: Int) -> String {
        switch code {
        case 4_000: "音频发送速度过快或请求格式异常"
        case 4_001: "请求参数不合法"
        case 4_003: "AppID 尚未开通语音识别服务"
        case 4_004: "腾讯云语音识别资源包已耗尽"
        case 4_005: "腾讯云账户欠费"
        case 4_006: "腾讯云语音识别并发超限"
        case 4_007: "音频解码失败"
        case 4_008: "音频分片等待超时"
        case 4_009: "客户端连接断开"
        case 4_010: "音频数据为空或时长不足"
        case 5_000: "腾讯云语音识别内部错误"
        case 5_001: "腾讯云语音识别引擎繁忙"
        case 5_002: "腾讯云语音识别引擎超时"
        case 6_001: "当前网络区域无法调用该服务"
        default: "服务暂时不可用"
        }
    }
}
