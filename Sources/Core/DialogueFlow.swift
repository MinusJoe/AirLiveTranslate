import Foundation

struct DialogueHandoff {
    private(set) var wantsListener = false
    private(set) var replyToken: UUID?

    mutating func listen() { replyToken = nil; wantsListener = true }
    mutating func pause() { replyToken = nil; wantsListener = false }

    mutating func beginReply() -> UUID? {
        guard replyToken == nil else { return nil }
        let token = UUID()
        replyToken = token
        wantsListener = false
        return token
    }

    mutating func finishPlayback(_ token: UUID, resumeListening: Bool = true) -> Bool {
        guard replyToken == token else { return false }
        if resumeListening { listen() } else { pause() }
        return true
    }

    mutating func failedReply(_ token: UUID) {
        if replyToken == token { pause() }
    }
}

struct DialogueEntry: Identifiable, Equatable {
    enum Speaker { case partner, me }
    enum Kind: Equatable {
        case heard, typed, prompt
        case reply(AppLanguage)
        case correction(AppLanguage, replaces: UUID)
    }
    let id: UUID
    let original: String
    var translated: String
    var isProvisional = false
    var kind: Kind = .heard
    var supersededBy: UUID?
    var party: VoiceParty?
    var sourceLanguage: AppLanguage?
    var translatedLanguage: AppLanguage?
    var partnerLanguage: AppLanguage?
    var overlapping = false
    var manuallyAssigned = false
    var audioStarted = false
    var participantLabel: String? { overlapping && !manuallyAssigned ? "多人发言 · 待确认" : party?.label }

    var canAssignSpeaker: Bool { party != nil && partnerLanguage != nil && supersededBy == nil && !isProvisional }
    var counterPartner: AppLanguage? {
        if let partnerLanguage { return partnerLanguage }
        switch kind {
        case .reply(let lang), .correction(let lang, _): return lang
        default: return [sourceLanguage, translatedLanguage].compactMap { $0 }.first { $0 != .chinese }
        }
    }

    var speaker: Speaker {
        if party == .wearer || party == .chineseSide { return .me }
        switch kind {
        case .heard, .typed: return .partner
        case .reply, .prompt, .correction: return .me
        }
    }

    var correctionLanguage: AppLanguage? {
        guard speaker == .me, supersededBy == nil else { return nil }
        switch kind {
        case .reply(let language), .correction(let language, _):
            return sourceLanguage == nil || sourceLanguage == .chinese ? language : nil
        default: return nil
        }
    }

    func mayAutoPlayAfterAssignment(on device: DialogueDevice) -> Bool {
        guard manuallyAssigned, !audioStarted, !overlapping, let party, case .guest = party,
              let sourceLanguage, let partnerLanguage else { return false }
        return device == .headphones && sourceLanguage == partnerLanguage && translatedLanguage == .chinese
    }

    func playback(in device: DialogueDevice) -> DialoguePlayback? {
        guard supersededBy == nil, !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        switch kind {
        case .reply(let language), .correction(let language, _): return .phoneSpeaker(language)
        case .prompt: return translatedLanguage.map(DialoguePlayback.phoneSpeaker)
        case .heard:
            guard let language = translatedLanguage else { return nil }
            return device == .phone ? .phoneSpeaker(language) : .earpiece(language)
        case .typed: return nil
        }
    }
}

struct DialogueEditor: Identifiable {
    enum Purpose { case partnerInput, correction(UUID) }
    let id = UUID()
    let purpose: Purpose
    let language: AppLanguage
    var initialText = ""

