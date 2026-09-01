import XCTest
@testable import OC3DCore

final class ThreeDDownloadPolicyTests: XCTestCase {
    private func allowed(_ s: String) -> Bool {
        guard let url = URL(string: s) else { return false }
        return ThreeDDownloadPolicy.isAllowedDownloadURL(url)
    }

    func testAllowsPlainHTTPSPublicHosts() {
        XCTAssertTrue(allowed("https://api.tripo3d.ai/models/abc.glb"))
        XCTAssertTrue(allowed("https://cdn.example.com/a/b/c.glb?sig=xyz"))
        XCTAssertTrue(allowed("https://8.8.8.8/model.glb"))
        XCTAssertTrue(allowed("https://172.15.0.1/model.glb"), "172.15 is outside the private 172.16-31 range")
        XCTAssertTrue(allowed("https://172.32.0.1/model.glb"), "172.32 is outside the private 172.16-31 range")
        XCTAssertTrue(allowed("https://192.167.0.1/model.glb"))
    }

    func testRejectsNonHTTPSSchemes() {
        XCTAssertFalse(allowed("http://api.tripo3d.ai/model.glb"))
        XCTAssertFalse(allowed("file:///etc/passwd"))
        XCTAssertFalse(allowed("ftp://example.com/model.glb"))
        XCTAssertFalse(allowed("data:application/octet-stream;base64,AAAA"))
    }

    func testRejectsCredentialsInURL() {
        XCTAssertFalse(allowed("https://user@example.com/model.glb"))
        XCTAssertFalse(allowed("https://user:secret@example.com/model.glb"))
    }

    func testRejectsLoopbackAndLinkLocal() {
        XCTAssertFalse(allowed("https://localhost/model.glb"))
        XCTAssertFalse(allowed("https://LOCALHOST/model.glb"), "host comparison must be case-insensitive")
        XCTAssertFalse(allowed("https://127.0.0.1/model.glb"))
        XCTAssertFalse(allowed("https://127.1.2.3/model.glb"))
        XCTAssertFalse(allowed("https://0.0.0.0/model.glb"))
        XCTAssertFalse(allowed("https://printer.local/model.glb"))
    }

    func testRejectsCloudMetadataEndpoint() {
        XCTAssertFalse(allowed("https://169.254.169.254/latest/meta-data/"))
    }

    func testRejectsPrivateRanges() {
        XCTAssertFalse(allowed("https://10.0.0.1/model.glb"))
        XCTAssertFalse(allowed("https://10.255.255.255/model.glb"))
        XCTAssertFalse(allowed("https://192.168.1.1/model.glb"))
        for second in [16, 20, 31] {
            XCTAssertFalse(allowed("https://172.\(second).0.1/model.glb"), "172.\(second) is private")
        }
    }

    func testRejectsIPv6Literals() {
        XCTAssertTrue(ThreeDDownloadPolicy.isBlockedDownloadHost("::1"))
        XCTAssertTrue(ThreeDDownloadPolicy.isBlockedDownloadHost("[::1]"))
        XCTAssertTrue(ThreeDDownloadPolicy.isBlockedDownloadHost("[fd00::1]"))
        XCTAssertTrue(ThreeDDownloadPolicy.isBlockedDownloadHost("[2606:4700::1111]"),
                      "the whole IPv6 family is blocked rather than range-enumerated")
    }
}
