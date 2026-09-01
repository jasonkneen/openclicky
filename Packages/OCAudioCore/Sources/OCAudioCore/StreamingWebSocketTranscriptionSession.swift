//
//  StreamingWebSocketTranscriptionSession.swift
//  OCAudioCore
//
//  Shared WebSocket open/receive-loop/send/close scaffolding for streaming
//  transcription providers (Deepgram, AssemblyAI). Protocol-specific
//  behavior — auth headers, connection query parameters, message payloads,
//  and response parsing — stays in each provider's session subclass.
//

import Foundation

/// Base class for a single streaming-transcription WebSocket connection.
/// Subclasses supply the provider-specific `URLRequest`, decode incoming
/// frames, and react to receive failures; this class owns the connection
/// lifecycle (open, receive loop, send, close).
open class StreamingWebSocketTranscriptionSession: NSObject, @unchecked Sendable {
    private let urlSession: URLSession
    let sendQueue: DispatchQueue

    public private(set) var webSocketTask: URLSessionWebSocketTask?

    public init(urlSession: URLSession, sendQueueLabel: String) {
        self.urlSession = urlSession
        self.sendQueue = DispatchQueue(label: sendQueueLabel)
    }

    /// Opens the WebSocket connection with the given request and starts the
    /// receive loop. Callers build `request` with their own auth headers.
    public func openWebSocket(with request: URLRequest) {
        let webSocketTask = urlSession.webSocketTask(with: request)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()
        receiveNextMessage()
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingText(text)
                    }
                @unknown default:
                    break
                }

                self.receiveNextMessage()
            case .failure(let error):
                self.handleReceiveFailure(error)
            }
        }
    }

    /// Override to decode and route an incoming text (or data-as-text) frame.
    open func handleIncomingText(_ text: String) {
        fatalError("\(Self.self) must override handleIncomingText(_:)")
    }

    /// Override to react to a WebSocket receive failure.
    open func handleReceiveFailure(_ error: Error) {
        fatalError("\(Self.self) must override handleReceiveFailure(_:)")
    }

    /// Sends raw audio data on the send queue.
    public func sendAudioData(_ data: Data, onError: @escaping (Error) -> Void) {
        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.data(data)) { error in
                if let error {
                    onError(error)
                }
            }
        }
    }

    /// Serializes and sends a JSON control message on the send queue.
    public func sendJSONMessage(_ payload: [String: Any], onError: @escaping (Error) -> Void) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.string(jsonString)) { error in
                if let error {
                    onError(error)
                }
            }
        }
    }

    /// Closes the underlying WebSocket task.
    public func closeWebSocket(with closeCode: URLSessionWebSocketTask.CloseCode = .goingAway, reason: Data? = nil) {
        webSocketTask?.cancel(with: closeCode, reason: reason)
    }
}
