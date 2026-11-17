import Foundation

struct TextAudioBoundary: Equatable, Sendable {
    let characterOffset: Int
    let audioEnd: Double
}

struct RecognitionUpdate: Sendable {
    let text: String
    let isFinal: Bool
    let start: Double
    let end: Double
    var boundaries: [TextAudioBoundary] = []
}

struct CommittedSegment: Sendable {
    let segment: SpeechSegment
    let isProvisional: Bool
    let subtitleOnly: Bool
    var replacesIDs: [UUID] = []
}

struct CommitBatch: Sendable {
    var segments: [CommittedSegment] = []
    var revisedIDs: [UUID] = []
    var confirmedIDs: [UUID] = []
    var draft = ""
}

/// An experimental conservative policy: only time-stable complete sentences can be speculative.
/// Final text is authoritative. A changed speculative prefix becomes an explicit subtitle correction.
struct StreamingCommitter {
    let lowLatencyEnabled: Bool
    let stabilitySeconds: TimeInterval
    let confirmations: Int
    private var finalizedThrough: Double = -.infinity
    private var phraseStart: Double?
    private var committedPrefix = ""
    private var committedIDs: [UUID] = []
    private var committedThrough: Double = -.infinity
    private var revisionSeen = false
    private var candidate = ""
    private var candidateSince: TimeInterval = 0
    private var candidateCount = 0
    var pendingIDs: [UUID] { committedIDs }

    init(lowLatencyEnabled: Bool = true, stabilitySeconds: TimeInterval = 0.45, confirmations: Int = 3) {
        self.lowLatencyEnabled = lowLatencyEnabled
        self.stabilitySeconds = stabilitySeconds
        self.confirmations = confirmations
    }

    mutating func process(_ update: RecognitionUpdate, now: TimeInterval) -> CommitBatch {
        var batch = CommitBatch(draft: update.isFinal ? "" : update.text)
        guard update.start.isFinite, update.end.isFinite, now.isFinite,
              update.end > update.start, update.end > finalizedThrough,
              update.start >= finalizedThrough - 0.001 else { return CommitBatch() }
        if let phraseStart, abs(phraseStart - update.start) > 0.05 {
            if update.start >= committedThrough - 0.001 || committedIDs.isEmpty {
                // A changed phrase boundary is not proof that an earlier speculative result was final.
                // Revoke it explicitly instead of leaving an unconfirmed spoken caption behind.
                batch.revisedIDs = committedIDs
                resetPhrase()
            } else if !revisionSeen {
                batch.revisedIDs = committedIDs
                revisionSeen = true
            }
        }
        if phraseStart == nil { phraseStart = update.start }
        if !committedPrefix.isEmpty && !update.text.hasPrefix(committedPrefix) && !revisionSeen {
            batch.revisedIDs = committedIDs
            revisionSeen = true
        }

        if update.isFinal {
            let finalText = revisionSeen ? update.text : String(update.text.dropFirst(committedPrefix.count))
            let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let start = revisionSeen ? update.start : max(update.start, committedThrough)
                if update.end > start {
                    batch.segments.append(CommittedSegment(
                        segment: SpeechSegment(text: text, start: start, end: update.end, committedAtUptime: now),
                        isProvisional: false, subtitleOnly: revisionSeen,
                        replacesIDs: revisionSeen ? committedIDs : []))
                }
            }
            if !revisionSeen { batch.confirmedIDs = committedIDs }
            finalizedThrough = max(finalizedThrough, update.end)
            resetPhrase()
            return batch
        }

        guard lowLatencyEnabled, !revisionSeen else { return batch }
        let characters = Array(update.text)
        let committedCount = committedPrefix.count
        guard committedCount <= characters.count else { return batch }
        batch.draft = String(characters.dropFirst(committedCount)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let boundary = sentenceBoundary(in: characters, after: committedCount) else {
            candidate = ""
            candidateCount = 0
            return batch
        }
        let prefix = String(characters[committedCount..<boundary])
        if prefix != candidate || now < candidateSince {
            candidate = prefix
            candidateSince = now
            candidateCount = 1
        } else {
            candidateCount += 1
        }
        guard candidateCount >= confirmations, now - candidateSince >= stabilitySeconds,
              let audioEnd = reliableEnd(at: boundary, text: characters, boundaries: update.boundaries),
              audioEnd > max(update.start, committedThrough), update.end - audioEnd >= 0.15 else { return batch }
        let segment = SpeechSegment(text: prefix.trimmingCharacters(in: .whitespacesAndNewlines),
                                    start: max(update.start, committedThrough), end: audioEnd, committedAtUptime: now)
        batch.segments.append(CommittedSegment(segment: segment, isProvisional: true, subtitleOnly: false))
        committedIDs.append(segment.id)
        committedPrefix = String(characters.prefix(boundary))
        committedThrough = audioEnd
        candidate = ""
        candidateCount = 0
        batch.draft = String(characters.dropFirst(boundary)).trimmingCharacters(in: .whitespacesAndNewlines)
        return batch
    }

