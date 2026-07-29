import AVFoundation
import Accelerate
import Foundation

/// Selects the audio path independently from the text generation provider.
enum InterviewAudioMode: String, Codable, CaseIterable, Sendable {
    case manualStreamingASR
    case openAIRealtimeExperimental

    var label: String {
        switch self {
        case .manualStreamingASR: "手动分轮（腾讯流式 ASR）"
        case .openAIRealtimeExperimental: "GPT Realtime（实验）"
        }
    }
}

enum InterviewASRProvider: String, Codable, CaseIterable, Sendable {
    case tencentStreaming
    case qwenLocalFallback

    var label: String {
        switch self {
        case .tencentStreaming: "腾讯云实时 ASR"
        case .qwenLocalFallback: "Qwen 本地慢速兜底"
        }
    }
}

enum InterviewRole: String, Codable, CaseIterable, Sendable {
    case interviewer
    case candidate

    var label: String { self == .interviewer ? "面试官" : "候选人" }
}

/// Normalized interview audio. All streaming providers receive 16 kHz mono
/// PCM16, while the Float32 copy can be retained in memory for local fallback.
struct InterviewAudioChunk: Sendable, Equatable {
    static let targetSampleRate = 16_000

    let pcm16: Data
    let samples: [Float]
    let sampleRate: Int
    let duration: TimeInterval
    let rms: Float

    init(
        pcm16: Data,
        samples: [Float],
        sampleRate: Int = targetSampleRate,
        duration: TimeInterval? = nil,
        rms: Float? = nil
    ) {
        self.pcm16 = pcm16
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = duration ?? (sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0)
        if let rms {
            self.rms = rms
        } else if samples.isEmpty {
            self.rms = 0
        } else {
            var value: Float = 0
            vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
            self.rms = value
        }
    }

    static func pcm16(_ data: Data, sampleRate: Int = targetSampleRate) -> InterviewAudioChunk {
        let evenCount = data.count - (data.count % 2)
        var samples = [Float]()
        samples.reserveCapacity(evenCount / 2)
        data.withUnsafeBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for offset in stride(from: 0, to: evenCount, by: 2) {
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                let value = Int16(bitPattern: bits)
                samples.append(value < 0 ? Float(value) / 32_768 : Float(value) / 32_767)
            }
        }
        return InterviewAudioChunk(
            pcm16: Data(data.prefix(evenCount)),
            samples: samples,
            sampleRate: sampleRate
        )
    }
}

/// Converts either system or microphone buffers to the one wire format used by
/// Tencent and the Qwen whole-turn fallback.
enum InterviewPCMEncoder {
    static let targetSampleRate = Double(InterviewAudioChunk.targetSampleRate)

    static func encode(_ buffer: AVAudioPCMBuffer) -> InterviewAudioChunk? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let sourceRate = buffer.format.sampleRate
        guard frameCount > 0, channelCount > 0, sourceRate > 0 else { return nil }

        var mono = [Float](repeating: 0, count: frameCount)
        if let channels = buffer.floatChannelData {
            for channel in 0..<channelCount {
                vDSP_vadd(mono, 1, channels[channel], 1, &mono, 1, vDSP_Length(frameCount))
            }
            var divisor = Float(channelCount)
            vDSP_vsdiv(mono, 1, &divisor, &mono, 1, vDSP_Length(frameCount))
        } else if let channels = buffer.int16ChannelData {
            let scale = 1 / Float(Int16.max)
            for index in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += Float(channels[channel][index]) * scale }
                mono[index] = sum / Float(channelCount)
            }
        } else {
            return nil
        }

        let outputCount = max(1, Int((Double(frameCount) * targetSampleRate / sourceRate).rounded()))
        let resampled: [Float]
        if outputCount == frameCount {
            resampled = mono
        } else {
            var output = [Float](repeating: 0, count: outputCount)
            let scale = Double(frameCount - 1) / Double(max(1, outputCount - 1))
            for index in 0..<outputCount {
                let source = Double(index) * scale
                let lower = min(frameCount - 1, Int(source))
                let upper = min(frameCount - 1, lower + 1)
                let fraction = Float(source - Double(lower))
                output[index] = mono[lower] + (mono[upper] - mono[lower]) * fraction
            }
            resampled = output
        }

        var rms: Float = 0
        vDSP_rmsqv(resampled, 1, &rms, vDSP_Length(resampled.count))
        var pcm16 = Data(capacity: resampled.count * 2)
        for sample in resampled {
            var value = Int16(
                clamping: Int((Swift.max(-1, Swift.min(1, sample)) * Float(Int16.max)).rounded())
            ).littleEndian
            Swift.withUnsafeBytes(of: &value) { pcm16.append(contentsOf: $0) }
        }

        return InterviewAudioChunk(
            pcm16: pcm16,
            samples: resampled,
            duration: Double(resampled.count) / targetSampleRate,
            rms: rms
        )
    }
}

enum InterviewASRError: LocalizedError, Equatable, Sendable {
    case missingCredentials
    case invalidConfiguration(String)
    case invalidAudio(String)
    case connectionFailed
    case authenticationFailed
    case serviceError(code: Int, message: String)
    case finalTimeout
    case invalidResponse
    case connectionClosed
    case localRuntimeUnavailable(String)
    case cancelled

    var isRecoverable: Bool {
        switch self {
        case .connectionFailed, .finalTimeout, .connectionClosed, .localRuntimeUnavailable:
            true
        case .serviceError(let code, _):
            code == 4008 || code == 4009 || (5_000...5_002).contains(code)
        default:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "请先配置腾讯云 AppID、SecretID 和 SecretKey。"
        case .invalidConfiguration(let message): "腾讯云 ASR 配置无效：\(message)"
        case .invalidAudio(let message): "音频格式无效：\(message)"
        case .connectionFailed: "无法连接腾讯云实时 ASR。"
        case .authenticationFailed: "腾讯云 ASR 鉴权失败，请检查 AppID 和密钥。"
        case .serviceError(let code, let message): "腾讯云 ASR 错误 \(code)：\(message)"
        case .finalTimeout: "腾讯云 ASR 在 2 秒内没有返回最终转写。"
        case .invalidResponse: "腾讯云 ASR 返回了无法解析的消息。"
        case .connectionClosed: "腾讯云 ASR 连接提前关闭。"
        case .localRuntimeUnavailable(let message): "Qwen 本地慢速兜底不可用：\(message)"
        case .cancelled: "本次语音识别已取消。"
        }
    }
}

enum InterviewASREvent: Equatable, Sendable {
    case connected
    case partial(String)
    case final(String)
    case recoverableError(InterviewASRError)
    case fatalError(InterviewASRError)
}

/// A segment-scoped streaming recognizer. Create a fresh session for each
/// interviewer or candidate turn because Tencent voice IDs cannot be reused.
protocol StreamingInterviewASRSession: Sendable {
    var events: AsyncStream<InterviewASREvent> { get }

    func connect() async throws
    func appendAudio(_ chunk: InterviewAudioChunk) async throws
    func finishSegment(timeout: Duration) async throws -> String
    func cancel() async
    func disconnect() async
}

extension StreamingInterviewASRSession {
    func appendAudio(_ pcm16: Data) async throws {
        try await appendAudio(.pcm16(pcm16))
    }

    func finishSegment() async throws -> String {
        try await finishSegment(timeout: .seconds(2))
    }
}
