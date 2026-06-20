import XCTest
@testable import OpenClicky

final class LocalChatCompletionsAPITests: XCTestCase {
    func testExtractsDeltaContent() {
        let line = #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#
        XCTAssertEqual(LocalChatCompletionsAPI.deltaContent(fromSSELine: line), "Hel")
    }

    func testDoneLineReturnsNil() {
        XCTAssertNil(LocalChatCompletionsAPI.deltaContent(fromSSELine: "data: [DONE]"))
    }

    func testNonDataLineReturnsNil() {
        XCTAssertNil(LocalChatCompletionsAPI.deltaContent(fromSSELine: ": keep-alive"))
    }

    func testEmptyDeltaReturnsNil() {
        let line = #"data: {"choices":[{"delta":{}}]}"#
        XCTAssertNil(LocalChatCompletionsAPI.deltaContent(fromSSELine: line))
    }

    func testRequestBodyShape() {
        let body = LocalChatCompletionsAPI.requestBody(
            model: "qwen2.5:7b",
            maxOutputTokens: 256,
            messages: [["role": "user", "content": "hi"]])
        XCTAssertEqual(body["model"] as? String, "qwen2.5:7b")
        XCTAssertEqual(body["max_tokens"] as? Int, 256)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNotNil(body["messages"])
    }
}
