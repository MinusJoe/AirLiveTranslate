import XCTest
@testable import AirPodsTranslator

final class DialogueEditingTests: XCTestCase {
    func testInviteCompletesWithoutStartingListenerAndCannotCompleteTwice() throws {
        var flow = DialogueHandoff()
        flow.listen()
        let turn = try XCTUnwrap(flow.beginReply())
        XCTAssertTrue(flow.finishPlayback(turn, resumeListening: false))
        XCTAssertFalse(flow.wantsListener)
        XCTAssertNil(flow.replyToken)
        XCTAssertFalse(flow.finishPlayback(turn))
        flow.listen()
        XCTAssertTrue(flow.wantsListener)
    }

    func testPartnerInputPreservesExactCodesAmountsTimeAndAddress() {
        var history = DialogueTranscript(existing: [])
        let values = ["0017", "150,50 EUR", "10:30", "〒100-0001\n東京都千代田区 1−2", "  A-12B  "]
        for value in values {
            let editor = DialogueEditor(purpose: .partnerInput, language: .japanese)
            XCTAssertTrue(history.addPartnerInput(value, editor: editor))
            XCTAssertFalse(history.addPartnerInput(value, editor: editor))
        }
        history.observe([])
        XCTAssertEqual(history.entries.map(\.original), values)
        XCTAssertTrue(history.entries.allSatisfy { $0.kind == .typed && $0.translated.isEmpty && $0.correctionLanguage == nil })
    }

    func testRejectsEmptyOversizedAndUnchangedDrafts() {
        var history = DialogueTranscript(existing: [])
        let editor = DialogueEditor(purpose: .partnerInput, language: .english)
        XCTAssertFalse(history.addPartnerInput(" \n ", editor: editor))
        XCTAssertFalse(history.addPartnerInput(String(repeating: "字", count: 1801), editor: editor))
        let correction = DialogueEditor(purpose: .correction(UUID()), language: .english, initialText: "两晚")
        XCTAssertFalse(correction.accepts(" 两晚\n"))
        XCTAssertFalse(history.addPartnerInput("三晚", editor: correction))
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testCorrectionKeepsOriginalLanguageAndSpokenHistory() throws {
        var history = DialogueTranscript(existing: [])
        history.addReply(original: "三晚", translated: "Three nights.", kind: .reply(.english))
        let first = try XCTUnwrap(history.entries.first)
        let editor = try XCTUnwrap(history.editorForCorrection(of: first.id))
        XCTAssertEqual(editor.language, .english)
        XCTAssertEqual(editor.initialText, "三晚")
        XCTAssertFalse(history.recordCorrection(of: first.id, original: "两晚", translated: " "))
        XCTAssertNil(history.entries.first?.supersededBy)
        XCTAssertTrue(history.recordCorrection(of: first.id, original: "两晚", translated: "Two nights."))
        let second = try XCTUnwrap(history.entries.last)
        XCTAssertEqual(history.entries.first?.original, "三晚")
        XCTAssertEqual(history.entries.first?.translated, "Three nights.")
        XCTAssertEqual(history.entries.first?.supersededBy, second.id)
        XCTAssertEqual(second.kind, .correction(.english, replaces: first.id))
        XCTAssertNil(history.editorForCorrection(of: first.id))
        XCTAssertFalse(history.recordCorrection(of: first.id, original: "一晚", translated: "One night."))
        XCTAssertEqual(history.editorForCorrection(of: second.id)?.initialText, "两晚")
        XCTAssertTrue(history.recordCorrection(of: second.id, original: "一晚", translated: "One night."))
        XCTAssertEqual(history.entries.count, 3)
    }

    func testCannedQuestionsAndIncomingSpeechCannotBeEditedAsMyWords() {
        var history = DialogueTranscript(existing: [])
        history.addReply(original: "请再说一遍", translated: "Please repeat.", kind: .prompt)
        history.observe([Caption(id: UUID(), original: "That's correct.")])
        XCTAssertEqual(history.entries.count, 2)
        for row in history.entries {
            XCTAssertNil(history.editorForCorrection(of: row.id))
            XCTAssertFalse(history.recordCorrection(of: row.id, original: "两晚", translated: "Two nights."))
        }
    }
}
