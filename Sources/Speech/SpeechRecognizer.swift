import AVFAudio
import Speech

@MainActor
final class SpeechRecognizer {
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var capturedAudio: BufferedMicrophoneAudio?
    private var generation = UUID()

    static func availableVariants(for language: AppLanguage) async -> [SpeechVariant] {
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
        let currentAnalyzer = SpeechAnalyzer(modules: [transcriber])
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
                                               start: start, end: end, boundaries: boundaries))
                }
                guard !Task.isCancelled, self?.generation == token else { return }
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
}