    func accepts(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, text.count <= ReplayPolicy.maximumCaptionCharacters else { return false }
        switch purpose {
        case .partnerInput: return true
        case .correction: return trimmed != initialText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

struct DialogueTranscript {
    private(set) var entries: [DialogueEntry] = []
    private var previousIDs: Set<UUID>
    init(existing: [Caption]) { previousIDs = Set(existing.map(\.id)) }

    mutating func observe(_ captions: [Caption]) {
        let removed = Set(captions.filter { $0.status == .superseded }.map(\.id))
        if !removed.isEmpty { entries.removeAll { removed.contains($0.id) } }
        let positions = Dictionary(uniqueKeysWithValues: entries.indices.map { (entries[$0].id, $0) })
        for caption in captions where !removed.contains(caption.id) {
            let line = DialogueEntry(id: caption.id, original: caption.original,
                                     translated: caption.translated, isProvisional: caption.isProvisional,
                                     translatedLanguage: caption.targetLanguage)
            if let index = positions[caption.id] {
                if entries[index] != line { entries[index] = line }
            } else if !previousIDs.contains(caption.id) {
                entries.append(line)
            }
        }
        previousIDs = Set(captions.map(\.id))
        trim()
    }

    mutating func addReply(original: String, translated: String, kind: DialogueEntry.Kind, language: AppLanguage? = nil) {
        entries.append(DialogueEntry(id: UUID(), original: original, translated: translated, kind: kind,
                                     sourceLanguage: .chinese, translatedLanguage: language, partnerLanguage: language))
        trim()
    }

    mutating func addSpoken(_ line: GroupUtterance, translation: String, party: VoiceParty,
                            direction: GroupDirection?, partner: AppLanguage) {
        let kind: DialogueEntry.Kind = direction.flatMap { $0.isOutgoingReply ? .reply($0.target) : nil } ?? .heard
        entries.append(DialogueEntry(id: UUID(), original: line.text, translated: translation,
                                     kind: kind, party: party, sourceLanguage: line.source,
                                     translatedLanguage: direction?.target, partnerLanguage: partner, overlapping: line.mixed))
        trim()
    }

    mutating func addPartnerInput(_ text: String, editor: DialogueEditor) -> Bool {
        guard case .partnerInput = editor.purpose, editor.accepts(text),
              !entries.contains(where: { $0.id == editor.id }) else { return false }
        entries.append(DialogueEntry(id: editor.id, original: text, translated: "", kind: .typed, partnerLanguage: editor.language))
        trim()
        return true
    }

    func editorForCorrection(of id: UUID) -> DialogueEditor? {
        guard let row = entries.first(where: { $0.id == id }), let language = row.correctionLanguage else { return nil }
        return DialogueEditor(purpose: .correction(id), language: language, initialText: row.original)
    }

    /// Commit only after the public playback succeeds. Both wordings stay in chronological order.
    mutating func recordCorrection(of id: UUID, original: String, translated: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              let editor = editorForCorrection(of: id), editor.accepts(original),
              !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let row = DialogueEntry(id: UUID(), original: original, translated: translated,
                                kind: .correction(editor.language, replaces: id), sourceLanguage: .chinese,
                                translatedLanguage: editor.language, partnerLanguage: editor.language, audioStarted: true)
        entries[index].supersededBy = row.id
        entries.append(row)
        trim()
        return true
    }

    @discardableResult mutating func markAudioStarted(_ id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].audioStarted else { return false }
        entries[index].audioStarted = true
        return true
    }

    /// Reassign one utterance in place; never update other entries or the voice gallery.
    mutating func reassign(_ id: UUID, to party: VoiceParty, source: AppLanguage, translation: String) -> DialogueEntry? {
        guard VoiceParty.assignable.contains(party), !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = entries.firstIndex(where: { $0.id == id }), entries[index].canAssignSpeaker,
              let partner = entries[index].partnerLanguage,
              entries[index].sourceLanguage.map({ $0 == source }) ?? (source == .chinese || source == partner) else { return nil }
        let target: AppLanguage = party == .wearer ? partner : .chinese
        entries[index].party = party
        entries[index].kind = party == .wearer ? .reply(partner) : .heard
        entries[index].sourceLanguage = source
        entries[index].translatedLanguage = target
        entries[index].translated = translation
        entries[index].manuallyAssigned = true
        return entries[index]
    }

    private mutating func trim() {
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }
}

enum DialogueQuestion: Identifiable, Equatable, CaseIterable {
    case repeatLast, slower, writeNumber, confirm(String)
    static let allCases: [Self] = [.repeatLast, .slower, .writeNumber]
    var id: String { label }

    var label: String {
        switch self {
        case .repeatLast: return "请再说一遍"
        case .slower: return "请慢一点"
        case .writeNumber: return "请写下数字"
        case .confirm(let value): return "确认 \(value)"
        }
    }

    func phrase(in language: AppLanguage) -> String? {
        switch (self, language) {
        case (.repeatLast, .english): return "Could you say that again, please?"
        case (.repeatLast, .japanese): return "すみません、もう一度言っていただけますか。"
        case (.slower, .english): return "Could you speak a little more slowly, please?"
        case (.slower, .japanese): return "もう少しゆっくり話していただけますか。"
        case (.writeNumber, .english): return "Could you type that on my phone, please?"
        case (.writeNumber, .japanese): return "こちらの画面に入力していただけますか。"
        case (.confirm(let value), .english): return "Just to check, did you say \(value)?"
        case (.confirm(let value), .japanese): return "確認ですが、\(value)とおっしゃいましたか。"
        case (_, .chinese): return nil
        }
    }

    private static let spokenNumber = { () -> NSRegularExpression? in
        let words = "(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million)"
        let english = #"\b(?:(?:minus|negative)\s+)?"# + words + "(?:[ -]+" + words + #")*(?:\s+(?:dollars?|euros?|pounds?|yen|percent))?\b"#
        let japanese = #"[0-9０-９零〇一二三四五六七八九十百千万億]+(?:[,.．，][0-9０-９]+)*(?:円|ドル|ユーロ|ポンド)"#
        return try? NSRegularExpression(pattern: english + "|" + japanese, options: .caseInsensitive)
    }()

    static func contextual(in original: String) -> Self? {
        guard !original.isEmpty, original.utf16.count <= 16_000 else { return nil }
        let highlights = KeyInformationHighlighter.highlights(in: original)
        guard !highlights.contains(where: { $0.kind == .dateTime }) else { return nil }
        var ranges = highlights.filter { $0.kind == .number || $0.kind == .amount }.map(\.range)
        for match in spokenNumber?.matches(in: original, range: NSRange(original.startIndex..., in: original)) ?? [] {
            // Preserve the longer form when the numeral alone was also highlighted.
            if ranges.contains(where: { NSIntersectionRange($0, match.range) == match.range }) { continue }
            ranges.removeAll { NSIntersectionRange($0, match.range) == $0 }
            ranges.append(match.range)
        }
        let sorted = ranges.sorted { $0.location < $1.location }.compactMap { Range($0, in: original) }
        guard (1...2).contains(sorted.count), let first = sorted.first, let last = sorted.last else { return nil }
        if sorted.count == 2 {
            guard first.upperBound <= last.lowerBound else { return nil }
            let separator = original[first.upperBound..<last.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
            guard ["or", "または", "あるいは", "それとも", "か"].contains(separator) else { return nil }
        }
        let quote = original[first.lowerBound..<last.upperBound]
        guard quote.count <= 64 else { return nil }
        return .confirm(String(quote))
    }
}