    private mutating func resetPhrase() {
        phraseStart = nil
        committedPrefix = ""
        committedIDs.removeAll()
        committedThrough = -.infinity
        revisionSeen = false
        candidate = ""
        candidateCount = 0
    }

    private func sentenceBoundary(in text: [Character], after start: Int) -> Int? {
        guard start < text.count else { return nil }
        let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e"]
        for index in start..<text.count where ".!?。！？".contains(text[index]) {
            if text[index] == "." {
                if index + 1 < text.count && !text[index + 1].isWhitespace { continue }
                let preceding = String(text[start..<index]).split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
                let word = preceding.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if abbreviations.contains(word) || word.count == 1 || word.contains(".") { continue }
            }
            let candidate = String(text[start...index])
            let letters = candidate.filter(\.isLetter).count
            let cjk = candidate.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }
            let words = candidate.split(whereSeparator: { $0.isWhitespace }).count
            if letters >= 6 && (cjk || words >= 3) { return index + 1 }
        }
        return nil
    }

    private func reliableEnd(at offset: Int, text: [Character], boundaries: [TextAudioBoundary]) -> Double? {
        // Punctuation can have no timing attribute; allow only punctuation/whitespace after a timed run.
        let eligible = boundaries.filter { boundary in
            guard boundary.characterOffset > 0, boundary.characterOffset <= offset,
                  boundary.characterOffset <= text.count, boundary.audioEnd.isFinite else { return false }
            return text[boundary.characterOffset..<offset].allSatisfy { $0.isWhitespace || $0.isPunctuation }
        }
        return eligible.max(by: { $0.characterOffset < $1.characterOffset })?.audioEnd
    }
}

struct SpeechJob: Identifiable, Sendable {
    let id: UUID
    let captionID: UUID?
    let text: String
    let committedAtUptime: TimeInterval
    let queuedAtUptime: TimeInterval
    let estimatedSeconds: Double
}

struct SpeechPlaybackQueue {
    private(set) var items: [SpeechJob] = []
    let capacity: Int
    let durationLimit: Double
    init(capacity: Int = 4, durationLimit: Double = 12) {
        self.capacity = max(1, capacity)
        self.durationLimit = max(1, durationLimit)
    }
    var estimatedDuration: Double {
        items.reduce(0) { $0 + ($1.captionID == nil ? min(durationLimit, $1.estimatedSeconds) : $1.estimatedSeconds) }
    }
    mutating func append(_ job: SpeechJob) -> [SpeechJob] {
        if job.captionID == nil {
            // One urgent correction notice is enough; never let ordinary translations evict it.
            guard !items.contains(where: { $0.captionID == nil }) else { return [] }
            items.insert(job, at: 0)
        } else {
            items.append(job)
        }
        var omitted: [SpeechJob] = []
        while items.count > capacity || estimatedDuration > durationLimit {
            guard let index = items.firstIndex(where: { $0.captionID != nil }) else { break }
            omitted.append(items.remove(at: index))
        }
        return omitted
    }
    mutating func pop() -> SpeechJob? { items.isEmpty ? nil : items.removeFirst() }
    mutating func remove(captionIDs: Set<UUID>) -> [SpeechJob] {
        let removed = items.filter { $0.captionID.map(captionIDs.contains) == true }
        items.removeAll { $0.captionID.map(captionIDs.contains) == true }
        return removed
    }
    mutating func removeAll() -> [SpeechJob] {
        let removed = items
        items.removeAll()
        return removed
    }
}

enum SpeechPacing {
    static func estimatedDuration(text: String, language: AppLanguage) -> Double {
        if language == .english {
            return max(0.6, Double(text.split(whereSeparator: { $0.isWhitespace }).count) / 2.8)
        }
        return max(0.6, Double(text.filter { !$0.isWhitespace && !$0.isPunctuation }.count) / 5)
    }
    static func rate(base: Float, queuedSeconds: Double, adaptive: Bool) -> Float {
        let base = min(0.6, max(0.35, base))
        guard adaptive else { return base }
        let uplift = min(0.12, max(0, queuedSeconds - 2) * 0.012)
        return min(0.65, base + Float(uplift))
    }
}

struct ProcessingMetrics: Sendable {
    var translationSeconds: Double?
    var playbackQueueSeconds: Double?
    var firstBufferScheduledSeconds: Double?
}

enum CaptionRetention {
    static func trim(_ captions: inout [Caption], limit: Int = 200, protecting protectedIDs: Set<UUID>) {
        while captions.count > limit {
            guard let index = captions.firstIndex(where: { !protectedIDs.contains($0.id) }) else { return }
            captions.remove(at: index)
        }
    }
}
