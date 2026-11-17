import XCTest
@testable import AirPodsTranslator

final class StreamingCoreTests: XCTestCase {
    func testUnstableNegationDoesNotCommitBeforeBoundaryStabilizes() {
        var committer = StreamingCommitter()
        func update(_ text: String) -> RecognitionUpdate {
            RecognitionUpdate(text: text, isFinal: false, start: 0, end: 3,
                              boundaries: [TextAudioBoundary(characterOffset: text.count, audioEnd: 2)])
        }
        XCTAssertTrue(committer.process(update("We can enter."), now: 0).segments.isEmpty)
        XCTAssertTrue(committer.process(update("We cannot enter."), now: 0.25).segments.isEmpty)
        XCTAssertTrue(committer.process(update("We cannot enter."), now: 0.5).segments.isEmpty)
        XCTAssertEqual(committer.process(update("We cannot enter."), now: 0.8).segments.map { $0.segment.text }, ["We cannot enter."])
    }

    func testCommaAndJapaneseIncompleteClauseWaitForFinal() {
        for text in ["If we receive payment,", "明日の会議に参加するかどうか、"] {
            var committer = StreamingCommitter()
            let update = RecognitionUpdate(text: text, isFinal: false, start: 0, end: 3,
                                           boundaries: [TextAudioBoundary(characterOffset: text.count, audioEnd: 2)])
            for index in 0..<5 { XCTAssertTrue(committer.process(update, now: Double(index)).segments.isEmpty) }
            let final = RecognitionUpdate(text: text, isFinal: true, start: 0, end: 3)
            XCTAssertEqual(committer.process(final, now: 5).segments.map { $0.segment.text }, [text])
        }
    }

    func testNoAudioLookaheadDoesNotSpeculate() {
        var committer = StreamingCommitter()
        let text = "Please turn left."
        let update = RecognitionUpdate(text: text, isFinal: false, start: 0, end: 2,
                                       boundaries: [TextAudioBoundary(characterOffset: text.count, audioEnd: 2)])
        for index in 0..<5 { XCTAssertTrue(committer.process(update, now: Double(index)).segments.isEmpty) }
    }

    func testPreviouslyFinalizedAudioCannotBeRepeatedByALatePartial() {
        var committer = StreamingCommitter()
        let final = RecognitionUpdate(text: "Please turn left.", isFinal: true, start: 0, end: 2)
        XCTAssertEqual(committer.process(final, now: 0).segments.count, 1)
        let late = RecognitionUpdate(text: "Please turn left. Wait here.", isFinal: false, start: 0, end: 4,
                                     boundaries: [TextAudioBoundary(characterOffset: 17, audioEnd: 2)])
        for index in 1..<5 { XCTAssertTrue(committer.process(late, now: Double(index)).segments.isEmpty) }
    }

    func testOversizedSpeechIsExplicitlyOmittedAndNotQueuedForever() {
        let id = UUID()
        let job = SpeechJob(id: UUID(), captionID: id, text: "long", committedAtUptime: 0,
                            queuedAtUptime: 1, estimatedSeconds: 13)
        var queue = SpeechPlaybackQueue()
        XCTAssertEqual(queue.append(job).map(\.captionID), [id])
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testTranslationLaneCanProgressWhileSpeechStillHasPendingWork() throws {
        var translation = SegmentQueue(capacity: 8)
        var playback = SpeechPlaybackQueue()
        let first = SpeechSegment(text: "first", start: 0, end: 1)
        let second = SpeechSegment(text: "second", start: 1, end: 2)
        try translation.append(first)
        try translation.append(second)
        let translated = try XCTUnwrap(translation.pop())
        XCTAssertTrue(playback.append(SpeechJob(id: UUID(), captionID: translated.id, text: "第一句",
                                               committedAtUptime: 0, queuedAtUptime: 1, estimatedSeconds: 2)).isEmpty)
        XCTAssertEqual(try translation.pop()?.id, second.id)
        XCTAssertEqual(playback.items.count, 1, "The translation lane must not require speech completion to dequeue its next item.")
    }

    func testSkipInvalidatesPlaybackWithoutInvalidatingTranslationAndStopInvalidatesBoth() {
        var session = SessionEpoch()
        var speech = SessionEpoch()
        let translationToken = session.advance()
        let oldSpeechToken = speech.advance()
        let newSpeechToken = speech.advance()
        XCTAssertTrue(session.accepts(translationToken))
        XCTAssertFalse(speech.accepts(oldSpeechToken))
        XCTAssertTrue(speech.accepts(newSpeechToken))
        session.advance()
        speech.advance()
        XCTAssertFalse(session.accepts(translationToken))
        XCTAssertFalse(speech.accepts(newSpeechToken))
    }

    func testAdaptiveRateIsBoundedAndOptOutPreservesSelectedRate() {
        XCTAssertEqual(SpeechPacing.rate(base: 0.5, queuedSeconds: 0, adaptive: true), 0.5)
        XCTAssertGreaterThan(SpeechPacing.rate(base: 0.5, queuedSeconds: 8, adaptive: true), 0.5)
        XCTAssertEqual(SpeechPacing.rate(base: 0.5, queuedSeconds: 100, adaptive: false), 0.5)
        XCTAssertLessThanOrEqual(SpeechPacing.rate(base: 0.6, queuedSeconds: 100, adaptive: true), 0.65)
    }

    func testRegionalSelectionNeverSilentlyFallsBackToAnotherRegion() {
        XCTAssertEqual(SpeechVariant.supported(for: .english, identifiers: ["en_US", "en-GB"]), [.englishUS, .englishUK])
        XCTAssertFalse(SpeechVariant.englishUK.matches("en-US"))
        XCTAssertTrue(SpeechVariant.chineseMainland.matches("zh-Hans-CN"))
        XCTAssertTrue(SpeechVariant.chineseTaiwan.matches("zh_Hant_TW"))
        XCTAssertFalse(SpeechVariant.chineseTaiwan.matches("zh-Hans-CN"))
    }
}
