import XCTest
@testable import AirPodsTranslator

/// Independent reviewer cases: synthetic recognizer events, not evidence of acoustic quality.
final class StreamingAdversarialTests: XCTestCase {
    private let firstSentence = "Please turn left."

    private func update(_ text: String, final: Bool = false, start: Double = 0,
                        end: Double = 3, timedPrefix: String? = nil) -> RecognitionUpdate {
        RecognitionUpdate(text: text, isFinal: final, start: start, end: end,
                          boundaries: timedPrefix.map {
                              [TextAudioBoundary(characterOffset: $0.count, audioEnd: 1)]
                          } ?? [])
    }

    private func commitFirstSentence(_ committer: inout StreamingCommitter) -> CommitBatch {
        let event = update(firstSentence + " We wait here.", timedPrefix: firstSentence)
        XCTAssertTrue(committer.process(event, now: 0).segments.isEmpty)
        XCTAssertTrue(committer.process(event, now: 0.25).segments.isEmpty)
        return committer.process(event, now: 0.5)
    }

    func testStablePrefixCommitsEvenWhileTheUncommittedTailGrows() {
        var committer = StreamingCommitter()
        let suffixes = [" We", " We wait", " We wait here"]
        var emitted: [CommittedSegment] = []
        for (index, suffix) in suffixes.enumerated() {
            emitted += committer.process(update(firstSentence + suffix, timedPrefix: firstSentence),
                                           now: Double(index) * 0.25).segments
        }
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.segment.text, firstSentence)
        XCTAssertEqual(emitted.first?.segment.end, 1)
        XCTAssertTrue(emitted.first?.isProvisional == true)
    }

    func testStableTextWithoutReliableAudioBoundaryWaitsForFinal() {
        var committer = StreamingCommitter()
        let text = firstSentence + " We wait here."
        for index in 0..<6 {
            XCTAssertTrue(committer.process(update(text), now: Double(index)).segments.isEmpty)
        }
        let final = committer.process(update(text, final: true), now: 6)
        XCTAssertEqual(final.segments.map { $0.segment.text }, [text])
        XCTAssertFalse(final.segments[0].isProvisional)
    }

    func testDecimalAndAbbreviationDoNotBecomeStandaloneSentences() {
        for sentence in ["Please pay 3.14 dollars.", "Dr. Smith will arrive.", "We accept U.S. dollars."] {
            var committer = StreamingCommitter()
            let text = sentence + " Please wait here."
            // Deliberately expose times at every punctuation mark: the text policy must reject
            // decimal and abbreviation points rather than relying on missing timing metadata.
            let points = Array(text).enumerated().compactMap { index, character -> TextAudioBoundary? in
                guard character == "." else { return nil }
                return TextAudioBoundary(characterOffset: index + 1, audioEnd: 1)
            }
            let event = RecognitionUpdate(text: text, isFinal: false, start: 0, end: 3, boundaries: points)
            _ = committer.process(event, now: 0)
            _ = committer.process(event, now: 0.25)
            XCTAssertEqual(committer.process(event, now: 0.5).segments.map { $0.segment.text }, [sentence])
        }
    }

    func testLateNegationInvalidatesTheEarlyCaptionAndDoesNotReplayTheWholeCorrection() {
        var committer = StreamingCommitter()
        let prefix = "We can enter."
        let initial = update(prefix + " Please wait here.", timedPrefix: prefix)
        _ = committer.process(initial, now: 0)
        _ = committer.process(initial, now: 0.25)
        let early = committer.process(initial, now: 0.5)
        XCTAssertEqual(early.segments.count, 1)
        let correctedText = "We cannot enter. Please wait here."
        let final = committer.process(update(correctedText, final: true), now: 1)
        XCTAssertEqual(final.revisedIDs, early.segments.map { $0.segment.id })
        XCTAssertTrue(final.confirmedIDs.isEmpty)
        XCTAssertEqual(final.segments.map { $0.segment.text }, [correctedText])
        XCTAssertTrue(final.segments.allSatisfy(\.subtitleOnly))
    }

    func testEmptyVolatileTextRevokesPreviouslyCommittedSpeech() {
        var committer = StreamingCommitter()
        let early = commitFirstSentence(&committer)
        XCTAssertEqual(early.segments.count, 1)
        let revoked = committer.process(update(""), now: 0.75)
        XCTAssertEqual(revoked.revisedIDs, early.segments.map { $0.segment.id })
        XCTAssertTrue(revoked.segments.isEmpty)
        let final = committer.process(update("", final: true), now: 1)
        XCTAssertTrue(final.segments.isEmpty)
        XCTAssertTrue(final.confirmedIDs.isEmpty)
    }

    func testPartialFinalTransitionCommitsOnlyTheTailAndConfirmsThePrefix() {
        var committer = StreamingCommitter()
        let early = commitFirstSentence(&committer)
        let final = committer.process(update(firstSentence + " We wait here.", final: true), now: 1)
        XCTAssertEqual(final.confirmedIDs, early.segments.map { $0.segment.id })
        XCTAssertEqual(final.segments.map { $0.segment.text }, ["We wait here."])
        XCTAssertEqual(final.segments.first?.segment.start, 1)
        XCTAssertTrue(final.revisedIDs.isEmpty)
        XCTAssertTrue(committer.process(update(firstSentence + " We wait here.", final: true), now: 2).segments.isEmpty)
    }

    func testIdenticalTextInANewAudioRangeIsNotMistakenForADuplicate() {
        var committer = StreamingCommitter()
        let first = committer.process(update("Thank you.", final: true, start: 0, end: 1), now: 0)
        let second = committer.process(update("Thank you.", final: true, start: 1, end: 2), now: 1)
        XCTAssertEqual(first.segments.map { $0.segment.text }, ["Thank you."])
        XCTAssertEqual(second.segments.map { $0.segment.text }, ["Thank you."])
        XCTAssertNotEqual(first.segments.first?.segment.id, second.segments.first?.segment.id)
    }

    func testCJKAndGraphemeOffsetsPreserveTheRemainingFinalText() {
        let prefix = "明日の会議は予定通りです。"
        let suffix = "ただし、参加は必須ではありません。"
        var committer = StreamingCommitter()
        let event = update(prefix + suffix, timedPrefix: prefix)
        _ = committer.process(event, now: 0)
        _ = committer.process(event, now: 0.25)
        let early = committer.process(event, now: 0.5)
        XCTAssertEqual(early.segments.map { $0.segment.text }, [prefix])
        let final = committer.process(update(prefix + suffix, final: true), now: 1)
        XCTAssertEqual(final.segments.map { $0.segment.text }, [suffix])
        XCTAssertEqual(final.confirmedIDs, early.segments.map { $0.segment.id })
    }

    func testFinalOnlyPolicyNeverSpeculatesEvenWithStablePunctuationAndTimes() {
        var committer = StreamingCommitter(lowLatencyEnabled: false)
        let event = update(firstSentence + " We wait here.", timedPrefix: firstSentence)
        for index in 0..<6 {
            XCTAssertTrue(committer.process(event, now: Double(index)).segments.isEmpty)
        }
        let final = committer.process(update(event.text, final: true), now: 6)
        XCTAssertEqual(final.segments.map { $0.segment.text }, [event.text])
        XCTAssertFalse(final.segments[0].isProvisional)
    }

    func testPlaybackOmissionsAreReturnedAndRevisionRemovesOnlyItsOwnQueuedSpeech() {
        let firstID = UUID(), secondID = UUID(), thirdID = UUID()
        func job(_ captionID: UUID, _ text: String) -> SpeechJob {
            SpeechJob(id: UUID(), captionID: captionID, text: text, committedAtUptime: 0,
                      queuedAtUptime: 0, estimatedSeconds: 1)
        }
        var queue = SpeechPlaybackQueue(capacity: 2, durationLimit: 10)
        XCTAssertTrue(queue.append(job(firstID, "first")).isEmpty)
        XCTAssertTrue(queue.append(job(secondID, "second")).isEmpty)
        XCTAssertEqual(queue.append(job(thirdID, "third")).map(\.captionID), [firstID])
        XCTAssertEqual(queue.remove(captionIDs: [secondID]).map(\.captionID), [secondID])
        XCTAssertEqual(queue.pop()?.captionID, thirdID)
        XCTAssertNil(queue.pop())
    }

    func testScriptQualifiedLocalesMatchTheirRegionWithoutCrossRegionFallback() {
        XCTAssertEqual(SpeechVariant.supported(for: .chinese, identifiers: ["zh-Hans-CN", "zh_Hant_TW"]),
                       [.chineseMainland, .chineseTaiwan])
        XCTAssertEqual(SpeechVariant.supported(for: .english, identifiers: ["en_GB"]), [.englishUK])
        XCTAssertFalse(SpeechVariant.supported(for: .english, identifiers: ["en-GB"]).contains(.englishUS))
    }

    func testCongestionCannotSilentlyEvictTheOnlyCorrectionNotice() {
        var queue = SpeechPlaybackQueue(capacity: 2, durationLimit: 10)
        let notice = SpeechJob(id: UUID(), captionID: nil, text: "An earlier transcript was corrected.",
                               committedAtUptime: 0, queuedAtUptime: 0, estimatedSeconds: 2)
        _ = queue.append(notice)
        for index in 0..<5 {
            let ordinary = SpeechJob(id: UUID(), captionID: UUID(), text: "sentence \(index)",
                                     committedAtUptime: Double(index), queuedAtUptime: Double(index),
                                     estimatedSeconds: 1)
            _ = queue.append(ordinary)
        }
        XCTAssertLessThanOrEqual(queue.items.count, 2)
        XCTAssertTrue(queue.items.contains { $0.captionID == nil },
                      "A lock-screen listener must still hear that earlier speech was corrected")
    }
}
