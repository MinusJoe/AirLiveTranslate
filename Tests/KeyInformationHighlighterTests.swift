import Foundation
import XCTest
@testable import AirPodsTranslator

final class KeyInformationHighlighterTests: XCTestCase {
    private func matches(_ text: String, kind: KeyInformationKind) -> [String] {
        KeyInformationHighlighter.highlights(in: text)
            .filter { $0.kind == kind }
            .map { (text as NSString).substring(with: $0.range) }
    }

    func testAmountsKeepSymbolsDecimalsAndGroupingTogether() {
        XCTAssertEqual(matches("Pay $1,250.50, EUR 25.00, or ２０００円.", kind: .amount),
                       ["$1,250.50", "EUR 25.00", "２０００円"])
    }

    func testDateAndTimeAreNotFragmentedIntoNumbers() {
        let text = "Meet on 2026-11-18 at 14:30, then November 19, 2026."
        XCTAssertEqual(matches(text, kind: .dateTime), ["2026-11-18", "14:30", "November 19, 2026"])
        XCTAssertTrue(matches(text, kind: .number).isEmpty)
    }

    func testChineseDateCurrencyAndNegation() {
        let text = "不是十五元，是五十元。十一月十八日下午三点付款，不要迟到。"
        XCTAssertEqual(matches(text, kind: .amount), ["十五元", "五十元"])
        XCTAssertEqual(matches(text, kind: .negation), ["不是", "不要"])
        XCTAssertTrue(matches(text, kind: .dateTime).contains("十一月十八日"))
        XCTAssertTrue(matches(text, kind: .dateTime).contains("下午三点"))
    }

    func testEnglishNegationHasWordBoundariesAndSupportsCurlyApostrophes() {
        let text = "Not notable: we can’t go, cannot pay, and won’t agree."
        XCTAssertEqual(matches(text, kind: .negation), ["Not", "can’t", "cannot", "won’t"])
    }

    func testJapaneseNegationAndDates() {
        let text = "明日、午後三時には参加しません。費用は無料ではありません。"
        XCTAssertEqual(matches(text, kind: .negation), ["しません", "ではありません"])
        XCTAssertEqual(matches(text, kind: .dateTime), ["明日", "午後三時"])
    }

    func testRangesPreserveUnicodeAndNeverOverlap() {
        let text = "👨‍👩‍👧‍👦 Café e\u{301}: not $20 at 15:00. 1️⃣"
        let highlights = KeyInformationHighlighter.highlights(in: text)
        let boundaries = Set(text.indices.map { $0.utf16Offset(in: text) } + [text.utf16.count])
        for highlight in highlights {
            XCTAssertTrue(boundaries.contains(highlight.range.location))
            XCTAssertTrue(boundaries.contains(NSMaxRange(highlight.range)))
        }
        for (left, right) in zip(highlights, highlights.dropFirst()) {
            XCTAssertLessThanOrEqual(NSMaxRange(left.range), right.range.location)
        }
        XCTAssertFalse(matches(text, kind: .number).contains("1"))
    }

    func testEmptyAndOversizedInputFallBackToPlainText() {
        XCTAssertTrue(KeyInformationHighlighter.highlights(in: "").isEmpty)
        XCTAssertTrue(KeyInformationHighlighter.highlights(in: String(repeating: "1", count: 16_001)).isEmpty)
    }

    func testRepeatedNumbersHaveIndependentPositions() {
        let text = "15 and 15, not 50."
        XCTAssertEqual(matches(text, kind: .number), ["15", "15", "50"])
        XCTAssertEqual(matches(text, kind: .negation), ["not"])
    }
}
