//
//  OpenClickyLocalSpeechModelManager.swift
//  cursor-buddy
//
//  User-visible status/download state for FluidAudio Parakeet STT models.
//

import Combine
@preconcurrency import FluidAudio
import Foundation

nonisolated enum OpenClickyLocalSpeechModelVersion: String, CaseIterable, Identifiable, Sendable {
    case v3
    case v2

    static let defaultsKey = "ParakeetTranscriptionModel"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .v3:
            return "Parakeet TDT v3"
        case .v2:
            return "Parakeet TDT v2"
        }
    }

    var subtitle: String {
        switch self {
        case .v3:
            return "Recommended local STT"
        case .v2:
            return "English fallback"
        }
    }

    var fluidAudioVersion: AsrModelVersion {
        switch self {
        case .v3:
            return .v3
        case .v2:
            return .v2
        }
    }

    static func configured(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> OpenClickyLocalSpeechModelVersion {
        let rawValue = environment["OPENCLICKY_PARAKEET_TRANSCRIPTION_MODEL"]
            ?? userDefaults.string(forKey: defaultsKey)
            ?? AppBundleConfiguration.stringValue(forKey: "ParakeetTranscriptionModel")

        switch rawValue?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines) {
        case "v2", "parakeet-v2", "parakeet_tdt_v2":
            return .v2
        default:
            return .v3
        }
    }
}

enum OpenClickyLocalSpeechDownloadState: Equatable, Sendable {
    case notDownloaded
    case downloading
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .notDownloaded:
            return "Not downloaded"
        case .downloading:
            return "Downloading"
        case .ready:
            return "Ready"
        case .failed:
            return "Failed"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

@MainActor
final class OpenClickyLocalSpeechModelManager: ObservableObject {
    static let shared = OpenClickyLocalSpeechModelManager()

    @Published private(set) var selectedVersion: OpenClickyLocalSpeechModelVersion
    @Published private(set) var downloadStates: [OpenClickyLocalSpeechModelVersion: OpenClickyLocalSpeechDownloadState] = [:]
    @Published private(set) var lastErrorMessage: String?

    private var activeDownloadTasks: [OpenClickyLocalSpeechModelVersion: Task<Void, Never>] = [:]
    private var activeDownloadTokens: [OpenClickyLocalSpeechModelVersion: UUID] = [:]

    var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    init(selectedVersion: OpenClickyLocalSpeechModelVersion = .configured()) {
        self.selectedVersion = selectedVersion
        for version in OpenClickyLocalSpeechModelVersion.allCases {
            downloadStates[version] = OpenClickyLocalSpeechModelCache.modelsExist(for: version)
                ? .ready
                : .notDownloaded
        }
        Task { [weak self] in
            await self?.refreshDiskStateInBackground()
        }
    }

    func setSelectedVersion(_ version: OpenClickyLocalSpeechModelVersion) {
        selectedVersion = version
        UserDefaults.standard.set(version.rawValue, forKey: OpenClickyLocalSpeechModelVersion.defaultsKey)
    }

    var isSelectedModelReady: Bool {
        state(for: selectedVersion).isReady
    }

    func refreshDiskStateInBackground() async {
        let versions = OpenClickyLocalSpeechModelVersion.allCases
        let states = await Task.detached(priority: .utility) {
            versions.reduce(into: [OpenClickyLocalSpeechModelVersion: Bool]()) { partialResult, version in
                partialResult[version] = OpenClickyLocalSpeechModelCache.modelsExist(for: version)
            }
        }.value

        for version in versions {
            if activeDownloadTasks[version] != nil { continue }
            downloadStates[version] = (states[version] == true) ? .ready : .notDownloaded
        }
    }

    func downloadSelectedModel() {
        downloadModel(selectedVersion)
    }

    func downloadModel(_ version: OpenClickyLocalSpeechModelVersion) {
        guard isAppleSilicon else {
            lastErrorMessage = "Parakeet local transcription requires Apple Silicon."
            downloadStates[version] = .failed(lastErrorMessage ?? "Unavailable")
            return
        }
        guard activeDownloadTasks[version] == nil else { return }

        let downloadToken = UUID()
        lastErrorMessage = nil
        activeDownloadTokens[version] = downloadToken
        downloadStates[version] = .downloading

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                _ = try await AsrModels.download(version: version.fluidAudioVersion)
                try Task.checkCancellation()
                guard self.activeDownloadTokens[version] == downloadToken else { return }
                if OpenClickyLocalSpeechModelCache.modelsExist(for: version) {
                    self.downloadStates[version] = .ready
                } else {
                    let message = "Parakeet download finished but model files were not found in the expected cache."
                    self.lastErrorMessage = message
                    self.downloadStates[version] = .failed(message)
                }
            } catch is CancellationError {
                guard self.activeDownloadTokens[version] == downloadToken else { return }
                self.downloadStates[version] = .notDownloaded
            } catch {
                guard self.activeDownloadTokens[version] == downloadToken else { return }
                let message = error.localizedDescription
                self.lastErrorMessage = message
                self.downloadStates[version] = .failed(message)
            }
            if self.activeDownloadTokens[version] == downloadToken {
                self.activeDownloadTokens[version] = nil
                self.activeDownloadTasks[version] = nil
            }
        }
        activeDownloadTasks[version] = task
    }

    func markReady(_ version: OpenClickyLocalSpeechModelVersion) {
        activeDownloadTokens[version] = nil
        activeDownloadTasks[version] = nil
        downloadStates[version] = .ready
    }

    func cancelDownload(_ version: OpenClickyLocalSpeechModelVersion) {
        activeDownloadTokens[version] = nil
        activeDownloadTasks[version]?.cancel()
        activeDownloadTasks[version] = nil
        downloadStates[version] = .notDownloaded
    }

    func state(for version: OpenClickyLocalSpeechModelVersion) -> OpenClickyLocalSpeechDownloadState {
        downloadStates[version] ?? .notDownloaded
    }

    func cacheDirectory(for version: OpenClickyLocalSpeechModelVersion) -> URL {
        OpenClickyLocalSpeechModelCache.cacheDirectory(for: version)
    }
}

nonisolated enum OpenClickyLocalSpeechModelCache {
    static func cacheDirectory(for version: OpenClickyLocalSpeechModelVersion) -> URL {
        AsrModels.defaultCacheDirectory(for: version.fluidAudioVersion)
    }

    static func modelsExist(for version: OpenClickyLocalSpeechModelVersion) -> Bool {
        AsrModels.modelsExist(
            at: cacheDirectory(for: version),
            version: version.fluidAudioVersion
        )
    }
}
