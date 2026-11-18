import Foundation

enum ReplayStatus: String, Sendable {
    case never = "未重播"
    case queued = "等待补听"
    case playing = "正在重播"
    case completed = "已完整补听"
    case interrupted = "重播未完成"
    case failed = "重播失败"
}

enum ReplayPolicy {
    static let maximumCaptionCharacters = 1800
    static let maximumChunkCharacters = 240

    static func canReplay(_ caption: Caption) -> Bool {
        caption.status != .superseded && !caption.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && caption.translated.count <= maximumCaptionCharacters
    }

    static func needsCatchUp(_ caption: Caption) -> Bool {
        guard canReplay(caption), caption.lastReplayAt == nil else { return false }
        return [.unspoken, .interrupted, .failed, .corrected].contains(caption.status)
    }

    /// Split only at Character boundaries; every character remains represented in concatenated chunks.
    static func chunks(for text: String) -> [String] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        var result: [String] = []
        var start = 0
        while start < characters.count {
            let limit = min(start + maximumChunkCharacters, characters.count)
            var end = limit
            if limit < characters.count {
                let lower = start + maximumChunkCharacters / 2
                if let boundary = (lower..<limit).last(where: {
                    characters[$0].isWhitespace || ".!?。！？；;".contains(characters[$0])
                }) { end = boundary + 1 }
            }
            result.append(String(characters[start..<end]))
            start = end
        }
        return result
    }
}

struct ReplayItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let language: AppLanguage
    let chunks: [String]
}

struct ReplayPlan: Sendable {
    let items: [ReplayItem]
    let omittedCount: Int
    let unavailableCount: Int

    static func make(from captions: [Caption], maxItems: Int = 20, totalCharacterLimit: Int = 12_000) -> ReplayPlan {
        var items: [ReplayItem] = []
        var characters = 0
        var unavailableCount = 0
        var omittedCount = 0
        var reachedLimit = false
        var seen: Set<UUID> = []
        for caption in captions where seen.insert(caption.id).inserted {
            guard ReplayPolicy.canReplay(caption) else { unavailableCount += 1; continue }
            if reachedLimit || items.count >= max(0, maxItems) || characters + caption.translated.count > max(0, totalCharacterLimit) {
                reachedLimit = true
                omittedCount += 1
                continue
            }
            items.append(ReplayItem(id: caption.id, text: caption.translated, language: caption.targetLanguage,
                                    chunks: ReplayPolicy.chunks(for: caption.translated)))
            characters += caption.translated.count
        }
        return ReplayPlan(items: items, omittedCount: omittedCount, unavailableCount: unavailableCount)
    }
}

/// Pure state for replay cancellation. A stale completion cannot complete a new item or attempt.
struct ReplayProgress {
    private var epoch = SessionEpoch()
    private(set) var itemID: UUID?

    mutating func begin() -> UInt64 {
        itemID = nil
        return epoch.advance()
    }
    func accepts(_ token: UInt64) -> Bool { epoch.accepts(token) }
    mutating func startItem(_ id: UUID, token: UInt64) -> Bool {
        guard accepts(token) else { return false }
        itemID = id
        return true
    }
    mutating func finishItem(_ id: UUID, token: UInt64) -> Bool {
        guard accepts(token), itemID == id else { return false }
        itemID = nil
        return true
    }
    mutating func cancel() {
        epoch.advance()
        itemID = nil
    }
}
