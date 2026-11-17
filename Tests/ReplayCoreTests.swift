import XCTest
@testable import AirPodsTranslator

final class ReplayCoreTests: XCTestCase {
    private func caption(_ text: String = "Hello.", language: AppLanguage = .english,
                         status: CaptionStatus = .unspoken) -> Caption {
        var caption = Caption(id: UUID(), original: "原文", targetLanguage: language)
        caption.translated = text
        caption.status = status
        return caption
    }

    func testReplayKeepsTheSavedLanguageForEachCaption() {
        let english = caption("Hello.", language: .english)
        let japanese = caption("こんにちは。", language: .japanese)
        let plan = ReplayPlan.make(from: [english, japanese])
        XCTAssertEqual(plan.items.map(\.language), [.english, .japanese])
        XCTAssertEqual(plan.items.map(\.text), ["Hello.", "こんにちは。"])
    }

    func testUnheardListSeparatesFirstPlaybackFromReplayHistory() {
        var item = caption()
        XCTAssertTrue(ReplayPolicy.needsCatchUp(item))
        item.replayStatus = .completed
        item.lastReplayAt = Date(timeIntervalSince1970: 1)
        XCTAssertFalse(ReplayPolicy.needsCatchUp(item))
        XCTAssertEqual(item.status, .unspoken)
        item.replayStatus = .interrupted
        XCTAssertFalse(ReplayPolicy.needsCatchUp(item), "Cancelling a later repeat cannot undo an earlier complete catch-up.")
        XCTAssertTrue(ReplayPolicy.canReplay(item))
    }

    func testSupersededAndEmptyTranslationsAreNeverPlayable() {
        XCTAssertFalse(ReplayPolicy.canReplay(caption(status: .superseded)))
        XCTAssertFalse(ReplayPolicy.needsCatchUp(caption(status: .superseded)))
        XCTAssertFalse(ReplayPolicy.canReplay(caption(" \n\t", status: .failed)))
        XCTAssertFalse(ReplayPolicy.needsCatchUp(caption("", status: .interrupted)))
        XCTAssertFalse(ReplayPolicy.canReplay(caption(String(repeating: "字", count: 1801))))
        XCTAssertFalse(ReplayPolicy.needsCatchUp(caption(String(repeating: "字", count: 1801))))
    }

    func testCatchUpIncludesCorrectedAndFailedAudioButNotNormalPendingOrAlreadyHeard() {
        for status in [CaptionStatus.unspoken, .interrupted, .failed, .corrected] {
            XCTAssertTrue(ReplayPolicy.needsCatchUp(caption(status: status)))
        }
        for status in [CaptionStatus.complete, .readyToSpeak, .speaking, .waiting, .translating] {
            XCTAssertFalse(ReplayPolicy.needsCatchUp(caption(status: status)))
        }
    }

    func testBatchItemBudgetPreservesOrderAndReportsRemainingItems() {
        let items = (0..<23).map { caption("Sentence \($0).") }
        let plan = ReplayPlan.make(from: items)
        XCTAssertEqual(plan.items.map(\.id), Array(items.prefix(20)).map(\.id))
        XCTAssertEqual(plan.omittedCount, 3)
        XCTAssertEqual(plan.unavailableCount, 0)
    }

    func testTotalCharacterBudgetNeverTruncatesACaptionOrSkipsAhead() {
        let first = caption("123456")
        let second = caption("abcdef")
        let third = caption("x")
        let plan = ReplayPlan.make(from: [first, second, third], totalCharacterLimit: 10)
        XCTAssertEqual(plan.items.map(\.text), ["123456"])
        XCTAssertEqual(plan.omittedCount, 2)
    }

    func testChunkingPreservesEveryGraphemeAndDoesNotUseLiveSpeechExpiry() {
        let text = String(repeating: "你👨‍👩‍👧‍👦好。日本語。e\u{301} ", count: 80)
        let chunks = ReplayPolicy.chunks(for: text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= ReplayPolicy.maximumChunkCharacters })
        XCTAssertEqual(chunks.joined(), text)
        let long = caption(String(repeating: "长", count: 1200))
        XCTAssertGreaterThan(SpeechPacing.estimatedDuration(text: long.translated, language: .chinese), 12)
        XCTAssertEqual(ReplayPlan.make(from: [long]).items.count, 1)
    }

    func testDuplicateIDsCannotBeQueuedTwiceWithinOneBatch() {
        let item = caption()
        let plan = ReplayPlan.make(from: [item, item])
        XCTAssertEqual(plan.items.count, 1)
    }

    func testLateCompletionAfterCancelCannotCompleteNewCaption() {
        var progress = ReplayProgress()
        let oldID = UUID(), newID = UUID()
        let old = progress.begin()
        XCTAssertTrue(progress.startItem(oldID, token: old))
        progress.cancel()
        let new = progress.begin()
        XCTAssertTrue(progress.startItem(newID, token: new))
        XCTAssertFalse(progress.finishItem(oldID, token: old))
        XCTAssertFalse(progress.finishItem(newID, token: old))
        XCTAssertEqual(progress.itemID, newID)
        XCTAssertTrue(progress.finishItem(newID, token: new))
        XCTAssertNil(progress.itemID)
        XCTAssertFalse(progress.finishItem(newID, token: new))
    }

    func testNewAttemptInvalidatesTheOldAttemptEvenForSameCaption() {
        var progress = ReplayProgress()
        let id = UUID()
        let old = progress.begin()
        XCTAssertTrue(progress.startItem(id, token: old))
        let new = progress.begin()
        XCTAssertTrue(progress.startItem(id, token: new))
        XCTAssertFalse(progress.finishItem(id, token: old))
        XCTAssertTrue(progress.finishItem(id, token: new))
    }
}
