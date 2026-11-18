#if os(iOS)
import AVFAudio
import Speech
import XCTest
@testable import AirPodsTranslator

final class BufferedMicrophoneTests: XCTestCase {
    private func block(_ format: AVAudioFormat, frames: Int = 1024) throws -> AVAudioPCMBuffer {
        let b = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        b.frameLength = b.frameCapacity
        return b
    }

    func testDelayedAnalyzerConsumesTheOpeningAndConcurrentLiveSpeechInOrder() async throws {
        let fmt = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let queue = BufferedMicrophoneAudio(format: fmt)
        let reused = try block(fmt)
        let samples = try XCTUnwrap(reused.floatChannelData)[0]
        func capture(_ n: Int) {
            for i in 0..<1024 { samples[i] = Float(n) }
            XCTAssertNil(queue.append(reused))
        }
        // Simulate four seconds of model preparation, including reuse of the tap's memory.
        for n in 0..<192 { capture(n) }
        XCTAssertEqual(queue.capturedSeconds, 192 * 1024.0 / 48_000, accuracy: 0.000001)
        var feed = CapturedSpeechInput(audio: queue, format: fmt).makeAsyncIterator()
        for expected in 0..<224 {
            if expected < 32 { capture(192 + expected) }
            let input = try await feed.next()
            let b = try XCTUnwrap(input).buffer
            XCTAssertEqual(b.frameLength, 1024)
            XCTAssertEqual(b.floatChannelData?[0][0], Float(expected))
            XCTAssertEqual(b.floatChannelData?[0][1023], Float(expected))
        }
        XCTAssertEqual(queue.capturedSeconds, 224 * 1024.0 / 48_000, accuracy: 0.000001)
        queue.discard()
    }

    func testDequeuingFreesBudgetAcrossRingWrap() async throws {
        let fmt = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let q = BufferedMicrophoneAudio(format: fmt, blockLimit: 2)
        let b = try block(fmt, frames: 1)
        var reader = q.makeReader()
        for i in 0..<10 {
            b.floatChannelData?[0][0] = Float(i)
            XCTAssertNil(q.append(b))
            let result = try await reader.next()
            XCTAssertEqual(result.floatChannelData?[0][0], Float(i))
        }
        q.discard()
    }

    func testOverrunIsExplicitForTimeByteAndBlockBounds() async throws {
        let fmt = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let b = try block(fmt, frames: 16)
        for q in [BufferedMicrophoneAudio(format: fmt, seconds: 0.001),
                  BufferedMicrophoneAudio(format: fmt, byteLimit: 64),
                  BufferedMicrophoneAudio(format: fmt, blockLimit: 1)] {
            XCTAssertNil(q.append(b))
            XCTAssertNotNil(q.append(b))
            XCTAssertNil(q.append(b), "Only the first failing callback should signal the UI")
            var reader = q.makeReader()
            do { _ = try await reader.next(); XCTFail("Overrun must not return a misleading partial opening") }
            catch is PipelineError {}
        }
    }

    func testStopClearsUnconsumedAudioAndWakesWaitingConsumer() async throws {
        let fmt = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let q = BufferedMicrophoneAudio(format: fmt)
        let waiting = expectation(description: "Consumer exits when capture is stopped")
        let task = Task {
            var reader = q.makeReader()
            do { _ = try await reader.next(); XCTFail("Unexpected audio after stop") }
            catch is CancellationError {}
            catch { XCTFail("Unexpected error: \(error)") }
            waiting.fulfill()
        }
        await Task.yield()
        q.discard()
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        let other = BufferedMicrophoneAudio(format: fmt)
        let b = try block(fmt)
        XCTAssertNil(other.append(b))
        other.discard()
        XCTAssertNil(other.append(b))
        var reader = other.makeReader()
        do { _ = try await reader.next(); XCTFail("Cancelled warmup leaked audio") }
        catch is CancellationError {}
    }
}
#endif
