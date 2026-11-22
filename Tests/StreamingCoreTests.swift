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

    private func job(_ seconds: Double, text: String = "translation") -> SpeechJob {
        SpeechJob(id: UUID(), captionID: UUID(), text: text, committedAtUptime: 0,
                  queuedAtUptime: 1, estimatedSeconds: seconds)
    }

    func testLongUtteranceCanStartOnAnIdleQueue() {
        var queue = SpeechPlaybackQueue()
        let long = job(13)
        XCTAssertTrue(queue.append(long).isEmpty)
        XCTAssertEqual(queue.pop()?.id, long.id)
    }

    func testShortBurstKeepsOrderAndOnlyRealBacklogEvicts() {
        var queue = SpeechPlaybackQueue()
        let burst = (0..<8).map { _ in job(1) }
        for piece in burst { XCTAssertTrue(queue.append(piece).isEmpty) }
        let long = job(10)
        XCTAssertTrue(queue.append(long).isEmpty)
        let newest = job(1)
        XCTAssertEqual(queue.append(newest).map(\.id), burst.prefix(6).map(\.id))
        XCTAssertEqual(queue.items.map(\.id), Array(burst.suffix(2)).map(\.id) + [long.id, newest.id])
    }

    func testUnplayableTextDoesNotEvictOtherSpeech() {
        var queue = SpeechPlaybackQueue()
        let valid = job(1)
        let oversized = job(15, text: String(repeating: "字", count: 1801))
        _ = queue.append(valid)
        XCTAssertEqual(queue.append(oversized).first?.id, oversized.id)
        XCTAssertEqual(queue.pop()?.id, valid.id)
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

    func testRollingCaptionsKeepActiveJobsSoSkipCanRecordTheirOmission() {
        var captions = (0..<205).map { Caption(id: UUID(), original: "line \($0)") }
        let speaking = captions[0].id
        let translating = captions[1].id
        let oldestInactive = captions[2].id
        CaptionRetention.trim(&captions, protecting: [speaking, translating])
        XCTAssertEqual(captions.count, 200)
        XCTAssertTrue(captions.contains { $0.id == speaking })
        XCTAssertTrue(captions.contains { $0.id == translating })
        XCTAssertFalse(captions.contains { $0.id == oldestInactive })
    }
}
