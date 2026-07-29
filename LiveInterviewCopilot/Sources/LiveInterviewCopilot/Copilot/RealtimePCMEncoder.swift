import AVFoundation
import Accelerate
import Foundation

struct RealtimeAudioChunk: Sendable {
    let pcm16: Data
    let duration: TimeInterval
    let rms: Float
}

enum RealtimePCMEncoder {
    static let targetSampleRate = 24_000.0

    static func encode(_ buffer: AVAudioPCMBuffer) -> RealtimeAudioChunk? {
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
        } else { return nil }

        var rms: Float = 0
        vDSP_rmsqv(mono, 1, &rms, vDSP_Length(mono.count))
        let outputCount = max(1, Int((Double(frameCount) * targetSampleRate / sourceRate).rounded()))
        var resampled = [Float](repeating: 0, count: outputCount)
        if outputCount == frameCount {
            resampled = mono
        } else {
            let scale = Double(frameCount - 1) / Double(max(1, outputCount - 1))
            for index in 0..<outputCount {
                let source = Double(index) * scale
                let lower = min(frameCount - 1, Int(source))
                let upper = min(frameCount - 1, lower + 1)
                let fraction = Float(source - Double(lower))
                resampled[index] = mono[lower] + (mono[upper] - mono[lower]) * fraction
            }
        }

        var data = Data(capacity: outputCount * 2)
        for sample in resampled {
            var value = Int16(clamping: Int((max(-1, min(1, sample)) * Float(Int16.max)).rounded())).littleEndian
            Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return RealtimeAudioChunk(
            pcm16: data,
            duration: Double(outputCount) / targetSampleRate,
            rms: rms
        )
    }
}
