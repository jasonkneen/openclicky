//
//  DeepgramStreamingTranscriptionProvider.swift
//  leanring-buddy
//
//  Streaming transcription provider backed by Deepgram's WebSocket API.
//

import AVFoundation
import Foundation

struct DeepgramStreamingTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class DeepgramStreamingTranscriptionProvider: BuddyTranscriptionProvider {
    private let apiKey = AppBundleConfiguration.deepgramAPIKey()
    private let modelName = AppBundleConfiguration.stringValue(forKey: "DeepgramTranscriptionModel") ?? "nova-3"

    let displayName = "Deepgram"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        apiKey != nil
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "Deepgram streaming is not configured. Add a Deepgram API key."
    }

    private let sharedWebSocketURLSession = URLSession(configuration: .default)

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let apiKey else {
            throw DeepgramStreamingTranscriptionProviderError(
                message: unavailableExplanation ?? "Deepgram streaming is not configured."
            )
        }

        let session = DeepgramStreamingTranscriptionSession(
            apiKey: apiKey,
            modelName: modelName,
            urlSession: sharedWebSocketURLSession,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )

        try await session.open()
        return session
    }
}

private final class DeepgramStreamingTranscriptionSession: BuddyStreamingTranscriptionSession {
    private struct MessageEnvelope: Decodable {
        let type: String?
    }

    private struct ResultsMessage: Decodable {
        let type: String?
        let is_final: Bool?
        let speech_final: Bool?
        let from_finalize: Bool?
        let channel: Channel?
    }

    private struct Channel: Decodable {
        let alternatives: [Alternative]
    }

    private struct Alternative: Decodable {
        let transcript: String?
    }

    private struct ErrorMessage: Decodable {
        let type: String?
        let description: String?
        let message: String?
    }

    private static let websocketBaseURLString = "wss://api.deepgram.com/v1/listen"
    private static let targetSampleRate = 16_000.0
    private static let explicitFinalTranscriptGracePeriodSeconds = 1.6

    let finalTranscriptFallbackDelaySeconds: TimeInterval = 3.0

