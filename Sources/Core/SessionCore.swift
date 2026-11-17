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

    init(text: String, start: Double, end: Double, receivedAt: Date = Date()) {
        id = UUID()
        self.text = text
        self.start = start
        self.end = end
        self.receivedAt = receivedAt
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
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .backlog: return "译文已积压，已暂停收音。未播完的片段已标记，请稍后重新开始。"
        case .staleSegment: return "译文落后超过 20 秒，已暂停，避免继续播放过时内容。"
        case .oversizedSegment: return "识别片段过长，已暂停。请让对方适当停顿后重试。"
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
}

enum CaptionStatus: String, Sendable {
    case waiting = "待翻译"
    case translating = "翻译中"
    case speaking = "播报中"
    case complete = "已播报"
    case interrupted = "未播完"
    case failed = "处理失败"
}

struct Caption: Identifiable, Sendable {
    let id: UUID
    let original: String
    var translated: String = ""
    var status: CaptionStatus = .waiting
    var processingSeconds: Double?
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
