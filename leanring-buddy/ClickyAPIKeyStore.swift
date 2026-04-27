//
//  ClickyAPIKeyStore.swift
//  leanring-buddy
//
//  User-provided API keys for Anthropic, OpenAI/Codex, AssemblyAI, Deepgram,
//  ElevenLabs, and Cartesia. Stored in the macOS Keychain so they persist
//  across launches and are never written to disk in plaintext. The app calls
//  each provider's API directly with the user's own key — there is no
//  server-side proxy.
//
//  This store is the canonical source of truth for user-provided keys.
//  `AppBundleConfiguration.*APIKey()` reads from this store first and only
//  falls back to Info.plist / launch environment / `~/.config/openclicky/secrets.env`
//  when the Keychain entry is empty.
//

import Combine
import Foundation
import Security
import SwiftUI

/// A string identifier for each secret the app stores. Each identifier
/// maps 1:1 to a Keychain account name, so renaming one would orphan
/// the previous entry on existing installs.
enum ClickyAPIKeyIdentifier: String, CaseIterable {
    case anthropicAPIKey = "anthropic_api_key"
    case openAIAPIKey = "openai_api_key"
    case assemblyAIAPIKey = "assemblyai_api_key"
    case deepgramAPIKey = "deepgram_api_key"
    case elevenLabsAPIKey = "elevenlabs_api_key"
    case elevenLabsVoiceID = "elevenlabs_voice_id"
    case cartesiaAPIKey = "cartesia_api_key"
    case cartesiaVoiceID = "cartesia_voice_id"

    /// Human-readable label shown in the settings UI.
    var displayName: String {
        switch self {
        case .anthropicAPIKey:
            return "Anthropic API Key"
        case .openAIAPIKey:
            return "OpenAI / Codex API Key"
        case .assemblyAIAPIKey:
            return "AssemblyAI API Key"
        case .deepgramAPIKey:
            return "Deepgram API Key"
        case .elevenLabsAPIKey:
            return "ElevenLabs API Key"
        case .elevenLabsVoiceID:
            return "ElevenLabs Voice ID"
        case .cartesiaAPIKey:
            return "Cartesia API Key"
        case .cartesiaVoiceID:
            return "Cartesia Voice ID"
        }
    }

    /// Where the user can go to obtain this value.
    var helpURL: URL? {
        switch self {
        case .anthropicAPIKey:
            return URL(string: "https://console.anthropic.com/settings/keys")
        case .openAIAPIKey:
            return URL(string: "https://platform.openai.com/api-keys")
        case .assemblyAIAPIKey:
            return URL(string: "https://www.assemblyai.com/app/api-keys")
        case .deepgramAPIKey:
            return URL(string: "https://console.deepgram.com/")
        case .elevenLabsAPIKey:
            return URL(string: "https://elevenlabs.io/app/settings/api-keys")
        case .elevenLabsVoiceID:
            return URL(string: "https://elevenlabs.io/app/voice-library")
        case .cartesiaAPIKey:
            return URL(string: "https://play.cartesia.ai/keys")
        case .cartesiaVoiceID:
            return URL(string: "https://play.cartesia.ai/voices")
        }
    }

    /// The legacy UserDefaults key that the app used before keys moved to
    /// the Keychain. Used once at first launch to migrate plaintext values
    /// out of the prefs plist and into the Keychain.
    var legacyUserDefaultsKey: String {
        switch self {
        case .anthropicAPIKey:
            return AppBundleConfiguration.userAnthropicAPIKeyDefaultsKey
        case .openAIAPIKey:
            return AppBundleConfiguration.userCodexAgentAPIKeyDefaultsKey
        case .assemblyAIAPIKey:
            return AppBundleConfiguration.userAssemblyAIAPIKeyDefaultsKey
        case .deepgramAPIKey:
            return AppBundleConfiguration.userDeepgramAPIKeyDefaultsKey
        case .elevenLabsAPIKey:
            return AppBundleConfiguration.userElevenLabsAPIKeyDefaultsKey
        case .elevenLabsVoiceID:
            return AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey
        case .cartesiaAPIKey:
            return AppBundleConfiguration.userCartesiaAPIKeyDefaultsKey
        case .cartesiaVoiceID:
            return AppBundleConfiguration.userCartesiaVoiceIDDefaultsKey
        }
    }
}

