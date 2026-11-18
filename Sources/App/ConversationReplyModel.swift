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

    func start(language: AppLanguage, variant: SpeechVariant, source: CaptureSource) {
        guard phase == .idle, language != .chinese else { return }
        cancel()
        let token = generation
        self.language = language
        chineseVariant = variant
        original = ""
        translated = ""
        turn = ConversationTurn()
        phase = .connecting
        message = "正在检查中文识别和翻译资源…"
        let recognizer = SpeechRecognizer()
        speech = recognizer
        startup = Task {
            do {
                let from = Locale.Language(identifier: AppLanguage.chinese.rawValue)
                let to = Locale.Language(identifier: language.rawValue)
                async let speechReady = SpeechRecognizer.hasInstalledAssets(for: variant)
                let availability = await LanguageAvailability().status(from: from, to: to)
                let installed = await speechReady
                guard generation == token else { return }
                guard availability != .unsupported else { throw PipelineError.message("此设备不支持这个翻译方向。") }
                if availability != .installed || !installed {
                    phase = .preparing
                    message = "正在准备本次对话需要的语言资源…"
                    configuration = .init(source: from, target: to)
                    return
                }
                let permitted = await AudioController.requestPermission()
                guard generation == token else { return }
                guard permitted else { throw PipelineError.message("请在系统设置中允许使用麦克风。") }
                _ = try await audio.configure(source: source, farField: false)
                try Task.checkCancellation()
                guard generation == token else { return }
                let capture = try audio.start(side: .both, onLevel: { _ in }, onRouteFailure: { [weak self] reason in
                    self?.fail(reason, token: token)
                })
                phase = .recording
                message = "可以说中文了。说完后点「说完，翻译」。"
                try await recognizer.start(variant: variant, lowLatency: true, finiteTurn: true, onLocale: { _ in },
                                           audio: capture, onResult: { [weak self] event in
                    guard let self, self.generation == token else { return }
                    do {
                        try self.turn.receive(event)
                        self.original = self.turn.displayed
                    } catch { self.fail(error.localizedDescription, token: token) }
                }, onError: { [weak self] error in self?.fail(error.localizedDescription, token: token) })
            } catch { fail(error.localizedDescription, token: token) }
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
            cancel()
            message = "资源已就绪，点「我说中文」即可收音。"
        } catch { fail(error.localizedDescription, token: token) }
    }

    func finish() {
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
                original = text
                phase = .translating
                message = "正在翻译…"
                let session = TranslationSession(installedSource: Locale.Language(identifier: AppLanguage.chinese.rawValue),
                                                 target: Locale.Language(identifier: language.rawValue))
                translator = session
                let response = try await session.translate(text)
                try Task.checkCancellation()
                guard generation == token else { return }
                let result = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !result.isEmpty else { throw PipelineError.message("没有返回译文，请再试一次。") }
                translated = result
                cancel()
                message = ""
            } catch { fail(error.localizedDescription, token: token) }
        }
    }

    func play(rate: Float) {
        guard phase == .idle, !translated.isEmpty else { return }
        let token = generation
        phase = .playing
        message = "正在用手机扬声器播放译文…"
        work = Task {
            do {
                try await audio.configurePartnerSpeaker { [weak self] reason in self?.fail(reason, token: token) }
                guard generation == token else { return }
                try await audio.speak(translated, language: language, rate: rate)
                guard generation == token else { return }
                cancel()
                message = ""
            } catch { fail(error.localizedDescription, token: token) }
        }
    }

    func cancel() {
        generation = UUID()
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

    private func fail(_ reason: String, token: UUID) {
        guard token == generation else { return }
        cancel()
        message = reason
    }
}
