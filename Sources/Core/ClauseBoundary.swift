import Foundation

/// Candidate cuts inside a sentence. The caller still checks recognizer stability
/// and word-level audio timing before sending any of these to translation or TTS.
enum ClauseBoundary {
    private static func rule(_ pattern: String) -> NSRegularExpression {
        // Fixed patterns; compilation is checked when the corresponding language is tested.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // Require an audible start of the NEXT proposition. "And a ..." in an object
    // list, and silence after a comma, are insufficient evidence to speak the left.
    private static let englishRestart = rule(#"\b(?:(?:and(?:\s+then)?|but|so|then|however|meanwhile)\s+)?(?:(?:i|we|you|they|he|she|it|(?:the|our|their)\s+(?:team|client|customer|manager|report|meeting|project))\s+(?:will|would|can|could|should|must|may|have|has|had|are|were|is|was|need(?:s)?|plan(?:s)?|[a-z]{3,}ed|sent|made|took|began)\s+|(?:we|you|they|he|she|i|it)['’](?:ll|re|ve|d)\s+)[a-z]+"#)
    private static let englishPredicate = rule(#"\b(?:(?:i|we|you|they|he|she|it|(?:the|our|their)\s+[a-z]+)\s+(?:(?:just|already|finally|also)\s+)*(?:[a-z]{3,}ed|sent|met|won|lost|wrote|built|bought|made|did|went|ran|got|found|took|paid|sold|gave|chose|left|came|became)|(?:is|are|was|were|am|can|will|have|has|had)\s+[a-z]+)\b"#)
    // A present-tense verb with a noun phrase, e.g. "we need more time".
    // Keep complements ("we need to ...") and open-ended lists out of this path.
    private static let englishPresentObject = rule(#"\b(?:i|we|you|they|he|she)\s+(?:needs?|wants?|uses?|prefers?|expects?)\s+(?:more|less|extra|another|the|our|your|this|that)\s+[a-z]+(?:\s+[a-z]+){0,2}$"#)
    private static let englishDependent = rule(#"\b(?:if|unless|whether|although|because|until|when|while|either|between|that|which|who|whose|not\s+only|as\s+long\s+as)\b"#)
    private static let englishOpenEnd = rule(#"(?:\b(?:a|an|the|my|your|our|their|this|these|to|of|for|from|at|by|with|into|about|on|as|than|and|but|or|not|no|only|is|are|was|were|can|could|will|would|should|must|have|has|had|think|thought|said|told|believe|believed|know|knew|sure|mean)|[-+.$£¥€])$"#)
    private static let englishStandaloneEnd = rule(#"\b(?:ready|complete|completed|finished|done|approved|available|closed|open|over|started|delivered|arrived)$"#)

    private static let chineseRestart = rule(#"(?:(?:但(?:是)?|不过|不過|然后|然後|所以|因此|接下来|接下來|同时|同時|而且|另外)[，,、\s]*)?(?:我们|我們|他们|他們|你们|你們|我|他|她|你|大家|团队|團隊)(?:接下来|接下來|现在|現在|明天|随后|隨後|已经|已經|还|還|也|就|再|将|將)*(?:可以|会|會|计划|計劃|准备|準備|要|需要|开始|開始|决定|決定|进行|進行)\p{Han}"#)
    private static let chineseStandaloneEnd = rule(#"(?:了|完毕|完畢|完成|结束|結束|通过|通過|就绪|就緒|到齐|到齊|收到|到达|到達|生效|公布|确定|確定)$"#)
    private static let chinesePredicate = rule(#"(?:完成了|确认了|確認了|收到了|通过了|通過了|发出了|發出了|提交了|决定了|決定了|安排了|检查了|檢查了|已经|已經)"#)
    private static let chineseDependent = rule(#"(?:如果|假如|除非|是否|只要|只有|虽然|雖然|因为|因為|一旦|要是|不但|不仅|不僅|并非只有|是不是)"#)

    private static let japaneseRestart = rule(#"(?:そして|それから|しかし|一方で|その後|次に|または次に|続いて|ですので|そこで|ただし)[、，,\s]*[\p{Han}\p{Hiragana}\p{Katakana}]{2}|(?:私たち|私達|こちら|弊社|次の工程)(?:は|が)[\p{Han}\p{Hiragana}\p{Katakana}]{2}"#)
    private static let japaneseEnd = rule(#"(?:ました|ませんでした|ません|でしょう|です|だった|終わった|決まった|届いた|完了した|承認した)$"#)
    private static let japaneseDependent = rule(#"(?:もし|かどうか|ならば|たとえ|だけでなく|としても)"#)
    private static let softSeparators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，、;；"))

    static func fragment(_ text: String) -> String {
        let suffix = text.drop(while: { $0.unicodeScalars.allSatisfy(softSeparators.contains) })
        return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func candidates(in characters: [Character], after start: Int, language: AppLanguage) -> [Int] {
        // Scope grammar work per partial. Unusually long/ambiguous clauses can still
        // be delivered by the existing sentence/final paths without truncating text.
        let text = String(characters.dropFirst(start).prefix(512))
        let restart: NSRegularExpression
        switch language {
        case .english: restart = englishRestart
        case .chinese: restart = chineseRestart
        case .japanese: restart = japaneseRestart
        }
        var offsets: [Int] = []
        for match in restart.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let left = text[..<range.lowerBound]
            // Keep separators on the draft side: punctuation insertion at the cut
            // should not invalidate an otherwise identical spoken prefix.
            guard let last = left.lastIndex(where: { !String($0).unicodeScalars.allSatisfy(softSeparators.contains) }) else { continue }
            let cut = left.index(after: last)
            let clause = fragment(String(left[..<cut]))
            guard clause.count >= 6 else { continue }
            switch language {
            case .english:
                let words = clause.split(whereSeparator: \.isWhitespace)
                guard words.count >= 3, matches(englishPredicate, clause) || matches(englishPresentObject, clause),
                      !matches(englishDependent, clause),
                      !matches(englishOpenEnd, clause) else { continue }
                let marker = text[range].lowercased().split(whereSeparator: \.isWhitespace).first
                let explicit = ["and", "but", "so", "then", "however", "meanwhile"].contains(String(marker ?? ""))
                let hasSeparator = left[cut...].contains { ",;".contains($0) }
                guard explicit || hasSeparator || matches(englishStandaloneEnd, clause) else { continue }
            case .chinese:
                guard !matches(chineseDependent, clause),
                      matches(chineseStandaloneEnd, clause) || (matches(chinesePredicate, clause) && !clause.hasSuffix("的")) else { continue }
            case .japanese:
                guard matches(japaneseEnd, clause), !matches(japaneseDependent, clause) else { continue }
            }
            offsets.append(start + text.distance(from: text.startIndex, to: cut))
        }
        return offsets
    }
}