/// Observable store for user-provided API keys. Reads once on init and
/// writes through to the Keychain on every change so the next launch
/// sees the same values.
@MainActor
final class ClickyAPIKeyStore: ObservableObject {
    /// Shared singleton — API clients and the settings UI both reach for
    /// the same instance so updates in the UI propagate to live clients.
    static let shared = ClickyAPIKeyStore()

    /// The Keychain service string used for every entry the app stores.
    /// Distinct from upstream Clicky's `so.clicky.apikeys` so a user with
    /// both apps installed doesn't share keys across them.
    private nonisolated static let keychainServiceName = "com.jkneen.openclicky.apikeys"

    /// UserDefaults flag that records whether the one-shot migration from
    /// plaintext UserDefaults values into the Keychain has run. Stored
    /// under a stable key so re-runs of the migration are skipped.
    private nonisolated static let userDefaultsMigrationCompletedKey = "openClickyAPIKeyKeychainMigrationCompleted"

    @Published private(set) var anthropicAPIKey: String = ""
    @Published private(set) var openAIAPIKey: String = ""
    @Published private(set) var assemblyAIAPIKey: String = ""
    @Published private(set) var deepgramAPIKey: String = ""
    @Published private(set) var elevenLabsAPIKey: String = ""
    @Published private(set) var elevenLabsVoiceID: String = ""
    @Published private(set) var cartesiaAPIKey: String = ""
    @Published private(set) var cartesiaVoiceID: String = ""

    private init() {
        Self.migrateLegacyUserDefaultsKeysIfNeeded()

        self.anthropicAPIKey = Self.readFromKeychain(.anthropicAPIKey) ?? ""
        self.openAIAPIKey = Self.readFromKeychain(.openAIAPIKey) ?? ""
        self.assemblyAIAPIKey = Self.readFromKeychain(.assemblyAIAPIKey) ?? ""
        self.deepgramAPIKey = Self.readFromKeychain(.deepgramAPIKey) ?? ""
        self.elevenLabsAPIKey = Self.readFromKeychain(.elevenLabsAPIKey) ?? ""
        self.elevenLabsVoiceID = Self.readFromKeychain(.elevenLabsVoiceID) ?? ""
        self.cartesiaAPIKey = Self.readFromKeychain(.cartesiaAPIKey) ?? ""
        self.cartesiaVoiceID = Self.readFromKeychain(.cartesiaVoiceID) ?? ""
    }

    // MARK: - Public API

