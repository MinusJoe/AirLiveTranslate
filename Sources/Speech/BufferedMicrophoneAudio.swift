import AVFAudio
import Speech

/// One tap and one consumer for the whole session. A single FIFO spans model warmup
/// and live input, so switching to recognition cannot duplicate or reorder the opening.
final class BufferedMicrophoneAudio: @unchecked Sendable {
    let format: AVAudioFormat
    private let maxFrames: Int
    private let lock = NSLock()
    private let wake = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var slots: [AVAudioPCMBuffer?]
    private var head = 0
    private var count = 0
    private var frames = 0
    private var acceptedFrames: Int64 = 0
    private var closed = false
    private var inputEnded = false
    private var failure: PipelineError?

    var capturedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(acceptedFrames) / format.sampleRate
    }

    init(format: AVAudioFormat, seconds: Double = 15, byteLimit: Int = 16 * 1024 * 1024, blockLimit: Int = 4096) {
        self.format = format
        let planes = format.isInterleaved ? 1 : Int(format.channelCount)
        let frameBytes = max(1, Int(format.streamDescription.pointee.mBytesPerFrame) * planes)
        maxFrames = min(Int(format.sampleRate * seconds), byteLimit / frameBytes)
        slots = Array(repeating: nil, count: max(1, blockLimit))
    }

    /// Returns a failure only to the first failing tap callback, so it can stop the
    /// session immediately even if analyzer preparation is still suspended.
    func append(_ borrowed: AVAudioPCMBuffer) -> PipelineError? {
        lock.lock()
        guard !closed, !inputEnded else { lock.unlock(); return nil }
        let length = Int(borrowed.frameLength)
        guard length > 0 else { lock.unlock(); return nil }
        let error: PipelineError
        if borrowed.format != format {
            error = .message("麦克风格式已改变，已停止听译。请重新开始。")
        } else if length > maxFrames - frames || count == slots.count {
            error = .message("语音识别未能及时接收音频，内存暂存已满。本次听译已停止，请重试。")
        } else if let owned = PCMUtilities.copy(borrowed) {
            slots[(head + count) % slots.count] = owned
            count += 1
            frames += length
            acceptedFrames += Int64(length)
            lock.unlock()
            wake.continuation.yield(())
            return nil
        } else {
            error = .message("无法暂存开头语音，已停止听译。")
        }
        failure = error
        clearLocked()
        lock.unlock()
        wake.continuation.finish()
        return error
    }

    private func clearLocked() {
        closed = true
        slots.removeAll()
        frames = 0
        count = 0
    }

    func discard() {
        lock.lock()
        clearLocked()
        lock.unlock()
        wake.continuation.finish()
    }

    /// End the producer while allowing the analyzer to read the final queued frames.
    func finishInput() {
        lock.lock()
        inputEnded = true
        lock.unlock()
        wake.continuation.finish()
    }

    private func pop() throws -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        if closed { throw CancellationError() }
        guard count > 0, let next = slots[head] else { return nil }
        slots[head] = nil
        head = (head + 1) % slots.count
        count -= 1
        frames -= Int(next.frameLength)
        return next
    }

    struct Reader {
        fileprivate let queue: BufferedMicrophoneAudio
        fileprivate var signals: AsyncStream<Void>.Iterator

        mutating func next() async throws -> AVAudioPCMBuffer? {
            while true {
                try Task.checkCancellation()
                if let buffer = try queue.pop() { return buffer }
                if await signals.next() == nil {
                    // Report a producer failure even if it occurred between pop and next.
                    return try queue.pop()
                }
            }
        }
    }

    func makeReader() -> Reader {
        Reader(queue: self, signals: wake.stream.makeAsyncIterator())
    }
}

/// SpeechAnalyzer pulls from the FIFO at its consumption rate. In particular, a
/// multi-second opening is not burst-written into a second, smaller input stream.
struct CapturedSpeechInput: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let audio: BufferedMicrophoneAudio
    let format: AVAudioFormat

    struct AsyncIterator: AsyncIteratorProtocol {
        var reader: BufferedMicrophoneAudio.Reader
        let converter: PCMConverter
        private var tail = ArraySlice<AVAudioPCMBuffer>()
        private var reachedEnd = false
        init(reader: BufferedMicrophoneAudio.Reader, converter: PCMConverter) {
            self.reader = reader
            self.converter = converter
        }
        mutating func next() async throws -> AnalyzerInput? {
            while true {
                try Task.checkCancellation()
                if reachedEnd { return tail.popFirst().map { AnalyzerInput(buffer: $0) } }
                guard let buffer = try await reader.next() else {
                    reachedEnd = true
                    tail = ArraySlice(try converter.finish())
                    continue
                }
                if let converted = try converter.convert(buffer) { return AnalyzerInput(buffer: converted) }
            }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(reader: audio.makeReader(), converter: PCMConverter(to: format))
    }
}
