import XCTest
@testable import AirPodsTranslator

final class GroupSpeechTests: XCTestCase {
    private func voice(_ index: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: VoiceGallery.dimension)
        vector[index] = 1
        return vector
    }

    func testEnrolledWearerAcrossLanguagesAndTwoEnglishGuests() {
        let samples = [voice(0), voice(1)]
        var gallery = VoiceGallery()
        XCTAssertEqual(gallery.identify(voice(0), owner: samples, language: .chinese), .wearer)
        XCTAssertEqual(gallery.identify(voice(1), owner: samples, language: .english), .wearer)
        XCTAssertEqual(gallery.identify(voice(1), owner: samples, language: nil), .wearer)
        XCTAssertEqual(gallery.identify(voice(2), owner: samples, language: .english), .guest(0))
        XCTAssertEqual(gallery.identify(voice(3), owner: samples, language: .english), .guest(1))
        XCTAssertEqual(gallery.identify(voice(2), owner: samples, language: .chinese), .guest(0))
        var fresh = VoiceGallery()
        XCTAssertEqual(fresh.identify(voice(3), owner: samples, language: .english), .guest(0))
    }

    func testMissingUnreliableAndTiedEmbeddingsDoNotClaimIdentity() {
        var gallery = VoiceGallery()
        XCTAssertNil(VoiceGallery.unit([.nan]))
        XCTAssertNil(VoiceGallery.unit([Float](repeating: 0, count: 256)))
        XCTAssertEqual(gallery.identify(nil, owner: [], language: .chinese), .chineseSide)
        XCTAssertEqual(gallery.identify(nil, owner: [voice(0)], language: .chinese), .unidentified)
        _ = gallery.identify(voice(1), owner: [voice(0)], language: .english)
        var tied = voice(0)
        tied[1] = 1
        XCTAssertEqual(gallery.identify(tied, owner: [voice(0)], language: .english), .unidentified)
    }

    func testPublicPlaybackNeedsATapAndPrivateAudioFollowsTheForeignGuest() {
        for source in [AppLanguage.chinese, .english] {
            let mine = GroupDirection(source: source, partner: .english, party: .wearer, enrolled: true, mixed: false)
            XCTAssertEqual(mine.target, .english)
            XCTAssertTrue(mine.isOutgoingReply)
            XCTAssertFalse(mine.automaticHeadphones)
        }
        for id in 0...1 {
            let other = GroupDirection(source: .english, partner: .english, party: .guest(id), enrolled: true, mixed: false)
            XCTAssertEqual(other.target, .chinese)
            XCTAssertFalse(other.isOutgoingReply)
            XCTAssertTrue(other.automaticHeadphones)
        }
        XCTAssertFalse(GroupDirection(source: .english, partner: .english, party: .unidentified,
                                      enrolled: true, mixed: false).automaticHeadphones)
        XCTAssertFalse(GroupDirection(source: .english, partner: .english, party: .unidentified,
                                      enrolled: false, mixed: true).automaticHeadphones)
    }

    func testPhoneModeShowsBothTranslationsAndUsesTheirOwnLanguageOnTap() throws {
        var history = DialogueTranscript(existing: [])
        for (source, guest, expected) in [(AppLanguage.chinese, VoiceParty.wearer, AppLanguage.english),
                                          (.english, .guest(0), .chinese), (.english, .guest(1), .chinese)] {
            let direction = GroupDirection(source: source, partner: .english, party: guest,
                                           enrolled: true, mixed: false, device: .phone)
            XCTAssertEqual(direction.target, expected)
            XCTAssertFalse(direction.automaticHeadphones)
            let line = GroupUtterance(text: "original", source: source, embedding: nil, mixed: false)
            history.addSpoken(line, translation: "translation", party: guest, direction: direction)
            let row = try XCTUnwrap(history.entries.last)
            XCTAssertEqual(row.playback(in: .phone), .phoneSpeaker(expected))
            XCTAssertEqual(row.playback(in: .headphones), guest == .wearer ? .phoneSpeaker(.english) : .earpiece(.chinese))
        }
    }

    func testPlaybackUsesRecordedTargetEvenForOverlappingSpeechOrLaterLanguageChange() throws {
        var history = DialogueTranscript(existing: [])
        let mixed = GroupUtterance(text: "你好", source: .chinese, embedding: nil, mixed: true)
        let direction = GroupDirection(source: .chinese, partner: .japanese, party: .unidentified,
                                       enrolled: false, mixed: true, device: .phone)
        history.addSpoken(mixed, translation: "こんにちは", party: .unidentified, direction: direction)
        let row = try XCTUnwrap(history.entries.last)
        XCTAssertEqual(row.kind, .heard)
        XCTAssertFalse(direction.automaticHeadphones)
        XCTAssertEqual(row.playback(in: .phone), .phoneSpeaker(.japanese))
        history.addReply(original: "请再说一遍", translated: "Say that again, please.", kind: .prompt, language: .english)
        XCTAssertEqual(history.entries.last?.playback(in: .phone), .phoneSpeaker(.english))
        XCTAssertEqual(history.entries.first?.playback(in: .phone), .phoneSpeaker(.japanese))
    }

    func testObsoleteMissingAndTypedTranslationsHaveNoPlaybackButton() throws {
        var history = DialogueTranscript(existing: [])
        history.addReply(original: "三晚", translated: "Three nights.", kind: .reply(.english))
        let id = try XCTUnwrap(history.entries.first).id
        XCTAssertTrue(history.recordCorrection(of: id, original: "两晚", translated: "Two nights."))
        XCTAssertNil(history.entries.first?.playback(in: .phone))
        XCTAssertEqual(history.entries.last?.playback(in: .phone), .phoneSpeaker(.english))
        let unknown = GroupUtterance(text: "uncertain", source: nil, embedding: nil, mixed: false)
        history.addSpoken(unknown, translation: "", party: .unidentified, direction: nil)
        XCTAssertNil(history.entries.last?.playback(in: .phone))
        XCTAssertTrue(history.addPartnerInput("0017", editor: DialogueEditor(purpose: .partnerInput, language: .english)))
        XCTAssertNil(history.entries.last?.playback(in: .phone))
    }

    func testAcousticWindowsKeepLeadingAudioAndFinalWordsWithoutHoldingButton() {
        var gate = UtteranceWindower()
        let silence = [Float](repeating: 0, count: 320 * 12)
        let a = [Float](repeating: 0.1, count: 320 * 16)
        let b = [Float](repeating: 0.2, count: 320 * 12 + 3)
        XCTAssertTrue(gate.append(silence + a).isEmpty)
        let first = gate.append(silence + silence)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.filter { $0 == 0.1 }.count, a.count)
        XCTAssertTrue(gate.append(b).isEmpty)
        XCTAssertEqual(gate.finish()?.filter { $0 == 0.2 }.count, b.count)
        XCTAssertNil(gate.finish())
    }

    func testEnrollingRequiresLongerSpeechAndRejectsSilence() {
        var gate = UtteranceWindower(enrollment: true)
        XCTAssertTrue(gate.append([Float](repeating: 0, count: 32_000)).isEmpty)
        XCTAssertTrue(gate.append([Float](repeating: 0.1, count: 16_000)).isEmpty)
        XCTAssertNil(gate.finish())
    }

    func testSameLanguageWearerCanShowAndPlayWithoutRetranslationOrChineseCorrection() throws {
        var history = DialogueTranscript(existing: [])
        let line = GroupUtterance(text: "Two nights.", source: .english, embedding: nil, mixed: false)
        let direction = GroupDirection(source: .english, partner: .english, party: .wearer, enrolled: true, mixed: false)
        history.addSpoken(line, translation: line.text, party: .wearer, direction: direction)
        let row = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(row.kind, .reply(.english))
        XCTAssertNil(row.correctionLanguage)
        var minutes = MeetingMinutes()
        minutes.recordDialogue(row)
        XCTAssertEqual(minutes.lines.first?.participant, "我")
        XCTAssertTrue(minutes.export(summary: nil).contains("· 我"))
    }
}
