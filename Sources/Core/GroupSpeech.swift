import Foundation

enum DialogueDevice: String, CaseIterable {
    case phone = "仅用手机"
    case headphones = "使用耳机"
}

enum DialoguePlayback: Equatable {
    case phoneSpeaker(AppLanguage)
    case earpiece(AppLanguage)
}

enum VoiceParty: Equatable, Sendable {
    case wearer, chineseSide, guest(Int), unidentified

    var label: String {
        switch self {
        case .wearer: return "我"
        case .chineseSide: return "中文发言"
        case .guest(let index): return "对方 " + String(UnicodeScalar(65 + index)!)
        case .unidentified: return "说话人待确认"
        }
    }

    static let assignable: [VoiceParty] = [.wearer] + (0..<8).map { .guest($0) }
}

struct VoiceGallery {
    private var guests: [[Float]] = []
    static let dimension = 256

    static func unit(_ v: [Float]) -> [Float]? {
        guard v.count == dimension, v.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0.0001 else { return nil }
        return v.map { $0 / norm }
    }

    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    mutating func identify(_ embedding: [Float]?, owner: [[Float]], language: AppLanguage?) -> VoiceParty {
        // Without enrollment, Chinese selects the translation direction, not an identity.
        if owner.isEmpty, language == .chinese { return .chineseSide }
        guard let embedding, let vector = Self.unit(embedding) else { return .unidentified }
        let rankings = guests.indices.map { ($0, Self.similarity(vector, guests[$0])) }.sorted { $0.1 > $1.1 }
        let best = rankings.first?.1 ?? -1
        if let score = owner.map({ Self.similarity(vector, $0) }).max() {
            if score >= 0.64, score - best >= 0.10 { return .wearer }
            if score > 0.38, best - score < 0.12 { return .unidentified }
        }
        if let first = rankings.first, best >= 0.58, best - (rankings.dropFirst().first?.1 ?? -1) >= 0.09 {
            return .guest(first.0)
        }
        guard best < 0.34, guests.count < 8 else { return .unidentified }
        guests.append(vector)
        return .guest(guests.count - 1)
    }
}

struct GroupUtterance: Sendable {
    let text: String
    let source: AppLanguage?
    let embedding: [Float]?
    let mixed: Bool
}

struct GroupDirection {
    let target: AppLanguage
    let isOutgoingReply: Bool
    let automaticHeadphones: Bool

    init(source: AppLanguage, partner: AppLanguage, party: VoiceParty, enrolled: Bool, mixed: Bool,
         device: DialogueDevice = .headphones) {
        let outgoing = party == .wearer || party == .chineseSide || (party == .unidentified && source == .chinese)
        target = outgoing ? partner : .chinese
        isOutgoingReply = outgoing && !mixed
        // A poor embedding in an enrolled conversation might actually be the wearer.
        automaticHeadphones = device == .headphones && !outgoing && source == partner && !mixed
            && (party != .unidentified || !enrolled)
    }
}

/// Short acoustic windows with a leading buffer and a quiet tail, at 16 kHz.
struct UtteranceWindower {
    private let frameSize = 320
    private var remainder: [Float] = []
    private var lead: [[Float]] = []
    private var audio: [Float] = []
    private var quietFrames = 0
    private var voicedFrames = 0
    private var noise: Float = 0.001
    let enrollment: Bool

    init(enrollment: Bool = false) { self.enrollment = enrollment }

    mutating func append(_ samples: [Float]) -> [[Float]] {
        remainder.append(contentsOf: samples)
        var result: [[Float]] = []
        var offset = 0
        while offset + frameSize <= remainder.count {
            let frame = Array(remainder[offset..<offset + frameSize])
            offset += frameSize
            let rms = sqrt(frame.reduce(0) { $0 + $1 * $1 } / Float(frameSize))
            let voiced = rms > max(0.0025, noise * 2.6)
            if audio.isEmpty && !voiced {
                noise = 0.96 * noise + 0.04 * min(rms, 0.018)
                lead.append(frame)
                if lead.count > 8 { lead.removeFirst() }
                continue
            }
            if audio.isEmpty { audio = lead.flatMap { $0 }; lead.removeAll(keepingCapacity: true) }
            audio.append(contentsOf: frame)
            if voiced { voicedFrames += 1; quietFrames = 0 } else { quietFrames += 1 }
            if quietFrames >= (enrollment ? 50 : 23) || audio.count >= (enrollment ? 9 : 7) * 16_000 {
                if let clip = take() { result.append(clip) }
            }
        }
        remainder.removeFirst(offset)
        return result
    }

    mutating func finish() -> [Float]? {
        if !audio.isEmpty { audio.append(contentsOf: remainder) }
        remainder.removeAll()
        return take()
    }

    private mutating func take() -> [Float]? {
        defer { audio = []; quietFrames = 0; voicedFrames = 0 }
        guard voicedFrames >= (enrollment ? 135 : 9) else { return nil }
        return audio
    }
}
