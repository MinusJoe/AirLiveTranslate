import AVFAudio
import Combine
import SwiftUI
import Translation

enum SessionState: String {
    case idle = "尚未开始"
    case preparing = "准备语言资源"
    case checking = "检查音频设备"
    case starting = "正在启动"
    case buffering = "已收音 · 识别预热中"
    case listening = "正在听译"
    case paused = "已暂停"
    case failed = "需要处理"
}

@MainActor
final class TranslationViewModel: ObservableObject {
    @Published var source: AppLanguage = .english {
        didSet {
            guard oldValue != source else { return }
            sourceVariant = .defaultVariant(for: source)
            availableVariants = []
            invalidatePreparation()
            Task { await refreshVariants() }
        }
    }
    @Published var target: AppLanguage = .chinese { didSet { invalidatePreparation() } }
    @Published var sourceVariant: SpeechVariant = .englishUS { didSet { if oldValue != sourceVariant { invalidatePreparation() } } }
    @Published private(set) var availableVariants: [SpeechVariant] = []
    @Published private(set) var actualLocaleIdentifier = "尚未启动"
    @Published var lowLatencyEnabled = true
    @Published var adaptiveRateEnabled = true
    @Published var captureSource: CaptureSource = .headset {
        didSet {
            if oldValue != captureSource { stopReplay(reason: "收音设置已变化，已停止重播。") }
            snapshot = AudioSnapshot()
        }
    }
    @Published var outputSide: OutputSide = .both {
        didSet { if oldValue != outputSide { stopReplay(reason: "播放耳侧已变化，已停止重播。") } }
    }
    @Published var speakingRate: Double = 0.5
    @Published var awarenessConfirmed = false
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var message = "先准备语言资源，再检查耳机。首次下载需要联网。"
    @Published private(set) var snapshot = AudioSnapshot()
    @Published private(set) var captions: [Caption] = []
    private(set) var latestSessionCaptionID: UUID?
    @Published private(set) var draft = ""
    @Published private(set) var pendingCount = 0
    @Published private(set) var pendingSpeechCount = 0
    @Published private(set) var skippedAudioCount = 0
    @Published private(set) var latestMetrics = ProcessingMetrics()
    @Published private(set) var phase = ""
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var microphonePermission = "未请求"
    @Published private(set) var preparedKey: String?
    @Published var translationConfiguration: TranslationSession.Configuration?
    @Published private(set) var replayingCaptionID: UUID?
    @Published private(set) var isReplaying = false
    @Published private(set) var replayMessage = ""

    private let audio = AudioController()
    private let speech = SpeechRecognizer()
    private var epoch = SessionEpoch()
    private var preparationEpoch: UInt64?
    private var committer = StreamingCommitter()
    private var queue = SegmentQueue(capacity: 8, characterLimit: 2400)
    private var speechQueue = SpeechPlaybackQueue()
    private var invalidatedIDs: Set<UUID> = []
    private var subtitleOnlyIDs: Set<UUID> = []
    private var scheduledAudioIDs: Set<UUID> = []
    private var activeTranslationID: UUID?
    private var activeSpeechID: UUID?
    private var speechEpoch = SessionEpoch()
    private var playbackCutoffUptime: TimeInterval = 0
    private var translator: TranslationSession?
    private var launchTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var replayTask: Task<Void, Never>?
    private var replayProgress = ReplayProgress()
    private var replayPlanIDs: [UUID] = []
    private var audioOrigin = Date()
    private var minutes = MeetingMinutes()
    private var finishedMinutes: MeetingMinutes?
    var readableMinutes: MeetingMinutes { minutes.lines.isEmpty ? (finishedMinutes ?? minutes) : minutes }

    var languageKey: String { "\(source.rawValue):\(sourceVariant.rawValue)>\(target.rawValue)" }
    var resourcesReady: Bool { preparedKey == languageKey }
    var isRunning: Bool { state == .listening }
    var microphoneActive: Bool { state == .buffering || isRunning }
    var isBusy: Bool { [.preparing, .checking, .starting, .buffering].contains(state) }
    var canConfigure: Bool { !isBusy && !isRunning && !isReplaying }
    var unheardCaptions: [Caption] { captions.filter(ReplayPolicy.needsCatchUp) }

