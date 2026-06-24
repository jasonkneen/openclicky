import XCTest
@testable import OpenClicky

final class LocalModelSettingsStoreTests: XCTestCase {
    func testDefaultBaseURL() {
        UserDefaults.standard.removeObject(forKey: "localModelBaseURL")
        XCTAssertEqual(LocalModelSettingsStore.baseURLString, "http://localhost:11434/v1")
    }

    func testRoundTripsBaseURL() {
        LocalModelSettingsStore.baseURLString = "http://127.0.0.1:1234/v1"
        XCTAssertEqual(LocalModelSettingsStore.baseURL.absoluteString, "http://127.0.0.1:1234/v1")
        UserDefaults.standard.removeObject(forKey: "localModelBaseURL")
    }

    func testRoundTripsMaxTokens() {
        LocalModelSettingsStore.maxOutputTokens = 4096
        XCTAssertEqual(LocalModelSettingsStore.maxOutputTokens, 4096)
        UserDefaults.standard.removeObject(forKey: "localModelMaxOutputTokens")
    }

    func testMaxTokensDefaultsWhenUnset() {
        UserDefaults.standard.removeObject(forKey: "localModelMaxOutputTokens")
        XCTAssertEqual(LocalModelSettingsStore.maxOutputTokens, 8192)
    }
}
