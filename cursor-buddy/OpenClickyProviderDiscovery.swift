//
//  OpenClickyProviderDiscovery.swift
//  cursor-buddy
//
//  Minimal auto-discovery for the three terminal-first voice backends:
//  Apple Foundation Models (on-device), Codex app-server / CLI, and Claude Agent SDK.
//  Does not package runtimes — only probes what is already installed.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

nonisolated struct OpenClickyProviderAvailability: Equatable, Sendable {
    let family: OpenClickyVoiceBackendFamily
    let isAvailable: Bool
    /// Short status for the bubble/notch indicator.
    let statusLabel: String
    /// Longer hint when unavailable.
    let detail: String
}

nonisolated enum OpenClickyProviderDiscovery {
    /// Probe installed backends. Safe to call from any context; does not spawn
    /// long-lived processes — only checks executables / system capability.
    static func availability(
        fileManager: FileManager = .default
    ) -> [OpenClickyProviderAvailability] {
        [
            appleAvailability(),
            codexAvailability(fileManager: fileManager),
            claudeAvailability(fileManager: fileManager)
        ]
    }

    static func isAvailable(
        _ family: OpenClickyVoiceBackendFamily,
        fileManager: FileManager = .default
    ) -> Bool {
        availability(fileManager: fileManager).first { $0.family == family }?.isAvailable ?? false
    }

    static func appleAvailability() -> OpenClickyProviderAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let available = SystemLanguageModel.default.isAvailable
            return OpenClickyProviderAvailability(
                family: .apple,
                isAvailable: available,
                statusLabel: available ? "Ready" : "Unavailable",
                detail: available
                    ? "Apple Intelligence on-device model is ready."
                    : "Apple Foundation Models are not available on this Mac (requires Apple Intelligence)."
            )
        }
        #endif
        return OpenClickyProviderAvailability(
            family: .apple,
            isAvailable: false,
            statusLabel: "macOS 26+",
            detail: "On-device Apple models require macOS 26 with Apple Intelligence."
        )
    }

    static func codexAvailability(fileManager: FileManager = .default) -> OpenClickyProviderAvailability {
        let hasExecutable = !CodexRuntimeLocator.codexExecutableCandidates(
            bundle: .main,
            fileManager: fileManager
        ).isEmpty
        let hasOpenAIKey = AppBundleConfiguration.openAIAPIKey() != nil
        let available = hasExecutable || hasOpenAIKey
        let detail: String
        if hasExecutable {
            detail = "Codex runtime detected."
        } else if hasOpenAIKey {
            detail = "No local Codex binary; OpenAI key can still serve as fallback."
        } else {
            detail = "Install Codex or set an OpenAI API key."
        }
        return OpenClickyProviderAvailability(
            family: .codex,
            isAvailable: available,
            statusLabel: hasExecutable ? "Detected" : (hasOpenAIKey ? "Key only" : "Missing"),
            detail: detail
        )
    }

    static func claudeAvailability(fileManager: FileManager = .default) -> OpenClickyProviderAvailability {
        // Probe PATH ourselves so this stays nonisolated (ClaudeAgentSDKAPI is @MainActor).
        let hasClaudeCLI = claudeExecutableURL(fileManager: fileManager) != nil
        let hasAnthropicKey = AppBundleConfiguration.anthropicAPIKey() != nil
        let available = hasClaudeCLI || hasAnthropicKey
        let detail: String
        if hasClaudeCLI {
            detail = "Claude Code CLI detected for Agent SDK sign-in reuse."
        } else if hasAnthropicKey {
            detail = "No Claude CLI; Anthropic API key can still serve as fallback."
        } else {
            detail = "Install Claude Code or set an Anthropic API key."
        }
        return OpenClickyProviderAvailability(
            family: .claude,
            isAvailable: available,
            statusLabel: hasClaudeCLI ? "Detected" : (hasAnthropicKey ? "Key only" : "Missing"),
            detail: detail
        )
    }

    /// Mirrors `ClaudeAgentSDKAPI.findExecutable` without MainActor isolation.
    private static func claudeExecutableURL(fileManager: FileManager) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let explicitPath = environment["OPENCLICKY_CLAUDE_EXECUTABLE"],
           fileManager.isExecutableFile(atPath: explicitPath) {
            return URL(fileURLWithPath: explicitPath)
        }

        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude", isDirectory: false) }

        let fixedCandidates = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude", isDirectory: false),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude", isDirectory: false),
            URL(fileURLWithPath: "/usr/local/bin/claude", isDirectory: false)
        ]

        return (pathCandidates + fixedCandidates).first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }
}
