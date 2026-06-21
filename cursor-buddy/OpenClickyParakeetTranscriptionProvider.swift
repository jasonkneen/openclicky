//
//  OpenClickyParakeetTranscriptionProvider.swift
//  cursor-buddy
//
//  Local transcription provider backed by FluidAudio Parakeet.
//

import AVFoundation
import CoreML
@preconcurrency import FluidAudio
import Foundation

struct OpenClickyParakeetTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class OpenClickyParakeetTranscriptionProvider: BuddyTranscriptionProvider {
    private var modelVersion: OpenClickyLocalSpeechModelVersion {
        OpenClickyLocalSpeechModelVersion.configured()
    }

    let displayName = "Parakeet"
    let requiresSpeechRecognitionPermission = false
    let shouldStartAudioCaptureBeforeProviderReady = false

    var isConfigured: Bool {
        OpenClickyLocalSpeechModelManager.shared.isAppleSilicon
            && OpenClickyLocalSpeechModelCache.modelsExist(for: modelVersion)
    }

    var unavailableExplanation: String? {
        if !OpenClickyLocalSpeechModelManager.shared.isAppleSilicon {
            return "Parakeet local transcription requires Apple Silicon."
        }

        let version = modelVersion
        if OpenClickyLocalSpeechModelCache.modelsExist(for: version) {
            return nil
        }
        return "Download \(version.label) before using Parakeet local transcription."
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard isConfigured else {
            throw OpenClickyParakeetTranscriptionProviderError(
                message: unavailableExplanation ?? "Parakeet local transcription is not available."
            )
        }

        let loadedModel = try await OpenClickyParakeetModelStore.shared.loadedModel(for: modelVersion)
        await MainActor.run {
            OpenClickyLocalSpeechModelManager.shared.markReady(modelVersion)
        }
        return OpenClickyParakeetTranscriptionSession(
            loadedModel: loadedModel,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private nonisolated final class OpenClickyParakeetLoadedModel: @unchecked Sendable {
    let manager: AsrManager

    init(manager: AsrManager) {
        self.manager = manager
    }
}

private actor OpenClickyParakeetModelStore {
    static let shared = OpenClickyParakeetModelStore()

    private var loadedModels: [OpenClickyLocalSpeechModelVersion: OpenClickyParakeetLoadedModel] = [:]

    func loadedModel(for version: OpenClickyLocalSpeechModelVersion) async throws -> OpenClickyParakeetLoadedModel {
        if let loadedModel = loadedModels[version] {
            return loadedModel
        }

        let cacheDirectory = OpenClickyLocalSpeechModelCache.cacheDirectory(for: version)
        guard OpenClickyLocalSpeechModelCache.modelsExist(for: version) else {
            throw OpenClickyParakeetTranscriptionProviderError(
                message: "Download \(version.label) before using Parakeet local transcription."
            )
        }

        let models = try OpenClickyParakeetCacheOnlyModelLoader.loadModels(
            from: cacheDirectory,
            version: version
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)

        let loadedModel = OpenClickyParakeetLoadedModel(manager: manager)
        loadedModels[version] = loadedModel
        return loadedModel
    }
}

private nonisolated enum OpenClickyParakeetCacheOnlyModelLoader {
    private static var configuration: MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return configuration
    }

    static func loadModels(
        from cacheDirectory: URL,
        version: OpenClickyLocalSpeechModelVersion
    ) throws -> AsrModels {
        let repoDirectory = cacheDirectory.standardizedFileURL
        let preprocessorConfiguration = MLModelConfiguration()
        preprocessorConfiguration.computeUnits = .cpuOnly

        let preprocessor = try loadModel(
            named: ModelNames.ASR.preprocessorFile,
            from: repoDirectory,
            configuration: preprocessorConfiguration
        )
        let encoder = try loadModel(
            named: ModelNames.ASR.encoderFile,
            from: repoDirectory,
            configuration: configuration
        )
        let decoder = try loadModel(
            named: ModelNames.ASR.decoderFile,
            from: repoDirectory,
            configuration: configuration
        )
        let joint = try loadModel(
            named: jointFileName(for: version),
            from: repoDirectory,
            configuration: configuration
        )
        let vocabulary = try loadVocabulary(from: repoDirectory)

        return AsrModels(
            encoder: encoder,
            preprocessor: preprocessor,
            decoder: decoder,
            joint: joint,
            configuration: configuration,
            vocabulary: vocabulary,
            version: version.fluidAudioVersion
        )
    }

    private static func loadModel(
        named fileName: String,
        from repoDirectory: URL,
        configuration: MLModelConfiguration
    ) throws -> MLModel {
        let modelURL = repoDirectory.appendingPathComponent(fileName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw OpenClickyParakeetTranscriptionProviderError(
                message: "Parakeet model file is missing: \(fileName). Reinstall the local voice model from Settings."
            )
        }
        return try MLModel(contentsOf: modelURL, configuration: configuration)
    }

    private static func jointFileName(for version: OpenClickyLocalSpeechModelVersion) -> String {
        switch version {
        case .v3:
            return ModelNames.ASR.jointV3File
        case .v2:
            return ModelNames.ASR.jointFile
        }
    }

    private static func loadVocabulary(from repoDirectory: URL) throws -> [Int: String] {
        let vocabularyURL = repoDirectory.appendingPathComponent(ModelNames.ASR.vocabularyFile)
        guard FileManager.default.fileExists(atPath: vocabularyURL.path) else {
            throw OpenClickyParakeetTranscriptionProviderError(
                message: "Parakeet vocabulary is missing. Reinstall the local voice model from Settings."
            )
        }

        let data = try Data(contentsOf: vocabularyURL)
        let object = try JSONSerialization.jsonObject(with: data)
        if let tokenArray = object as? [String] {
            return Dictionary(uniqueKeysWithValues: tokenArray.enumerated().map { ($0.offset, $0.element) })
        }
        if let tokenMap = object as? [String: String] {
            return Dictionary(uniqueKeysWithValues: tokenMap.compactMap { key, value in
                guard let tokenID = Int(key) else { return nil }
                return (tokenID, value)
            })
        }
        throw OpenClickyParakeetTranscriptionProviderError(
            message: "Parakeet vocabulary format is not recognized. Reinstall the local voice model from Settings."
        )
    }
}

private enum OpenClickyParakeetDecoderStateFactory {
    static func make(for manager: AsrManager) async -> TdtDecoderState {
        let decoderLayers = await manager.decoderLayerCount
        return TdtDecoderState.make(decoderLayers: decoderLayers)
    }
}

private final class OpenClickyParakeetTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 12.0

    private static let targetSampleRate = 16_000

    private let loadedModel: OpenClickyParakeetLoadedModel
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.openclicky.parakeet.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        loadedModel: OpenClickyParakeetLoadedModel,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.loadedModel = loadedModel
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }

