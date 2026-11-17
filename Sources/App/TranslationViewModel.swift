import AVFAudio
import Combine
import SwiftUI
import Translation

enum SessionState: String {
    case idle = "尚未开始"
    case preparing = "准备语言资源"
    case checking = "检查音频设备"
    case starting = "正在启动"
    case listening = "正在听译"
    case paused = "已暂停"
    case failed = "需要处理"
}

@MainActor
final class TranslationViewModel: ObservableObject {
    @Published var source: AppLanguage = .english { didSet { invalidatePreparation() } }
    @Published var target: AppLanguage = .chinese { didSet { invalidatePreparation() } }
    @Published var captureSource: CaptureSource = .headset { didSet { snapshot = AudioSnapshot() } }
    @Published var outputSide: OutputSide = .both
    @Published var speakingRate: Double = 0.5
    @Published var awarenessConfirmed = false
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var message = "先准备语言资源，再检查耳机。首次下载需要联网。"
    @Published private(set) var snapshot = AudioSnapshot()
    @Published private(set) var captions: [Caption] = []
    @Published private(set) var draft = ""
    @Published private(set) var pendingCount = 0
    @Published private(set) var phase = ""
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var microphonePermission = "未请求"
    @Published private(set) var preparedKey: String?
    @Published var translationConfiguration: TranslationSession.Configuration?

    private let audio = AudioController()
    private let speech = SpeechRecognizer()
    private var epoch = SessionEpoch()
    private var preparationEpoch: UInt64?
    private var ledger = FinalizationLedger()
    private var queue = SegmentQueue()
    private var translator: TranslationSession?
    private var launchTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?

    var languageKey: String { "\(source.rawValue)>\(target.rawValue)" }
    var resourcesReady: Bool { preparedKey == languageKey }
    var isRunning: Bool { state == .listening }
    var isBusy: Bool { [.preparing, .checking, .starting].contains(state) }
    var canConfigure: Bool { !isBusy && !isRunning }

    func requestPreparation() {
        guard canConfigure else { return }
        guard source != target else {
            message = "请选择不同的原文和译文语言。"
            state = .failed
            return
        }
        preparationEpoch = epoch.advance()
        preparedKey = nil
        state = .preparing
        message = "正在检查并准备本地语言模型；首次下载可能需要几分钟。"
        if translationConfiguration == nil {
            translationConfiguration = .init(source: Locale.Language(identifier: source.rawValue),
                                             target: Locale.Language(identifier: target.rawValue))
        } else {
            translationConfiguration?.invalidate()
        }
    }

