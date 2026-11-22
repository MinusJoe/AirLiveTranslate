import Foundation

/// Both people read the same utterance. Place text by language, not by speaker or bubble position.
struct CounterText: Equatable {
    let id: UUID
    let partner: AppLanguage
    let source: AppLanguage?
    let original: String
    let chinese: String?
    let foreign: String?

    init(_ row: DialogueEntry, fallbackPartner: AppLanguage) {
        id = row.id
        let other = row.counterPartner ?? fallbackPartner
        partner = other
        original = row.original
        let from = row.sourceLanguage ?? (row.party == nil && row.speaker == .me ? .chinese : nil)
        let to = row.translatedLanguage ?? row.correctionLanguage
        source = from
        func side(_ language: AppLanguage) -> String? {
            if row.kind == .typed || language == from { return row.original }
            if language == to && !row.translated.isEmpty { return row.translated }
            return nil
        }
        chinese = side(.chinese)
        foreign = side(other)
    }
}
