import AVFAudio
import Combine
import Translation

@MainActor
final class DialogueCoordinator: ObservableObject {
    enum Phase { case idle, preparing, capturing, finishing, enrolling, externalPlayback, privatePlayback, editing }
    unowned let listener: TranslationViewModel
    let reply = ConversationReplyModel()
    @Published private(set) var language: AppLanguage
    @Published private(set) var device: DialogueDevice = .phone
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var entries: [DialogueEntry] = []
    @Published private(set) var editor: DialogueEditor?
    @Published private(set) var message = ""
    @Published private(set) var enrolled = false
    @Published private(set) var canShowTypingFallback = false
    @Published var configuration: TranslationSession.Configuration?
    private var models: GroupSpeechAnalyzer?
    private let audio = AudioController()
    private var gallery = VoiceGallery()
    private var owner: [[Float]] = []
    private var history = DialogueTranscript(existing: [])
    private(set) var minutes = MeetingMinutes()
    private var epoch = UUID()
    private var task: Task<Void, Never>?
    private var earWorker: Task<Void, Never>?
    private var earQueue: [(text: String, language: AppLanguage)] = []
    private var devicePickedByUser = false
    private var sessions: [AppLanguage: TranslationSession] = [:]
    private var preparePair: (AppLanguage, AppLanguage)?
    private var prepareWaiter: CheckedContinuation<Void, Error>?
    private var attempted = Set<AppLanguage>()
    private var afterDrain: (() -> Void)?
    private var resumeAfterAction = false
    private var isEditingPlayback = false

    init(listener: TranslationViewModel) {
        self.listener = listener
        language = ConversationTurn.partnerLanguage(source: listener.source, target: listener.target)
    }

    var realtimeBusy: Bool { listener.isBusy || listener.isRunning || listener.isReplaying }
    var canAct: Bool { !realtimeBusy && (phase == .idle || phase == .capturing) }
    var canBeginReply: Bool { canAct && editor == nil }
    var canConfigureDialogue: Bool { phase == .idle && !realtimeBusy }
    var amountQuestion: DialogueQuestion? {
        guard let last = entries.last(where: { $0.speaker == .partner }), last.kind == .heard,
              last.sourceLanguage == language else { return nil }
        return DialogueQuestion.contextual(in: last.original)
    }

    /// Browsing never acquires, releases, or reconfigures the microphone.
    func open() {
        if phase == .idle && !devicePickedByUser {
            device = AudioController.headphonesSelected ? .headphones : .phone
        }
        do { enrolled = !(try WearerVoiceprint.read()).isEmpty }
        catch { message = error.localizedDescription }
    }

    func selectLanguage(_ choice: AppLanguage) {
        guard canConfigureDialogue, choice != .chinese else { return }
        language = choice
    }

    func selectDevice(_ choice: DialogueDevice) {
        guard canConfigureDialogue else { return }
        devicePickedByUser = true
        device = choice
    }

    func start(enrollment: Bool = false, additional: Bool = false) {
        guard phase == .idle, listener.reserveDialogueAudio() else { return }
        gallery = VoiceGallery()
        launch(enrollment: enrollment, newConversation: !enrollment, additional: additional)
    }