    /// Returns true when the minimum viable key (Anthropic) is present.
    /// Claude is the only key the app truly cannot operate without —
    /// every other key is an optional upgrade or has a fallback path.
    var hasAnthropicAPIKey: Bool {
        !anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasOpenAIAPIKey: Bool {
        !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasAssemblyAIAPIKey: Bool {
        !assemblyAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasDeepgramAPIKey: Bool {
        !deepgramAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasElevenLabsAPIKey: Bool {
        !elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCartesiaAPIKey: Bool {
        !cartesiaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns the current value (trimmed of whitespace) for `identifier`,
    /// or `nil` if it is unset. API clients should call this right before
    /// making a request so they always see the latest user-provided value.
    func value(for identifier: ClickyAPIKeyIdentifier) -> String? {
        let rawValue: String
        switch identifier {
        case .anthropicAPIKey:
            rawValue = anthropicAPIKey
        case .openAIAPIKey:
            rawValue = openAIAPIKey
        case .assemblyAIAPIKey:
            rawValue = assemblyAIAPIKey
        case .deepgramAPIKey:
            rawValue = deepgramAPIKey
        case .elevenLabsAPIKey:
            rawValue = elevenLabsAPIKey
        case .elevenLabsVoiceID:
            rawValue = elevenLabsVoiceID
        case .cartesiaAPIKey:
            rawValue = cartesiaAPIKey
        case .cartesiaVoiceID:
            rawValue = cartesiaVoiceID
        }
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    /// Persist a new value for `identifier`. Passing an empty string
    /// clears the entry from the Keychain entirely so the next launch
    /// sees an unset value rather than an empty string.
    func setValue(_ newValue: String, for identifier: ClickyAPIKeyIdentifier) {
        let trimmedNewValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

        switch identifier {
        case .anthropicAPIKey:
            anthropicAPIKey = trimmedNewValue
        case .openAIAPIKey:
            openAIAPIKey = trimmedNewValue
        case .assemblyAIAPIKey:
            assemblyAIAPIKey = trimmedNewValue
        case .deepgramAPIKey:
            deepgramAPIKey = trimmedNewValue
        case .elevenLabsAPIKey:
            elevenLabsAPIKey = trimmedNewValue
        case .elevenLabsVoiceID:
            elevenLabsVoiceID = trimmedNewValue
        case .cartesiaAPIKey:
            cartesiaAPIKey = trimmedNewValue
        case .cartesiaVoiceID:
            cartesiaVoiceID = trimmedNewValue
        }

        if trimmedNewValue.isEmpty {
            Self.deleteFromKeychain(identifier)
        } else {
            Self.writeToKeychain(trimmedNewValue, for: identifier)
        }
    }

    // MARK: - Migration

    /// One-shot migration that copies any pre-existing UserDefaults values
    /// into the Keychain on first launch and then removes the UserDefaults
    /// entries so plaintext keys aren't left sitting in the prefs plist.
    /// Idempotent — guarded by a UserDefaults flag so subsequent launches
    /// are no-ops.
    private nonisolated static func migrateLegacyUserDefaultsKeysIfNeeded() {
        let userDefaults = UserDefaults.standard
        if userDefaults.bool(forKey: userDefaultsMigrationCompletedKey) {
            return
        }

        for identifier in ClickyAPIKeyIdentifier.allCases {
            let legacyValue = userDefaults.string(forKey: identifier.legacyUserDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let legacyValue, !legacyValue.isEmpty else { continue }

            // Only write to the Keychain if we don't already have a value
            // there — a previous partial migration or manual Keychain entry
            // wins over a stale UserDefaults copy.
            if readFromKeychain(identifier) == nil {
                writeToKeychain(legacyValue, for: identifier)
            }

            userDefaults.removeObject(forKey: identifier.legacyUserDefaultsKey)
        }

        userDefaults.set(true, forKey: userDefaultsMigrationCompletedKey)
    }

    // MARK: - Keychain

    /// Builds the query dictionary shared between read, write, and delete
    /// operations. `kSecClassGenericPassword` is the right class for
    /// opaque API tokens — they're not tied to a server or protocol.
    private nonisolated static func baseKeychainQuery(for identifier: ClickyAPIKeyIdentifier) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: identifier.rawValue
        ]
    }

    private nonisolated static func readFromKeychain(_ identifier: ClickyAPIKeyIdentifier) -> String? {
        var query = baseKeychainQuery(for: identifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var resultRef: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &resultRef)

        guard status == errSecSuccess,
              let data = resultRef as? Data,
              let storedValue = String(data: data, encoding: .utf8) else {
            return nil
        }

        return storedValue
    }

    private nonisolated static func writeToKeychain(_ value: String, for identifier: ClickyAPIKeyIdentifier) {
        guard let valueData = value.data(using: .utf8) else { return }

        // Try update first; if no existing entry, fall through to add.
        let updateQuery = baseKeychainQuery(for: identifier)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: valueData
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }

        // No existing entry — create one. kSecAttrAccessibleAfterFirstUnlock
        // is the right accessibility for background menu bar apps that
        // may be relaunched on login before the user unlocks again.
        var addQuery = baseKeychainQuery(for: identifier)
        addQuery[kSecValueData as String] = valueData
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        _ = SecItemAdd(addQuery as CFDictionary, nil)
    }

    private nonisolated static func deleteFromKeychain(_ identifier: ClickyAPIKeyIdentifier) {
        let query = baseKeychainQuery(for: identifier)
        _ = SecItemDelete(query as CFDictionary)
    }

    /// Synchronous Keychain read used by `AppBundleConfiguration` from
    /// non-`@MainActor` contexts. Bypasses the published cache because the
    /// callers are usually background API clients. Returns nil for unset
    /// entries.
    nonisolated static func keychainValue(for identifier: ClickyAPIKeyIdentifier) -> String? {
        let trimmedValue = readFromKeychain(identifier)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedValue, !trimmedValue.isEmpty else { return nil }
        return trimmedValue
    }
}
