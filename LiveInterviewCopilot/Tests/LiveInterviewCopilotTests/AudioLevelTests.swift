import AVFoundation
import XCTest
@testable import LiveInterviewCopilotKit

final class AudioLevelTests: XCTestCase {
    func testNormalizedRMSReadsFloat32Buffers() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        buffer.frameLength = 4
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<4 {
            samples[index] = index.isMultiple(of: 2) ? 0.5 : -0.5
        }

        XCTAssertEqual(MicCapture.normalizedRMS(from: buffer), 0.5, accuracy: 0.001)
    }

    func testNormalizedRMSReadsInt16Buffers() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        buffer.frameLength = 4
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        let amplitude = Int16.max / 2
        for index in 0..<4 {
            samples[index] = index.isMultiple(of: 2) ? amplitude : -amplitude
        }

        XCTAssertEqual(MicCapture.normalizedRMS(from: buffer), 0.5, accuracy: 0.002)
    }

    func testNormalizedRMSCombinesNonInterleavedInt16Channels() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 2,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        buffer.frameLength = 4
        let channels = try XCTUnwrap(buffer.int16ChannelData)
        let amplitude = Int16.max / 2
        for index in 0..<4 {
            channels[0][index] = 0
            channels[1][index] = index.isMultiple(of: 2) ? amplitude : -amplitude
        }

        XCTAssertEqual(
            MicCapture.normalizedRMS(from: buffer),
            sqrt(Float(0.125)),
            accuracy: 0.002
        )
    }

    func testNormalizedRMSReadsAllInterleavedInt32Samples() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt32,
                sampleRate: 16_000,
                channels: 2,
                interleaved: true
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        buffer.frameLength = 4
        let samples = try XCTUnwrap(buffer.int32ChannelData?[0])
        let amplitude = Int32.max / 2
        for frame in 0..<4 {
            samples[frame * 2] = 0
            samples[frame * 2 + 1] = frame.isMultiple(of: 2) ? amplitude : -amplitude
        }

        XCTAssertEqual(
            MicCapture.normalizedRMS(from: buffer),
            sqrt(Float(0.125)),
            accuracy: 0.002
        )
    }
}
