import AVFAudio
import SwiftUI
import Translation

@MainActor
final class ConversationReplyModel: ObservableObject {
    enum Phase { case idle, translating, playing }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var original = ""
    @Published private(set) var translated = ""
    @Published private(set) var message = ""
    private(set) var language: AppLanguage = .english
    private let audio = AudioController()
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var translator: TextTranslationRoute?
    private var speakingRate: Float = 0.5
    private var onStopped: (@MainActor () -> Void)?
    private var onPlayed: (@MainActor () -> Void)?
    func speakCorrection(_ text: String, language: AppLanguage, rate: Float, connection: MeetingConnection? = nil,
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
            do { try await translateAndPlayCorrection(text, token: token, connection: connection) }
            catch { stop(with: error.localizedDescription, token: token) }
        }
    }

    private func translateAndPlayCorrection(_ text: String, token: UUID, connection: MeetingConnection?) async throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        original = text
        phase = .translating
        message = "正在翻译更正内容…"
        let session = try TextTranslationRoute(from: .chinese, to: language, connection: connection, use: .dialogue)
        translator = session
        let response = try await session.translate(text)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let result = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw PipelineError.message("没有返回译文，请再试一次。") }
        translated = result
        let introduction = language == .japanese ? "すみません、訂正します。" : "Sorry, let me correct that. "
        try await playOutLoud(result, introduction: introduction, token: token)
    }

    func speakPrompt(original: String, translated: String, language: AppLanguage,
                     rate: Float, onStopped: @escaping @MainActor () -> Void = {},
                     onFirstAudio: (@MainActor () -> Void)? = nil,
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
            do { try await playOutLoud(translated, token: token, onFirstAudio: onFirstAudio) }
            catch { stop(with: error.localizedDescription, token: token) }
        }
    }

    private func playOutLoud(_ text: String, introduction: String = "", token: UUID,
                             onFirstAudio: (@MainActor () -> Void)? = nil) async throws {
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
            try await audio.speak(part, language: language, rate: speakingRate, onFirstBufferScheduled: onFirstAudio)
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
        work?.cancel()
        work = nil
        translator?.cancel()
        translator = nil
        audio.stop()
        phase = .idle
        message = ""
    }

    private func stop(with reason: String, token: UUID) {
        guard token == generation else { return }
        let stopped = onStopped
        cancel()
        message = reason
        stopped?()
    }
}
