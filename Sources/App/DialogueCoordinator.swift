import Combine
import Foundation

@MainActor
final class DialogueCoordinator: ObservableObject {
    let listener: TranslationViewModel
    let reply = ConversationReplyModel()
    @Published private(set) var language: AppLanguage
    @Published private(set) var entries: [DialogueEntry] = []
    @Published private(set) var amountQuestion: DialogueQuestion?
    @Published private(set) var editor: DialogueEditor?
    @Published private(set) var canShowTypingFallback = false
    @Published private var handoff = DialogueHandoff()
    private let chineseVariant: SpeechVariant
    private var transcript: DialogueTranscript
    private var subscriptions: Set<AnyCancellable> = []
    private var openPage = false
    private var waitingForPreparation = false
    private var excludedContext: UUID?

    init(listener: TranslationViewModel) {
        self.listener = listener
        language = ConversationTurn.partnerLanguage(source: listener.source, target: listener.target)
        chineseVariant = listener.sourceVariant.language == .chinese ? listener.sourceVariant : .chineseMainland
        transcript = DialogueTranscript(existing: listener.captions)
    }

    var isListeningRequested: Bool { handoff.wantsListener }
    var canBeginReply: Bool { openPage && editor == nil && handoff.replyToken == nil && reply.phase == .idle }
    var canChangeLanguage: Bool { canBeginReply }

    func open() {
        guard !openPage, listener.awarenessConfirmed else { return }
        openPage = true
        // A live listener may already have heard the price the user wants to ask
        // about. Import only its latest utterance, never a prior session's captions.
        let carry = listener.isRunning && listener.source == language && listener.target == .chinese
            ? listener.latestSessionCaptionID : nil
        transcript = DialogueTranscript(existing: listener.captions.filter { $0.id != carry })
        reply.warmResources(language: language, variant: chineseVariant)
        listener.$captions.sink { [weak self] captions in
            guard let self, self.openPage else { return }
            self.transcript.observe(captions)
            self.publishTranscript()
        }.store(in: &subscriptions)
        listener.$state.dropFirst().sink { [weak self] state in
            guard let self, self.openPage, self.handoff.wantsListener else { return }
            if state == .failed || state == .paused {
                self.waitingForPreparation = false
                self.handoff.pause()
            } else if state == .idle, self.waitingForPreparation {
                // @Published sends state in willSet; start only once the listener is configurable.
                Task { @MainActor [weak self] in self?.startWhenPrepared() }
            }
        }.store(in: &subscriptions)
        startListening()
    }

    func selectLanguage(_ choice: AppLanguage) {
        guard canChangeLanguage, choice != .chinese, choice != language else { return }
        let shouldListen = handoff.wantsListener
        pause()
        language = choice
        reply.warmResources(language: choice, variant: chineseVariant)
        excludedContext = entries.last(where: { $0.speaker == .partner })?.id
        amountQuestion = nil
        if shouldListen { startListening() }
    }

    func startListening() {
        guard openPage, editor == nil, listener.awarenessConfirmed, handoff.replyToken == nil else { return }
        canShowTypingFallback = false
        if listener.source != language || listener.target != .chinese {
            stopPartner()
            if listener.source != language { listener.source = language }
            if listener.target != .chinese { listener.target = .chinese }
        }
        handoff.listen()
        guard !listener.isRunning && !listener.isBusy else { return }
        if listener.resourcesReady {
            waitingForPreparation = false
            listener.start()
        } else {
            waitingForPreparation = true
            listener.requestPreparation(forListening: true)
        }
    }

    private func startWhenPrepared() {
        guard openPage, waitingForPreparation, handoff.wantsListener, listener.state == .idle,
              listener.resourcesReady else { return }
        waitingForPreparation = false
        listener.start()
    }

    func press() {
        guard let token = takeOutgoingTurn() else { return }
        reply.start(language: language, variant: chineseVariant, source: listener.captureSource,
                    rate: Float(listener.speakingRate),
                    onStopped: { [weak self] in self?.stopped(token) },
                    onPlayed: { [weak self] in self?.played(token) })
    }

    func release() {
        guard openPage, handoff.replyToken != nil else { return }
        reply.finish()
    }