    private func launch(enrollment: Bool = false, newConversation: Bool = false, additional: Bool = false) {
        let token = UUID()
        epoch = token
        let analyzer = models ?? GroupSpeechAnalyzer()
        models = analyzer
        let restoring = !enrollment && !newConversation && sessions[.chinese] != nil && sessions[language] != nil
        attempted.removeAll()
        phase = .preparing
        message = restoring ? "正在恢复\(device == .phone ? "手机" : "对话")收音…" : "正在准备本机模型，首次使用需要下载…"
        task = Task {
            do {
                if !restoring && (!enrollment || additional) {
                    owner = try WearerVoiceprint.read()
                    enrolled = !owner.isEmpty
                }
                if !enrollment && !restoring {
                    for (from, to) in [(AppLanguage.chinese, language), (language, .chinese)] {
                        let source = Locale.Language(identifier: from.rawValue)
                        let target = Locale.Language(identifier: to.rawValue)
                        let status = await LanguageAvailability().status(from: source, to: target)
                        try validate(token)
                        guard status != .unsupported else { throw PipelineError.message("设备不支持这个翻译方向。") }
                        if status != .installed {
                            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                                prepareWaiter = waiter
                                preparePair = (from, to)
                                configuration = .init(source: source, target: target)
                                message = "请准备 \(from.name) → \(to.name) 的翻译资源。"
                            }
                            try validate(token)
                        }
                        sessions[from] = TranslationSession(installedSource: source, target: target)
                    }
                }
                try await analyzer.prepare(enrollment: enrollment)
                try validate(token)
                guard await AudioController.requestPermission() else { throw PipelineError.message("请允许麦克风访问后重试。") }
                try validate(token)
                let side: OutputSide
                switch device {
                case .phone:
                    side = .both
                    try await audio.configurePhoneMicrophone()
                case .headphones:
                    side = listener.outputSide
                    _ = try await audio.configure(source: listener.captureSource, side: side, farField: !enrollment)
                }
                try validate(token)
                let fifo = try audio.start(side: side, onLevel: { _ in }, onRouteFailure: { [weak self] reason in
                    self?.fail(reason, token: token)
                })
                if newConversation { history = DialogueTranscript(existing: []); minutes = MeetingMinutes(); entries = [] }
                phase = enrollment ? .enrolling : .capturing
                message = enrollment ? "请一个人自然说约五秒，然后停顿。可以中英文混说。" : "正在连续听译"
                try await analyzer.consume(fifo, enrollment: enrollment, receive: { [weak self] line in
                    guard let self else { throw CancellationError() }
                    try await self.receive(line, token: token)
                }, register: { [weak self] vector in
                    guard let self else { throw CancellationError() }
                    try self.validate(token)
                    try WearerVoiceprint.save(vector, additional: additional)
                    self.enrolled = true
                })
                try validate(token)
                audio.stop()
                task = nil
                if let next = afterDrain { afterDrain = nil; next() }
                else { reset(enrollment ? "我的声纹已保存在本机。" : "本次连续对话已结束。") }
            } catch { fail(error.localizedDescription, token: token) }
        }
    }

    func prepare(using session: TranslationSession) async {
        guard phase == .preparing, let (from, to) = preparePair, !attempted.contains(from),
              session.sourceLanguage?.languageCode == Locale.Language(identifier: from.rawValue).languageCode,
              session.targetLanguage?.languageCode == Locale.Language(identifier: to.rawValue).languageCode else { return }
        attempted.insert(from)
        let token = epoch
        do {
            try await session.prepareTranslation()
            try validate(token)
            guard await LanguageAvailability().status(from: Locale.Language(identifier: from.rawValue),
                                                      to: Locale.Language(identifier: to.rawValue)) == .installed
            else { throw PipelineError.message("翻译资源尚未安装完成。") }
            try validate(token)
            preparePair = nil
            configuration = nil
            prepareWaiter?.resume()
            prepareWaiter = nil
        } catch { fail(error.localizedDescription, token: token) }
    }

    private func receive(_ line: GroupUtterance, token: UUID) async throws {
        try validate(token)
        let party: VoiceParty = line.mixed ? .unidentified : gallery.identify(line.embedding, owner: owner, language: line.source)
        guard let source = line.source, source == .chinese || source == language else {
            history.addSpoken(line, translation: "", party: party, direction: nil)
            publishLine()
            message = "这句语言未确认或不在当前语言组合，已保留原文。"
            return
        }
        let direction = GroupDirection(source: source, partner: language, party: party, enrolled: !owner.isEmpty,
                                       mixed: line.mixed, device: device)
        let translation: String
        if source == direction.target { translation = line.text }
        else {
            guard let session = sessions[source] else { throw PipelineError.message("翻译没有就绪。") }
            do {
                translation = try await session.translate(line.text).targetText
                guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PipelineError.message("这句话没有返回译文。")
                }
            } catch {
                try validate(token)
                history.addSpoken(line, translation: "", party: party, direction: nil)
                publishLine()
                message = "这句翻译失败，已保留原文。"
                return
            }
        }
        try validate(token)
        history.addSpoken(line, translation: translation, party: party, direction: direction)
        publishLine()
        if direction.automaticHeadphones && phase == .capturing {
            enqueueEarpiece(translation, language: direction.target, token: token)
        }
    }

    private func enqueueEarpiece(_ text: String, language: AppLanguage, token: UUID) {
        guard device == .headphones, phase == .capturing else { return }
        if earQueue.count >= 8 { earQueue.removeFirst(); message = "耳机播报积压，较早的译文可看字幕。" }
        earQueue.append((text, language))
        guard earWorker == nil else { return }
        earWorker = Task {
            do {
                while phase == .capturing && !earQueue.isEmpty {
                    let item = earQueue.removeFirst()
                    do {
                        for part in ReplayPolicy.chunks(for: item.text) {
                            try validate(token)
                            try await audio.speak(part, language: item.language, rate: Float(listener.speakingRate))
                        }
                    } catch PipelineError.synthesisBacklog {
                        try validate(token)
                        message = "这句未完整播出，字幕已保留。正在继续听译。"
                    }
                }
                if epoch == token { earWorker = nil }
            } catch { if !Task.isCancelled { fail(error.localizedDescription, token: token) } }
        }
    }

    func end() {
        if phase == .capturing { drain(then: nil) }
        else { reset("已停止。") }
    }

    private func drain(then next: (() -> Void)?) {
        afterDrain = next
        phase = .finishing
        message = "正在处理最后一段发言…"
        earWorker?.cancel(); earWorker = nil; earQueue.removeAll()
        audio.finishTurnCapture()
    }

    private func quietForAction(_ action: @escaping () -> Void) {
        guard canAct, listener.reserveDialogueAudio() else { return }
        resumeAfterAction = phase == .capturing
        if resumeAfterAction { drain(then: action) } else { action() }
    }

    func play(_ entry: DialogueEntry) {
        guard canAct, let row = entries.first(where: { $0.id == entry.id }),
              let destination = row.playback(in: device) else { return }
        switch destination {
        case .phoneSpeaker(let target):
            quietForAction { [weak self] in
                self?.publicSpeech(original: row.original, text: row.translated, language: target, question: nil)
            }
        case .earpiece(let target):
            hearPrivately(row.translated, language: target)
        }
    }

    private func hearPrivately(_ text: String, language: AppLanguage) {
        guard device == .headphones else { return }
        let token = epoch
        if phase == .capturing {
            enqueueEarpiece(text, language: language, token: token)
            return
        }
        guard listener.reserveDialogueAudio() else { return }
        phase = .privatePlayback
        message = "正在耳机中播放译文。"
        task = Task {
            do {
                _ = try await audio.configurePlayback(side: listener.outputSide) { [weak self] reason in
                    self?.fail(reason, token: token)
                }
                for chunk in ReplayPolicy.chunks(for: text) {
                    try validate(token)
                    try await audio.speak(chunk, language: language, rate: Float(listener.speakingRate))
                }
                try validate(token)
                reset("耳机播放完成。")
            } catch { fail(error.localizedDescription, token: token) }
        }
    }

    func ask(_ question: DialogueQuestion) {
        if case .confirm = question, amountQuestion != question { return }
        guard let phrase = question.phrase(in: language) else { return }
        quietForAction { [weak self] in
            guard let self else { return }
            self.publicSpeech(original: question.label, text: phrase, language: self.language, question: question)
        }
    }

    private func publicSpeech(original: String, text: String, language: AppLanguage, question: DialogueQuestion?) {
        phase = .externalPlayback
        message = "正在用手机扬声器播放，收音已暂停。"
        let token = epoch
        reply.speakPrompt(original: original, translated: text, language: language, rate: Float(listener.speakingRate),
                          onStopped: { [weak self] in
            guard let self, self.epoch == token else { return }
            self.reset(self.reply.message)
            self.canShowTypingFallback = question == .writeNumber
        }, onPlayed: { [weak self] in
            guard let self, self.epoch == token else { return }
            if let question {
                self.history.addReply(original: original, translated: text, kind: .prompt, language: language)
                self.publishLine()
                if question == .writeNumber {
                    self.editor = DialogueEditor(purpose: .partnerInput, language: language)
                    self.phase = .editing
                    return
                }
            }
            self.completeAction()
        })
    }

    func beginCorrection(of id: UUID) {
        guard let draft = history.editorForCorrection(of: id) else { return }
        quietForAction { [weak self] in self?.editor = draft; self?.phase = .editing }
    }

    func submitEditor(_ id: UUID, text: String) {
        guard phase == .editing, !isEditingPlayback, let draft = editor, draft.id == id, draft.accepts(text) else { return }
        switch draft.purpose {
        case .partnerInput:
            guard history.addPartnerInput(text, editor: draft) else { return }
            publishLine()
            completeAction()
        case .correction(let oldID):
            isEditingPlayback = true
            let token = epoch
            reply.speakCorrection(text, language: draft.language, rate: Float(listener.speakingRate), onStopped: { [weak self] in
                guard let self, self.epoch == token else { return }
                self.isEditingPlayback = false
            }, onPlayed: { [weak self] in
                guard let self, self.epoch == token, self.editor?.id == id else { return }
                _ = self.history.recordCorrection(of: oldID, original: text, translated: self.reply.translated)
                self.publishLine()
                self.completeAction()
            })
        }
    }

    func cancelEditor(_ id: UUID) { if editor?.id == id { reset("已取消，收音保持关闭。") } }
    func showTypingFallback() {
        guard canShowTypingFallback else { return }
        quietForAction { [weak self] in
            guard let self else { return }
            self.canShowTypingFallback = false
            self.editor = DialogueEditor(purpose: .partnerInput, language: self.language)
            self.phase = .editing
        }
    }

    private func completeAction() {
        editor = nil
        isEditingPlayback = false
        if resumeAfterAction { resumeAfterAction = false; launch() }
        else { reset("已完成。") }
    }

    func removeVoiceprint() {
        guard phase == .idle else { return }
        do { try WearerVoiceprint.delete(); owner = []; enrolled = false; message = "已删除我的声纹。" }
        catch { message = error.localizedDescription }
    }

    private func validate(_ token: UUID) throws {
        try Task.checkCancellation()
        guard epoch == token else { throw CancellationError() }
    }

    private func publishLine() {
        if let last = history.entries.last { minutes.recordDialogue(last) }
        entries = history.entries
    }
    private func fail(_ reason: String, token: UUID) { if epoch == token { reset(reason) } }
    private func reset(_ note: String) {
        epoch = UUID()
        afterDrain = nil
        task?.cancel(); task = nil
        earWorker?.cancel(); earWorker = nil; earQueue.removeAll()
        reply.cancel()
        audio.stop()
        sessions.values.forEach { $0.cancel() }; sessions.removeAll()
        preparePair = nil; configuration = nil; editor = nil
        prepareWaiter?.resume(throwing: CancellationError())
        prepareWaiter = nil
        gallery = VoiceGallery(); owner = []
        resumeAfterAction = false; isEditingPlayback = false; canShowTypingFallback = false
        models = nil
        phase = .idle
        listener.releaseDialogueAudio()
        message = note
    }
}
