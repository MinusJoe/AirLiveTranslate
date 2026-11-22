#if os(iOS)
import XCTest
@testable import AirPodsTranslator

final class ModelCenterTests: XCTestCase {
    func testKeysAreScopedByUseAndOldSummaryKeysKeepTheirNamespace() {
        XCTAssertEqual(MeetingKeychain.service(for: .summary), "AirLiveTranslate.MeetingAI")
        XCTAssertEqual(Set(ModelUse.allCases.map { MeetingKeychain.service(for: $0) }).count, 3)
    }
    @MainActor
    func testPreviousSummaryConfigurationDoesNotOptInOtherScenarios() throws {
        let name = "model-center-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let old = MeetingConnection(baseURL: "https://summary.example/v1", model: "summarizer")
        defaults.set(try JSONEncoder().encode(old), forKey: "minutes.connection")
        defaults.set(SummaryProvider.custom.rawValue, forKey: "minutes.provider")
        let settings = MeetingModelPreferences(defaults: defaults)
        XCTAssertEqual(settings.remote(for: .summary), old)
        XCTAssertNil(settings.remote(for: .live))
        XCTAssertNil(settings.remote(for: .dialogue))
        let fast = MeetingConnection(baseURL: "https://translation.example/v1", model: "fast", api: .chat, effort: .low)
        try settings.save(.custom, fast, key: "", for: .live)
        let restored = MeetingModelPreferences(defaults: defaults)
        XCTAssertEqual(restored.remote(for: .live), fast)
        XCTAssertEqual(restored.remote(for: .summary), old)
        XCTAssertNil(restored.remote(for: .dialogue))
        try restored.save(.apple, fast, key: "", for: .live)
        XCTAssertNil(restored.remote(for: .live))
        XCTAssertEqual(restored.connection(for: .live), fast)
    }

    func testProgressIsIndeterminateUntilReportedAndLateEventsCannotRegressIt() {
        let start = ModelResourceState.preparing("准备", nil)
        XCTAssertEqual(start.updated(label: "等待系统", fraction: nil), .preparing("等待系统", nil))
        let half = start.updated(label: "下载", fraction: 0.52)
        XCTAssertEqual(half.updated(label: "较早回调", fraction: 0.3), half)
        XCTAssertEqual(half.updated(label: "无效", fraction: .nan), half)
        XCTAssertEqual(half.updated(label: "编译", fraction: 1.03), .preparing("编译", 1))
        XCTAssertEqual(ModelResourceState.installed.updated(label: "下载", fraction: 0.2), .installed)
    }

    @MainActor
    func testTwoCallersJoinOneModelPreparationAndAFailureCanBeRetried() async throws {
        let loader = SharedModelLoad<Int>()
        let started = expectation(description: "one download started")
        let joining = expectation(description: "session requests same model")
        let gate = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let first = Task { try await loader.run {
            started.fulfill()
            for await value in gate.stream { return value }
            return -2
        } }
        await fulfillment(of: [started], timeout: 2)
        let second = Task {
            joining.fulfill()
            return try await loader.run { XCTFail("Duplicate download"); return -1 }
        }
        await fulfillment(of: [joining], timeout: 2)
        gate.continuation.yield(42)
        gate.continuation.finish()
        let a = try await first.value
        let b = try await second.value
        XCTAssertEqual(a, 42)
        XCTAssertEqual(b, 42)
        do {
            _ = try await loader.run { throw PipelineError.message("test failure") }
            XCTFail("Expected load to fail")
        } catch {}
        let retry = try await loader.run { 7 }
        XCTAssertEqual(retry, 7)
    }
}
#endif
