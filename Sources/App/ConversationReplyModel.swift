import AVFAudio
import SwiftUI
import Translation

@MainActor
final class ConversationReplyModel: ObservableObject {
    enum Phase { case idle, preparing, connecting, recording, finishing, translating, playing }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var original = ""
    @Published private(set) var translated = ""
    @Published private(set) var message = ""
    @Published var configuration: TranslationSession.Configuration?
    private(set) var language: AppLanguage = .english
    private var chineseVariant: SpeechVariant = .chineseMainland
    private let audio = AudioController()
    private var speech: SpeechRecognizer?
    private var startup: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var turn = ConversationTurn()
    private var translator: TranslationSession?
    private var speakingRate: Float = 0.5
    private var onStopped: (@MainActor () -> Void)?
    private var onPlayed: (@MainActor () -> Void)?
    private var installed: InstalledResources?
    private var probe: (language: AppLanguage, variant: SpeechVariant, task: Task<Void, Never>)?

    struct InstalledResources {
        let language: AppLanguage
        let variant: SpeechVariant
        let checkedAt: TimeInterval

        init(language: AppLanguage, variant: SpeechVariant, checkedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            self.language = language
            self.variant = variant
            self.checkedAt = checkedAt
        }

        func matches(_ language: AppLanguage, _ variant: SpeechVariant,
                     now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
            let age = now - checkedAt
            return self.language == language && self.variant == variant && age >= 0 && age < 60
        }
    }

    /// Visiting the page can populate this short-lived cache. A probe never
    /// requests permission, installs assets, activates audio or changes phase.
    func warmResources(language: AppLanguage, variant: SpeechVariant) {
        guard installed?.matches(language, variant) != true else { return }
        if let probe, probe.language == language, probe.variant == variant { return }
        invalidateResourceCheck()
        guard language != .chinese, variant.language == .chinese else { return }
        let task = Task { [weak self] in
            let status = await Self.resourceStatus(language: language, variant: variant)
            guard !Task.isCancelled, let self else { return }
            if status == .installed { installed = InstalledResources(language: language, variant: variant) }
            probe = nil
        }
        probe = (language, variant, task)
    }

    private func invalidateResourceCheck() {
        probe?.task.cancel()
        probe = nil
        installed = nil
    }

    private static func resourceStatus(language: AppLanguage, variant: SpeechVariant) async -> LanguageAvailability.Status {
        let from = Locale.Language(identifier: AppLanguage.chinese.rawValue)
        let to = Locale.Language(identifier: language.rawValue)
        async let speechReady = SpeechRecognizer.hasInstalledAssets(for: variant)
        let translation = await LanguageAvailability().status(from: from, to: to)
        let hasSpeech = await speechReady
        return translation == .installed && !hasSpeech ? .supported : translation
    }

    func start(language: AppLanguage, variant: SpeechVariant, source: CaptureSource,
               rate: Float, onStopped: @escaping @MainActor () -> Void = {},
               onPlayed: @escaping @MainActor () -> Void) {
        guard phase == .idle, language != .chinese else { onStopped(); return }
        cancel()
        let token = generation
        self.language = language
        speakingRate = rate
        self.onStopped = onStopped
        self.onPlayed = onPlayed
        chineseVariant = variant
        original = ""
        translated = ""
        turn = ConversationTurn()
        phase = .connecting
        message = "正在检查中文识别和翻译资源…"
        let recognizer = SpeechRecognizer()
        speech = recognizer
        if let probe, probe.language != language || probe.variant != variant { invalidateResourceCheck() }
        startup = Task {
            do {
                try Task.checkCancellation()
                let from = Locale.Language(identifier: AppLanguage.chinese.rawValue)
                let to = Locale.Language(identifier: language.rawValue)
                if let probe { await probe.task.value }
                try Task.checkCancellation()
                let availability: LanguageAvailability.Status
                let reused = installed?.matches(language, variant) == true
                if reused {
                    availability = .installed
                } else {
                    availability = await Self.resourceStatus(language: language, variant: variant)
                }
                guard generation == token else { return }
                guard availability != .unsupported else { throw PipelineError.message("此设备不支持这个翻译方向。") }
                if availability != .installed {
                    invalidateResourceCheck()
                    phase = .preparing
                    message = "正在准备本次对话需要的语言资源…"
                    configuration = .init(source: from, target: to)
                    return
                }
                if !reused { installed = InstalledResources(language: language, variant: variant) }
                let permitted = await AudioController.requestPermission()
                guard generation == token else { return }
                guard permitted else { throw PipelineError.message("请在系统设置中允许使用麦克风。") }
                _ = try await audio.configure(source: source, farField: false)
                try Task.checkCancellation()
                guard generation == token else { return }
                let capture = try audio.start(side: .both, onLevel: { _ in }, onRouteFailure: { [weak self] reason in
                    self?.stop(with: reason, token: token)
                })
                phase = .recording
                message = "可以说中文，松开后将翻译并用手机播给对方。"
                try await recognizer.start(variant: variant, lowLatency: true, finiteTurn: true, onLocale: { _ in },
                                           audio: capture, onResult: { [weak self] event in
                    guard let self, self.generation == token else { return }
                    do {
                        try self.turn.receive(event)
                        self.original = self.turn.displayed
                    } catch { self.stop(with: error.localizedDescription, token: token) }
                }, onError: { [weak self] error in self?.stop(with: error.localizedDescription, token: token) })
            } catch { stop(with: error.localizedDescription, token: token) }
        }
    }

