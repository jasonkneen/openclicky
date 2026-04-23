//
//  AppBundleConfiguration.swift
//  leanring-buddy
//
//  Shared helper for reading runtime configuration from the built app bundle.
//

import Foundation

enum AppBundleConfiguration {
    static let userAnthropicAPIKeyDefaultsKey = "openClickyAnthropicAPIKey"
    static let userElevenLabsAPIKeyDefaultsKey = "openClickyElevenLabsAPIKey"
    static let userElevenLabsVoiceIDDefaultsKey = "openClickyElevenLabsVoiceID"
    static let userCodexAgentAPIKeyDefaultsKey = "openClickyCodexAgentAPIKey"

    static func postHogAPIKey() -> String? {
        stringValue(
            forKey: "PostHogAPIKey",
            environmentKeys: ["POSTHOG_API_KEY"]
        ) ?? localDevelopmentEnvironmentValue(forKey: "POSTHOG_API_KEY")
    }

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
    func trimmingMatchingQuotes() -> String {
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
