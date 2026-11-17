import AVFAudio

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
