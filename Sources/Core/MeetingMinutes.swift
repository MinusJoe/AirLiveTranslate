import Foundation

struct MeetingLine: Identifiable, Sendable {
    let id: UUID
    let time: Date
    let original: String
    var translated = ""
    var participant: String?
}

enum MeetingFactKind: String, CaseIterable {
    case point = "讨论要点", decision = "会议决定", action = "待办事项"
}

struct MeetingFact {
    let kind: MeetingFactKind
    let text: String
    let source: Int
    let quote: String
}

struct MeetingFindings {
    private var facts: [MeetingFact] = []
    private var seen: Set<String> = []
    private var rejected = false

    mutating func add(_ fact: MeetingFact, from minutes: MeetingMinutes, allowedSources: Set<Int>) {
        let quote = fact.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = fact.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowedSources.contains(fact.source), fact.source > 0, fact.source <= minutes.lines.count,
              !text.isEmpty, !quote.isEmpty, minutes.lines[fact.source - 1].original.contains(quote) else {
            rejected = true
            return
        }
        if seen.insert(fact.kind.rawValue + "\n" + text).inserted { facts.append(fact) }
    }

    var formatted: String {
        var sections = MeetingFactKind.allCases.compactMap { kind -> String? in
            let items = facts.filter { $0.kind == kind }
            guard !items.isEmpty else { return nil }
            return ([kind.rawValue] + items.map { "• \($0.text) [\($0.source)]" }).joined(separator: "\n")
        }
        if sections.isEmpty { sections.append("从这些定稿发言中未提取到可核对的要点。") }
        if rejected { sections.append("部分生成内容未能对应原文引用，已略去。") }
        return sections.joined(separator: "\n\n")
    }
}

struct MeetingMinutes: Identifiable, Sendable {
    let id = UUID()
    private(set) var lines: [MeetingLine] = []
    private(set) var omitted = 0
    private var positions: [UUID: Int] = [:]
    private var pending: [UUID: MeetingLine] = [:]
    private let limit: Int

    init(limit: Int = 10_000) { self.limit = limit }

    mutating func ingest(_ batch: CommitBatch, audioOrigin: Date) {
        for id in batch.revisedIDs { pending.removeValue(forKey: id) }
        for id in batch.confirmedIDs {
            if let line = pending.removeValue(forKey: id) { confirm(line) }
        }
        for item in batch.segments {
            let segment = item.segment
            let line = MeetingLine(id: segment.id, time: audioOrigin.addingTimeInterval(segment.start), original: segment.text)
            if item.isProvisional { pending[segment.id] = line }
            else { confirm(line) }
        }
    }

    private mutating func confirm(_ line: MeetingLine) {
        guard positions[line.id] == nil else { return }
        guard lines.count < limit else { omitted += 1; return }
        positions[line.id] = lines.count
        lines.append(line)
    }

    mutating func setTranslation(_ text: String, for id: UUID) {
        if let index = positions[id] { lines[index].translated = text }
        else { pending[id]?.translated = text }
    }

    mutating func recordDialogue(_ row: DialogueEntry, at date: Date = Date()) {
        var participant = row.participantLabel ?? (row.speaker == .me ? "我" : "对方")
        if case .correction = row.kind { participant += " · 更正" }
        if row.kind == .typed { participant += " · 填写" }
        confirm(MeetingLine(id: row.id, time: date, original: row.original, translated: row.translated, participant: participant))
    }

    mutating func discardUnconfirmed() { pending.removeAll() }

    func export(summary: String?) -> String {
        let clock = DateFormatter()
        clock.dateStyle = .short
        clock.timeStyle = .medium
        var sections = ["会议纪要"]
        if let summary { sections.append("AI 总结（请核对原文）\n" + summary) }
        if omitted > 0 { sections.append("记录达到上限，另有 \(omitted) 段未收录。") }
        sections.append("会议记录 · 已定稿")
        for (index, line) in lines.enumerated() {
            var text = "[\(index + 1)] \(clock.string(from: line.time))" + (line.participant.map { " · " + $0 } ?? "") + "\n" + line.original
            if !line.translated.isEmpty { text += "\n" + line.translated }
            sections.append(text)
        }
        return sections.joined(separator: "\n\n")
    }

    // Sequential bounded prompts preserve source references, even when a single
    // finalized recognition is longer than the model input budget.
    struct Chunk {
        var text = ""
        var sources: Set<Int> = []
    }
    func summaryChunks(limit: Int = 1600) -> [Chunk] {
        precondition(limit >= 32)
        var chunks: [Chunk] = []
        var current = Chunk()
        var count = 0
        for (index, line) in lines.enumerated() {
            let prefix = "[\(index + 1)] " + (line.participant.map { String($0.prefix(10)) + "：" } ?? "")
            var rest = line.original[...]
            while !rest.isEmpty {
                let piece = rest.prefix(limit - prefix.count)
                let length = prefix.count + piece.count
                if count > 0 && count + 1 + length > limit {
                    chunks.append(current)
                    current = Chunk()
                    count = 0
                }
                if count > 0 { current.text += "\n"; count += 1 }
                current.text += prefix + piece
                current.sources.insert(index + 1)
                count += length
                rest = rest[piece.endIndex...]
            }
        }
        if !current.text.isEmpty { chunks.append(current) }
        return chunks
    }
}
