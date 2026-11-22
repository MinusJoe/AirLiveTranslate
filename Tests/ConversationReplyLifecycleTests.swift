#if os(iOS)
import XCTest
@testable import AirPodsTranslator

final class ConversationReplyLifecycleTests: XCTestCase {
    @MainActor
    func testWarmReadinessExpiresAndIsBoundToBothLanguages() {
        let ready = ConversationReplyModel.InstalledResources(language: .english, variant: .chineseMainland, checkedAt: 100)
        XCTAssertTrue(ready.matches(.english, .chineseMainland, now: 159.9))
        XCTAssertFalse(ready.matches(.english, .chineseMainland, now: 160))
        XCTAssertFalse(ready.matches(.english, .chineseMainland, now: 99))
        XCTAssertFalse(ready.matches(.japanese, .chineseMainland, now: 101))
        XCTAssertFalse(ready.matches(.english, .chineseTaiwan, now: 101))
    }

    @MainActor
    func testReleaseBeforeStartupRunsCannotBeginRecordingOrHandOff() async {
        let reply = ConversationReplyModel()
        var handedOff = false
        var stopMessages: [String] = []
        reply.start(language: .english, variant: .chineseMainland, source: .headset, rate: 0.5,
                    onStopped: { stopMessages.append(reply.message) }) {
            handedOff = true
        }
        XCTAssertTrue(reply.phase == .connecting)
        reply.finish()
        XCTAssertTrue(reply.phase == .idle)
        XCTAssertTrue(reply.message.contains("麦克风尚未就绪"))
        await Task.yield()
        XCTAssertTrue(reply.phase == .idle)
        XCTAssertTrue(reply.original.isEmpty)
        XCTAssertFalse(handedOff)
        XCTAssertEqual(stopMessages, [reply.message])
    }

    @MainActor
    func testCancelledPromptCannotResumeTheListenerOnANewTurn() async {
        let reply = ConversationReplyModel()
        var handoffs = 0
        reply.speakPrompt(original: "请再说一遍。", translated: "Please repeat that.", language: .english, rate: 0.5) {
            handoffs += 1
        }
        XCTAssertTrue(reply.phase == .playing)
        reply.cancel()
        reply.start(language: .japanese, variant: .chineseMainland, source: .headset, rate: 0.5) {
            handoffs += 1
        }
        reply.finish()
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
