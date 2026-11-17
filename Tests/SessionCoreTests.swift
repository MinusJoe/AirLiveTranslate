import XCTest
@testable import AirPodsTranslator

final class SessionCoreTests: XCTestCase {
    func testEndingSessionRejectsLateTranslation() {
        var epoch = SessionEpoch()
        let first = epoch.advance()
        XCTAssertTrue(epoch.accepts(first))
        epoch.advance()
        XCTAssertFalse(epoch.accepts(first))
        let next = epoch.advance()
        XCTAssertTrue(epoch.accepts(next))
        XCTAssertFalse(epoch.accepts(first))
    }

    func testFinalizationDeduplicatesRangesButPreservesRepeatedSpeech() {
        var ledger = FinalizationLedger()
        XCTAssertNotNil(ledger.accept(text: "谢谢", start: 0, end: 1))
        XCTAssertNil(ledger.accept(text: "谢谢", start: 0, end: 1))
        XCTAssertNil(ledger.accept(text: "修订", start: 0.5, end: 1.5))
        XCTAssertNotNil(ledger.accept(text: "谢谢", start: 1, end: 2))
        XCTAssertNil(ledger.accept(text: "bad", start: .nan, end: 3))
    }

    func testBacklogDoesNotSilentlyDiscardAcceptedSpeech() throws {
        var queue = SegmentQueue(capacity: 1)
        let accepted = SpeechSegment(text: "hello", start: 0, end: 1)
        try queue.append(accepted)
        XCTAssertThrowsError(try queue.append(SpeechSegment(text: "later", start: 1, end: 2))) {
            XCTAssertEqual($0 as? PipelineError, .backlog)
        }
        XCTAssertEqual(try queue.pop()?.id, accepted.id)
        XCTAssertNil(try queue.pop())
    }

    func testStaleQueuePausesInsteadOfSpeakingOldText() throws {
        let date = Date(timeIntervalSince1970: 100)
        var queue = SegmentQueue()
        try queue.append(SpeechSegment(text: "old", start: 0, end: 1, receivedAt: date))
        XCTAssertThrowsError(try queue.pop(now: date.addingTimeInterval(21))) {
            XCTAssertEqual($0 as? PipelineError, .staleSegment)
        }
        XCTAssertEqual(queue.items.count, 1)
    }

    func testMonoAndUnknownLayoutsCannotClaimSingleEarSupport() {
        var capability = OutputCapability(channelCount: 1, hasLeftRightLabels: false,
                                          systemMono: false, isHeadphones: true)
        XCTAssertTrue(capability.permits(.both))
        XCTAssertFalse(capability.permits(.right))
        capability.channelCount = 2
        XCTAssertFalse(capability.permits(.left))
        capability.hasLeftRightLabels = true
        XCTAssertTrue(capability.permits(.left))
        capability.systemMono = true
        XCTAssertFalse(capability.permits(.left))
        capability.systemMono = false
        capability.isHeadphones = false
        XCTAssertFalse(capability.permits(.both))
    }

    func testQueueCharacterBudgetAndOversizedInput() throws {
        var queue = SegmentQueue(characterLimit: 5)
        try queue.append(SpeechSegment(text: "12345", start: 0, end: 1))
        XCTAssertThrowsError(try queue.append(SpeechSegment(text: "6", start: 1, end: 2)))
        var large = SegmentQueue()
        XCTAssertThrowsError(try large.append(SpeechSegment(text: String(repeating: "a", count: 601), start: 0, end: 1))) {
            XCTAssertEqual($0 as? PipelineError, .oversizedSegment)
        }
    }
}
