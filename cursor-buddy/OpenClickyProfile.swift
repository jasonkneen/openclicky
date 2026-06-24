//
//  OpenClickyProfile.swift
//  cursor-buddy
//
//  A settings "profile" is a named bundle that flips the whole voice provider
//  matrix at once (STT + response model + TTS + activation), so users switch
//  between coherent modes instead of hand-tuning a dozen independent toggles.
//
//  Step 1 of design-notes/settings-profiles-spec.md: data model, the three
//  built-in profiles, and atomic apply over the EXISTING UserDefaults keys.
//  No UI yet; nothing in the running app reads `activeProfileID` until the
//  selector is wired in a later step.
//

import Foundation

/// A coherent voice/agent mode. Pure value data — applying it just writes the
/// existing UserDefaults keys that the rest of the app already reads.
nonisolated struct OpenClickyProfile: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    /// `BuddyTranscriptionProviderID` raw value (e.g. "parakeet").
    let sttProvider: String
    /// `OpenClickyModelCatalog` model id used for spoken responses.
    let responseModelID: String
    /// `OpenClickyTTSProvider` raw value (e.g. "elevenlabs").
    let ttsProvider: String
    /// `OpenClickyVoiceActivationMode` raw value (e.g. "push_to_talk").
    let activationMode: String
    /// Optional provider-specific TTS voice. `nil` leaves the user's current
    /// voice for that provider untouched.
    let ttsVoiceID: String?
    /// Optional Agent Mode (Codex) model override. `nil` leaves it untouched.
    let agentModelID: String?
}

/// Built-in profiles + atomic apply. `nonisolated` so it can be exercised from
/// tests and any context; it only touches `UserDefaults`, which is thread-safe.
nonisolated enum OpenClickyProfileCatalog {
    /// UserDefaults key recording the currently-selected profile.
    static let activeProfileDefaultsKey = "openClickyActiveProfileID"
    /// Mirrors the literal key written by `CompanionManager.setSelectedModel`.
    static let voiceResponseModelDefaultsKey = "selectedVoiceResponseModel"

    static let local = OpenClickyProfile(
        id: "local",
        displayName: "Local",
        sttProvider: BuddyTranscriptionProviderID.parakeet.rawValue,
        // Anthropic provider -> Claude Agent SDK first (local Code sign-in,
        // no per-token key) per the money rule. Haiku keeps it fast/cheap.
        responseModelID: "claude-haiku-4-5",
        ttsProvider: OpenClickyTTSProvider.microsoftEdge.rawValue,
        activationMode: OpenClickyVoiceActivationMode.pushToTalk.rawValue,
        ttsVoiceID: nil,
        agentModelID: nil
    )

    static let realtime = OpenClickyProfile(
        id: "realtime",
        displayName: "Realtime",
        sttProvider: BuddyTranscriptionProviderID.openAI.rawValue,
        // Speech-to-speech: owns STT + reasoning + audio in one Realtime turn,
        // avoiding the multi-hop first-audio latency of the text->TTS path.
        responseModelID: OpenClickyModelCatalog.defaultSpeechModelID,
        ttsProvider: OpenClickyTTSProvider.openAIRealtime.rawValue,
        activationMode: OpenClickyVoiceActivationMode.pushToTalk.rawValue,
        ttsVoiceID: nil,
        agentModelID: nil
    )

    static let quality = OpenClickyProfile(
        id: "quality",
        displayName: "Quality",
        sttProvider: BuddyTranscriptionProviderID.deepgram.rawValue,
        responseModelID: OpenClickyModelCatalog.defaultDelegationModelID, // claude-sonnet
        ttsProvider: OpenClickyTTSProvider.elevenLabs.rawValue,
        activationMode: OpenClickyVoiceActivationMode.pushToTalk.rawValue,
        ttsVoiceID: nil,
        agentModelID: nil
    )

    static let all: [OpenClickyProfile] = [local, realtime, quality]

    static let defaultProfileID = local.id

    /// Resolves a profile by id, falling back to the default for unknown ids.
    static func profile(withID id: String?) -> OpenClickyProfile {
        guard let id, let match = all.first(where: { $0.id == id }) else {
            return all.first(where: { $0.id == defaultProfileID }) ?? local
        }
        return match
    }

    /// The currently-selected profile (default if none stored yet).
    static func activeProfile(defaults: UserDefaults = .standard) -> OpenClickyProfile {
        profile(withID: defaults.string(forKey: activeProfileDefaultsKey))
    }

    /// Atomically writes the existing keys the rest of the app already reads.
    /// Optional fields are only written when present, so switching profiles
    /// never clobbers an unrelated provider's voice or the agent model.
    static func apply(_ profile: OpenClickyProfile, defaults: UserDefaults = .standard) {
        defaults.set(profile.id, forKey: activeProfileDefaultsKey)
        defaults.set(profile.sttProvider, forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey)
        defaults.set(profile.responseModelID, forKey: voiceResponseModelDefaultsKey)
        defaults.set(profile.ttsProvider, forKey: AppBundleConfiguration.userTTSProviderDefaultsKey)
        defaults.set(profile.activationMode, forKey: AppBundleConfiguration.userVoiceActivationModeDefaultsKey)

        if let ttsVoiceID = profile.ttsVoiceID {
            defaults.set(ttsVoiceID, forKey: ttsVoiceDefaultsKey(for: profile.ttsProvider))
        }
        if let agentModelID = profile.agentModelID {
            defaults.set(agentModelID, forKey: "clickyCodexModel")
        }
    }

    /// Maps a TTS provider raw value to its provider-specific voice key.
    private static func ttsVoiceDefaultsKey(for ttsProvider: String) -> String {
        switch OpenClickyTTSProvider(rawValue: ttsProvider) {
        case .elevenLabs:
            return AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey
        case .cartesia:
            return AppBundleConfiguration.userCartesiaVoiceIDDefaultsKey
        case .openAIRealtime:
            return AppBundleConfiguration.userOpenAIRealtimeVoiceIDDefaultsKey
        case .microsoftEdge:
            return AppBundleConfiguration.userMicrosoftEdgeVoiceIDDefaultsKey
        case .deepgram:
            return AppBundleConfiguration.userDeepgramTTSVoiceDefaultsKey
        case .kokoro:
            return AppBundleConfiguration.userKokoroVoiceDefaultsKey
        case .none:
            return AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey
        }
    }
}
