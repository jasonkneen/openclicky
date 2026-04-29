//
//  AppBundleConfiguration.swift
//  leanring-buddy
//
//  Shared helper for reading runtime configuration from the built app bundle.
//

import Foundation

nonisolated enum AppBundleConfiguration {
    static let userAnthropicAPIKeyDefaultsKey = "openClickyAnthropicAPIKey"
    static let userElevenLabsAPIKeyDefaultsKey = "openClickyElevenLabsAPIKey"
    static let userElevenLabsVoiceIDDefaultsKey = "openClickyElevenLabsVoiceID"
    static let userCartesiaAPIKeyDefaultsKey = "openClickyCartesiaAPIKey"
    static let userCartesiaVoiceIDDefaultsKey = "openClickyCartesiaVoiceID"
    /// Deepgram TTS reuses the existing Deepgram STT API key
    /// (`userDeepgramAPIKeyDefaultsKey`). Only the voice/model is
    /// TTS-specific.
    static let userDeepgramTTSVoiceDefaultsKey = "openClickyDeepgramTTSVoice"
    static let userGeminiAPIKeyDefaultsKey = "openClickyGeminiAPIKey"
    static let userGeminiTTSVoiceDefaultsKey = "openClickyGeminiTTSVoice"
    static let userGeminiTTSModelDefaultsKey = "openClickyGeminiTTSModel"
    static let userTTSProviderDefaultsKey = "openClickyTTSProvider"
    static let userSpeculativePreFireDefaultsKey = "openClickySpeculativePreFireEnabled"
    static let userCodexAgentAPIKeyDefaultsKey = "openClickyCodexAgentAPIKey"
    static let userOpenAITTSVoiceDefaultsKey = "openClickyOpenAITTSVoice"
    static let userOpenAITTSModelDefaultsKey = "openClickyOpenAITTSModel"
    static let userAssemblyAIAPIKeyDefaultsKey = "openClickyAssemblyAIAPIKey"
    static let userDeepgramAPIKeyDefaultsKey = "openClickyDeepgramAPIKey"
    static let userVoiceTranscriptionProviderDefaultsKey = "openClickyVoiceTranscriptionProvider"
    static let userAdvancedModeDefaultsKey = "openClickyAdvancedModeEnabled"
    static let userComputerUseBackendDefaultsKey = "openClickyComputerUseBackend"
    static let userNativeComputerUseDefaultsKey = "openClickyNativeComputerUseEnabled"
    static let userWidgetsEnabledDefaultsKey = "openClickyWidgetsEnabled"
    static let userWidgetsIncludeAgentTaskNamesDefaultsKey = "openClickyWidgetsIncludeAgentTaskNames"
    static let userWidgetsIncludeMemorySnippetsDefaultsKey = "openClickyWidgetsIncludeMemorySnippets"
    static let userWidgetsIncludeFocusedAppContextDefaultsKey = "openClickyWidgetsIncludeFocusedAppContext"
    /// Fades out the buddy cursor after no HID activity (covers video/fullscreen passive viewing).
    static let userBuddyFadeWhenIdleEnabledKey = "openClickyBuddyFadeWhenIdleEnabled"
    /// Seconds of keyboard/mouse inactivity before fading (stored as Double).
    static let userBuddyFadeWhenIdleSecondsKey = "openClickyBuddyFadeWhenIdleSeconds"
    static let appGroupIdentifier = "group.com.jkneen.openclicky"

    static func anthropicAPIKey() -> String? {
        let configuredAnthropicAPIKey = userDefaultsValue(forKey: userAnthropicAPIKeyDefaultsKey) ?? stringValue(
            forKey: "AnthropicAPIKey",
            environmentKeys: ["ANTHROPIC_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "ANTHROPIC_API_KEY")

        guard let configuredAnthropicAPIKey else { return nil }
        return configuredAnthropicAPIKey.hasPrefix("sk-ant-api") ? configuredAnthropicAPIKey : nil
    }

    static func openAIAPIKey() -> String? {
        userDefaultsValue(forKey: userCodexAgentAPIKeyDefaultsKey) ?? stringValue(
            forKey: "OpenAIAPIKey",
            environmentKeys: ["OPENAI_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "OPENAI_API_KEY")
    }

    /// OpenAI TTS voice (`alloy`, `echo`, `fable`, `onyx`, `nova`, `shimmer`).
    static func openAITTSVoice() -> String {
        userDefaultsValue(forKey: userOpenAITTSVoiceDefaultsKey) ?? stringValue(
            forKey: "OpenAITTSVoice",
            environmentKeys: ["OPENAI_TTS_VOICE"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "OPENAI_TTS_VOICE")
        ?? "alloy"
    }

    /// OpenAI TTS model for `/v1/audio/speech`. Some API projects no longer allow
    /// legacy `tts-1` / `tts-1-hd`; `gpt-4o-mini-tts` is the current default.
    /// Override with `OPENAI_TTS_MODEL` or Settings → Voice.
    static func openAITTSModel() -> String {
        userDefaultsValue(forKey: userOpenAITTSModelDefaultsKey) ?? stringValue(
            forKey: "OpenAITTSModel",
            environmentKeys: ["OPENAI_TTS_MODEL"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "OPENAI_TTS_MODEL")
        ?? "gpt-4o-mini-tts"
    }

    static func assemblyAIAPIKey() -> String? {
        userDefaultsValue(forKey: userAssemblyAIAPIKeyDefaultsKey) ?? stringValue(
            forKey: "AssemblyAIAPIKey",
            environmentKeys: ["ASSEMBLYAI_API_KEY", "ASSEMBLY_AI_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "ASSEMBLYAI_API_KEY")
            ?? localDevelopmentEnvironmentValue(forKey: "ASSEMBLY_AI_API_KEY")
    }

    static func deepgramAPIKey() -> String? {
        userDefaultsValue(forKey: userDeepgramAPIKeyDefaultsKey) ?? stringValue(
            forKey: "DeepgramAPIKey",
            environmentKeys: ["DEEPGRAM_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "DEEPGRAM_API_KEY")
    }

    static func elevenLabsAPIKey() -> String? {
        userDefaultsValue(forKey: userElevenLabsAPIKeyDefaultsKey) ?? stringValue(
            forKey: "ElevenLabsAPIKey",
            environmentKeys: ["ELEVENLABS_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "ELEVENLABS_API_KEY")
    }

    static func elevenLabsVoiceID() -> String {
        userDefaultsValue(forKey: userElevenLabsVoiceIDDefaultsKey) ?? stringValue(
            forKey: "ElevenLabsVoiceID",
            environmentKeys: ["ELEVENLABS_VOICE_ID"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "ELEVENLABS_VOICE_ID")
        ?? "kPzsL2i3teMYv0FxEYQ6"
    }

    static func cartesiaAPIKey() -> String? {
        userDefaultsValue(forKey: userCartesiaAPIKeyDefaultsKey) ?? stringValue(
            forKey: "CartesiaAPIKey",
            environmentKeys: ["CARTESIA_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "CARTESIA_API_KEY")
    }

    /// Cartesia voice ID. Defaults to one of their public neutral voices.
    /// Users override via Settings → Voice → Cartesia voice ID.
    static func cartesiaVoiceID() -> String {
        userDefaultsValue(forKey: userCartesiaVoiceIDDefaultsKey) ?? stringValue(
            forKey: "CartesiaVoiceID",
            environmentKeys: ["CARTESIA_VOICE_ID"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "CARTESIA_VOICE_ID")
        ?? "a0e99841-438c-4a64-b679-ae501e7d6091"
    }

    /// Selected TTS provider — "elevenlabs" (default), "cartesia", "deepgram", or "gemini".
    static func ttsProviderRaw() -> String {
        userDefaultsValue(forKey: userTTSProviderDefaultsKey)
        ?? stringValue(forKey: "OpenClickyTTSProvider", environmentKeys: ["OPENCLICKY_TTS_PROVIDER"])
        ?? localDevelopmentEnvironmentValue(forKey: "OPENCLICKY_TTS_PROVIDER")
        ?? "elevenlabs"
    }

    /// Google AI Studio / Gemini API key (used for Gemini native TTS).
    static func geminiAPIKey() -> String? {
        userDefaultsValue(forKey: userGeminiAPIKeyDefaultsKey) ?? stringValue(
            forKey: "GeminiAPIKey",
            environmentKeys: ["GEMINI_API_KEY", "GOOGLE_GEMINI_API_KEY", "GOOGLE_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "GEMINI_API_KEY")
            ?? localDevelopmentEnvironmentValue(forKey: "GOOGLE_GEMINI_API_KEY")
            ?? localDevelopmentEnvironmentValue(forKey: "GOOGLE_API_KEY")
    }

    /// Prebuilt voice name for Gemini speech generation (e.g. `Kore`, `Puck`).
    static func geminiTTSVoice() -> String {
        userDefaultsValue(forKey: userGeminiTTSVoiceDefaultsKey) ?? stringValue(
            forKey: "GeminiTTSVoice",
            environmentKeys: ["GEMINI_TTS_VOICE"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "GEMINI_TTS_VOICE")
        ?? "Kore"
    }

    /// Gemini TTS model id for `generateContent` (e.g. `gemini-2.5-flash-preview-tts`).
    static func geminiTTSModel() -> String {
        userDefaultsValue(forKey: userGeminiTTSModelDefaultsKey) ?? stringValue(
            forKey: "GeminiTTSModel",
            environmentKeys: ["GEMINI_TTS_MODEL"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "GEMINI_TTS_MODEL")
        ?? "gemini-2.5-flash-preview-tts"
    }

    /// OpenAI audio transcription model (`/v1/audio/transcriptions`): `whisper-1`,
    /// `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, etc. Set `OPENAI_TRANSCRIPTION_MODEL`
    /// if your project restricts Whisper or you prefer GPT-4o-class STT.
    static func openAITranscriptionModel() -> String {
        stringValue(
            forKey: "OpenAITranscriptionModel",
            environmentKeys: ["OPENAI_TRANSCRIPTION_MODEL"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "OPENAI_TRANSCRIPTION_MODEL")
        ?? "whisper-1"
    }

    /// Voice STT provider id: `automatic`, `apple`, `assemblyai`, `deepgram`, `openai`. Secrets: `OPENCLICKY_VOICE_TRANSCRIPTION_PROVIDER`.
    static func voiceTranscriptionProviderRaw() -> String? {
        userDefaultsValue(forKey: userVoiceTranscriptionProviderDefaultsKey)
        ?? stringValue(
            forKey: "VoiceTranscriptionProvider",
            environmentKeys: ["OPENCLICKY_VOICE_TRANSCRIPTION_PROVIDER"]
        )
        ?? localDevelopmentEnvironmentValue(forKey: "OPENCLICKY_VOICE_TRANSCRIPTION_PROVIDER")
    }

    /// Deepgram TTS voice/model identifier. Defaults to Aura 2 Thalia
    /// (en). Verified against https://developers.deepgram.com (2026-04-26):
    /// auth uses the same `Authorization: Token <key>` as STT, model
    /// goes in `?model=` query param, output is PCM linear16 when
    /// requested via `encoding=linear16&sample_rate=22050&container=none`.
    static func deepgramTTSVoice() -> String {
        userDefaultsValue(forKey: userDeepgramTTSVoiceDefaultsKey) ?? stringValue(
            forKey: "DeepgramTTSVoice",
            environmentKeys: ["DEEPGRAM_TTS_VOICE"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "DEEPGRAM_TTS_VOICE")
        ?? "aura-2-thalia-en"
    }

    private static func userDefaultsValue(forKey key: String) -> String? {
        normalizedConfigurationValue(UserDefaults.standard.string(forKey: key))
    }

    static func stringValue(forKey key: String, environmentKeys: [String] = []) -> String? {
        if let bundledInfoValue = normalizedConfigurationValue(Bundle.main.object(forInfoDictionaryKey: key) as? String) {
            return bundledInfoValue
        }

        guard let resourceInfoPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              let resourceInfo = NSDictionary(contentsOfFile: resourceInfoPath) else {
            return stringValueFromEnvironment(forKey: key, environmentKeys: environmentKeys)
        }

        if let resourceInfoValue = normalizedConfigurationValue(resourceInfo[key] as? String) {
            return resourceInfoValue
        }

        return stringValueFromEnvironment(forKey: key, environmentKeys: environmentKeys)
    }

    private static func stringValueFromEnvironment(forKey key: String, environmentKeys: [String]) -> String? {
        let candidateEnvironmentKeys = [key] + environmentKeys

        for environmentKey in candidateEnvironmentKeys {
            if let environmentValue = normalizedConfigurationValue(ProcessInfo.processInfo.environment[environmentKey]) {
                return environmentValue
            }
        }

        return nil
    }

    private static func localDevelopmentEnvironmentValue(forKey key: String) -> String? {
        for environmentFileURL in localDevelopmentEnvironmentFileURLs() {
            guard let fileContents = try? String(contentsOf: environmentFileURL, encoding: .utf8) else {
                continue
            }

            if let value = environmentValue(forKey: key, in: fileContents) {
                return value
            }
        }

        return nil
    }

    private static func localDevelopmentEnvironmentFileURLs() -> [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = []

        if let explicitSecretsFilePath = normalizedConfigurationValue(ProcessInfo.processInfo.environment["OPENCLICKY_SECRETS_FILE"]) {
            urls.append(URL(fileURLWithPath: explicitSecretsFilePath))
        }

        if let homeDirectory = fileManager.homeDirectoryForCurrentUser.path.removingPercentEncoding {
            urls.append(URL(fileURLWithPath: homeDirectory).appendingPathComponent(".config/openclicky/secrets.env"))
        }

        return urls
    }

    private static func environmentValue(forKey key: String, in fileContents: String) -> String? {
        for rawLine in fileContents.components(separatedBy: .newlines) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else {
                continue
            }

            let lineWithoutExportPrefix: String
            if trimmedLine.hasPrefix("export ") {
                lineWithoutExportPrefix = String(trimmedLine.dropFirst("export ".count))
            } else {
                lineWithoutExportPrefix = trimmedLine
            }

            let keyValueParts = lineWithoutExportPrefix.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValueParts.count == 2 else {
                continue
            }

            let parsedKey = keyValueParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard parsedKey == key else {
                continue
            }

            let rawValue = keyValueParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedConfigurationValue(rawValue.trimmingMatchingQuotes())
        }

        return nil
    }

    private static func normalizedConfigurationValue(_ value: String?) -> String? {
        guard let value else { return nil }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }

        // Xcode leaves unresolved build-setting placeholders in Info.plist as
        // literal strings. Treat those as missing configuration instead of
        // accidentally sending "$(KEY)" as an API key.
        if trimmedValue.hasPrefix("$("), trimmedValue.hasSuffix(")") {
            return nil
        }

        return trimmedValue
    }
}

private extension String {
    nonisolated func trimmingMatchingQuotes() -> String {
        guard count >= 2 else { return self }

        if hasPrefix("\""), hasSuffix("\"") {
            return String(dropFirst().dropLast())
        }

        if hasPrefix("'"), hasSuffix("'") {
            return String(dropFirst().dropLast())
        }

        return self
    }
}
