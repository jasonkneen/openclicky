import XCTest
@testable import OCAudioCore

/// Concrete subclass standing in for the app's Deepgram / AssemblyAI sessions,
/// which subclass this type across a module boundary — so this also pins that
/// the class and its two overridables stay `open`.
private final class RecordingSession: StreamingWebSocketTranscriptionSession, @unchecked Sendable {
    var received: [String] = []
    var failures: [Error] = []

    override func handleIncomingText(_ text: String) { received.append(text) }
    override func handleReceiveFailure(_ error: Error) { failures.append(error) }
}

final class StreamingWebSocketTranscriptionSessionTests: XCTestCase {
    private func makeSession() -> RecordingSession {
        RecordingSession(urlSession: URLSession(configuration: .ephemeral), sendQueueLabel: "test.send")
    }

    func testStartsWithNoConnection() {
        XCTAssertNil(makeSession().webSocketTask)
    }

    func testOpenWebSocketCreatesAndResumesATask() {
        let session = makeSession()
        session.openWebSocket(with: URLRequest(url: URL(string: "wss://example.invalid/socket")!))
        XCTAssertNotNil(session.webSocketTask)
        session.closeWebSocket()
    }

    func testCloseIsSafeBeforeOpen() {
        // Providers call close on teardown paths that may never have connected.
        makeSession().closeWebSocket()
    }

    func testSendsAreDroppedSilentlyWhenNotConnected() {
        let session = makeSession()
        let noErrors = expectation(description: "no error callback")
        noErrors.isInverted = true
        session.sendAudioData(Data([1, 2, 3])) { _ in noErrors.fulfill() }
        session.sendJSONMessage(["type": "Finalize"]) { _ in noErrors.fulfill() }
        wait(for: [noErrors], timeout: 0.3)
    }

    func testSerializableControlMessagesAreAccepted() {
        // Every real call site sends string-keyed string values, e.g.
        // ["type": "Finalize"] / ["type": "Terminate"].
        let session = makeSession()
        session.openWebSocket(with: URLRequest(url: URL(string: "wss://example.invalid/socket")!))
        session.sendJSONMessage(["type": "Finalize"]) { _ in }
        session.closeWebSocket()
    }

    func testSubclassHooksAreInvokable() {
        let session = makeSession()
        session.handleIncomingText("{\"type\":\"Results\"}")
        session.handleReceiveFailure(URLError(.networkConnectionLost))
        XCTAssertEqual(session.received, ["{\"type\":\"Results\"}"])
        XCTAssertEqual(session.failures.count, 1)
    }
}
