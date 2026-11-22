import Foundation

enum KeyInformationKind: String, Sendable {
    case number, amount, dateTime, negation

    fileprivate var priority: Int {
        switch self {
        case .amount: return 4
        case .dateTime: return 3
        case .negation: return 2
        case .number: return 1
        }
    }
}

struct KeyInformationHighlight: Equatable, Sendable {
    /// UTF-16 offsets, always aligned to complete Swift Characters.
    let range: NSRange
    let kind: KeyInformationKind
}

/// Visual cues, not entity extraction or translation validation. The source text is never rewritten.
/// Rules intentionally avoid isolated Chinese 无/非 and Japanese ない, which also occur in names/adjectives.
enum KeyInformationHighlighter {
    private struct Rule {
        let kind: KeyInformationKind
        let expression: NSRegularExpression
    }

    private static let number = #"[+＋\-−－]?(?:[0-9０-９]{1,3}(?:[,，][0-9０-９]{3})+|[0-9０-９]+)(?:[.．][0-9０-９]+)?"#
    private static let hanNumber = #"[零〇一二两兩三四五六七八九十百千万萬亿億]+"#

    private static let rules: [Rule] = {
        let quantity = "(?:" + number + "|" + hanNumber + ")"
        let englishNegation = #"(?<![\p{L}\p{N}_])(?:cannot|can['’]t|won['’]t|don['’]t|doesn['’]t|didn['’]t|isn['’]t|aren['’]t|wasn['’]t|weren['’]t|hasn['’]t|haven['’]t|hadn['’]t|shouldn['’]t|wouldn['’]t|couldn['’]t|mustn['’]t|needn['’]t|neither|never|not|nor|no)(?![\p{L}\p{N}_])"#
        let patterns: [(KeyInformationKind, String)] = [
            (.amount, #"(?<![\p{L}\p{N}_])(?:USD|EUR|GBP|JPY|CNY|RMB)\s*"# + number + #"(?![0-9０-９])"#),
            (.amount, #"[+＋\-−－]?[$＄€£¥￥]\s*"# + number),
            (.amount, quantity + #"\s*(?:美元|美金|人民币|人民幣|日元|日圓|日圆|欧元|歐元|英镑|英鎊|元|円|圓|块钱|塊錢|块|塊)"#),
            (.amount, number + #"\s*(?:USD|EUR|GBP|JPY|CNY|RMB|dollars?|euros?|pounds?|yen)(?![\p{L}\p{N}_])"#),
            (.dateTime, #"(?<![0-9０-９])[0-9０-９]{4}[-/／][0-9０-９]{1,2}[-/／][0-9０-９]{1,2}(?![0-9０-９])"#),
            (.dateTime, #"(?<![0-9０-９])[0-9０-９]{1,2}[:：][0-9０-９]{2}(?:[:：][0-9０-９]{2})?(?:\s*(?:a\.?m\.?|p\.?m\.?))?(?![\p{L}\p{N}_])"#),
            (.dateTime, "(?:" + quantity + "年)?" + quantity + "月" + quantity + "[日号號]"),
            (.dateTime, #"(?:上午|下午|晚上|凌晨|早上|午前|午後)?\s*"# + quantity + #"(?:点|點|時)(?:半|"# + quantity + "分)?"),
            (.dateTime, #"(?<![\p{L}\p{N}_])(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?\s+[0-9]{1,2}(?:st|nd|rd|th)?(?:,?\s+[0-9]{4})?(?![\p{L}\p{N}_])"#),
            (.dateTime, #"(?<![\p{L}\p{N}_])[0-9]{1,2}(?:st|nd|rd|th)?\s+(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)(?:\s+[0-9]{4})?(?![\p{L}\p{N}_])"#),
            (.dateTime, #"(?:今天|明天|后天|後天|昨天|下周|下週|本周|本週|周[一二三四五六日天]|週[一二三四五六日天]|今日|明日|明後日|昨日|来週|今週|[月火水木金土日]曜日)"#),
            (.dateTime, #"(?<![\p{L}\p{N}_])(?:today|tomorrow|yesterday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)(?![\p{L}\p{N}_])"#),
            (.negation, englishNegation),
            (.negation, #"(?:不(?:可以|允许|允許|超过|超過|低于|低於|高于|高於|同意|接受|参加|參加|存在|需要|应该|應該|是|要|能|会|會|可|需|得|必|应|應|该|該|许|許|行|去|来|來|收|付|含)|没有|沒有|没收到|沒收到|没完成|沒完成|尚未|并非|並非|禁止|无需|無需|无须|無須|无法|無法|无效|無效|未(?:经|經|能|收到|付款|确认|確認|完成|批准))"#),
            (.negation, #"(?:ではありません|じゃありません|ではない|じゃない|できません|出来ません|できない|出来ない|しません|ありません|ません|しない|必要ない|いらない|禁止|不可|不要)"#),
            (.number, #"(?<![A-Za-z0-9０-９_])"# + number + #"(?:[%％])?(?![A-Za-z0-9０-９_])"#),
            (.number, quantity + #"\s*(?:小时|小時|分钟|分鐘|秒钟|秒鐘|秒|時間|分間|人|个|個|位|次|份|件|台|张|張|天|周|週|个月|個月|年|公里|千米|米|公斤|千克|克)"#)
        ]
        // Bad optional highlighting must never crash the listening session. Tests cover every rule family.
        return patterns.compactMap { kind, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return Rule(kind: kind, expression: expression)
        }
    }()

    static func highlights(in text: String) -> [KeyInformationHighlight] {
        let length = text.utf16.count
        guard length > 0, length <= 16_000 else { return [] }
        let searchRange = NSRange(location: 0, length: length)
        var boundaries = Set(text.indices.map { $0.utf16Offset(in: text) })
        boundaries.insert(length)
        var candidates: [KeyInformationHighlight] = []
        for rule in rules {
            for match in rule.expression.matches(in: text, range: searchRange) {
                let range = match.range
                guard range.length > 0, boundaries.contains(range.location),
                      boundaries.contains(NSMaxRange(range)) else { continue }
                candidates.append(KeyInformationHighlight(range: range, kind: rule.kind))
            }
        }
        candidates.sort {
            if $0.kind.priority != $1.kind.priority { return $0.kind.priority > $1.kind.priority }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.range.location < $1.range.location
        }
        var selected: [KeyInformationHighlight] = []
        for candidate in candidates {
            guard !selected.contains(where: { NSIntersectionRange($0.range, candidate.range).length > 0 }) else { continue }
            selected.append(candidate)
        }
        return selected.sorted { $0.range.location < $1.range.location }
    }
}
