import XCTest
@testable import OpenClicky

final class AppleFoundationModelClientTests: XCTestCase {
    func testAvailabilityQueryDoesNotCrash() {
        // Returns a Bool on any host; false where Apple Intelligence is absent.
        _ = AppleFoundationModelAvailability.isAvailable()
    }

    func testUnavailableReasonConsistentWithAvailability() {
        if AppleFoundationModelAvailability.isAvailable() {
            XCTAssertNil(AppleFoundationModelAvailability.unavailableReason())
        } else {
            XCTAssertNotNil(AppleFoundationModelAvailability.unavailableReason())
        }
    }
}