    func canReplay(_ caption: Caption) -> Bool { ReplayPolicy.canReplay(caption) }

    func replayUnavailableReason(_ caption: Caption) -> String? {
        if caption.status == .superseded { return "旧译文已修订，不能重播。" }
        if caption.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "此条尚无译文，不能重播。" }
        if caption.translated.count > ReplayPolicy.maximumCaptionCharacters { return "译文超过单条 1800 字的重播上限。" }
        return nil
    }

    func refreshVariants() async {
        let language = source
        let supported = await SpeechRecognizer.availableVariants(for: language)
        guard language == source, canConfigure else { return }
        availableVariants = supported
        if !supported.contains(sourceVariant), let first = supported.first { sourceVariant = first }
    }

    func requestPreparation(forListening: Bool = false) {
        guard canConfigure else { return }
        guard source != target else {
            message = "请选择不同的原文和译文语言。"
            state = .failed
            return
        }
        let token = epoch.advance()
        preparationEpoch = token
        preparedKey = nil
        state = .preparing
        message = "正在检查离线语言资源，麦克风尚未开启。"
        if forListening {
            // On a fresh launch our in-memory preparedKey is empty even when every
            // language asset is installed. Skip the download UI on this common path.
            let variant = sourceVariant
            let from = Locale.Language(identifier: source.rawValue)
            let to = Locale.Language(identifier: target.rawValue)
            launchTask = Task {
                async let installed = SpeechRecognizer.hasInstalledAssets(for: variant)
                let translation = await LanguageAvailability().status(from: from, to: to)
                let hasSpeech = await installed
                guard !Task.isCancelled, epoch.accepts(token) else { return }
                if hasSpeech, translation == .installed, AVSpeechSynthesisVoice(language: target.speechLocale) != nil {
                    preparedKey = languageKey
                    state = .idle
                } else {
                    prepareWithDownloadUI()
                }
            }
        } else {
            prepareWithDownloadUI()
        }
    }

    private func prepareWithDownloadUI() {
        message = "正在准备离线语言资源，准备完成后才能收音。"
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
        let requestedVariant = sourceVariant
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
            guard requestedVariant.language == requestedSource else { throw PipelineError.message("请选择与源语言匹配的识别地区。") }
            try await SpeechRecognizer.installAssets(for: requestedVariant)
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
                self.snapshot = try await self.audio.configure(source: requestedSource, probeStereo: true)
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
        replayMessage = ""
        let token = epoch.advance()
        let requestedSource = source
        let requestedVariant = sourceVariant
        let requestedLowLatency = lowLatencyEnabled
        let requestedTarget = target
        let requestedCapture = captureSource
        let requestedSide = outputSide
        state = .starting
        message = "正在连接麦克风。看到“已收音”后即可讲话。"
        draft = ""
        committer = StreamingCommitter(lowLatencyEnabled: requestedLowLatency, language: requestedSource)
        latestSessionCaptionID = nil
        queue.removeAll()
        _ = speechQueue.removeAll()
        invalidatedIDs.removeAll()
        subtitleOnlyIDs.removeAll()
        scheduledAudioIDs.removeAll()
        playbackCutoffUptime = 0
        latestMetrics = ProcessingMetrics()
        pendingCount = 0
        pendingSpeechCount = 0
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
                self.snapshot = try await self.audio.configure(source: requestedCapture, side: requestedSide)
                try Task.checkCancellation()
                guard self.epoch.accepts(token) else { return }
                self.audioOrigin = Date()
                let capture = try self.audio.start(side: requestedSide, onLevel: { [weak self] level in
                    guard let self, self.epoch.accepts(token) else { return }
                    self.inputLevel = level
                }, onRouteFailure: { [weak self] reason in
                    guard let self, self.epoch.accepts(token) else { return }
                    self.snapshot = self.audio.snapshot
                    self.stop(reason: reason, failed: true)
                })
                self.state = .buffering
                self.finishedMinutes = nil
                self.message = "可以讲话了。开头语音已开始在内存中暂存，识别就绪后会从头处理。"
                let status = await LanguageAvailability().status(from: Locale.Language(identifier: requestedSource.rawValue),
                                                                to: Locale.Language(identifier: requestedTarget.rawValue))
                try Task.checkCancellation()
                guard self.epoch.accepts(token) else { return }
                guard status == .installed else {
                    self.preparedKey = nil
                    throw PipelineError.message("翻译语言资源未安装或已被系统移除，请重新准备资源。")
                }
                try Task.checkCancellation()
                guard self.epoch.accepts(token) else { return }
                self.translator = TranslationSession(installedSource: Locale.Language(identifier: requestedSource.rawValue),
                                                     target: Locale.Language(identifier: requestedTarget.rawValue))
                try await self.speech.start(variant: requestedVariant, lowLatency: requestedLowLatency, onLocale: { [weak self] locale in
                    guard let self, self.epoch.accepts(token) else { return }
                    self.actualLocaleIdentifier = locale
                }, audio: capture,
                onResult: { [weak self] update in
                    guard let self, self.epoch.accepts(token) else { return }
                    self.receive(update, token: token)
                }, onError: { [weak self] error in
                    guard let self, self.epoch.accepts(token) else { return }
                    self.stop(reason: "语音识别停止：\(error.localizedDescription)", failed: true)
                })
                try Task.checkCancellation()
                guard self.epoch.accepts(token) else { return }
                self.state = .listening
                self.phase = requestedLowLatency ? "正在听译，稳定的句子或分句可以先播。" : "正在听译，等待识别定稿。"
                self.message = "开始听译后可以锁屏继续收听。来电中断或耳机断开后，请回到 App 恢复听译。"
            } catch {
                guard self.epoch.accepts(token), !Task.isCancelled else { return }
                self.snapshot = self.audio.snapshot
                self.stop(reason: error.localizedDescription, failed: true)
            }
        }
    }

    func stop(reason: String = "已暂停。尚未播完的片段不会自动重播。", failed: Bool = false, end: Bool = false) {
        stopReplay(reason: "已停止重播；尚未播完的内容可再次补听。")
        epoch.advance()
        preparationEpoch = nil
        translationConfiguration = nil
        launchTask?.cancel()
        launchTask = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        speechEpoch.advance()
        speechTask?.cancel()
        speechTask = nil
        translator?.cancel()
        minutes.discardUnconfirmed()
        translator = nil
        audio.stop()
        cleanupTask = Task { [speech] in await speech.stop() }
        queue.removeAll()
        _ = speechQueue.removeAll()
        activeTranslationID = nil
        activeSpeechID = nil
        pendingCount = 0
        pendingSpeechCount = 0
        draft = ""
        phase = ""
        inputLevel = 0
        for index in captions.indices where [.waiting, .translating, .readyToSpeak, .speaking].contains(captions[index].status) {
            captions[index].status = .interrupted
        }
        state = failed ? .failed : (end ? .idle : .paused)
        message = reason
    }

    func end(keepMinutes: Bool = false) {
        stop(reason: "会话已结束，当前会话字幕已清空。", end: true)
        finishedMinutes = keepMinutes ? minutes : nil
        minutes = MeetingMinutes()
        captions.removeAll()
        skippedAudioCount = 0
        replayMessage = ""
    }

    func clearCaptions() {
        guard canConfigure else { return }
        finishedMinutes = nil
        minutes = MeetingMinutes()
        captions.removeAll()
        draft = ""
    }

    private func invalidatePreparation() {
        stopReplay(reason: "语言设置已变化，已停止重播。")
        preparedKey = nil
        translationConfiguration = nil
        preparationEpoch = nil
        if isRunning || isBusy { stop(reason: "语言已变化，请重新准备资源。") }
    }

    /// The UI confirms pausing live listening before calling these replay entry points.
    func replayCaption(_ id: UUID) {
        guard let caption = captions.first(where: { $0.id == id }) else {
            replayMessage = "此条字幕已不在当前内存中，无法重播。"
            return
        }
        if let reason = replayUnavailableReason(caption) {
            replayMessage = reason
            return
        }
        beginReplay(from: [caption])
    }

    func replayUnheard() {
        // Snapshot the list the person selected before pausing live work. Newly interrupted live
        // captions remain available for the next batch instead of silently joining this batch.
        let candidates = unheardCaptions
        guard !candidates.isEmpty else {
            replayMessage = "当前没有可补听的未完整播出译文。"
            return
        }
        beginReplay(from: candidates)
    }

    func stopReplay(reason: String = "已停止重播。未完成的条目可再次补听；实时收音不会自动恢复。") {
        guard isReplaying else { return }
        replayProgress.cancel()
        replayTask?.cancel()
        replayTask = nil
        for id in replayPlanIDs {
            update(id) {
                if $0.replayStatus == .queued || $0.replayStatus == .playing { $0.replayStatus = .interrupted }
            }
        }
        replayPlanIDs.removeAll()
        replayingCaptionID = nil
        audio.stop()
        isReplaying = false
        replayMessage = reason
        message = reason
        // Do not call start(): replay is never consent to resume environmental capture.
    }

    private func beginReplay(from candidates: [Caption]) {
        let plan = ReplayPlan.make(from: candidates)
        guard !plan.items.isEmpty else {
            replayMessage = "所选内容不可重播。需有有效译文，且每条不超过 1800 字。"
            return
        }
        stop(reason: "实时听译已暂停。现在只播放译文，不采集周围声音。")
        let token = replayProgress.begin()
        let side = outputSide
        let rate = Float(speakingRate)
        let cleanup = cleanupTask
        replayPlanIDs = plan.items.map(\.id)
        for id in replayPlanIDs { update(id) { $0.replayStatus = .queued } }
        isReplaying = true
        replayMessage = "准备重播 \(plan.items.count) 条；麦克风保持关闭。"
        if plan.omittedCount > 0 { replayMessage += " 另有 \(plan.omittedCount) 条保留到下一批。" }
        if plan.unavailableCount > 0 { replayMessage += " \(plan.unavailableCount) 条不满足播放条件。" }
        replayTask = Task { [weak self] in
            guard let self else { return }
            await cleanup?.value
            do {
                try Task.checkCancellation()
                guard self.replayProgress.accepts(token), self.isReplaying else { return }
                let replaySnapshot = try await self.audio.configurePlayback(side: side) { [weak self] reason in
                    guard let self, self.replayProgress.accepts(token) else { return }
                    self.snapshot = self.audio.snapshot
                    self.stopReplay(reason: "重播已停止：\(reason) 实时收音未恢复。")
                }
                try Task.checkCancellation()
                guard self.replayProgress.accepts(token), self.isReplaying else { return }
                self.snapshot = replaySnapshot
                for (index, item) in plan.items.enumerated() {
                    try Task.checkCancellation()
                    guard self.replayProgress.accepts(token), self.isReplaying else { return }
                    guard let caption = self.captions.first(where: { $0.id == item.id }),
                          ReplayPolicy.canReplay(caption), caption.translated == item.text,
                          caption.targetLanguage == item.language else {
                        throw PipelineError.message("字幕内容或有效性已变化，已停止此次重播。")
                    }
                    guard self.replayProgress.startItem(item.id, token: token) else { return }
                    self.replayingCaptionID = item.id
                    self.update(item.id) { $0.replayStatus = .playing }
                    self.replayMessage = "正在重播 \(index + 1)/\(plan.items.count) · \(item.language.name)；麦克风关闭。"
                    for chunk in item.chunks {
                        try Task.checkCancellation()
                        guard self.replayProgress.accepts(token), self.isReplaying else { return }
                        if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                        // Chunked synthesis is bounded but has no live 12-second/15-second expiry.
                        // The saved language belongs to the caption, not to the current settings.
                        try await self.audio.speak(chunk, language: item.language, rate: rate)
                        try Task.checkCancellation()
                        guard self.replayProgress.accepts(token), self.isReplaying else { return }
                    }
                    guard self.replayProgress.finishItem(item.id, token: token) else { return }
                    self.update(item.id) {
                        $0.replayStatus = .completed
                        $0.lastReplayAt = Date()
                    }
                    self.replayingCaptionID = nil
                }
                guard self.replayProgress.accepts(token), self.isReplaying else { return }
                self.audio.stop()
                self.replayPlanIDs.removeAll()
                self.replayTask = nil
                self.isReplaying = false
                self.replayMessage = "已完整重播 \(plan.items.count) 条。实时收音保持暂停。"
                if plan.omittedCount > 0 { self.replayMessage += " 还有 \(plan.omittedCount) 条可在下一批补听。" }
                self.message = self.replayMessage
            } catch {
                guard self.replayProgress.accepts(token), !Task.isCancelled else { return }
                if let id = self.replayingCaptionID { self.update(id) { $0.replayStatus = .failed } }
                self.stopReplay(reason: "重播未完成：\(error.localizedDescription) 未完成条目可重试；实时收音未恢复。")
            }
        }
    }

    func skipToLive() {
        guard isRunning else { return }
        playbackCutoffUptime = ProcessInfo.processInfo.systemUptime
        if let activeSpeechID { markUnspoken(activeSpeechID, reason: "用户跳到当前，已中止这段播报。") }
        for job in speechQueue.removeAll() {
            if let id = job.captionID { markUnspoken(id, reason: "用户跳到当前，保留字幕但未播报。") }
        }
        cancelSpeechWorker()
        pendingSpeechCount = 0
        message = "已跳过旧译音。已接收内容继续生成字幕，只播报此后新提交的片段。"
    }

    private func receive(_ recognition: RecognitionUpdate, token: UInt64) {
        guard epoch.accepts(token) else { return }
        guard recognition.text.count <= 12_000 else {
            stop(reason: "识别片段过长，已暂停以限制内存。请稍后重新开始。", failed: true)
            return
        }
        let batch = committer.process(recognition, now: ProcessInfo.processInfo.systemUptime)
        if let captured = recognition.capturedSeconds, !recognition.text.isEmpty, recognition.end.isFinite {
            latestMetrics.recognitionLagSeconds = max(0, captured - recognition.end)
            if let committed = batch.segments.last {
                latestMetrics.commitLagSeconds = max(0, captured - committed.segment.end)
            }
        }
        if draft != batch.draft { draft = batch.draft }
        guard !batch.segments.isEmpty || !batch.revisedIDs.isEmpty || !batch.confirmedIDs.isEmpty else { return }
        minutes.ingest(batch, audioOrigin: audioOrigin)
        if !batch.revisedIDs.isEmpty { revoke(batch.revisedIDs, token: token) }
        for id in batch.confirmedIDs { update(id) { $0.isProvisional = false } }
        do {
            for committed in batch.segments {
                let segment = committed.segment
                var caption = Caption(id: segment.id, original: segment.text, targetLanguage: target)
                caption.isProvisional = committed.isProvisional
                if committed.subtitleOnly && committed.replacesIDs.contains(where: scheduledAudioIDs.contains) {
                    subtitleOnlyIDs.insert(segment.id)
                    caption.note = "更正：此前识别已变化。此条仅更新字幕，不自动重播整段。"
                } else if committed.subtitleOnly {
                    caption.note = "识别已更正。旧译音尚未开始，已撤销；将播报这条更正后的内容。"
                }
                latestSessionCaptionID = caption.id
                captions.append(caption)
                try queue.append(segment)
            }
            trimCaptions()
            trimBookkeeping()
            pendingCount = queue.items.count
            drainTranslations(token: token)
        } catch {
            trimCaptions()
            stop(reason: error.localizedDescription, failed: true)
        }
    }

    private func revoke(_ ids: [UUID], token: UInt64) {
        let revised = Set(ids)
        let hadScheduledAudio = ids.contains(where: scheduledAudioIDs.contains)
        invalidatedIDs.formUnion(revised)
        queue.remove(ids: revised)
        _ = speechQueue.remove(captionIDs: revised)
        for id in ids {
            update(id) {
                $0.status = .superseded
                $0.isProvisional = false
                $0.note = "后续识别修订了这段原文，旧译文不再可靠；请查看更正字幕。"
            }
        }
        if let activeSpeechID, revised.contains(activeSpeechID) { cancelSpeechWorker() }
        if hadScheduledAudio {
            let notice: String
            switch target {
            case .chinese: notice = "刚才的识别有修正，请查看字幕。"
            case .english: notice = "An earlier transcript was corrected. Please check the screen."
            case .japanese: notice = "先ほどの認識が修正されました。字幕を確認してください。"
            }
            let now = ProcessInfo.processInfo.systemUptime
            enqueueSpeech(SpeechJob(id: UUID(), captionID: nil, text: notice, committedAtUptime: now,
                                   queuedAtUptime: now, estimatedSeconds: SpeechPacing.estimatedDuration(text: notice, language: target)), token: token)
        } else {
            drainSpeech(token: token)
        }
        message = hadScheduledAudio ? "识别修订了提前播报的内容：已发出更正提示，最终更正仅保留字幕，不重复播整段。"
                                    : "识别已修订：尚未开始的旧译音已撤销，将只播放更正后的内容。"
        pendingCount = queue.items.count
    }

    /// This worker never waits for TTS playback; translations remain ordered while speech drains separately.
    private func drainTranslations(token: UInt64) {
        guard pipelineTask == nil else { return }
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            do {
                while self.epoch.accepts(token), let segment = try self.queue.pop() {
                    try Task.checkCancellation()
                    guard !self.invalidatedIDs.contains(segment.id) else { continue }
                    self.activeTranslationID = segment.id
                    self.pendingCount = self.queue.items.count
                    guard let translator = self.translator else { throw CancellationError() }
                    self.phase = "正在识别与翻译，译音独立播放"
                    self.update(segment.id) { $0.status = .translating }
                    let began = ProcessInfo.processInfo.systemUptime
                    let response = try await translator.translate(segment.text)
                    try Task.checkCancellation()
                    guard self.epoch.accepts(token) else { return }
                    guard !self.invalidatedIDs.contains(segment.id) else {
                        self.activeTranslationID = nil
                        continue
                    }
                    let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { throw PipelineError.message("翻译未返回内容，已暂停。") }
                    let now = ProcessInfo.processInfo.systemUptime
                    self.latestMetrics.translationSeconds = now - began
                    self.minutes.setTranslation(text, for: segment.id)
                    self.update(segment.id) {
                        $0.translated = text
                        $0.processingSeconds = now - segment.committedAtUptime
                    }
                    if self.subtitleOnlyIDs.contains(segment.id) {
                        self.update(segment.id) { $0.status = .corrected }
                    } else if text.count > ReplayPolicy.maximumCaptionCharacters {
                        self.markUnspoken(segment.id, reason: "译文超过单次播报的字数上限，已保留完整字幕。")
                    } else if segment.committedAtUptime < self.playbackCutoffUptime || now - segment.committedAtUptime > 15 {
                        self.markUnspoken(segment.id, reason: "译文已过时或已跳到当前，仅保留字幕。")
                    } else {
                        self.update(segment.id) { $0.status = .readyToSpeak }
                        self.enqueueSpeech(SpeechJob(id: UUID(), captionID: segment.id, text: text,
                                                     committedAtUptime: segment.committedAtUptime, queuedAtUptime: now,
                                                     estimatedSeconds: SpeechPacing.estimatedDuration(text: text, language: self.target)), token: token)
                    }
                    self.activeTranslationID = nil
                }
                guard self.epoch.accepts(token) else { return }
                self.pipelineTask = nil
                self.phase = self.speechTask == nil ? "正在听，等待下一个片段。" : "正在听译，继续播报"
            } catch {
                guard self.epoch.accepts(token), !Task.isCancelled else { return }
                if let id = self.activeTranslationID { self.update(id) { $0.status = .failed } }
                self.stop(reason: error.localizedDescription, failed: true)
            }
        }
    }

    private func enqueueSpeech(_ job: SpeechJob, token: UInt64) {
        for omitted in speechQueue.append(job) {
            if let id = omitted.captionID { markUnspoken(id, reason: "为跟上当前讲话，已跳过这段译音，可在「补听」中收听。") }
        }
        pendingSpeechCount = speechQueue.items.count
        drainSpeech(token: token)
    }

    private func drainSpeech(token: UInt64) {
        guard speechTask == nil else { return }
        let playbackToken = speechEpoch.advance()
        speechTask = Task { [weak self] in
            guard let self else { return }
            do {
                while self.epoch.accepts(token), self.speechEpoch.accepts(playbackToken), let job = self.speechQueue.pop() {
                    try Task.checkCancellation()
                    self.pendingSpeechCount = self.speechQueue.items.count
                    if let id = job.captionID, self.invalidatedIDs.contains(id) { continue }
                    let now = ProcessInfo.processInfo.systemUptime
                    if job.captionID != nil && (job.committedAtUptime < self.playbackCutoffUptime || now - job.committedAtUptime > 15) {
                        if let id = job.captionID { self.markUnspoken(id, reason: "译音已过时，仅保留字幕。") }
                        continue
                    }
                    self.activeSpeechID = job.captionID
                    if let id = job.captionID { self.update(id) { $0.status = .speaking } }
                    self.latestMetrics.playbackQueueSeconds = now - job.queuedAtUptime
                    let rate = SpeechPacing.rate(base: Float(self.speakingRate), queuedSeconds: self.speechQueue.estimatedDuration,
                                                 adaptive: self.adaptiveRateEnabled)
                    do {
                        try await self.audio.speak(job.text, language: self.target, rate: rate, onFirstBufferScheduled: { [weak self] in
                            guard let self, self.epoch.accepts(token), self.speechEpoch.accepts(playbackToken) else { return }
                            if let id = job.captionID { self.scheduledAudioIDs.insert(id) }
                            self.latestMetrics.firstBufferScheduledSeconds = ProcessInfo.processInfo.systemUptime - job.committedAtUptime
                        })
                    } catch PipelineError.synthesisBacklog {
                        guard self.epoch.accepts(token), self.speechEpoch.accepts(playbackToken) else { return }
                        guard let id = job.captionID else { throw PipelineError.synthesisBacklog }
                        self.markUnspoken(id, reason: "这段译音未播完，可在「补听」中重新收听。")
                        self.activeSpeechID = nil
                        continue
                    }
                    try Task.checkCancellation()
                    guard self.epoch.accepts(token), self.speechEpoch.accepts(playbackToken) else { return }
                    if let id = job.captionID { self.update(id) { $0.status = .complete } }
                    self.activeSpeechID = nil
                }
                guard self.epoch.accepts(token), self.speechEpoch.accepts(playbackToken) else { return }
                self.speechTask = nil
                self.activeSpeechID = nil
                self.phase = self.pipelineTask == nil ? "正在听，等待下一个片段。" : "正在识别与翻译"
            } catch {
                guard self.epoch.accepts(token), self.speechEpoch.accepts(playbackToken), !Task.isCancelled else { return }
                if let id = self.activeSpeechID { self.update(id) { $0.status = .failed } }
                self.stop(reason: error.localizedDescription, failed: true)
            }
        }
    }

    private func cancelSpeechWorker() {
        speechEpoch.advance()
        speechTask?.cancel()
        speechTask = nil
        audio.stopSpeech()
        activeSpeechID = nil
    }

    private func markUnspoken(_ id: UUID, reason: String) {
        guard let index = captions.firstIndex(where: { $0.id == id }),
              captions[index].status != .unspoken, captions[index].status != .superseded else { return }
        captions[index].status = .unspoken
        captions[index].note = reason
        skippedAudioCount += 1
        message = "播报未能覆盖全部内容：累计 \(skippedAudioCount) 段未完整播报，字幕已保留。"
    }

    private func trimBookkeeping() {
        var live = Set(captions.map(\.id))
        live.formUnion(committer.pendingIDs)
        if let activeTranslationID { live.insert(activeTranslationID) }
        if let activeSpeechID { live.insert(activeSpeechID) }
        invalidatedIDs.formIntersection(live)
        subtitleOnlyIDs.formIntersection(live)
        scheduledAudioIDs.formIntersection(live)
    }

    private func trimCaptions() {
        var protected = Set(queue.items.map(\.id))
        protected.formUnion(speechQueue.items.compactMap(\.captionID))
        if let activeTranslationID { protected.insert(activeTranslationID) }
        if let activeSpeechID { protected.insert(activeSpeechID) }
        CaptionRetention.trim(&captions, protecting: protected)
    }

    private func update(_ id: UUID, mutate: (inout Caption) -> Void) {
        guard let index = captions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&captions[index])
    }
}
