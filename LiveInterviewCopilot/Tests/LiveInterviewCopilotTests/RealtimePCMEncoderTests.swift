import AVFoundation
import XCTest
@testable import LiveInterviewCopilotKit

final class RealtimePCMEncoderTests: XCTestCase {
    func testEncodesMonoPCM16At24kHz() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        for index in 0..<4_800 {
            buffer.floatChannelData?[0][index] = sin(Float(index) * 0.05) * 0.1
        }

        let chunk = try XCTUnwrap(RealtimePCMEncoder.encode(buffer))
        XCTAssertEqual(chunk.pcm16.count, 4_800, accuracy: 4)
        XCTAssertEqual(chunk.duration, 0.1, accuracy: 0.002)
        XCTAssertGreaterThan(chunk.rms, 0.01)
    }
}
