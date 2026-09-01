import XCTest
@testable import OC3DCore

final class ThreeDGenerationTypesTests: XCTestCase {
    func testRequestDefaultsMatchChatUsage() {
        let r = ThreeDGenerationRequest(prompt: "a small red house")
        XCTAssertEqual(r.prompt, "a small red house")
        XCTAssertEqual(r.style, .lowPolyStylized)
        XCTAssertTrue(r.quad)
        XCTAssertTrue(r.pbr)
        XCTAssertEqual(r.negativePrompt?.contains("high poly"), true)
    }

    func testRequestHonoursExplicitValues() {
        let r = ThreeDGenerationRequest(prompt: "p", style: .voxel, negativePrompt: nil, quad: false, pbr: false)
        XCTAssertEqual(r.style, .voxel)
        XCTAssertNil(r.negativePrompt)
        XCTAssertFalse(r.quad)
        XCTAssertFalse(r.pbr)
    }

    func testStylePromptPrefixes() {
        XCTAssertTrue(ThreeDStyle.lowPolyStylized.promptPrefix.hasPrefix("faithful low-poly"))
        XCTAssertEqual(ThreeDStyle.voxel.promptPrefix, "voxel art, blocky, cubic geometry, ")
        // Both realistic and none must contribute nothing to the prompt.
        XCTAssertEqual(ThreeDStyle.realistic.promptPrefix, "")
        XCTAssertEqual(ThreeDStyle.none.promptPrefix, "")
    }

    func testStyleCodableRoundTripUsesStableRawValues() throws {
        for style in ThreeDStyle.allCases {
            let data = try JSONEncoder().encode(style)
            XCTAssertEqual(try JSONDecoder().decode(ThreeDStyle.self, from: data), style)
        }
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(ThreeDStyle.gameAsset), as: UTF8.self), "\"gameAsset\"")
    }

    func testTaskStatusParsesProviderStrings() {
        XCTAssertEqual(ThreeDTaskStatus(rawValue: "queued"), .queued)
        XCTAssertEqual(ThreeDTaskStatus(rawValue: "running"), .running)
        XCTAssertEqual(ThreeDTaskStatus(rawValue: "success"), .success)
        XCTAssertEqual(ThreeDTaskStatus(rawValue: "failed"), .failed)
        XCTAssertEqual(ThreeDTaskStatus(rawValue: "cancelled"), .cancelled)
        // Tripo also emits "completed"; the provider maps unknown values to .running.
        XCTAssertNil(ThreeDTaskStatus(rawValue: "completed"))
    }

    func testProgressDefaults() {
        let p = ThreeDGenerationProgress(status: .running)
        XCTAssertNil(p.progress)
        XCTAssertNil(p.message)
    }

    func testErrorDescriptionsIdentifyProviderAndCause() {
        XCTAssertEqual(
            ThreeDGenerationError.submissionFailed(provider: "tripo", status: 402, body: "no credit").errorDescription,
            "tripo submission failed (402): no credit"
        )
        XCTAssertEqual(
            ThreeDGenerationError.taskFailed(provider: "tripo", reason: "banned").errorDescription,
            "tripo task failed: banned"
        )
        XCTAssertEqual(
            ThreeDGenerationError.timedOut(taskId: "t1", afterSeconds: 300).errorDescription,
            "Task t1 timed out after 300s."
        )
        XCTAssertEqual(ThreeDGenerationError.cancelled.errorDescription, "3D generation cancelled.")
        XCTAssertEqual(
            ThreeDGenerationError.noModelURL(provider: "tripo").errorDescription,
            "tripo finished but returned no GLB URL."
        )
    }

    func testErrorIsReachableThroughLocalizedErrorCast() {
        // The app surfaces failures via `(error as? LocalizedError)?.errorDescription`.
        let error: Error = ThreeDGenerationError.missingAPIKey(provider: "tripo")
        XCTAssertEqual((error as? LocalizedError)?.errorDescription?.contains("tripo"), true)
    }
}
