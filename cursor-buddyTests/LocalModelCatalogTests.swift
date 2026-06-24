import XCTest
@testable import OpenClicky

final class LocalModelCatalogTests: XCTestCase {
    func testFoundationIDResolvesToFoundationProvider() {
        let opt = OpenClickyModelCatalog.localModelOption(forID: "apple-foundation")
        XCTAssertEqual(opt?.provider, .appleFoundation)
        XCTAssertEqual(opt?.id, "apple-foundation")
    }

    func testLocalPrefixResolvesToLocalProviderAndStripsPrefix() {
        let opt = OpenClickyModelCatalog.localModelOption(forID: "local:qwen2.5:7b")
        XCTAssertEqual(opt?.provider, .localOpenAICompatible)
        XCTAssertEqual(opt?.label, "qwen2.5:7b")
        XCTAssertEqual(opt?.id, "local:qwen2.5:7b")
    }

    func testCloudIDIsNotLocal() {
        XCTAssertNil(OpenClickyModelCatalog.localModelOption(forID: "claude-haiku-4-5"))
        XCTAssertFalse(OpenClickyModelCatalog.isLocalModelID("gpt-5.5"))
    }

    func testRawLocalModelIDStripsPrefix() {
        XCTAssertEqual(OpenClickyModelCatalog.rawLocalModelID(forID: "local:llama3.1"), "llama3.1")
        XCTAssertEqual(OpenClickyModelCatalog.rawLocalModelID(forID: "gpt-5.5"), "gpt-5.5")
    }

    func testVoiceResolverReturnsLocalOptionInsteadOfCloudFallback() {
        let opt = OpenClickyModelCatalog.voiceResponseModel(withID: "local:llama3.1")
        XCTAssertEqual(opt.provider, .localOpenAICompatible)
    }

    func testComputerUseResolverReturnsLocalOption() {
        let opt = OpenClickyModelCatalog.computerUseModel(withID: "local:qwen2-vl")
        XCTAssertEqual(opt.provider, .localOpenAICompatible)
    }
}
