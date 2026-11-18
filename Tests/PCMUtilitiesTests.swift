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

    func testFragmentedReplayHasContinuousSamplesAtTheOriginalDuration() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let replay = ReplayPCMBuffer(format: format)
        var total = 0
        // Hundreds of short fragments, including an uneven final tail. A per-fragment
        // hardware-played callback would repeatedly stall on a high-latency output.
        for index in 0..<700 {
            let count = [1, 37, 64, 241, 480][index % 5]
            let part = try buffer(channels: 2, frames: AVAudioFrameCount(count))
            let samples = try XCTUnwrap(part.floatChannelData)
            for frame in 0..<count { samples[1][frame] = Float((total + frame) % 127) / 128 }
            try PCMUtilities.isolate(part, side: .right)
            try replay.append(part)
            total += count
        }
        let result = try XCTUnwrap(replay.buffer)
        XCTAssertEqual(Int(result.frameLength), total)
        XCTAssertEqual(result.format, format)
        let samples = try XCTUnwrap(result.floatChannelData)
        for frame in 0..<total {
            guard samples[0][frame] == 0, samples[1][frame] == Float(frame % 127) / 128 else {
                return XCTFail("Gap, repeated sample or incorrect ear at frame \(frame)")
            }
        }
    }

    func testReplayResamplingPreservesSpokenDurationIncludingFinalTail() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = PCMConverter(to: format)
        let replay = ReplayPCMBuffer(format: format)
        for _ in 0..<100 {
            if let part = try converter.convert(buffer(channels: 1, frames: 240, rate: 24_000)) {
                try replay.append(part)
            }
        }
        for tail in try converter.finish() { try replay.append(tail) }
        let result = try XCTUnwrap(replay.buffer)
        XCTAssertEqual(Double(result.frameLength) / result.format.sampleRate, 1.0, accuracy: 0.01)
    }

    func testReplayCapacityAndFormatErrorsDoNotTruncatePreviouslyAcceptedAudio() throws {
        let part = try buffer(channels: 2, frames: 16)
        let replay = ReplayPCMBuffer(format: part.format, byteLimit: 16 * 2 * 4)
        try replay.append(part)
        XCTAssertThrowsError(try replay.append(part))
        XCTAssertThrowsError(try replay.append(buffer(channels: 1)))
        XCTAssertEqual(replay.buffer?.frameLength, 16)
    }

    func testLiveSpeechDoesNotWaitForHeadphonePlaybackBetweenTinyFragments() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pipe = SpeechPCMProducer.Stream.makeStream()
        let producer = SpeechPCMProducer(format: format, side: .right, live: true, continuation: pipe.continuation)
        let first = expectation(description: "First live packet arrives before synthesis finishes")
        let read = Task { () throws -> [SpeechPlaybackPacket] in
            var packets: [SpeechPlaybackPacket] = []
            for try await packet in pipe.stream {
                packets.append(packet)
                if packets.count == 1 { first.fulfill() }
            }
            return packets
        }
        let frames = 48_013
        var offset = 0
        while offset < frames {
            let count = min(31, frames - offset)
            let part = try buffer(channels: 2, frames: AVAudioFrameCount(count))
            let channels = try XCTUnwrap(part.floatChannelData)
            for i in 0..<count { channels[1][i] = Float((offset + i) % 113) / 128 }
            producer.receive(part)
            offset += count
        }
        await fulfillment(of: [first], timeout: 2)
        let end = try buffer(channels: 2, frames: 1)
        end.frameLength = 0
        producer.receive(end)
        let packets = try await read.value
        XCTAssertEqual(packets.count, 13)
        XCTAssertEqual(packets.filter(\.isFinal).count, 1)
        XCTAssertEqual(packets.last?.completionType, .dataPlayedBack)
        XCTAssertTrue(packets.dropLast().allSatisfy { $0.completionType == .dataConsumed && $0.buffer.frameLength == 3840 })
        var index = 0
        for packet in packets {
            let data = try XCTUnwrap(packet.buffer.floatChannelData)
            for frame in 0..<Int(packet.buffer.frameLength) {
                guard data[0][frame] == 0, data[1][frame] == Float(index % 113) / 128 else {
                    return XCTFail("Unexpected gap, sample order or ear in live speech")
                }
                index += 1
            }
        }
        XCTAssertEqual(index, frames)
    }

    func testLivePacketTimingTracksTheActiveRouteAndExactMultipleHasAFinalCallback() async throws {
        for rate: Double in [16_000, 24_000, 44_100, 48_000] {
            let part = try buffer(channels: 1, frames: AVAudioFrameCount(rate * 0.32), rate: rate)
            let pipe = SpeechPCMProducer.Stream.makeStream()
            let producer = SpeechPCMProducer(format: part.format, side: .both, live: true, continuation: pipe.continuation)
            producer.receive(part)
            part.frameLength = 0
            producer.receive(part)
            var flags: [Bool] = []
            for try await packet in pipe.stream {
                XCTAssertEqual(Double(packet.buffer.frameLength) / rate, 0.080, accuracy: 0.00001)
                flags.append(packet.isFinal)
            }
            XCTAssertEqual(flags, [false, false, false, true])
        }
    }

    func testShortLiveSpeechAndManualReplayIncludeResampledTailAndFinishOnce() async throws {
        for live in [true, false] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let pipe = SpeechPCMProducer.Stream.makeStream()
            let producer = SpeechPCMProducer(format: format, side: .both, live: live, continuation: pipe.continuation)
            let count = live ? 6 : 100
            let part = try buffer(channels: 1, frames: 240, rate: 24_000)
            for _ in 0..<count { producer.receive(part) }
            part.frameLength = 0
            producer.receive(part)
            producer.receive(part)
            var packets: [SpeechPlaybackPacket] = []
            for try await packet in pipe.stream { packets.append(packet) }
            XCTAssertEqual(packets.count, 1)
            let last = try XCTUnwrap(packets.last)
            XCTAssertEqual(last.completionType, .dataPlayedBack)
            XCTAssertEqual(Double(last.buffer.frameLength) / format.sampleRate, Double(count) * 0.01, accuracy: 0.005)
        }
    }
}
#endif
