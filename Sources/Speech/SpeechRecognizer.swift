import AVFAudio
import Speech

@MainActor
final class SpeechRecognizer {
    private var analyzer: SpeechAnalyzer?
    private var inputTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var generation = UUID()

    static func availableVariants(for language: AppLanguage) async -> [SpeechVariant] {
        let locales = await SpeechTranscriber.supportedLocales
        return SpeechVariant.supported(for: language, identifiers: locales.map(\.identifier))
    }

    private static func exactLocale(for variant: SpeechVariant) async throws -> Locale {
        let locales = await SpeechTranscriber.supportedLocales
        guard let locale = locales.first(where: { variant.matches($0.identifier) }) else {
            throw PipelineError.message("系统不支持所选地区的语音模型，请选择列表中的可用地区。")
        }
        return locale
    }

    static func installAssets(for variant: SpeechVariant) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw PipelineError.message("这台设备不支持本地 SpeechTranscriber，无法启动此版本的听译。")
        }
        let locale = try await exactLocale(for: variant)
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
    }

    func start(variant: SpeechVariant, lowLatency: Bool,
               onLocale: @escaping @MainActor (String) -> Void,
               audio: @escaping @MainActor () throws -> AsyncThrowingStream<AVAudioPCMBuffer, Error>,
               inputFormat: AVAudioFormat,
               onResult: @escaping @MainActor (RecognitionUpdate) -> Void,
               onError: @escaping @MainActor (Error) -> Void) async throws {
        try Task.checkCancellation()
        await stop()
        try Task.checkCancellation()
        let token = UUID()
        generation = token
        let locale = try await Self.exactLocale(for: variant)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        onLocale(locale.identifier)
        let reporting: Set<SpeechTranscriber.ReportingOption> = lowLatency ? [.volatileResults, .fastResults] : [.volatileResults]
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: reporting, attributeOptions: [.audioTimeRange])
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
                    var offset = 0
                    var boundaries: [TextAudioBoundary] = []
                    for run in result.text.runs {
                        offset += result.text[run.range].characters.count
                        if let range = run.audioTimeRange {
                            boundaries.append(TextAudioBoundary(characterOffset: offset,
                                                                audioEnd: CMTimeGetSeconds(CMTimeRangeGetEnd(range))))
                        }
                    }
                    onResult(RecognitionUpdate(text: String(result.text.characters), isFinal: result.isFinal,
                                               start: start, end: end, boundaries: boundaries))
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
