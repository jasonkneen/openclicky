import XCTest
@testable import OpenClicky

final class LocalModelDiscoveryTests: XCTestCase {
    func testParsesOpenAIModelList() throws {
        let json = Data("""
        {"object":"list","data":[{"id":"qwen2.5:7b","object":"model"},{"id":"llava","object":"model"}]}
        """.utf8)
        XCTAssertEqual(try LocalModelDiscovery.parseModelList(json), ["qwen2.5:7b", "llava"])
    }

    func testEmptyListThrows() {
        let json = Data(#"{"object":"list","data":[]}"#.utf8)
        XCTAssertThrowsError(try LocalModelDiscovery.parseModelList(json)) { error in
            XCTAssertTrue(error is LocalModelError)
        }
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try LocalModelDiscovery.parseModelList(Data("nope".utf8)))
    }
}
