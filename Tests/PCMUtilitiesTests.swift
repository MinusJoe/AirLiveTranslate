#if os(iOS)
import AVFAudio
import XCTest
@testable import AirPodsTranslator

final class PCMUtilitiesTests: XCTestCase {
    private func buffer(channels: AVAudioChannelCount = 2, frames: AVAudioFrameCount = 256,
                        rate: Double = 48_000) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let value = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        value.frameLength = frames
        let data = try XCTUnwrap(value.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                data[channel][frame] = Float(channel + 1) * 0.2
            }
        }
        return value
    }

    func testLeftPlaybackZerosOnlyRightChannel() throws {
        let audio = try buffer()
        try PCMUtilities.isolate(audio, side: .left)
        let channels = try XCTUnwrap(audio.floatChannelData)
        for frame in 0..<Int(audio.frameLength) {
            XCTAssertEqual(channels[0][frame], 0.2, accuracy: 0.0001)
            XCTAssertEqual(channels[1][frame], 0)
        }
    }

    func testRightPlaybackZerosOnlyLeftChannel() throws {
        let audio = try buffer()
        try PCMUtilities.isolate(audio, side: .right)
        let channels = try XCTUnwrap(audio.floatChannelData)
        for frame in 0..<Int(audio.frameLength) {
            XCTAssertEqual(channels[0][frame], 0)
            XCTAssertEqual(channels[1][frame], 0.4, accuracy: 0.0001)
        }
    }

    func testBothPreservesSignalAndMonoRejectsSingleEar() throws {
        let stereo = try buffer()
        try PCMUtilities.isolate(stereo, side: .both)
        XCTAssertEqual(try XCTUnwrap(stereo.floatChannelData)[1][0], 0.4, accuracy: 0.0001)
        let mono = try buffer(channels: 1)
        XCTAssertThrowsError(try PCMUtilities.isolate(mono, side: .left))
        XCTAssertThrowsError(try PCMUtilities.isolate(mono, side: .right))
        XCTAssertNoThrow(try PCMUtilities.isolate(mono, side: .both))
    }

    func testCopiedTapBufferSurvivesSourceReuse() throws {
        let source = try buffer()
        let copied = try XCTUnwrap(PCMUtilities.copy(source))
        try PCMUtilities.isolate(source, side: .left)
        XCTAssertEqual(copied.frameLength, source.frameLength)
        XCTAssertEqual(try XCTUnwrap(copied.floatChannelData)[1][0], 0.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(source.floatChannelData)[1][0], 0)
    }

    func testConverterProducesFiniteResampledAudioAndFinishes() throws {
        let target = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = PCMConverter(to: target)
        var results: [AVAudioPCMBuffer] = []
        for _ in 0..<10 {
            if let result = try converter.convert(buffer(channels: 1, frames: 480)) {
                results.append(result)
            }
        }
        results.append(contentsOf: try converter.finish())
        XCTAssertFalse(results.isEmpty)
        let frames = results.reduce(0) { $0 + Int($1.frameLength) }
        // 4,800 frames at 48 kHz are 1,600 at 16 kHz. Allow filter priming,
        // while detecting lost chunks or a missing converter tail.
        XCTAssertTrue((1500...1700).contains(frames), "Unexpected resampled length: \(frames)")
        for result in results {
            XCTAssertEqual(result.format.sampleRate, 16_000)
            XCTAssertEqual(result.format.channelCount, 1)
            let data = try XCTUnwrap(result.floatChannelData)
            for frame in 0..<Int(result.frameLength) {
                XCTAssertTrue(data[0][frame].isFinite)
            }
        }
    }

    func testMonoSpeechUpmixRetainsTheSelectedEar() throws {
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let converter = PCMConverter(to: stereo)
        var buffers: [AVAudioPCMBuffer] = []
        if let converted = try converter.convert(buffer(channels: 1, frames: 2048)) {
            buffers.append(converted)
        }
        buffers.append(contentsOf: try converter.finish())
        XCTAssertFalse(buffers.isEmpty)
        var targetPeak: Float = 0
        for converted in buffers {
            try PCMUtilities.isolate(converted, side: .right)
            let channels = try XCTUnwrap(converted.floatChannelData)
            for frame in 0..<Int(converted.frameLength) {
                XCTAssertEqual(channels[0][frame], 0)
                targetPeak = max(targetPeak, abs(channels[1][frame]))
            }
        }
        XCTAssertGreaterThan(targetPeak, 0.01, "Upmix must not silence the desired ear")
    }
}
#endif
