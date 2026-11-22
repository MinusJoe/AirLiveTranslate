import XCTest
@testable import AirPodsTranslator

final class DialogueFlowTests: XCTestCase {
    func testPlaybackHandsOffOnceAndRejectsASecondReplyWhileBusy() throws {
        var handoff = DialogueHandoff()
        XCTAssertFalse(handoff.wantsListener)
        handoff.listen()
        let turn = try XCTUnwrap(handoff.beginReply())
        XCTAssertFalse(handoff.wantsListener)
        XCTAssertNil(handoff.beginReply())
        XCTAssertTrue(handoff.finishPlayback(turn))
        XCTAssertTrue(handoff.wantsListener)
        XCTAssertFalse(handoff.finishPlayback(turn))
        handoff.failedReply(turn)
        XCTAssertTrue(handoff.wantsListener)
    }

    func testLateCallbacksCannotReopenMicrophoneAfterPauseFailureOrNextTurn() throws {
        var handoff = DialogueHandoff()
        let paused = try XCTUnwrap(handoff.beginReply())
        handoff.pause()
        XCTAssertFalse(handoff.finishPlayback(paused))
        XCTAssertFalse(handoff.wantsListener)
        let failed = try XCTUnwrap(handoff.beginReply())
        handoff.failedReply(failed)
        XCTAssertFalse(handoff.finishPlayback(failed))
        let next = try XCTUnwrap(handoff.beginReply())
        handoff.failedReply(paused)
        XCTAssertFalse(handoff.finishPlayback(failed))
        XCTAssertFalse(handoff.wantsListener)
        XCTAssertTrue(handoff.finishPlayback(next))
        XCTAssertTrue(handoff.wantsListener)
    }

    func testContextualQuestionUsesTheSpokenAmountInBothLanguages() throws {
        let question = try XCTUnwrap(DialogueQuestion.contextual(in: "The refundable deposit is $50."))
        let english = try XCTUnwrap(question.phrase(in: .english))
        let japanese = try XCTUnwrap(question.phrase(in: .japanese))
        XCTAssertTrue(english.contains("$50"))
        XCTAssertTrue(japanese.contains("$50"))
        XCTAssertNotEqual(english, japanese)
        XCTAssertNil(DialogueQuestion.contextual(in: "It is $50 per day with a $200 deposit."))
        XCTAssertNil(DialogueQuestion.contextual(in: "Could you sign here?"))
    }

    func testGeneralPromptsRemainAvailableWithoutRecognizedSpeech() throws {
        for question in [DialogueQuestion.repeatLast, .slower, .writeNumber] {
            let english = try XCTUnwrap(question.phrase(in: .english))
            let japanese = try XCTUnwrap(question.phrase(in: .japanese))
            XCTAssertFalse(english.isEmpty)
            XCTAssertFalse(japanese.isEmpty)
            XCTAssertNotEqual(english, japanese)
        }
    }

    func testEnglishSpokenAmountWithoutDigitsProducesAClarification() throws {
        let question = try XCTUnwrap(DialogueQuestion.contextual(in: "The deposit is fifty dollars."))
        let prompt = try XCTUnwrap(question.phrase(in: .english)).lowercased()
        XCTAssertTrue(prompt.contains("fifty") || prompt.contains("50"))
        XCTAssertTrue(prompt.contains("dollar") || prompt.contains("$"))
        XCTAssertNil(DialogueQuestion.contextual(in: "The room has a wonderful view."))
    }

    func testAnExplicitSpokenAlternativeCarriesBothNumbers() throws {
        let english = try XCTUnwrap(DialogueQuestion.contextual(in: "Was that fifteen or fifty?"))
        let englishText = try XCTUnwrap(english.phrase(in: .english)).lowercased()
        XCTAssertTrue(englishText.contains("fifteen") || englishText.contains("15"))
        XCTAssertTrue(englishText.contains("fifty") || englishText.contains("50"))

        let japanese = try XCTUnwrap(DialogueQuestion.contextual(in: "15または50ですか。"))
        let japaneseText = try XCTUnwrap(japanese.phrase(in: .japanese))
        XCTAssertTrue(japaneseText.contains("15"))
        XCTAssertTrue(japaneseText.contains("50"))
    }

    func testSeparateChargesMustNotBeOfferedAsAChoice() {
        XCTAssertNil(DialogueQuestion.contextual(in: "Fifteen dollars per day, plus fifty dollars as a deposit."))
        XCTAssertNil(DialogueQuestion.contextual(in: "料金は1500円、保証金は5000円です。"))
    }

    private func caption(_ original: String, translated: String) -> Caption {
        var caption = Caption(id: UUID(), original: original)
        caption.translated = translated
        caption.status = .complete
        return caption
    }

    func testTranscriptUpdatesInPlaceAndPreservesDialogueOrder() {
        let earlier = caption("Previous conversation", translated: "先前会话")
        var timeline = DialogueTranscript(existing: [earlier])
        var payment = caption("The deposit is $50.", translated: "")
        timeline.observe([earlier, payment])
        payment.translated = "押金是 50 美元。"
        timeline.observe([earlier, payment])
        timeline.addReply(original: "押金什么时候退？", translated: "When is it refunded?", kind: .reply(.english))
        let refund = caption("On checkout.", translated: "退房时。")
        timeline.observe([payment, refund])
        timeline.observe([payment, refund])
        XCTAssertEqual(timeline.entries.map(\.original), [payment.original, "押金什么时候退？", refund.original])
        XCTAssertEqual(timeline.entries.map(\.translated), [payment.translated, "When is it refunded?", refund.translated])
    }

    func testRevisionRemovesTheSupersededPriceFromCurrentConversation() {
        var timeline = DialogueTranscript(existing: [])
        var oldPrice = caption("The deposit is $15.", translated: "押金是 15 美元。")
        oldPrice.isProvisional = true
        timeline.observe([oldPrice])
        oldPrice.status = .superseded
        var newPrice = caption("The deposit is $50.", translated: "押金是 50 美元。")
        newPrice.status = .corrected
        timeline.observe([oldPrice, newPrice])
        timeline.observe([oldPrice, newPrice])
        XCTAssertEqual(timeline.entries.map(\.original), [newPrice.original])
    }
}
