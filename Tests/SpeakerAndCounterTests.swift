import XCTest
@testable import AirPodsTranslator

final class SpeakerAndCounterTests: XCTestCase {
    private func spoken(_ source: AppLanguage?, _ partner: AppLanguage, _ party: VoiceParty,
                        original: String, translated: String, mixed: Bool = false) -> DialogueTranscript {
        let line = GroupUtterance(text: original, source: source, embedding: nil, mixed: mixed)
        let direction = source.map {
            GroupDirection(source: $0, partner: partner, party: party, enrolled: true, mixed: mixed)
        }
        var transcript = DialogueTranscript(existing: [])
        transcript.addSpoken(line, translation: translated, party: party, direction: direction, partner: partner)
        return transcript
    }

    func testWrongGuestBecomesWearerAndKeepsTheOriginalConversationLanguage() throws {
        var transcript = spoken(.english, .english, .guest(0), original: "Two nights.", translated: "两晚。")
        let before = try XCTUnwrap(transcript.entries.first)
        let after = try XCTUnwrap(transcript.reassign(before.id, to: .wearer, source: .english, translation: before.original))
        XCTAssertEqual(transcript.entries.map(\.id), [before.id])
        XCTAssertEqual(after.original, before.original)
        XCTAssertEqual(after.speaker, .me)
        XCTAssertEqual(after.participantLabel, "我")
        XCTAssertEqual(after.playback(in: .headphones), .phoneSpeaker(.english))
        XCTAssertFalse(after.mayAutoPlayAfterAssignment(on: .headphones))
        XCTAssertEqual(CounterText(after, fallbackPartner: .japanese).partner, .english)
    }

    func testOnceAudioHasStartedEveryLaterAttributionRequiresATap() throws {
        var transcript = spoken(.english, .english, .unidentified, original: "Deposit?", translated: "押金？")
        let id = try XCTUnwrap(transcript.entries.first?.id)
        let first = try XCTUnwrap(transcript.reassign(id, to: .guest(1), source: .english, translation: "押金？"))
        XCTAssertTrue(first.mayAutoPlayAfterAssignment(on: .headphones))
        XCTAssertFalse(first.mayAutoPlayAfterAssignment(on: .phone))
        XCTAssertTrue(transcript.markAudioStarted(id))
        XCTAssertFalse(transcript.markAudioStarted(id))
        for party in [VoiceParty.wearer, .guest(0), .guest(1)] {
            let text = party == .wearer ? "Deposit?" : "押金？"
            let changed = try XCTUnwrap(transcript.reassign(id, to: party, source: .english, translation: text))
            XCTAssertTrue(changed.audioStarted)
            XCTAssertFalse(changed.mayAutoPlayAfterAssignment(on: .headphones))
            XCTAssertNotNil(changed.playback(in: .phone))
        }
    }

    func testUncertainOrOverlappingRoleCanBeClarifiedWithoutForcingPlayback() throws {
        var transcript = spoken(nil, .japanese, .unidentified, original: "いくらですか", translated: "", mixed: true)
        let id = try XCTUnwrap(transcript.entries.first?.id)
        XCTAssertNil(transcript.reassign(id, to: .guest(8), source: .japanese, translation: "多少钱？"))
        XCTAssertNil(transcript.reassign(id, to: .guest(1), source: .english, translation: "多少钱？"))
        XCTAssertNil(transcript.reassign(id, to: .guest(1), source: .japanese, translation: " "))
        let row = try XCTUnwrap(transcript.reassign(id, to: .guest(1), source: .japanese, translation: "多少钱？"))
        XCTAssertEqual(row.participantLabel, "对方 B")
        XCTAssertEqual(row.sourceLanguage, .japanese)
        XCTAssertFalse(row.mayAutoPlayAfterAssignment(on: .headphones))
    }

    func testMinutesAndReferencesAreUpdatedInPlaceWithTheirOriginalTimestamp() throws {
        var transcript = spoken(.english, .english, .guest(0), original: "Hello.", translated: "你好。")
        let row = try XCTUnwrap(transcript.entries.first)
        var minutes = MeetingMinutes()
        let time = Date(timeIntervalSince1970: 42)
        minutes.recordDialogue(row, at: time)
        let change = try XCTUnwrap(transcript.reassign(row.id, to: .guest(1), source: .english, translation: "您好。"))
        minutes.updateAttribution(change)
        XCTAssertEqual(minutes.lines.count, 1)
        XCTAssertEqual(minutes.lines.first?.time, time)
        XCTAssertEqual(minutes.lines.first?.participant, "对方 B")
        XCTAssertEqual(minutes.attributionRevision, 1)
        XCTAssertTrue(minutes.export(summary: nil).contains("您好。"))
        XCTAssertTrue(minutes.summaryChunks().first?.text.contains("[1] 对方 B：Hello.") == true)
    }

    func testCounterOrdersLanguagesInBothDirectionsAndPreservesTypedValues() throws {
        let incoming = spoken(.japanese, .japanese, .guest(0), original: "二泊です", translated: "住两晚")
        let a = CounterText(try XCTUnwrap(incoming.entries.first), fallbackPartner: .english)
        XCTAssertEqual(a.foreign, "二泊です")
        XCTAssertEqual(a.chinese, "住两晚")
        var outgoing = spoken(.chinese, .english, .wearer, original: "两晚", translated: "Two nights")
        let b = CounterText(try XCTUnwrap(outgoing.entries.first), fallbackPartner: .japanese)
        XCTAssertEqual(b.foreign, "Two nights")
        XCTAssertEqual(b.chinese, "两晚")
        XCTAssertTrue(outgoing.addPartnerInput("0017", editor: DialogueEditor(purpose: .partnerInput, language: .japanese)))
        let typed = try XCTUnwrap(outgoing.entries.last)
        XCTAssertFalse(typed.canAssignSpeaker)
        let c = CounterText(typed, fallbackPartner: .english)
        XCTAssertEqual(c.partner, .japanese)
        XCTAssertEqual(c.foreign, "0017")
        XCTAssertEqual(c.chinese, "0017")
    }

    func testCounterRequestsOnlyTheMissingSideAndNeverMislabelsUnknownAudio() throws {
        let owner = spoken(.english, .english, .wearer, original: "Yes", translated: "Yes")
        let pair = CounterText(try XCTUnwrap(owner.entries.first), fallbackPartner: .english)
        XCTAssertNil(pair.chinese)
        XCTAssertEqual(pair.foreign, "Yes")
        let unknown = spoken(nil, .japanese, .unidentified, original: "Raw", translated: "")
        let other = CounterText(try XCTUnwrap(unknown.entries.first), fallbackPartner: .english)
        XCTAssertNil(other.source)
        XCTAssertNil(other.chinese)
        XCTAssertNil(other.foreign)
        XCTAssertEqual(other.original, "Raw")
    }
}