    private let apiKey: String
    private let modelName: String
    private let urlSession: URLSession
    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.deepgram.state")
    private let sendQueue = DispatchQueue(label: "com.learningbuddy.deepgram.send")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: targetSampleRate)

    private var webSocketTask: URLSessionWebSocketTask?
    private var hasDeliveredFinalTranscript = false
    private var isAwaitingExplicitFinalTranscript = false
    private var isCancelled = false
    private var committedTranscriptSegments: [String] = []
    private var latestInterimTranscriptText = ""
    private var explicitFinalTranscriptDeadlineWorkItem: DispatchWorkItem?

    init(
        apiKey: String,
        modelName: String,
        urlSession: URLSession,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.urlSession = urlSession
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func open() async throws {
        let websocketURL = try Self.makeWebsocketURL(modelName: modelName, keyterms: keyterms)
        var websocketRequest = URLRequest(url: websocketURL)
        websocketRequest.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let webSocketTask = urlSession.webSocketTask(with: websocketRequest)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()
        receiveNextMessage()
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.data(audioPCM16Data)) { [weak self] error in
                if let error {
                    self?.failSession(with: error)
                }
            }
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasDeliveredFinalTranscript else { return }
            self.isAwaitingExplicitFinalTranscript = true
            self.scheduleExplicitFinalTranscriptDeadline()
        }

        sendJSONMessage(["type": "Finalize"])
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
            self.explicitFinalTranscriptDeadlineWorkItem = nil
        }

        sendJSONMessage(["type": "CloseStream"])
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingTextMessage(text)
                    }
                @unknown default:
                    break
                }

                self.receiveNextMessage()
            case .failure(let error):
                self.failSession(with: error)
            }
        }
    }

    private func handleIncomingTextMessage(_ text: String) {
        guard let messageData = text.data(using: .utf8) else { return }

        do {
            let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: messageData)
            switch envelope.type?.lowercased() {
            case "results":
                let resultsMessage = try JSONDecoder().decode(ResultsMessage.self, from: messageData)
                handleResultsMessage(resultsMessage)
            case "error":
                let errorMessage = try JSONDecoder().decode(ErrorMessage.self, from: messageData)
                let messageText = errorMessage.description ?? errorMessage.message ?? "Deepgram returned an error."
                failSession(with: DeepgramStreamingTranscriptionProviderError(message: messageText))
            default:
                break
            }
        } catch {
            failSession(with: error)
        }
    }

    private func handleResultsMessage(_ resultsMessage: ResultsMessage) {
        let transcriptText = resultsMessage.channel?.alternatives.first?.transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        stateQueue.async {
            if resultsMessage.is_final == true || resultsMessage.speech_final == true {
                if !transcriptText.isEmpty {
                    self.committedTranscriptSegments.append(transcriptText)
                }
                self.latestInterimTranscriptText = ""
            } else {
                self.latestInterimTranscriptText = transcriptText
            }

            let fullTranscriptText = self.bestAvailableTranscriptText()
            if !fullTranscriptText.isEmpty {
                self.onTranscriptUpdate(fullTranscriptText)
            }

            guard self.isAwaitingExplicitFinalTranscript else { return }

            if resultsMessage.from_finalize == true
                || resultsMessage.is_final == true
                || resultsMessage.speech_final == true {
                self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
                self.explicitFinalTranscriptDeadlineWorkItem = nil
                self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
            }
        }
    }

    private func scheduleExplicitFinalTranscriptDeadline() {
        explicitFinalTranscriptDeadlineWorkItem?.cancel()

        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            self?.stateQueue.async {
                guard let self else { return }
                self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
            }
        }

        explicitFinalTranscriptDeadlineWorkItem = deadlineWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.explicitFinalTranscriptGracePeriodSeconds,
            execute: deadlineWorkItem
        )
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        explicitFinalTranscriptDeadlineWorkItem?.cancel()
        explicitFinalTranscriptDeadlineWorkItem = nil
        onFinalTranscriptReady(transcriptText)
        sendJSONMessage(["type": "CloseStream"])
    }

    private func sendJSONMessage(_ payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.string(jsonString)) { [weak self] error in
                if let error {
                    self?.failSession(with: error)
                }
            }
        }
    }

    private func failSession(with error: Error) {
        stateQueue.async {
            guard !self.isCancelled else { return }

            let latestTranscriptText = self.bestAvailableTranscriptText()
            if self.isAwaitingExplicitFinalTranscript
                && !self.hasDeliveredFinalTranscript
                && !latestTranscriptText.isEmpty {
                print("[Deepgram] WebSocket error during finalization, delivering partial transcript: \(error.localizedDescription)")
                self.deliverFinalTranscriptIfNeeded(latestTranscriptText)
                return
            }

            print("[Deepgram] Session failed with error: \(error.localizedDescription)")
            self.onError(error)
        }
    }

    private func bestAvailableTranscriptText() -> String {
        var transcriptSegments = committedTranscriptSegments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let trimmedInterimText = latestInterimTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInterimText.isEmpty {
            transcriptSegments.append(trimmedInterimText)
        }

        return transcriptSegments.joined(separator: " ")
    }

    private static func makeWebsocketURL(modelName: String, keyterms: [String]) throws -> URL {
        guard var websocketURLComponents = URLComponents(string: websocketBaseURLString) else {
            throw DeepgramStreamingTranscriptionProviderError(message: "Deepgram websocket URL is invalid.")
        }

        var queryItems = [
            URLQueryItem(name: "model", value: modelName),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "endpointing", value: "300")
        ]

        for keyterm in keyterms
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty })
            .prefix(25) {
            queryItems.append(URLQueryItem(name: "keywords", value: keyterm))
        }

        websocketURLComponents.queryItems = queryItems

        guard let websocketURL = websocketURLComponents.url else {
            throw DeepgramStreamingTranscriptionProviderError(message: "Deepgram websocket URL could not be created.")
        }

        return websocketURL
    }
}