    func prepare(using session: TranslationSession) async {
        guard phase == .preparing,
              session.sourceLanguage?.languageCode == Locale.Language(identifier: "zh").languageCode,
              session.targetLanguage?.languageCode == Locale.Language(identifier: language.rawValue).languageCode else { return }
        let token = generation
        do {
            try await SpeechRecognizer.installAssets(for: chineseVariant)
            try Task.checkCancellation()
            guard generation == token else { return }
            try await session.prepareTranslation()
            try Task.checkCancellation()
            guard generation == token else { return }
            installed = InstalledResources(language: language, variant: chineseVariant)
            stop(with: "资源已就绪，重新按住按钮即可说中文。", token: token, keepResources: true)
        } catch { stop(with: error.localizedDescription, token: token) }
    }

    func finish() {
        if phase == .connecting {
            stop(with: "松开时麦克风尚未就绪。请重新按住，看到可以说话后再开口。", token: generation, keepResources: true)
            return
        }
        guard phase == .recording, let recognizer = speech else { return }
        let token = generation
        let starting = startup
        phase = .finishing
        message = "正在确认最后几个字…"
        audio.finishTurnCapture()
        work = Task {
            do {
                await starting?.value
                try Task.checkCancellation()
                guard generation == token else { return }
                try await recognizer.finishTurn()
                guard generation == token else { return }
                let text = turn.confirmed
                guard !text.isEmpty else { throw PipelineError.message("这次没有听清，请再说一次中文。") }
                try await translateAndPlay(text, correction: false, token: token)
            } catch { stop(with: error.localizedDescription, token: token) }
        }
    }

    func speakCorrection(_ text: String, language: AppLanguage, rate: Float,
                         onStopped: @escaping @MainActor () -> Void, onPlayed: @escaping @MainActor () -> Void) {
        guard phase == .idle, language != .chinese else { onStopped(); return }
        cancel()
        let token = generation
        self.language = language
        self.speakingRate = rate
        self.onStopped = onStopped
        self.onPlayed = onPlayed
        original = text
        translated = ""
        phase = .translating
        message = "正在翻译更正内容…"
        work = Task {
            do { try await translateAndPlay(text, correction: true, token: token) }
            catch { stop(with: error.localizedDescription, token: token) }
        }
    }

    private func translateAndPlay(_ text: String, correction: Bool, token: UUID) async throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        original = text
        phase = .translating
        message = correction ? "正在翻译更正内容…" : "正在翻译…"
        let session = TranslationSession(installedSource: Locale.Language(identifier: AppLanguage.chinese.rawValue),
                                         target: Locale.Language(identifier: language.rawValue))
        translator = session
        let response = try await session.translate(text)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let result = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw PipelineError.message("没有返回译文，请再试一次。") }
        translated = result
        let introduction = language == .japanese ? "すみません、訂正します。" : "Sorry, let me correct that. "
        try await playOutLoud(result, introduction: correction ? introduction : "", token: token)
    }

    func speakPrompt(original: String, translated: String, language: AppLanguage,
                     rate: Float, onStopped: @escaping @MainActor () -> Void = {},
                     onPlayed: @escaping @MainActor () -> Void) {
        guard phase == .idle, language != .chinese, !translated.isEmpty else { onStopped(); return }
        cancel()
        let token = generation
        self.original = original
        self.translated = translated
        self.language = language
        speakingRate = rate
        self.onStopped = onStopped
        self.onPlayed = onPlayed
        phase = .playing
        work = Task {
            do { try await playOutLoud(translated, token: token) }
            catch { stop(with: error.localizedDescription, token: token) }
        }
    }

    private func playOutLoud(_ text: String, introduction: String = "", token: UUID) async throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard text.count <= ReplayPolicy.maximumCaptionCharacters else {
            throw PipelineError.message("译文超过单次播报上限，请缩短这句话后重试。")
        }
        phase = .playing
        message = "正在用手机扬声器播放…"
        try await audio.configurePartnerSpeaker { [weak self] reason in self?.stop(with: reason, token: token) }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let complete = introduction + text
        let parts = complete.count <= ReplayPolicy.maximumCaptionCharacters ? [complete] : [introduction, text]
        for part in parts {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            try await audio.speak(part, language: language, rate: speakingRate)
        }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        try audio.releasePartnerSpeaker()
        let completed = onPlayed
        work = nil
        cancel()
        completed?()
    }

    func cancel() {
        generation = UUID()
        onStopped = nil
        onPlayed = nil
        startup?.cancel()
        startup = nil
        work?.cancel()
        work = nil
        translator?.cancel()
        translator = nil
        configuration = nil
        audio.stop()
        if let speech { Task { await speech.stop() } }
        speech = nil
        phase = .idle
        message = ""
    }

    private func stop(with reason: String, token: UUID, keepResources: Bool = false) {
        guard token == generation else { return }
        if !keepResources { invalidateResourceCheck() }
        let stopped = onStopped
        cancel()
        message = reason
        stopped?()
    }
}
