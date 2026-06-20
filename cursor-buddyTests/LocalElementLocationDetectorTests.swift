import XCTest
@testable import OpenClicky

final class LocalElementLocationDetectorTests: XCTestCase {
    func testParsesNormalizedPoint() {
        let result = LocalElementLocationDetector.parseNormalizedPoint("Sure! [POINT:0.42,0.88]")
        XCTAssertEqual(result?.x ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(result?.y ?? -1, 0.88, accuracy: 0.0001)
    }

    func testNoneReturnsNil() {
        XCTAssertNil(LocalElementLocationDetector.parseNormalizedPoint("[POINT:none]"))
    }

    func testMissingTagReturnsNil() {
        XCTAssertNil(LocalElementLocationDetector.parseNormalizedPoint("I cannot find it."))
    }

    func testOutOfRangeReturnsNil() {
        XCTAssertNil(LocalElementLocationDetector.parseNormalizedPoint("[POINT:1.4,0.2]"))
    }
}
