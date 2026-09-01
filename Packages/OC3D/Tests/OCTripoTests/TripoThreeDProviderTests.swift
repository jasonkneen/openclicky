import XCTest
import OC3DCore
@testable import OCTripo

/// Serves canned responses so the provider's submit/poll/download paths can be
/// exercised without touching the network.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var body: Data
        init(status: Int = 200, json: String) {
            self.status = status
            self.body = Data(json.utf8)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queued: [Reply] = []
    nonisolated(unsafe) private static var requestedPaths: [String] = []

    static func reset(_ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        queued = replies
        requestedPaths = []
    }

    static var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return requestedPaths
    }

    private static func next(for request: URLRequest) -> Reply? {
        lock.lock(); defer { lock.unlock() }
        requestedPaths.append(request.url?.path ?? "")
        return queued.isEmpty ? nil : queued.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let reply = StubURLProtocol.next(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class TripoThreeDProviderTests: XCTestCase {
    private var scratch: URL!

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeProvider(apiKey: String? = "tsk_test") -> TripoThreeDProvider {
        TripoThreeDProvider(
            apiKeyProvider: { apiKey },
            session: makeSession(),
            pollInterval: 0.01,
            timeoutSeconds: 5
        )
    }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCTripoTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        StubURLProtocol.reset([])
    }

    private func generate(_ provider: TripoThreeDProvider) async throws -> ThreeDGenerationResult {
        try await provider.generate(
            request: ThreeDGenerationRequest(prompt: "a small red house"),
            destinationDirectory: scratch,
            onProgress: { _ in }
        )
    }

    private func assertThrows(
        _ provider: TripoThreeDProvider,
        _ check: (ThreeDGenerationError) -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await generate(provider)
            XCTFail("expected \(message)", file: file, line: line)
        } catch let error as ThreeDGenerationError {
            XCTAssertTrue(check(error), "got \(error) — expected \(message)", file: file, line: line)
        } catch {
            XCTFail("unexpected error type \(error)", file: file, line: line)
        }
    }

    func testIdentityMatchesProviderProtocol() async {
        let provider = makeProvider()
        XCTAssertEqual(provider.identifier, "tripo")
        XCTAssertEqual(provider.displayName, "Tripo AI")
    }

    func testMissingAPIKeyFailsBeforeAnyRequest() async {
        StubURLProtocol.reset([])
        await assertThrows(makeProvider(apiKey: nil), { if case .missingAPIKey = $0 { return true }; return false }, "missingAPIKey")
        XCTAssertTrue(StubURLProtocol.paths.isEmpty, "must not hit the network without a key")
    }

    func testEmptyAPIKeyIsTreatedAsMissing() async {
        StubURLProtocol.reset([])
        await assertThrows(makeProvider(apiKey: ""), { if case .missingAPIKey = $0 { return true }; return false }, "missingAPIKey")
    }

    func testNonSuccessSubmitStatusThrowsSubmissionFailed() async {
        StubURLProtocol.reset([.init(status: 402, json: #"{"code":1,"message":"no credit"}"#)])
        await assertThrows(makeProvider(), {
            if case .submissionFailed(_, let status, _) = $0 { return status == 402 }
            return false
        }, "submissionFailed(402)")
    }

    func testNonZeroBodyCodeThrowsSubmissionFailed() async {
        // HTTP 200 but Tripo's envelope reports an application-level failure.
        StubURLProtocol.reset([.init(json: #"{"code":2010,"message":"invalid prompt"}"#)])
        await assertThrows(makeProvider(), {
            if case .submissionFailed(_, _, let body) = $0 { return body == "invalid prompt" }
            return false
        }, "submissionFailed carrying the API message")
    }

    func testTerminalFailureStatusThrowsTaskFailed() async {
        StubURLProtocol.reset([
            .init(json: #"{"code":0,"data":{"task_id":"t1"}}"#),
            .init(json: #"{"code":0,"data":{"task_id":"t1","status":"banned","progress":0}}"#),
        ])
        await assertThrows(makeProvider(), {
            if case .taskFailed(_, let reason) = $0 { return reason == "banned" }
            return false
        }, "taskFailed(banned)")
    }

    func testBlockedModelURLIsRejectedAsNoModelURL() async {
        // The download policy must be enforced on the URL the remote API returns,
        // not just on URLs the caller supplies.
        StubURLProtocol.reset([
            .init(json: #"{"code":0,"data":{"task_id":"t1"}}"#),
            .init(json: #"{"code":0,"data":{"task_id":"t1","status":"success","output":{"model":"http://169.254.169.254/latest/meta-data/"}}}"#),
        ])
        await assertThrows(makeProvider(), {
            if case .noModelURL = $0 { return true }
            return false
        }, "noModelURL for a blocked download target")
    }

    func testPollingErrorStatusThrowsPollingFailed() async {
        StubURLProtocol.reset([
            .init(json: #"{"code":0,"data":{"task_id":"t1"}}"#),
            .init(status: 500, json: #"{"code":1,"message":"upstream"}"#),
        ])
        await assertThrows(makeProvider(), {
            if case .pollingFailed(_, let status, _) = $0 { return status == 500 }
            return false
        }, "pollingFailed(500)")
    }

    func testProgressIsReportedForIntermediatePolls() async throws {
        StubURLProtocol.reset([
            .init(json: #"{"code":0,"data":{"task_id":"t1"}}"#),
            .init(json: #"{"code":0,"data":{"task_id":"t1","status":"running","progress":40}}"#),
            .init(json: #"{"code":0,"data":{"task_id":"t1","status":"banned"}}"#),
        ])
        let collector = ProgressCollector()
        let provider = makeProvider()
        _ = try? await provider.generate(
            request: ThreeDGenerationRequest(prompt: "p"),
            destinationDirectory: scratch,
            onProgress: { collector.append($0) }
        )
        let seen = collector.values
        XCTAssertEqual(seen.first?.status, .queued, "first callback announces submission")
        XCTAssertTrue(seen.contains { $0.status == .running && $0.progress == 0.4 },
                      "provider must convert Tripo's 0-100 progress to 0-1; got \(seen.map { ($0.status, $0.progress) })")
    }

    func testSubmitPostsToTaskEndpoint() async {
        StubURLProtocol.reset([.init(status: 401, json: #"{"code":1,"message":"bad key"}"#)])
        _ = try? await generate(makeProvider())
        XCTAssertEqual(StubURLProtocol.paths.first, "/v2/openapi/task")
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ThreeDGenerationProgress] = []

    func append(_ value: ThreeDGenerationProgress) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }

    var values: [ThreeDGenerationProgress] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
