import Foundation
import XCTest
@testable import AirPodsTranslator

final class HighlightAdversarialTests: XCTestCase {
    private func texts(_ text: String, kind: KeyInformationKind) -> [String] {
        KeyInformationHighlighter.highlights(in: text).filter { $0.kind == kind }.compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    private func assertValidPartition(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let highlights = KeyInformationHighlighter.highlights(in: text)
        var boundaries = Set(text.indices.map { $0.utf16Offset(in: text) })
        boundaries.insert(text.utf16.count)
        var previousEnd = 0
        var reconstructed = ""
        let nsText = text as NSString
        for highlight in highlights {
            let range = highlight.range
            XCTAssertGreaterThan(range.length, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(range.location, previousEnd, file: file, line: line)
            XCTAssertLessThanOrEqual(NSMaxRange(range), text.utf16.count, file: file, line: line)
            XCTAssertTrue(boundaries.contains(range.location), file: file, line: line)
            XCTAssertTrue(boundaries.contains(NSMaxRange(range)), file: file, line: line)
            _ = try XCTUnwrap(Range(range, in: text), file: file, line: line)
            guard range.location >= previousEnd, NSMaxRange(range) <= text.utf16.count else { continue }
            reconstructed += nsText.substring(with: NSRange(location: previousEnd, length: range.location - previousEnd))
            reconstructed += nsText.substring(with: range)
            previousEnd = NSMaxRange(range)
        }
        reconstructed += nsText.substring(from: previousEnd)
        XCTAssertEqual(reconstructed, text, file: file, line: line)
    }

    func testEmojiAndCombiningMarksBeforeMatchesDoNotShiftUTF16Ranges() throws {
        let text = "👨‍👩‍👧‍👦 👍🏽 🇯🇵 e\u{301} 不要支付 $1,234.56；日期 2026-11-18，时间 14:30。"
        try assertValidPartition(text)
        XCTAssertEqual(texts(text, kind: .amount), ["$1,234.56"])
        XCTAssertTrue(texts(text, kind: .dateTime).contains("2026-11-18"))
        XCTAssertTrue(texts(text, kind: .dateTime).contains("14:30"))
    }

    func testKeycapAndCombiningDigitCannotBePartiallyHighlighted() throws {
        let text = "选择 1️⃣ 或 2\u{301}；实际数量 25。"
        try assertValidPartition(text)
        XCTAssertEqual(texts(text, kind: .number), ["25"])
    }

    func testEnglishNegationUsesWordBoundariesAndAcceptsCurlyApostrophes() throws {
        let text = "A notable innovation from nobody in the north cannot fail. We can’t pay; never assume otherwise."
        try assertValidPartition(text)
        XCTAssertEqual(texts(text, kind: .negation), ["cannot", "can’t", "never"])
    }

    func testJapaneseAdjectiveNaiIsNotMistakenForASentenceNegation() throws {
        let text = "危ない場所ではありません。少ない人数で参加しない。"
        try assertValidPartition(text)
        XCTAssertEqual(texts(text, kind: .negation), ["ではありません", "しない"])
    }

    func testAmountsAndDateTimesOwnTheirInternalDigitsWithoutOverlappingMatches() throws {
        let text = "USD 1,234.56 at 2026-11-18 14:30; ¥3,000 and 12.50元."
        try assertValidPartition(text)
        XCTAssertEqual(texts(text, kind: .amount), ["USD 1,234.56", "¥3,000", "12.50元"])
        XCTAssertEqual(texts(text, kind: .dateTime), ["2026-11-18", "14:30"])
        XCTAssertTrue(texts(text, kind: .number).isEmpty)
    }

    func testChineseNegationAndFullWidthAmountsPreserveTheOriginalSpelling() throws {
        let text = "不要付款，并非取消。金额￥３，０００．５０，优惠１５％。"
        try assertValidPartition(text)
        XCTAssertTrue(texts(text, kind: .negation).contains("不要"))
        XCTAssertTrue(texts(text, kind: .negation).contains("并非"))
        XCTAssertEqual(texts(text, kind: .amount), ["￥３，０００．５０"])
        XCTAssertTrue(texts(text, kind: .number).contains("１５％"))
    }

    func testEmptyAndOversizedOptionalHighlightingNeverFabricateRanges() throws {
        for text in ["", " \n\t ", String(repeating: "1", count: 16_001)] {
            XCTAssertTrue(KeyInformationHighlighter.highlights(in: text).isEmpty)
            try assertValidPartition(text)
        }
    }
}
