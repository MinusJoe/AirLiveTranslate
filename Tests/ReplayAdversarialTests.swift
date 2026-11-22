import XCTest
@testable import AirPodsTranslator

/// Independent replay-policy cases; actual microphone/route behavior still requires iOS tests.
final class ReplayAdversarialTests: XCTestCase {
    private func caption(_ text: String, status: CaptionStatus = .unspoken,
                         language: AppLanguage = .english, id: UUID = UUID()) -> Caption {
        var value = Caption(id: id, original: "source", targetLanguage: language)
        value.translated = text
        value.status = status
        return value
    }

    func testSupersededAndWhitespaceCannotBeReplayedOrCountedAsCatchUp() {
        for value in [caption("Old incorrect translation", status: .superseded),
                      caption(" \n\t "), caption("")] {
            XCTAssertFalse(ReplayPolicy.canReplay(value))
            XCTAssertFalse(ReplayPolicy.needsCatchUp(value))
        }
    }

    func testOversizedTranslationIsNotAdvertisedAsAnAvailableCatchUpItem() {
        let value = caption(String(repeating: "字", count: ReplayPolicy.maximumCaptionCharacters + 1))
        XCTAssertFalse(ReplayPolicy.canReplay(value))
        XCTAssertFalse(ReplayPolicy.needsCatchUp(value))
        let plan = ReplayPlan.make(from: [value])
        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertEqual(plan.unavailableCount, 1)
        XCTAssertEqual(plan.omittedCount, 0)
    }

    func testFinalCorrectionCanBeHeardButCompletedAutomaticSpeechIsNotCatchUp() {
        let corrected = caption("The meeting is cancelled.", status: .corrected)
        XCTAssertTrue(ReplayPolicy.canReplay(corrected))
        XCTAssertTrue(ReplayPolicy.needsCatchUp(corrected))
        let completed = caption("The meeting is cancelled.", status: .complete)
        XCTAssertTrue(ReplayPolicy.canReplay(completed), "Single replay remains available for already heard text")
        XCTAssertFalse(ReplayPolicy.needsCatchUp(completed))
    }

    func testSuccessfulCatchUpHistorySurvivesALaterInterruptedReplay() {
        var value = caption("Please wait here.")
        XCTAssertTrue(ReplayPolicy.needsCatchUp(value))
        value.lastReplayAt = Date(timeIntervalSince1970: 100)
        value.replayStatus = .completed
        XCTAssertFalse(ReplayPolicy.needsCatchUp(value))
        value.replayStatus = .interrupted
        XCTAssertFalse(ReplayPolicy.needsCatchUp(value), "A later failed optional replay must not erase earlier complete catch-up")
        XCTAssertEqual(value.status, .unspoken, "The first automatic playback outcome remains a separate fact")
        XCTAssertTrue(ReplayPolicy.canReplay(value))
    }

    func testPlanUsesEachCaptionLanguageAndDeduplicatesIDsWithoutReordering() {
        let japanese = caption("ここで待ってください。", language: .japanese)
        let english = caption("Please wait here.", language: .english)
        let chinese = caption("请在这里等候。", language: .chinese)
        let plan = ReplayPlan.make(from: [japanese, english, japanese, chinese])
        XCTAssertEqual(plan.items.map(\.id), [japanese.id, english.id, chinese.id])
        XCTAssertEqual(plan.items.map(\.language), [.japanese, .english, .chinese])
        XCTAssertEqual(plan.omittedCount, 0)
        XCTAssertEqual(plan.unavailableCount, 0)
    }

    func testBudgetDefersWholeItemsInsteadOfTruncatingOrSkippingAhead() {
        let first = caption("1234")
        let tooLargeForRemainder = caption("1234567890")
        let later = caption("x")
        let plan = ReplayPlan.make(from: [first, tooLargeForRemainder, later], totalCharacterLimit: 5)
        XCTAssertEqual(plan.items.map(\.text), ["1234"])
        XCTAssertEqual(plan.omittedCount, 2)
        XCTAssertEqual(plan.unavailableCount, 0)
        let emptyBudget = ReplayPlan.make(from: [first], maxItems: 0)
        XCTAssertTrue(emptyBudget.items.isEmpty)
        XCTAssertEqual(emptyBudget.omittedCount, 1)
    }

    func testChunksPreserveGraphemesAndEveryOriginalCharacter() {
        let group = "👨‍👩‍👧‍👦 👍🏽 🇯🇵 e\u{301} ここで待ってください。 不要支付 12.50 元； "
        let text = String(repeating: group, count: 30)
        let chunks = ReplayPolicy.chunks(for: text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= ReplayPolicy.maximumChunkCharacters })
        XCTAssertTrue(ReplayPolicy.chunks(for: "").isEmpty)
    }

    func testOldAttemptCompletionCannotFinishSameCaptionInANewAttempt() {
        var progress = ReplayProgress()
        let captionID = UUID()
        let first = progress.begin()
        XCTAssertTrue(progress.startItem(captionID, token: first))
        progress.cancel()
        let second = progress.begin()
        XCTAssertTrue(progress.startItem(captionID, token: second))
        XCTAssertFalse(progress.finishItem(captionID, token: first))
        XCTAssertEqual(progress.itemID, captionID)
        XCTAssertTrue(progress.finishItem(captionID, token: second))
        XCTAssertNil(progress.itemID)
        XCTAssertFalse(progress.finishItem(captionID, token: second), "Duplicate completion must be ignored")
    }
}