    func ask(_ prompt: DialogueQuestion) {
        if case .confirm = prompt, prompt != amountQuestion { return }
        guard let phrase = prompt.phrase(in: language), let token = takeOutgoingTurn() else { return }
        reply.speakPrompt(original: prompt.label, translated: phrase, language: language,
                          rate: Float(listener.speakingRate),
                          onStopped: { [weak self] in self?.stopped(token, offerTyping: prompt == .writeNumber) },
                          onPlayed: { [weak self] in self?.played(token, prompt: prompt) })
    }

    private func takeOutgoingTurn() -> UUID? {
        guard canBeginReply, let token = handoff.beginReply() else { return nil }
        canShowTypingFallback = false
        waitingForPreparation = false
        stopPartner()
        return token
    }

    private func played(_ token: UUID, prompt: DialogueQuestion? = nil) {
        let needsInput = prompt == .writeNumber
        guard openPage, handoff.finishPlayback(token, resumeListening: !needsInput) else { return }
        transcript.addReply(original: reply.original, translated: reply.translated,
                            kind: prompt == nil ? .reply(reply.language) : .prompt)
        publishTranscript()
        if needsInput {
            editor = DialogueEditor(purpose: .partnerInput, language: reply.language)
        } else { startListening() }
    }

    func beginCorrection(of entryID: UUID) {
        guard canBeginReply, let draft = transcript.editorForCorrection(of: entryID) else { return }
        pause()
        editor = draft
    }

    func submitEditor(_ editorID: UUID, text: String) {
        guard openPage, let draft = editor, draft.id == editorID, draft.accepts(text),
              handoff.replyToken == nil, reply.phase == .idle else { return }
        switch draft.purpose {
        case .partnerInput:
            guard transcript.addPartnerInput(text, editor: draft) else { return }
            publishTranscript()
            editor = nil
            startListening()
        case .correction(let entryID):
            guard transcript.editorForCorrection(of: entryID) != nil, let token = handoff.beginReply() else { return }
            reply.speakCorrection(text, language: draft.language, rate: Float(listener.speakingRate),
                                  onStopped: { [weak self] in self?.stopped(token) },
                                  onPlayed: { [weak self] in
                guard let self, self.openPage, self.editor?.id == editorID,
                      self.handoff.finishPlayback(token) else { return }
                guard self.transcript.recordCorrection(of: entryID, original: text, translated: self.reply.translated) else {
                    self.handoff.pause()
                    self.editor = nil
                    return
                }
                self.publishTranscript()
                self.editor = nil
                self.startListening()
            })
        }
    }

    func cancelEditor(_ editorID: UUID) {
        guard editor?.id == editorID else { return }
        pause()
        editor = nil
    }

    private func stopped(_ token: UUID, offerTyping: Bool = false) {
        guard openPage, handoff.replyToken == token else { return }
        handoff.failedReply(token)
        canShowTypingFallback = offerTyping
    }

    func showTypingFallback() {
        guard canShowTypingFallback, canBeginReply else { return }
        pause()
        editor = DialogueEditor(purpose: .partnerInput, language: language)
    }

    private func publishTranscript() {
        guard entries != transcript.entries else { return }
        let old = entries.last(where: { $0.speaker == .partner })
        entries = transcript.entries
        let latest = entries.last(where: { $0.speaker == .partner })
        if latest?.id != old?.id || latest?.isProvisional != old?.isProvisional || latest?.original != old?.original {
            if let latest, latest.kind == .heard, !latest.isProvisional, latest.id != excludedContext {
                amountQuestion = DialogueQuestion.contextual(in: latest.original)
            } else { amountQuestion = nil }
        }
    }

    private func stopPartner() {
        if listener.isRunning || listener.isBusy || listener.isReplaying { listener.stop() }
    }

    func cancelReply() {
        guard handoff.replyToken != nil else { return }
        handoff.pause()
        reply.cancel()
    }

    func pause() {
        handoff.pause()
        canShowTypingFallback = false
        waitingForPreparation = false
        reply.cancel()
        stopPartner()
    }

    func close() {
        guard openPage else { return }
        openPage = false
        subscriptions.removeAll()
        pause()
        editor = nil
    }
}
