import XCTest
@testable import AirPodsTranslator

final class ConversationTurnTests: XCTestCase {
    func testPartnerLanguageWorksFromEitherHomeDirection() {
        XCTAssertEqual(ConversationTurn.partnerLanguage(source: .japanese, target: .chinese), .japanese)
        XCTAssertEqual(ConversationTurn.partnerLanguage(source: .chinese, target: .english), .english)
        XCTAssertEqual(ConversationTurn.partnerLanguage(source: .chinese, target: .chinese), .english)
    }

    func testFinalReplyUsesRevisedNumbersAndRetainsTheLastUtterance() throws {
        var turn = ConversationTurn()
        try turn.receive(.init(text: "订三晚", isFinal: false, start: 0, end: 1))
        XCTAssertEqual(turn.displayed, "订三晚")
        XCTAssertTrue(turn.confirmed.isEmpty)
        try turn.receive(.init(text: "订两晚。", isFinal: true, start: 0, end: 1.5))
        try turn.receive(.init(text: "要安静的房间", isFinal: false, start: 1.5, end: 3))
        try turn.receive(.init(text: "订三晚", isFinal: false, start: 0, end: 1))
        XCTAssertEqual(turn.displayed, "订两晚。 要安静的房间")
        try turn.receive(.init(text: "要安静的房间。", isFinal: true, start: 1.5, end: 3.2))
        XCTAssertEqual(turn.confirmed, "订两晚。 要安静的房间。")
    }

    func testInvalidTimeAndOversizeNeverBecomeAReply() throws {
        var turn = ConversationTurn()
        try turn.receive(.init(text: "修订", isFinal: true, start: 2, end: 1))
        XCTAssertThrowsError(try turn.receive(.init(text: String(repeating: "字", count: 1801), isFinal: true, start: 0, end: 3)))
        XCTAssertTrue(turn.confirmed.isEmpty)
    }

    func testFinalizationKeepsRentalQuestionAddedAtTheEndOfTheTurn() throws {
        var turn = ConversationTurn()
        try turn.receive(.init(text: "请问最晚", isFinal: false, start: 0, end: 0.6))
        try turn.receive(.init(text: "请问最晚还车时间？", isFinal: true, start: 0, end: 1.4))
        XCTAssertEqual(turn.confirmed, "请问最晚还车时间？")
    }
}
