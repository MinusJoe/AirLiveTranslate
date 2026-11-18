import AVFAudio

/// Contiguous planar Float32 samples in the actual player format, including the resampler tail.
final class ReplayPCMBuffer {
    let format: AVAudioFormat
    private let maxFrames: Int
    private(set) var buffer: AVAudioPCMBuffer?

    init(format: AVAudioFormat, byteLimit: Int = 32 * 1024 * 1024) {
        self.format = format
        maxFrames = max(0, byteLimit) / (max(1, Int(format.channelCount)) * MemoryLayout<Float>.stride)
    }

    func append(_ input: AVAudioPCMBuffer) throws {
        guard input.format == format, !format.isInterleaved, format.commonFormat == .pcmFormatFloat32,
              let source = input.floatChannelData else {
            throw PipelineError.message("补听音频格式已改变，请重新播放。")
        }
        let count = Int(input.frameLength)
        guard count > 0 else { return }
        let used = Int(buffer?.frameLength ?? 0)
        let needed = used + count
        guard needed <= maxFrames else { throw PipelineError.message("此段合成音频过长，无法完整补听。") }
        let capacity = Int(buffer?.frameCapacity ?? 0)
        if needed > capacity {
            let nextSize = min(maxFrames, max(needed, max(4096, capacity * 2)))
            guard let next = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(nextSize)),
                  let destination = next.floatChannelData else {
                throw PipelineError.message("补听音频缓冲区分配失败。")
            }
            if let previous = buffer?.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    destination[channel].update(from: previous[channel], count: used)
                }
            }
            buffer = next
        }
        guard let buffer, let destination = buffer.floatChannelData else {
            throw PipelineError.message("补听音频缓冲区不可用。")
        }
        for channel in 0..<Int(format.channelCount) {
            destination[channel].advanced(by: used).update(from: source[channel], count: count)
        }
        buffer.frameLength = AVAudioFrameCount(needed)
    }
}

enum PCMUtilities {
    /// Audio taps reuse their buffer after the callback returns. Never enqueue the borrowed buffer.
    static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            return nil
        }
        destination.frameLength = source.frameLength
        let input = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let output = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard input.count == output.count else { return nil }
        for index in input.indices {
            guard let from = input[index].mData, let to = output[index].mData else { return nil }
            memcpy(to, from, min(Int(input[index].mDataByteSize), Int(output[index].mDataByteSize)))
        }
        return destination
    }

    static func isolate(_ buffer: AVAudioPCMBuffer, side: OutputSide) throws {
        guard side != .both else { return }
        guard buffer.format.channelCount == 2, let channels = buffer.floatChannelData,
              !buffer.format.isInterleaved else {
            throw PipelineError.message("当前播放格式不能隔离左右声道，已停止播放。")
        }
        // The converter has already upmixed mono TTS to stereo. Silence only the unwanted ear.
        let muted = side == .left ? 1 : 0
        channels[muted].initialize(repeating: 0, count: Int(buffer.frameLength))
    }
}

final class PCMConverter {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let destinationFormat: AVAudioFormat

    init(to format: AVAudioFormat) { destinationFormat = format }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        if input.format == destinationFormat { return PCMUtilities.copy(input) }
        if sourceFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: destinationFormat)
            sourceFormat = input.format
        }
        guard let converter else { throw PipelineError.message("无法转换当前音频格式。") }
        let ratio = destinationFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: capacity) else {
            throw PipelineError.message("音频缓冲区分配失败。")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard status != .error else { throw PipelineError.message("音频转换失败。") }
        return output.frameLength > 0 ? output : nil
    }

    func finish() throws -> [AVAudioPCMBuffer] {
        guard let converter else { return [] }
        var buffers: [AVAudioPCMBuffer] = []
        for _ in 0..<16 {
            guard let output = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: 4096) else {
                throw PipelineError.message("音频缓冲区分配失败。")
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            guard status != .error else { throw PipelineError.message("音频尾部转换失败。") }
            if output.frameLength > 0 { buffers.append(output) }
            if status == .endOfStream || output.frameLength == 0 { return buffers }
        }
        throw PipelineError.message("音频转换未能正常结束。")
    }
}