    /// The SwiftUI-provided session is used only inside its translationTask lifetime for downloads.
    func prepareResources(using session: TranslationSession) async {
        guard let token = preparationEpoch, epoch.accepts(token), state == .preparing else { return }
        let requestedSource = source
        let requestedTarget = target
        let requestedKey = languageKey
        guard session.sourceLanguage?.languageCode == Locale.Language(identifier: requestedSource.rawValue).languageCode,
              session.targetLanguage?.languageCode == Locale.Language(identifier: requestedTarget.rawValue).languageCode else { return }
        do {
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: requestedSource.rawValue),
                                                            to: Locale.Language(identifier: requestedTarget.rawValue))
            guard status != .unsupported else {
                throw PipelineError.message("系统不支持这个翻译语言对，请选择其他语言。")
            }
            try Task.checkCancellation()
            guard epoch.accepts(token) else { return }
            message = "准备语音识别资源…"
            try await SpeechRecognizer.installAssets(for: requestedSource)
            try Task.checkCancellation()
            guard epoch.accepts(token) else { return }
            message = "准备翻译资源，请完成系统下载确认。"
            try await session.prepareTranslation()
            try Task.checkCancellation()
            guard epoch.accepts(token) else { return }
            guard AVSpeechSynthesisVoice(language: requestedTarget.speechLocale) != nil else {
                throw PipelineError.message("未找到译文语言的系统声音，请在 iPhone 设置中下载相应声音。")
            }
            preparedKey = requestedKey
            state = .idle
            message = "语言资源已准备。请检查音频设备，再开始听译。"
        } catch {
            guard epoch.accepts(token), !Task.isCancelled else { return }
            state = .failed
            message = error.localizedDescription
        }
    }

    func checkAudio() {
        guard canConfigure else { return }
        let token = epoch.advance()
        let requestedSource = captureSource
        state = .checking
        message = "检查实际麦克风、远场能力和输出声道…"
        let cleanup = cleanupTask
        launchTask = Task { [weak self] in
            guard let self else { return }
            await cleanup?.value
            do {
                try Task.checkCancellation()
                let permitted = await AudioController.requestPermission()
                try Task.checkCancellation()
                guard self.epoch.accepts(token) else { return }
                self.microphonePermission = permitted ? "已允许" : "未允许"
                guard permitted else {
                    throw PipelineError.message("麦克风权限未开启，请到系统设置允许访问。")
                }
                try Task.checkCancellation()
                guard self.epoch.accepts(token) else { return }
                self.snapshot = try await self.audio.configure(source: requestedSource)
                try Task.checkCancellation()
                guard self.epoch.accepts(token) else { return }
                self.audio.stop()
                self.state = .idle
                self.message = self.snapshot.output.supportsSingleEar
                    ? "检测到独立左右声道，可选择单耳。首次使用请确认实际听感。"
                    : "输入与输出已检查；当前仅可使用双耳，不能保证单耳隔离。"
            } catch {
                guard self.epoch.accepts(token), !Task.isCancelled else { return }
                self.snapshot = self.audio.snapshot
                self.audio.stop()
                self.state = .failed
                self.message = error.localizedDescription
            }
        }
    }

    func start() {
        guard canConfigure, resourcesReady, source != target, awarenessConfirmed else { return }
        let token = epoch.advance()
        let requestedSource = source
        let requestedTarget = target
        let requestedCapture = captureSource
        let requestedSide = outputSide
        state = .starting
        message = "正在启动本地识别与耳机音频。"
        draft = ""
        ledger = FinalizationLedger()
        queue.removeAll()
        pendingCount = 0
        let cleanup = cleanupTask
        launchTask = Task { [weak self] in
            guard let self else { return }
            await cleanup?.value
            do {
                try Task.checkCancellation()
                let permitted = await AudioController.requestPermission()
                try Task.checkCancellation()
                guard self.epoch.accepts(token) else { return }
                self.microphonePermission = permitted ? "已允许" : "未允许"
                guard permitted else {
                    throw PipelineError.message("麦克风权限未开启，请到系统设置允许访问。")
                }
                try Task.checkCancellation()
                guard self.epoch.accepts(token) else { return }
                self.snapshot = try await self.audio.configure(source: requestedCapture)
                try Task.checkCancellation()
                guard self.epoch.accepts(token) else { return }
                let status = await LanguageAvailability().status(from: Locale.Language(identifier: requestedSource.rawValue),
                                                                to: Locale.Language(identifier: requestedTarget.rawValue))
                guard status == .installed else {
                    self.preparedKey = nil
                    throw PipelineError.message("翻译语言资源未安装或已被系统移除，请重新准备资源。")
                }
                try Task.checkCancellation()
                guard self.epoch.accepts(token) else { return }
                self.translator = TranslationSession(installedSource: Locale.Language(identifier: requestedSource.rawValue),
                                                     target: Locale.Language(identifier: requestedTarget.rawValue))
                try await self.speech.start(language: requestedSource, audio: { [weak self] in
                    guard let self, self.epoch.accepts(token) else { throw CancellationError() }
                    return try self.audio.start(side: requestedSide, onLevel: { [weak self] level in
                        guard let self, self.epoch.accepts(token) else { return }
                        self.inputLevel = level
                    }, onRouteFailure: { [weak self] reason in
                        guard let self, self.epoch.accepts(token) else { return }
                        self.stop(reason: reason, failed: true)
                    })
                }, inputFormat: self.audio.inputFormat,
                                            onResult: { [weak self] text, final, start, end in
                    guard let self, self.epoch.accepts(token) else { return }
                    self.receive(text: text, final: final, start: start, end: end, token: token)
                }, onError: { [weak self] error in
                    guard let self, self.epoch.accepts(token) else { return }
                    self.stop(reason: "语音识别停止：\(error.localizedDescription)", failed: true)
                })
                try Task.checkCancellation()
                guard self.epoch.accepts(token) else { return }
                self.state = .listening
                self.phase = "正在听，确定的语义片段会依次翻译播报。"
                self.message = "收音与处理仅在本机进行。已配置锁屏音频，实际连续性待真机验证；来电或路由变化会暂停。"
            } catch {
                guard self.epoch.accepts(token), !Task.isCancelled else { return }
                self.snapshot = self.audio.snapshot
                self.stop(reason: error.localizedDescription, failed: true)
            }
        }
    }

    func stop(reason: String = "已暂停。尚未播完的片段不会自动重播。", failed: Bool = false, end: Bool = false) {
        epoch.advance()
        preparationEpoch = nil
        translationConfiguration = nil
        launchTask?.cancel()
        launchTask = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        translator?.cancel()
        translator = nil
        audio.stop()
        cleanupTask = Task { [speech] in await speech.stop() }
        queue.removeAll()
        pendingCount = 0
        draft = ""
        phase = ""
        inputLevel = 0
        for index in captions.indices where [.waiting, .translating, .speaking].contains(captions[index].status) {
            captions[index].status = .interrupted
        }
        state = failed ? .failed : (end ? .idle : .paused)
        message = reason
    }

    func end() {
        stop(reason: "会话已结束，当前会话字幕已清空。", end: true)
        captions.removeAll()
    }

    func clearCaptions() {
        guard canConfigure else { return }
        captions.removeAll()
        draft = ""
    }

    private func invalidatePreparation() {
        preparedKey = nil
        translationConfiguration = nil
        preparationEpoch = nil
        if isRunning || isBusy { stop(reason: "语言已变化，请重新准备资源。") }
    }

    private func receive(text: String, final: Bool, start: Double, end: Double, token: UInt64) {
        guard epoch.accepts(token) else { return }
        if !final { draft = text; return }
        draft = ""
        guard let segment = ledger.accept(text: text, start: start, end: end) else { return }
        captions.append(Caption(id: segment.id, original: segment.text))
        // This screen is intentionally an in-memory rolling transcript, not an archival history.
        if captions.count > 200 { captions.removeFirst(captions.count - 200) }
        do {
            try queue.append(segment)
            pendingCount = queue.items.count
            drain(token: token)
        } catch {
            stop(reason: error.localizedDescription, failed: true)
        }
    }

    private func drain(token: UInt64) {
        guard pipelineTask == nil else { return }
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            var activeSegmentID: UUID?
            do {
                while self.epoch.accepts(token), let segment = try self.queue.pop() {
                    activeSegmentID = segment.id
                    try Task.checkCancellation()
                    self.pendingCount = self.queue.items.count
                    guard let translator = self.translator else { throw CancellationError() }
                    self.phase = "正在翻译"
                    self.update(segment.id) { $0.status = .translating }
                    let response = try await translator.translate(segment.text)
                    try Task.checkCancellation()
                    guard self.epoch.accepts(token) else { return }
                    let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { throw PipelineError.message("翻译未返回内容，已暂停。") }
                    guard Date().timeIntervalSince(segment.receivedAt) <= 20 else { throw PipelineError.staleSegment }
                    self.update(segment.id) {
                        $0.translated = text
                        $0.status = .speaking
                        // Measures finalized-text-to-TTS-request processing, not acoustic latency.
                        $0.processingSeconds = Date().timeIntervalSince(segment.receivedAt)
                    }
                    self.phase = "正在播报，同时继续收音"
                    try await self.audio.speak(text, language: self.target, rate: Float(self.speakingRate))
                    try Task.checkCancellation()
                    guard self.epoch.accepts(token) else { return }
                    self.update(segment.id) { $0.status = .complete }
                    activeSegmentID = nil
                }
                guard self.epoch.accepts(token) else { return }
                self.pipelineTask = nil
                self.phase = "正在听，等待下一个确定片段。"
            } catch {
                guard self.epoch.accepts(token), !Task.isCancelled else { return }
                if let activeSegmentID { self.update(activeSegmentID) { $0.status = .failed } }
                self.stop(reason: error.localizedDescription, failed: true)
            }
        }
    }

    private func update(_ id: UUID, mutate: (inout Caption) -> Void) {
        guard let index = captions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&captions[index])
    }
}
