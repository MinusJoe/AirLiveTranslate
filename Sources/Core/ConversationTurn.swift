import Foundation

struct ConversationTurn {
    private var ledger = FinalizationLedger()
    private(set) var confirmed = ""
    private(set) var partial = ""

    static func partnerLanguage(source: AppLanguage, target: AppLanguage) -> AppLanguage {
        if target != .chinese { return target }
        return source == .chinese ? .english : source
    }

    mutating func receive(_ update: RecognitionUpdate) throws {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard update.start.isFinite, update.end.isFinite, update.end > update.start,
              update.end > ledger.lastEnd, update.start >= ledger.lastEnd - 0.001 else { return }
        guard confirmed.count + text.count <= 1800 else { throw PipelineError.message("这次发言较长，请分两次说。") }
        if update.isFinal {
            if let finalized = ledger.accept(text: text, start: update.start, end: update.end) {
                confirmed += (confirmed.isEmpty ? "" : " ") + finalized.text
            }
            partial = ""
        } else { partial = text }
    }

    var displayed: String { [confirmed, partial].filter { !$0.isEmpty }.joined(separator: " ") }
}
