import XCTest
@testable import AirPodsTranslator

final class ClauseBoundaryTests: XCTestCase {
    private func partial(_ text: String, prefix: String, end: Double = 3) -> RecognitionUpdate {
        RecognitionUpdate(text: text, isFinal: false, start: 0, end: end,
                          boundaries: [TextAudioBoundary(characterOffset: prefix.count, audioEnd: 2)])
    }

    func testFastContinuousSpeechEmitsAClauseWithoutPauseOrPunctuation() {
        for (language, first, next) in [
            (AppLanguage.english, "we finished the first round of testing", " and we can start"),
            (.chinese, "我们已经完成了第一轮测试", "然后我们可以开始"),
            (.japanese, "最初のテストが終わりました", "そして次の作業に")
        ] {
            var engine = StreamingCommitter(language: language)
            let body = first + next
            for i in 0..<2 { XCTAssertTrue(engine.process(partial(body, prefix: first), now: Double(i)*0.25).segments.isEmpty) }
            let early = engine.process(partial(body, prefix: first), now: 0.5)
            XCTAssertEqual(early.segments.map { $0.segment.text }, [first])
            XCTAssertEqual(early.segments.first?.isProvisional, true)
            XCTAssertEqual(early.segments.first?.subtitleOnly, false, "The prefix must enter the live speech lane")
            let final = engine.process(RecognitionUpdate(text: body, isFinal: true, start: 0, end: 4), now: 1)
            XCTAssertEqual(final.segments.map { $0.segment.text }, [next.trimmingCharacters(in: .whitespaces)])
            XCTAssertEqual(final.segments.first?.segment.start, 2)
            XCTAssertEqual(final.confirmedIDs, early.segments.map { $0.segment.id })
        }
    }

    func testHoldConditionsListsNumbersAndIncompletePredicates() {
        for (lang, lhs, rhs) in [
            (AppLanguage.english, "if the report is ready", " then we can start"),
            (.english, "we paid fifteen", " hundred dollars"),
            (.english, "we ordered tea", " and coffee for everyone"),
            (.english, "we are waiting for", " the team to arrive"),
            (.english, "a detailed inventory", " and we can start"),
            (.chinese, "如果第一轮测试已经完成", "我们就可以开始"),
            (.japanese, "明日の会議に参加するかどうか", "そして何を話すか")
        ] {
            var engine = StreamingCommitter(language: lang)
            for i in 0..<4 {
                XCTAssertTrue(engine.process(partial(lhs + rhs, prefix: lhs), now: Double(i)).segments.isEmpty, lhs + rhs)
            }
        }
    }

    func testUnpunctuatedRestartNeedsTimingLookaheadAndFastMode() {
        let lhs = "the report is ready", rhs = " we can send it"
        let noTiming = RecognitionUpdate(text: lhs + rhs, isFinal: false, start: 0, end: 3)
        var engine = StreamingCommitter()
        var careful = StreamingCommitter(lowLatencyEnabled: false)
        for i in 0..<3 {
            XCTAssertTrue(engine.process(noTiming, now: Double(i)).segments.isEmpty)
            XCTAssertTrue(engine.process(partial(lhs + rhs, prefix: lhs, end: 2.1), now: Double(i)).segments.isEmpty)
            XCTAssertTrue(careful.process(partial(lhs + rhs, prefix: lhs), now: Double(i)).segments.isEmpty)
        }
        for i in 0..<2 { _ = engine.process(partial(lhs + rhs, prefix: lhs), now: 3 + Double(i)*0.25) }
        XCTAssertEqual(engine.process(partial(lhs + rhs, prefix: lhs), now: 3.5).segments.first?.segment.text, lhs)
    }

    func testChangedEarlyClauseIsRevokedAndFinalCorrectionUsesExistingReplayPolicy() {
        var engine = StreamingCommitter()
        let first = "the report is ready", tail = " and we can send it"
        let u = partial(first + tail, prefix: first)
        _ = engine.process(u, now: 0); _ = engine.process(u, now: 0.25)
        let emitted = engine.process(u, now: 0.5)
        XCTAssertEqual(emitted.segments.count, 1)
        let revised = engine.process(.init(text: "the report is not ready" + tail, isFinal: true, start: 0, end: 4), now: 1)
        XCTAssertEqual(revised.revisedIDs, emitted.segments.map { $0.segment.id })
        XCTAssertEqual(revised.segments.first?.replacesIDs, revised.revisedIDs)
        XCTAssertEqual(revised.segments.first?.subtitleOnly, true)
    }

    func testSeveralClausesThenFinalSuffixAreDeliveredExactlyOnce() {
        var engine = StreamingCommitter()
        let one = "the report is ready"
        let two = " and we have reviewed it"
        let three = " so we will send it tomorrow"
        let text = one + two + three
        let update = RecognitionUpdate(text: text, isFinal: false, start: 0, end: 5, boundaries: [
            .init(characterOffset: one.count, audioEnd: 1),
            .init(characterOffset: (one + two).count, audioEnd: 3)])
        var emitted: [String] = []
        for i in 0..<6 {
            emitted += engine.process(update, now: Double(i)*0.25).segments.map { $0.segment.text }
        }
        let final = RecognitionUpdate(text: text, isFinal: true, start: 0, end: 6)
        emitted += engine.process(final, now: 2).segments.map { $0.segment.text }
        XCTAssertEqual(emitted, [one, String(two.dropFirst()), String(three.dropFirst())])
        XCTAssertTrue(engine.process(final, now: 3).segments.isEmpty)
    }

    func testGrowingTailAndInsertedCommaPreserveSpokenClause() {
        var engine = StreamingCommitter()
        let first = "we delivered the final report"
        var emitted: [CommittedSegment] = []
        for (i, tail) in [" and our client approved it", " and our client approved it this", " and our client approved it this morning"].enumerated() {
            emitted += engine.process(partial(first + tail, prefix: first), now: Double(i)*0.25).segments
        }
        XCTAssertEqual(emitted.map { $0.segment.text }, [first])
        let result = engine.process(.init(text: first + ", and our client approved it this morning.",
                                          isFinal: true, start: 0, end: 5), now: 1)
        XCTAssertTrue(result.revisedIDs.isEmpty)
        XCTAssertEqual(result.segments.map { $0.segment.text }, ["and our client approved it this morning."])
    }
}