        transcriptionTask?.cancel()
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let shouldStop = stateQueue.sync {
            isCancelled || bufferedPCM16AudioData.isEmpty
        }

        if shouldStop {
            deliverFinalTranscript("")
            return
        }

        let samples = Self.floatSamples(fromPCM16LittleEndianAudio: bufferedPCM16AudioData)
        guard samples.count >= Self.targetSampleRate / 10 else {
            deliverFinalTranscript("")
            return
        }

        do {
            var decoderState = await OpenClickyParakeetDecoderStateFactory.make(for: loadedModel.manager)
            let result = try await loadedModel.manager.transcribe(samples, decoderState: &decoderState)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            let transcriptText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }

            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            onError(error)
        }
    }

    private static func floatSamples(fromPCM16LittleEndianAudio audioData: Data) -> [Float] {
        let sampleCount = audioData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }

        var samples: [Float] = []
        samples.reserveCapacity(sampleCount)

        audioData.withUnsafeBytes { rawBuffer in
            var byteOffset = 0
            while byteOffset + MemoryLayout<Int16>.size <= rawBuffer.count {
                let rawSample = rawBuffer.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self)
                let sample = Int16(littleEndian: rawSample)
                samples.append(max(-1, min(1, Float(sample) / 32768.0)))
                byteOffset += MemoryLayout<Int16>.size
            }
        }

        return samples
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        transcriptionTask?.cancel()
    }
}
