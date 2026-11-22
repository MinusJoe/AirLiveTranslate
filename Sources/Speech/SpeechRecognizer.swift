import AVFAudio
import Speech

@MainActor
final class SpeechRecognizer {
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var capturedAudio: BufferedMicrophoneAudio?
    private var generation = UUID()

    static func availableVariants(for language: AppLanguage) async -> [SpeechVariant] {
        guard SpeechTranscriber.isAvailable else { return [] }
        let locales = await SpeechTranscriber.supportedLocales
        return SpeechVariant.supported(for: language, identifiers: locales.map(\.identifier))
    }

    static func hasInstalledAssets(for variant: SpeechVariant) async -> Bool {
        let locales = await SpeechTranscriber.installedLocales
        return SpeechTranscriber.isAvailable && locales.contains { variant.matches($0.identifier) }
    }

    private static func exactLocale(for variant: SpeechVariant) async throws -> Locale {
        let locales = await SpeechTranscriber.supportedLocales
        guard let locale = locales.first(where: { variant.matches($0.identifier) }) else {
            throw PipelineError.message("系统不支持所选地区的语音模型，请选择列表中的可用地区。")
        }
        return locale
    }

    static func installAssets(for variant: SpeechVariant,
                              progress: @escaping @MainActor (Double?) -> Void = { _ in }) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw PipelineError.message("这台设备不支持本地 SpeechTranscriber，无法启动此版本的听译。")
        }
        let locale = try await exactLocale(for: variant)
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let observer = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
                let fraction = value.totalUnitCount > 0 ? value.fractionCompleted : nil
                Task { @MainActor in progress(fraction) }
            }
            defer { observer.invalidate() }
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
    }

    func start(variant: SpeechVariant, lowLatency: Bool, finiteTurn: Bool = false,
               onLocale: @escaping @MainActor (String) -> Void,
               audio: BufferedMicrophoneAudio,
               onResult: @escaping @MainActor (RecognitionUpdate) -> Void,
               onError: @escaping @MainActor (Error) -> Void) async throws {
        try Task.checkCancellation()
        await stop()
        try Task.checkCancellation()
        let token = UUID()
        generation = token
        capturedAudio = audio
        let locale = try await Self.exactLocale(for: variant)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        onLocale(locale.identifier)
        let reporting: Set<SpeechTranscriber.ReportingOption> = lowLatency ? [.volatileResults, .fastResults] : [.volatileResults]
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: reporting, attributeOptions: [.audioTimeRange])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: audio.format) else {
            throw PipelineError.message("本地语音模型尚未就绪，请先准备语言资源。")
        }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let options: SpeechAnalyzer.Options? = lowLatency ? .init(priority: .userInitiated, modelRetention: .lingering) : nil
        let currentAnalyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        analyzer = currentAnalyzer
        try await currentAnalyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }

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
                                               start: start, end: end, boundaries: boundaries, capturedSeconds: audio.capturedSeconds))
                }
                guard !Task.isCancelled, self?.generation == token, !finiteTurn else { return }
                onError(PipelineError.message("语音分析已结束，请重新开始听译。"))
            } catch {
                guard !Task.isCancelled, self?.generation == token else { return }
                onError(error)
            }
        }

        try await currentAnalyzer.start(inputSequence: CapturedSpeechInput(audio: audio, format: format))
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    func stop() async {
        generation = UUID()
        resultsTask?.cancel()
        capturedAudio?.discard()
        capturedAudio = nil
        resultsTask = nil
        let previous = analyzer
        analyzer = nil
        await previous?.cancelAndFinishNow()
    }

    func finishTurn() async throws {
        guard let analyzer else { throw PipelineError.message("语音识别尚未就绪。") }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        try Task.checkCancellation()
    }
}
