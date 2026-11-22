import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AirPodsTranslator

private final class MeetingMockService: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func bodyData() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 2048)
        var data = Data()
        while true {
            let count = stream.read(&bytes, maxLength: 2048)
            guard count > 0 else { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }

    override func startLoading() {
        let url = request.url!
        let path = url.path
        var status = 200
        var json: [String: Any] = [:]
        let result = #"{"findings":[{"category":"decision","finding":"周五开会","sourceNumber":1,"quotation":"Friday"}]}"#
        if request.value(forHTTPHeaderField: "Authorization") != "Bearer fixture-only" { status = 401 }
        else if path == "/api/v1/models" && request.httpMethod == "GET" {
            json = ["data": [["id":"beta"], ["id":"alpha"], ["id":"beta"]]]
        } else if let body = (try? JSONSerialization.jsonObject(with: bodyData())) as? [String: Any],
                  request.httpMethod == "POST", body["model"] as? String == "mock-model" {
            let content = "[1] Friday"
            let phrase = "The deposit is 150 EUR."
            let translated = "押金是 150 欧元。"
            let messages = body["messages"] as? [[String: String]]
            if path == "/api/v1/responses", body["input"] as? String == phrase,
               (body["instructions"] as? String)?.contains("from en into zh-Hans") == true,
               Set(body.keys) == ["model", "stream", "instructions", "input", "store", "reasoning"] {
                json = ["status":"completed","output":[["type":"message","content":[["type":"output_text","text":translated]]]]]
            } else if path == "/api/v1/chat/completions", messages?.last?["content"] == phrase,
                      messages?.first?["content"]?.contains("from en into zh-Hans") == true,
                      Set(body.keys) == ["model", "stream", "messages", "reasoning_effort"] {
                json = ["choices":[["finish_reason":"stop","message":["content":translated]]]]
            } else if path == "/api/v1/responses", body["input"] as? String == content,
               body["store"] as? Bool == false, (body["reasoning"] as? [String:String])?["effort"] == "high" {
                json = ["status":"completed","output":[["type":"reasoning"], ["type":"message","content":[["type":"output_text","text":result]]]]]
            } else if path == "/api/v1/chat/completions", (body["messages"] as? [[String:String]])?.last?["content"] == content,
                      body["reasoning_effort"] as? String == "high" || body["reasoning_effort"] == nil {
                json = ["choices":[["finish_reason":"stop","message":["content":result,"reasoning_content":"do not use"]]]]
            } else if path == "/incomplete/responses" { json = ["status":"incomplete","output":[]] }
            else { status = 422 }
        } else { status = 404 }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class CustomMeetingModelTests: XCTestCase {
    private func client(_ api: MeetingAPI = .responses, effort: ReasoningEffort = .high,
                        base: String = "https://example.invalid/api/v1/", key: String = "fixture-only") -> CustomMeetingModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MeetingMockService.self]
        let connection = MeetingConnection(baseURL: base, model: "mock-model", api: api, effort: effort)
        return CustomMeetingModel(connection: connection, key: key, session: URLSession(configuration: config))
    }
    private let chunk = MeetingMinutes.Chunk(text: "[1] Friday", sources: [1])

    func testModelDiscoveryAndBothReasoningFormatsAgainstMockService() async throws {
        let api = client()
        let models = try await api.listModels()
        XCTAssertEqual(models, ["alpha","beta"])
        for candidate in [api, client(.chat), client(.chat, effort: .automatic)] {
            let facts = try await candidate.findings(for: chunk)
            XCTAssertEqual(facts.first?.source, 1)
            XCTAssertEqual(facts.first?.kind, .decision)
            XCTAssertEqual(facts.first?.quote, "Friday")
        }
    }

    func testInvalidCredentialAndIncompleteResponseDoNotProduceSummaries() async {
        for api in [client(key: "invalid"), client(base: "https://example.invalid/incomplete")] {
            do { _ = try await api.findings(for: chunk); XCTFail("Expected explicit failure") }
            catch { XCTAssertFalse(error.localizedDescription.contains("fixture-only")) }
        }
    }

    func testTranslationUsesOnlyTextInBothProtocols() async throws {
        for api in [client(.responses), client(.chat)] {
            let result = try await api.translate("The deposit is 150 EUR.", from: .english, to: .chinese)
            XCTAssertEqual(result, "押金是 150 欧元。")
        }
    }

    func testSameLanguageBypassesTheServiceAndFailedTranslationIsNotSpoken() async throws {
        let unauthorized = client(key: "invalid")
        let same = try await unauthorized.translate("0017", from: .english, to: .english)
        XCTAssertEqual(same, "0017")
        do {
            _ = try await unauthorized.translate("0017", from: .english, to: .japanese)
            XCTFail("An API error must not be returned as a translation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("401")) }
    }

    func testBaseAddressAndCredentialScope() throws {
        let normalized = try MeetingConnection(baseURL: "https://EXAMPLE.com:443/").endpoint()
        XCTAssertEqual(normalized.absoluteString, "https://example.com/v1")
        for invalid in ["http://example.com", "https://user@host/v1", "https://host/v1?key=secret", "https://host/v1#part"] {
            XCTAssertThrowsError(try MeetingConnection(baseURL: invalid).endpoint())
        }
        XCTAssertNotEqual(try MeetingConnection(baseURL: "https://host/a").endpoint(),
                          try MeetingConnection(baseURL: "https://host/b").endpoint())
    }
}
