import AVFAudio
import Speech

@MainActor
final class SpeechRecognizer {
    private var analyzer: SpeechAnalyzer?
    private var inputTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var generation = UUID()

    static func installAssets(for language: AppLanguage) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw PipelineError.message("这台设备不支持本地 SpeechTranscriber，无法启动此版本的听译。")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language.speechLocale)) else {
            throw PipelineError.message("此设备不支持所选语言的本地语音识别。")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
    }

    func start(language: AppLanguage,
               audio: @escaping @MainActor () throws -> AsyncThrowingStream<AVAudioPCMBuffer, Error>,
               inputFormat: AVAudioFormat,
               onResult: @escaping @MainActor (String, Bool, Double, Double) -> Void,
               onError: @escaping @MainActor (Error) -> Void) async throws {
        try Task.checkCancellation()
        await stop()
        try Task.checkCancellation()
        let token = UUID()
        generation = token
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language.speechLocale)) else {
            throw PipelineError.message("所选语音识别语言不可用。")
        }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: inputFormat) else {
            throw PipelineError.message("本地语音模型尚未就绪，请先准备语言资源。")
        }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let currentAnalyzer = SpeechAnalyzer(modules: [transcriber])
        analyzer = currentAnalyzer
        try await currentAnalyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }

        let pair = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        continuation = pair.continuation
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    guard self?.generation == token else { return }
                    let start = CMTimeGetSeconds(result.range.start)
                    let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                    onResult(String(result.text.characters), result.isFinal, start, end)
                }
                guard !Task.isCancelled, self?.generation == token else { return }
                onError(PipelineError.message("语音分析已结束，请重新开始听译。"))
            } catch {
                guard !Task.isCancelled, self?.generation == token else { return }
                onError(error)
            }
        }

        try await currentAnalyzer.start(inputSequence: pair.stream)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        // Only start the hardware after model preparation, so cold starts cannot overflow capture.
        let audioStream = try audio()
        inputTask = Task { [weak self] in
            let converter = PCMConverter(to: format)
            do {
                for try await buffer in audioStream {
                    try Task.checkCancellation()
                    guard self?.generation == token else { return }
                    if let converted = try converter.convert(buffer) {
                        switch pair.continuation.yield(AnalyzerInput(buffer: converted)) {
                        case .dropped:
                            throw PipelineError.message("语音分析跟不上收音速度，已暂停，避免丢失音频。")
                        case .terminated: return
                        case .enqueued: break
                        @unknown default: break
                        }
                    }
                }
                try Task.checkCancellation()
                guard self?.generation == token else { return }
                for tail in try converter.finish() {
                    if case .dropped = pair.continuation.yield(AnalyzerInput(buffer: tail)) {
                        throw PipelineError.message("语音分析尾部积压，已停止。")
                    }
                }
                pair.continuation.finish()
                try await currentAnalyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                pair.continuation.finish(throwing: error)
                guard !Task.isCancelled, self?.generation == token else { return }
                onError(error)
            }
        }
    }

    func stop() async {
        generation = UUID()
        inputTask?.cancel()
        resultsTask?.cancel()
        continuation?.finish()
        continuation = nil
        inputTask = nil
        resultsTask = nil
        let previous = analyzer
        analyzer = nil
        await previous?.cancelAndFinishNow()
    }
}
