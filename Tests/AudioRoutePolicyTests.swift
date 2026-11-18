import XCTest
@testable import AirPodsTranslator

final class AudioRoutePolicyTests: XCTestCase {
    private let headphones = RoutePortIdentity(uid: "out-a2dp", name: "My headphones")
    private let mic = RoutePortIdentity(uid: "in-hfp", name: "My headphones")
    private let other = RoutePortIdentity(uid: "other", name: "Other headset")

    func testSelectsSystemHeadphonesEvenIfAnotherMicrophoneIsListedFirst() {
        var policy = CaptureRouteNegotiation(selectedHeadphones: headphones)
        XCTAssertNil(policy.choose(available: [], active: nil, output: headphones))
        XCTAssertEqual(policy.choose(available: [other, mic], active: other, output: headphones), mic)
        XCTAssertNil(policy.choose(available: [other], active: other, output: other))
    }

    func testAmbiguousMicrophonesRequireUserSelection() {
        var policy = CaptureRouteNegotiation(selectedHeadphones: nil)
        XCTAssertNil(policy.choose(available: [other, mic], active: nil, output: nil))
        XCTAssertEqual(policy.choose(available: [other, mic], active: mic, output: headphones), mic)
    }

    func testReconcilesChangedBluetoothUIDOnlyOnMatchingActiveHeadphones() {
        let next = RoutePortIdentity(uid: "in-le", name: mic.name)
        var policy = CaptureRouteNegotiation(selectedHeadphones: headphones)
        XCTAssertEqual(policy.choose(available: [mic], active: nil, output: nil), mic)
        XCTAssertNil(policy.choose(available: [next], active: next, output: other))
        // iOS has activated the new input, but availableInputs has not refreshed yet.
        XCTAssertEqual(policy.choose(available: [mic], active: next, output: headphones), next)
    }

    func testNeverRequestsAlreadyActiveMicrophoneAndBoundsRetries() {
        var policy = CaptureRouteNegotiation(selectedHeadphones: nil)
        XCTAssertFalse(policy.shouldRequest(mic.uid, activeUID: mic.uid, now: 0))
        XCTAssertTrue(policy.shouldRequest(mic.uid, activeUID: nil, now: 1))
        XCTAssertFalse(policy.shouldRequest(mic.uid, activeUID: nil, now: 1.5))
        XCTAssertTrue(policy.shouldRequest(mic.uid, activeUID: nil, now: 2.1))
        XCTAssertFalse(policy.shouldRequest(mic.uid, activeUID: nil, now: 4))
    }

    func testWaitsThroughLateBluetoothActivationAndTransientSpeakerOutput() {
        var policy = CaptureRouteNegotiation(selectedHeadphones: nil)
        _ = policy.choose(available: [mic], active: nil, output: nil)
        XCTAssertFalse(policy.ready(input: nil, output: nil, capabilitiesOK: false, now: 0))
        XCTAssertFalse(policy.ready(input: mic.uid, output: headphones.uid, capabilitiesOK: true, now: 2))
        XCTAssertFalse(policy.ready(input: mic.uid, output: nil, capabilitiesOK: true, now: 2.1))
        XCTAssertFalse(policy.ready(input: mic.uid, output: headphones.uid, capabilitiesOK: true, now: 3))
        XCTAssertTrue(policy.ready(input: mic.uid, output: headphones.uid, capabilitiesOK: true, now: 3.3))
        XCTAssertFalse(policy.ready(input: other.uid, output: headphones.uid, capabilitiesOK: true, now: 3.5))
        XCTAssertFalse(policy.ready(input: mic.uid, output: headphones.uid, capabilitiesOK: false, now: 3.6))
    }

    func testNotificationsOnHealthyGraphDoNotInterruptCaptureOrReplay() {
        for signal in [AudioSessionSignal.routeChanged, .engineChanged, .monoChanged, .interruptionEnded] {
            XCTAssertNil(signal.pauseReason(routeFailure: nil, engineRunning: true, formatMatches: true))
        }
        for signal in [AudioSessionSignal.interruptionBegan, .servicesLost] {
            XCTAssertNotNil(signal.pauseReason(routeFailure: nil, engineRunning: true, formatMatches: true))
        }
    }

    func testRealRouteOrFormatLossStopsEvenOnOtherwiseBenignNotification() {
        XCTAssertEqual(AudioSessionSignal.routeChanged.pauseReason(routeFailure: "headphone disconnected", engineRunning: true, formatMatches: true), "headphone disconnected")
        XCTAssertNotNil(AudioSessionSignal.engineChanged.pauseReason(routeFailure: nil, engineRunning: false, formatMatches: true))
        XCTAssertNotNil(AudioSessionSignal.engineChanged.pauseReason(routeFailure: nil, engineRunning: true, formatMatches: false))
        XCTAssertNotNil(AudioSessionSignal.monoChanged.pauseReason(routeFailure: "single-ear output unavailable", engineRunning: true, formatMatches: true))
    }
}
