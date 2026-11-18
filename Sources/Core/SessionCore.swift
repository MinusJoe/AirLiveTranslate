import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case chinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }
    var name: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }
    var speechLocale: String {
        switch self {
        case .chinese: return "zh-CN"
        case .english: return "en-US"
        case .japanese: return "ja-JP"
        }
    }
}

enum SpeechVariant: String, CaseIterable, Identifiable, Sendable {
    case chineseMainland = "zh-CN"
    case chineseTaiwan = "zh-TW"
    case englishUS = "en-US"
    case englishUK = "en-GB"
    case englishAustralia = "en-AU"
    case englishIndia = "en-IN"
    case japaneseJapan = "ja-JP"
    var id: String { rawValue }
    var localeIdentifier: String { rawValue }
    var language: AppLanguage {
        switch self {
        case .chineseMainland, .chineseTaiwan: return .chinese
        case .japaneseJapan: return .japanese
        default: return .english
        }
    }
    var name: String {
        switch self {
        case .chineseMainland: return "普通话（中国大陆）"
        case .chineseTaiwan: return "国语（台湾）"
        case .englishUS: return "英语（美国）"
        case .englishUK: return "英语（英国）"
        case .englishAustralia: return "英语（澳大利亚）"
        case .englishIndia: return "英语（印度）"
        case .japaneseJapan: return "日语（日本）"
        }
    }
    static func defaultVariant(for language: AppLanguage) -> SpeechVariant {
        switch language {
        case .chinese: return .chineseMainland
        case .english: return .englishUS
        case .japanese: return .japaneseJapan
        }
    }
    static func supported(for language: AppLanguage, identifiers: [String]) -> [SpeechVariant] {
        allCases.filter { variant in variant.language == language && identifiers.contains(where: variant.matches) }
    }
    func matches(_ identifier: String) -> Bool {
        let requested = Locale(identifier: rawValue)
        let actual = Locale(identifier: identifier)
        return requested.language.languageCode == actual.language.languageCode && requested.region == actual.region
    }
}

enum CaptureSource: String, CaseIterable, Identifiable, Sendable {
    case headset, phone
    var id: String { rawValue }
    var name: String { self == .headset ? "耳机远场收音" : "手机麦克风（备用）" }
}

enum OutputSide: String, CaseIterable, Identifiable, Sendable {
    case both, left, right
    var id: String { rawValue }
    var name: String {
        switch self {
        case .both: return "双耳"
        case .left: return "左耳"
        case .right: return "右耳"
        }
    }
}

struct SessionEpoch: Equatable, Sendable {
    private(set) var value: UInt64 = 0
    @discardableResult mutating func advance() -> UInt64 {
        value &+= 1
        return value
    }
    func accepts(_ candidate: UInt64) -> Bool { value == candidate }
}

struct SpeechSegment: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let start: Double
    let end: Double
    let receivedAt: Date
    let committedAtUptime: TimeInterval

    init(text: String, start: Double, end: Double, receivedAt: Date = Date(),
         committedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        id = UUID()
        self.text = text
        self.start = start
        self.end = end
        self.receivedAt = receivedAt
        self.committedAtUptime = committedAtUptime
    }
}

/// Deduplicate by finalized audio range, never by text: repeated words can be genuine speech.
struct FinalizationLedger {
    private var lastEnd: Double = -.infinity

    mutating func accept(text: String, start: Double, end: Double) -> SpeechSegment? {
        guard start.isFinite, end.isFinite, end > start, end > lastEnd,
              start >= lastEnd - 0.001 else { return nil }
        lastEnd = end
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return SpeechSegment(text: trimmed, start: start, end: end)
    }
}

enum PipelineError: LocalizedError, Equatable {
    case message(String)
    case backlog
    case staleSegment
    case oversizedSegment
    case synthesisBacklog
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .backlog: return "译文已积压，已暂停收音。未播完的片段已标记，请稍后重新开始。"
        case .staleSegment: return "译文落后超过 20 秒，已暂停，避免继续播放过时内容。"
        case .oversizedSegment: return "识别片段过长，已暂停。请让对方适当停顿后重试。"
        case .synthesisBacklog: return "语音合成缓冲已满，这段译音未播完。"
        }
    }
}

struct SegmentQueue {
    private(set) var items: [SpeechSegment] = []
    let capacity: Int
    let characterLimit: Int

    init(capacity: Int = 6, characterLimit: Int = 1800) {
        self.capacity = capacity
        self.characterLimit = characterLimit
    }

    mutating func append(_ segment: SpeechSegment) throws {
        guard segment.text.count <= 600 else { throw PipelineError.oversizedSegment }
        guard items.count < capacity,
              items.reduce(0, { $0 + $1.text.count }) + segment.text.count <= characterLimit else {
            throw PipelineError.backlog
        }
        items.append(segment)
    }

    mutating func pop(now: Date = Date()) throws -> SpeechSegment? {
        guard !items.isEmpty else { return nil }
        guard now.timeIntervalSince(items[0].receivedAt) <= 20 else { throw PipelineError.staleSegment }
        return items.removeFirst()
    }

    mutating func removeAll() { items.removeAll() }
    mutating func remove(ids: Set<UUID>) { items.removeAll { ids.contains($0.id) } }
}

enum CaptionStatus: String, Sendable {
    case waiting = "待翻译"
    case translating = "翻译中"
    case speaking = "播报中"
    case complete = "已播报"
    case interrupted = "未播完"
    case failed = "处理失败"
    case readyToSpeak = "待播报"
    case unspoken = "仅字幕·未播报"
    case superseded = "识别已修订"
    case corrected = "更正字幕·未重播"
}

struct Caption: Identifiable, Sendable {
    let id: UUID
    let original: String
    let targetLanguage: AppLanguage
    var translated: String = ""
    var status: CaptionStatus = .waiting
    var processingSeconds: Double?
    var isProvisional = false
    var note: String?
    var replayStatus: ReplayStatus = .never
    var lastReplayAt: Date?

    init(id: UUID, original: String, targetLanguage: AppLanguage = .chinese) {
        self.id = id
        self.original = original
        self.targetLanguage = targetLanguage
    }
}

/// Real output capability, including system mono mixing, gates one-ear playback.
struct OutputCapability: Equatable, Sendable {
    var channelCount: Int = 0
    var hasLeftRightLabels = false
    var systemMono = false
    var isHeadphones = false

    var supportsSingleEar: Bool {
        channelCount == 2 && hasLeftRightLabels && !systemMono && isHeadphones
    }

    func permits(_ side: OutputSide) -> Bool {
        isHeadphones && (side == .both || supportsSingleEar)
    }
}
