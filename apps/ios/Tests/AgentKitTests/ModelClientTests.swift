import XCTest
@testable import AgentKit

final class ModelClientTests: XCTestCase {
    func testUnknownCitationsAreRejected() throws {
        try ModelClient.validateCitations("内容 [1]，补充 [2]", sourceCount: 2)
        XCTAssertThrowsError(try ModelClient.validateCitations("编造来源 [99]", sourceCount: 2))
        XCTAssertThrowsError(try ModelClient.validateCitations("无效来源 [0]", sourceCount: 2))
    }

    func testEndpointRejectsCredentialsQueriesAndRemoteCleartext() throws {
        for endpoint in ["http://example.com/v1", "https://user:secret@example.com/v1", "https://example.com/v1?key=x", "file:///etc/passwd"] {
            XCTAssertThrowsError(try ModelConfiguration(endpoint: endpoint).validatedURL())
        }
        XCTAssertEqual(try ModelConfiguration(endpoint: "http://127.0.0.1:8765/v1").validatedURL().host, "127.0.0.1")
        XCTAssertNotEqual(ModelConfiguration(endpoint: "https://a.example/v1").credentialAccount,
                          ModelConfiguration(endpoint: "https://b.example/v1").credentialAccount)
    }

    func testOutboundRequestRedactsPIIAndRejectsSecrets() throws {
        let client = ModelClient(configuration: ModelConfiguration(endpoint: "https://model.example/v1", model: "test"), key: "test-key")
        let request = try client.completionRequest(goal: "总结", sources: ["邮件 alice@example.com"], language: "zh-Hans")
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)!
        XCTAssertFalse(body.contains("alice@example.com"))
        XCTAssertTrue(body.contains("a***@example.com"))
        XCTAssertFalse(body.contains("test-key"))
        XCTAssertThrowsError(try client.completionRequest(goal: "总结", sources: ["api_key=supersecret12345"], language: "zh-Hans"))
    }

    func testIncompleteAndToolResponsesNeverBecomeCompletedText() throws {
        for json in [#"{"choices":[{"finish_reason":"length","message":{"content":"半截结果"}}]}"#,
                     #"{"choices":[{"finish_reason":"tool_calls","message":{"tool_calls":[]}}]}"#,
                     #"{"choices":[{"finish_reason":"stop","message":{"content":""}}]}"#] {
            XCTAssertThrowsError(try ModelClient.decodeCompletion(Data(json.utf8), provider: .compatible))
        }
        XCTAssertEqual(try ModelClient.decodeCompletion(Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"资料 [1]"}}]}"#.utf8), provider: .compatible), "资料 [1]")
        XCTAssertEqual(try ModelClient.decodeCompletion(Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"结果"}]}"#.utf8), provider: .anthropic), "结果")
        XCTAssertEqual(try ModelClient.decodeCompletion(Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"结果"}]}}]}"#.utf8), provider: .gemini), "结果")
    }
}
