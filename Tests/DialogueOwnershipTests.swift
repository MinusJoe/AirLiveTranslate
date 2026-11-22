#if os(iOS)
import XCTest
@testable import AirPodsTranslator

final class DialogueOwnershipTests: XCTestCase {
    @MainActor
    func testBrowsingAndReopeningDoNotRequestAMicrophone() {
        let live = TranslationViewModel()
        let group = live.dialogue
        group.open()
        XCTAssertTrue(group === live.dialogue)
        XCTAssertTrue(group.phase == .idle)
        XCTAssertFalse(live.dialogueOwnsAudio)
        XCTAssertTrue(live.canConfigure)
    }

    @MainActor
    func testLivePreparationBlocksGroupEvenIfThePageIsOpen() {
        let live = TranslationViewModel()
        live.requestPreparation(forListening: true)
        let group = live.dialogue
        group.open()
        group.start()
        XCTAssertTrue(live.isBusy)
        XCTAssertFalse(live.dialogueOwnsAudio)
        XCTAssertTrue(group.phase == .idle)
        live.stop()
    }

    @MainActor
    func testGroupLeaseBlocksRealtimePreparationAndCheckingAudioUntilReleased() {
        let live = TranslationViewModel()
        XCTAssertTrue(live.reserveDialogueAudio())
        live.requestPreparation(forListening: true)
        live.checkAudio()
        live.start()
        XCTAssertFalse(live.isBusy)
        XCTAssertFalse(live.canConfigure)
        live.releaseDialogueAudio()
        XCTAssertTrue(live.canConfigure)
    }

    @MainActor
    func testSelectingPhoneModeChangesOnlyTheDialogueAndDoesNotTakeAudio() {
        let live = TranslationViewModel()
        live.captureSource = .headset
        live.outputSide = .left
        let group = live.dialogue
        group.selectDevice(.phone)
        group.open()
        XCTAssertEqual(group.device, .phone)
        XCTAssertEqual(live.captureSource, .headset)
        XCTAssertEqual(live.outputSide, .left)
        XCTAssertFalse(live.dialogueOwnsAudio)
        live.requestPreparation(forListening: true)
        group.selectDevice(.headphones)
        XCTAssertEqual(group.device, .phone)
        live.stop()
    }
}
#endif
