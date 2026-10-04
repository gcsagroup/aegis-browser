import XCTest
@testable import AgentKit

final class ModelStreamingTests: XCTestCase {
    private func decode(_ provider: ModelProvider, _ events: [String], ending: String = "\r\n") throws -> String {
        var decoder = ModelStreamDecoder(provider: provider)
        let wire = ": 合成注释\(ending)" + events.map { "data: \($0)\(ending)\(ending)" }.joined()
        for byte in wire.utf8 { _ = try decoder.consume(byte) }
        return try decoder.finish()
    }

    func testProviderStreamsAcrossUTF8BytesAndCRLF() throws {
        XCTAssertEqual(try decode(.compatible, [
            #"{"choices":[{"delta":{"content":"中文 [1]"}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#, "[DONE]"
        ]), "中文 [1]")
        XCTAssertEqual(try decode(.anthropic, [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"中文 [1]"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"{"type":"message_stop"}"#
        ], ending: "\n"), "中文 [1]")
        XCTAssertEqual(try decode(.gemini, [
            #"{"candidates":[{"content":{"parts":[{"text":"不可展示","thought":true},{"text":"中文 [1]"}]},"finishReason":"STOP"}]}"#
        ]), "中文 [1]")
    }

    func testIncompleteRefusalToolAndOversizedStreamsAreRejected() throws {
        XCTAssertThrowsError(try decode(.compatible, [#"{"choices":[{"delta":{"content":"半截"}}]}"#]))
        XCTAssertThrowsError(try decode(.compatible, ["[DONE]"]))
        XCTAssertThrowsError(try decode(.compatible, [#"{"choices":[{"delta":{"content":"尾部丢失"},"finish_reason":"stop"}]}"#]))
        XCTAssertThrowsError(try decode(.compatible, [#"{"choices":[{"delta":{"tool_calls":[]},"finish_reason":"stop"}]}"#]))
        XCTAssertThrowsError(try decode(.compatible, [#"{"choices":[{"delta":{"refusal":"拒绝"},"finish_reason":"stop"}]}"#]))
        XCTAssertThrowsError(try decode(.anthropic, [#"{"type":"message_stop"}"#]))
        XCTAssertThrowsError(try decode(.gemini, [#"{"candidates":[{"content":{"parts":[{"text":"半截"}]},"finishReason":"MAX_TOKENS"}]}"#]))
        var decoder = ModelStreamDecoder(provider: .compatible)
        XCTAssertThrowsError(try ("data: " + String(repeating: "x", count: 128_001)).utf8.forEach { _ = try decoder.consume($0) })
    }

    @MainActor func testRealHTTPStreamingForThreeProvidersAndJSONFallback() async throws {
        for provider in ModelProvider.allCases {
            let configuration = ModelConfiguration(provider: provider, endpoint: "http://127.0.0.1:8768/v1", model: "aegis-simulator-fixture")
            var updates: [String] = []
            let text = try await ModelClient(configuration: configuration, key: "").streamComplete(
                goal: "总结", sources: ["城市绿地观察"], language: "zh-Hans") { updates.append($0) }
            XCTAssertTrue(text.contains("12 公顷"))
            XCTAssertGreaterThan(updates.count, 1)
            XCTAssertLessThan(try XCTUnwrap(updates.first).count, text.count)
            XCTAssertEqual(updates.last, text)
        }
        let fallback = ModelClient(configuration: ModelConfiguration(endpoint: "http://127.0.0.1:8768/v1", model: "json-fallback"), key: "")
        let output = try await fallback.streamComplete(goal: "总结", sources: ["城市绿地观察"], language: "zh-Hans") { _ in }
        XCTAssertTrue(output.contains("[1]"))
    }

    @MainActor func testTruncationAndCancellationNeverReturnCompletedText() async throws {
        let cut = ModelClient(configuration: ModelConfiguration(endpoint: "http://127.0.0.1:8768/v1", model: "stream-cut"), key: "")
        do {
            _ = try await cut.streamComplete(goal: "总结", sources: ["城市绿地观察"], language: "zh-Hans") { _ in }
            XCTFail("断流不能成为完成结果")
        } catch { XCTAssertTrue(error is ModelClientError) }
        var updates: [String] = []
        let slow = ModelClient(configuration: ModelConfiguration(endpoint: "http://127.0.0.1:8768/v1", model: "stream-slow"), key: "")
        let task = Task { try await slow.streamComplete(goal: "总结", sources: ["城市绿地观察"], language: "zh-Hans") { updates.append($0) } }
        let limit = Date().addingTimeInterval(5)
        while updates.isEmpty, Date() < limit { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(updates.isEmpty)
        task.cancel()
        do { _ = try await task.value; XCTFail("取消后不应完成") } catch { XCTAssertTrue(error is CancellationError) }
        let count = updates.count
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(updates.count, count)
    }

    func testHTTPAndNetworkErrorsHaveActionableCategories() throws {
        for status in [401, 403, 429, 503] {
            let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: status,
                                           httpVersion: nil, headerFields: ["Retry-After": "3"])!
            XCTAssertThrowsError(try ModelClient.validateHTTP(response)) { error in
                guard let error = error as? ModelClientError else { return XCTFail("错误分类丢失") }
                switch (status, error) {
                case (401, .unauthorized), (403, .unauthorized), (429, .rateLimited(3)), (503, .serviceUnavailable): break
                default: XCTFail("错误分类不符")
                }
            }
        }
        if case ModelClientError.timedOut = ModelClient.classify(URLError(.timedOut)) {} else { XCTFail("超时分类") }
        if case ModelClientError.offline = ModelClient.classify(URLError(.networkConnectionLost)) {} else { XCTFail("断网分类") }
    }
}
