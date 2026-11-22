#if os(iOS)
import XCTest
@testable import AirPodsTranslator

final class ConversationReplyLifecycleTests: XCTestCase {
    @MainActor
    func testCancelledPromptCannotResumeTheListenerOnANewTurn() async {
        let reply = ConversationReplyModel()
        var handoffs = 0
        reply.speakPrompt(original: "请再说一遍。", translated: "Please repeat that.", language: .english, rate: 0.5) {
            handoffs += 1
        }
        XCTAssertTrue(reply.phase == .playing)
        reply.cancel()
        await Task.yield()
        XCTAssertTrue(reply.phase == .idle)
        XCTAssertEqual(handoffs, 0)
    }

    @MainActor
    func testCancellingEditedReplyBeforeTranslationCannotCommitOrListen() async {
        let reply = ConversationReplyModel()
        var completed = false
        reply.speakCorrection("我订的是两晚。", language: .japanese, rate: 0.5,
                              onStopped: {}, onPlayed: { completed = true })
        XCTAssertEqual(reply.language, .japanese)
        XCTAssertTrue(reply.phase == .translating)
        reply.cancel()
        await Task.yield()
        XCTAssertFalse(completed)
        XCTAssertTrue(reply.phase == .idle)
    }
}
#endif
