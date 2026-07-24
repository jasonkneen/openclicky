//
//  AppBundleConfiguration.swift
//  cursor-buddy
//
//  Shared helper for reading runtime configuration from the built app bundle.
//

import Foundation
import Security

nonisolated enum AppBundleConfiguration {
    static let userAnthropicAPIKeyDefaultsKey = "openClickyAnthropicAPIKey"
    static let userElevenLabsAPIKeyDefaultsKey = "openClickyElevenLabsAPIKey"
    static let userElevenLabsVoiceIDDefaultsKey = "openClickyElevenLabsVoiceID"
    static let userCartesiaAPIKeyDefaultsKey = "openClickyCartesiaAPIKey"
    static let userCartesiaVoiceIDDefaultsKey = "openClickyCartesiaVoiceID"
    static let userOpenAIRealtimeVoiceIDDefaultsKey = "openClickyOpenAIRealtimeVoiceID"
    static let userMicrosoftEdgeVoiceIDDefaultsKey = "openClickyMicrosoftEdgeVoiceID"
    /// Deepgram TTS reuses the existing Deepgram STT API key
    /// (`userDeepgramAPIKeyDefaultsKey`). Only the voice/model is
    /// TTS-specific.
    static let userDeepgramTTSVoiceDefaultsKey = "openClickyDeepgramTTSVoice"
    static let userDeepgramVoiceAgentThinkModelDefaultsKey = "openClickyDeepgramVoiceAgentThinkModel"
    static let userTTSProviderDefaultsKey = "openClickyTTSProvider"
    static let openClickyVoicePlaybackVolumeDefaultsKey = "openClickyVoicePlaybackVolume"
    static let defaultVoicePlaybackVolume = 0.45
    static let userSpeculativePreFireDefaultsKey = "openClickySpeculativePreFireEnabled"
    static let userVoiceResponseCaptionsEnabledDefaultsKey = "openClickyVoiceResponseCaptionsEnabled"
    static let userVoiceResponseCaptionFontDefaultsKey = "openClickyVoiceResponseCaptionFont"
    static let userVoiceResponseCaptionOpacityDefaultsKey = "openClickyVoiceResponseCaptionOpacity"
    static let defaultVoiceResponseCaptionOpacity = 0.92
    static let userAppFontDefaultsKey = "openClickyAppFont"
    static let userAppTitleFontSizeDefaultsKey = "openClickyAppTitleFontSize"
    static let userAppBodyFontSizeDefaultsKey = "openClickyAppBodyFontSize"
    static let userAppSubtextFontSizeDefaultsKey = "openClickyAppSubtextFontSize"
    static let userAppLineSpacingDefaultsKey = "openClickyAppLineSpacing"
    static let userAppBoldTextDefaultsKey = "openClickyAppBoldTextEnabled"
    static let userCodexAgentAPIKeyDefaultsKey = "openClickyCodexAgentAPIKey"
    static let userAssemblyAIAPIKeyDefaultsKey = "openClickyAssemblyAIAPIKey"
    static let userDeepgramAPIKeyDefaultsKey = "openClickyDeepgramAPIKey"
    static let userVoiceTranscriptionProviderDefaultsKey = "openClickyVoiceTranscriptionProvider"
    static let userVoiceActivationModeDefaultsKey = "openClickyVoiceActivationMode"
    static let userCameraDeviceIDDefaultsKey = "openClickyCameraDeviceID"
    static let userCameraVoiceContextEnabledDefaultsKey = "openClickyCameraVoiceContextEnabled"
    static let userAdvancedModeDefaultsKey = "openClickyAdvancedModeEnabled"
    static let userComputerUseBackendDefaultsKey = "openClickyComputerUseBackend"
    static let userNativeComputerUseDefaultsKey = "openClickyNativeComputerUseEnabled"
    static let userMCPDeveloperDocsEnabledDefaultsKey = "openClickyMCPDeveloperDocsEnabled"
    static let userMCPComposioConnectEnabledDefaultsKey = "openClickyMCPComposioConnectEnabled"
    static let userMCPComputerUseEnabledDefaultsKey = "openClickyMCPComputerUseEnabled"
    static let userMCPCuaDriverCommandDefaultsKey = "openClickyMCPCuaDriverCommand"
    static let userExternalInferenceProxyEnabledDefaultsKey = "openClickyExternalInferenceProxyEnabled"
    static let userVisualDrawingOverlayToolsEnabledDefaultsKey = "openClickyVisualDrawingOverlayToolsEnabled"
    static let userGmailOAuthToolsEnabledDefaultsKey = "openClickyGmailOAuthToolsEnabled"
    static let userExternalControlBridgeTokenDefaultsKey = "openClickyExternalControlBridgeToken"
    static let userAgentPlaintextProviderSyncEnabledDefaultsKey = "openClickyAgentPlaintextProviderSyncEnabled"
    static let userDesktopNotificationsEnabledDefaultsKey = "openClickyDesktopNotificationsEnabled"
    static let userAgentCompletionVoiceEnabledDefaultsKey = "openClickyAgentCompletionVoiceEnabled"
    static let userWidgetsEnabledDefaultsKey = "openClickyWidgetsEnabled"
    static let userWidgetsIncludeAgentTaskNamesDefaultsKey = "openClickyWidgetsIncludeAgentTaskNames"
    static let userWidgetsIncludeMemorySnippetsDefaultsKey = "openClickyWidgetsIncludeMemorySnippets"
    static let userWidgetsIncludeFocusedAppContextDefaultsKey = "openClickyWidgetsIncludeFocusedAppContext"
    static let userGlassOpacityDefaultsKey = "openClickyGlassOpacity"
    static let userGlassFrostingDefaultsKey = "openClickyGlassFrosting"
    static let userThemeDefaultsKey = "openClickyThemeAppearance"
    /// Hold push-to-talk and circle a region while speaking.
    static let userCircleWhileTalkingEnabledDefaultsKey = "openClickyCircleWhileTalkingEnabled"
    /// When true (default), sample only while the primary mouse button is dragged during PTT hold.
    /// When false, any mouse movement while holding the key draws.
    static let userCircleWhileTalkingRequireClickDefaultsKey = "openClickyCircleWhileTalkingRequireClick"
    static let appGroupIdentifier = "group.com.jkneen.openclicky"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            userAgentCompletionVoiceEnabledDefaultsKey: true,
            userWidgetsEnabledDefaultsKey: true,
            userWidgetsIncludeAgentTaskNamesDefaultsKey: true,
            userWidgetsIncludeMemorySnippetsDefaultsKey: true,
            userWidgetsIncludeFocusedAppContextDefaultsKey: true,
            userCircleWhileTalkingEnabledDefaultsKey: true,
            userCircleWhileTalkingRequireClickDefaultsKey: true
        ])
    }

    static func isCircleWhileTalkingEnabled() -> Bool {
        userDefaultsBool(forKey: userCircleWhileTalkingEnabledDefaultsKey, defaultValue: true)
    }

    static func isCircleWhileTalkingRequireClickEnabled() -> Bool {
        // Default click-and-drag: only true when the key is missing, or when
        // the user explicitly left it on. Users who previously saved false keep that.
        if UserDefaults.standard.object(forKey: userCircleWhileTalkingRequireClickDefaultsKey) == nil {
            return true
        }
        return userDefaultsBool(forKey: userCircleWhileTalkingRequireClickDefaultsKey, defaultValue: true)
    }

    static func anthropicAPIKey() -> String? {
        let configuredAnthropicAPIKey = userDefaultsValue(forKey: userAnthropicAPIKeyDefaultsKey) ?? stringValue(
            forKey: "AnthropicAPIKey",
            environmentKeys: ["ANTHROPIC_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "ANTHROPIC_API_KEY")

        guard let configuredAnthropicAPIKey else { return nil }
        // A custom ANTHROPIC_BASE_URL (e.g. a MiniMax or other Anthropic-compatible
        // provider) implies keys won't follow Anthropic's own "sk-ant-api" prefix.
        if usesCustomAnthropicBaseURL {
            return configuredAnthropicAPIKey
        }
        return configuredAnthropicAPIKey.hasPrefix("sk-ant-api") ? configuredAnthropicAPIKey : nil
    }

    static let defaultAnthropicBaseURL = "https://api.anthropic.com"

    /// Base URL for Anthropic-compatible /v1/messages requests. Lets OpenClicky
    /// point at a compatible provider (e.g. MiniMax) instead of api.anthropic.com.
    /// Falls back to the default on anything that isn't a well-formed absolute
    /// http(s) URL with a host, since callers build request URLs from this with
    /// a force-unwrapped `URL(string:)!` — a malformed value must never reach them.
    static func anthropicBaseURL() -> String {
        let configured = stringValue(
            forKey: "AnthropicBaseURL",
            environmentKeys: ["ANTHROPIC_BASE_URL"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "ANTHROPIC_BASE_URL")

        guard let configured, !configured.isEmpty else { return defaultAnthropicBaseURL }

        var trimmed = configured
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return defaultAnthropicBaseURL
        }

        return trimmed
    }

    static var usesCustomAnthropicBaseURL: Bool {
        anthropicBaseURL() != defaultAnthropicBaseURL
    }

    static func openAIAPIKey() -> String? {
        userDefaultsValue(forKey: userCodexAgentAPIKeyDefaultsKey) ?? stringValue(
            forKey: "OpenAIAPIKey",
            environmentKeys: ["OPENAI_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "OPENAI_API_KEY")
    }

    static func gogKeyringPassword() -> String? {
        stringValue(
            forKey: "GogKeyringPassword",
            environmentKeys: ["GOG_KEYRING_PASSWORD"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "GOG_KEYRING_PASSWORD")
    }

    static func gogAccount() -> String? {
        stringValue(
            forKey: "GogAccount",
            environmentKeys: ["GOG_ACCOUNT"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "GOG_ACCOUNT")
    }

    static func gogClient() -> String? {
        stringValue(
            forKey: "GogClient",
            environmentKeys: ["GOG_CLIENT"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "GOG_CLIENT")
    }

    static func gogExecutablePath() -> String? {
        stringValue(
            forKey: "OpenClickyGogPath",
            environmentKeys: ["OPENCLICKY_GOG_PATH"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "OPENCLICKY_GOG_PATH")
    }

    static func mcpDeveloperDocsEnabled() -> Bool {
        userDefaultsBool(forKey: userMCPDeveloperDocsEnabledDefaultsKey, defaultValue: false)
    }

    static func mcpComposioConnectEnabled() -> Bool {
        userDefaultsBool(forKey: userMCPComposioConnectEnabledDefaultsKey, defaultValue: false)
    }

    static func mcpComputerUseEnabled() -> Bool {
        userDefaultsBool(forKey: userMCPComputerUseEnabledDefaultsKey, defaultValue: false)
    }

    static func mcpCuaDriverCommand() -> String? {
        userDefaultsValue(forKey: userMCPCuaDriverCommandDefaultsKey)
            ?? stringValue(
                forKey: "OpenClickyCuaDriverMCPCommand",
                environmentKeys: [CuaDriverMCPConfiguration.environmentOverrideKey]
            )
            ?? localDevelopmentEnvironmentValue(forKey: CuaDriverMCPConfiguration.environmentOverrideKey)
            ?? CuaDriverMCPConfiguration.resolvedCommandPath()
    }

    static func externalInferenceProxyEnabled() -> Bool {
        userDefaultsBool(forKey: userExternalInferenceProxyEnabledDefaultsKey, defaultValue: false)
            || normalizedConfigurationValue(ProcessInfo.processInfo.environment["OPENCLICKY_EXTERNAL_INFERENCE_PROXY_ENABLED"]) == "1"
            || normalizedConfigurationValue(ProcessInfo.processInfo.environment["OPENCLICKY_EXTERNAL_INFERENCE_PROXY_ENABLED"])?.lowercased() == "true"
    }

    static func visualDrawingOverlayToolsEnabled() -> Bool {
        let environmentValue = normalizedConfigurationValue(ProcessInfo.processInfo.environment["OPENCLICKY_VISUAL_DRAWING_OVERLAY_TOOLS_ENABLED"])
        return userDefaultsBool(forKey: userVisualDrawingOverlayToolsEnabledDefaultsKey, defaultValue: true)
            && environmentValue != "0"
            && environmentValue?.lowercased() != "false"
    }

    static func gmailOAuthToolsEnabled() -> Bool {
        let environmentValue = normalizedConfigurationValue(ProcessInfo.processInfo.environment["OPENCLICKY_GMAIL_OAUTH_TOOLS_ENABLED"])
        return userDefaultsBool(forKey: userGmailOAuthToolsEnabledDefaultsKey, defaultValue: false)
            || environmentValue == "1"
            || environmentValue?.lowercased() == "true"
    }

    static func externalControlBridgeToken() -> String? {
        userDefaultsValue(forKey: userExternalControlBridgeTokenDefaultsKey) ?? stringValue(
            forKey: "OpenClickyExternalControlBridgeToken",
            environmentKeys: ["OPENCLICKY_BRIDGE_TOKEN"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "OPENCLICKY_BRIDGE_TOKEN")
    }

    static func agentPlaintextProviderSyncEnabled() -> Bool {
        userDefaultsBool(forKey: userAgentPlaintextProviderSyncEnabledDefaultsKey, defaultValue: false)
    }

    static func agentCompletionVoiceEnabled() -> Bool {
        userDefaultsBool(forKey: userAgentCompletionVoiceEnabledDefaultsKey, defaultValue: true)
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
        ?? "hpp4J3VqNfWAUOO0d1Us"
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

    /// OpenAI Realtime output voice. Realtime supports the built-in voice
    /// names directly; Settings stores the selected name here.
    static func openAIRealtimeVoiceID() -> String {
        userDefaultsValue(forKey: userOpenAIRealtimeVoiceIDDefaultsKey) ?? stringValue(
            forKey: "OpenAIRealtimeVoiceID",
            environmentKeys: ["OPENAI_REALTIME_VOICE_ID"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "OPENAI_REALTIME_VOICE_ID")
        ?? "cedar"
    }

    /// Selected playback engine — "openai_realtime" (default), "elevenlabs",
    /// "cartesia", "deepgram", or "microsoft_edge".
    static func ttsProviderRaw() -> String {
        userDefaultsValue(forKey: userTTSProviderDefaultsKey) ?? "openai_realtime"
    }

    static func voicePlaybackVolume() -> Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: openClickyVoicePlaybackVolumeDefaultsKey) != nil else {
            return defaultVoicePlaybackVolume
        }
        let volume = defaults.double(forKey: openClickyVoicePlaybackVolumeDefaultsKey)
        guard volume.isFinite else { return defaultVoicePlaybackVolume }
        return min(max(volume, 0.0), 1.0)
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

    /// LLM model Deepgram Voice Agent should use for the think stage.
    static func deepgramVoiceAgentThinkModel() -> String {
        let rawModel = userDefaultsValue(forKey: userDeepgramVoiceAgentThinkModelDefaultsKey) ?? stringValue(
            forKey: "DeepgramVoiceAgentThinkModel",
            environmentKeys: ["DEEPGRAM_VOICE_AGENT_THINK_MODEL"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "DEEPGRAM_VOICE_AGENT_THINK_MODEL")
        ?? "gpt-4o-mini"
        return normalizeDeepgramVoiceAgentThinkModel(rawModel)
    }

    static func normalizeDeepgramVoiceAgentThinkModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "gpt-4o-mini" : trimmed.lowercased()
    }

    /// Microsoft Edge Read Aloud voice identifier. These are the free
    /// Edge online voices, not Azure Speech API keys.
    static func microsoftEdgeVoiceID() -> String {
        userDefaultsValue(forKey: userMicrosoftEdgeVoiceIDDefaultsKey) ?? stringValue(
            forKey: "MicrosoftEdgeVoiceID",
            environmentKeys: ["MICROSOFT_EDGE_VOICE_ID", "EDGE_TTS_VOICE"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "MICROSOFT_EDGE_VOICE_ID")
            ?? localDevelopmentEnvironmentValue(forKey: "EDGE_TTS_VOICE")
        ?? "en-US-EmmaMultilingualNeural"
    }

    private static func userDefaultsBool(forKey key: String, defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }

    private static func userDefaultsValue(forKey key: String) -> String? {
        if keychainBackedDefaultsKeys.contains(key) {
            if let keychainValue = keychainValue(forKey: key) {
                return keychainValue
            }
            if let migrated = normalizedConfigurationValue(UserDefaults.standard.string(forKey: key)) {
                _ = setKeychainValue(migrated, forKey: key)
                UserDefaults.standard.removeObject(forKey: key)
                return migrated
            }
            return nil
        }
        return normalizedConfigurationValue(UserDefaults.standard.string(forKey: key))
    }

    static func persistSecret(_ value: String, defaultsKey: String) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty {
            deleteKeychainValue(forKey: defaultsKey)
        } else {
            _ = setKeychainValue(trimmedValue, forKey: defaultsKey)
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
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

    private static let keychainService = "com.jkneen.openclicky.secrets"

    private static let keychainBackedDefaultsKeys: Set<String> = [
        userAnthropicAPIKeyDefaultsKey,
        userElevenLabsAPIKeyDefaultsKey,
        userCartesiaAPIKeyDefaultsKey,
        userCodexAgentAPIKeyDefaultsKey,
        userAssemblyAIAPIKeyDefaultsKey,
        userDeepgramAPIKeyDefaultsKey,
        userExternalControlBridgeTokenDefaultsKey
    ]

    private static func keychainValue(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return normalizedConfigurationValue(String(data: data, encoding: .utf8))
    }

    @discardableResult
    private static func setKeychainValue(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status != errSecItemNotFound { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteKeychainValue(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
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
