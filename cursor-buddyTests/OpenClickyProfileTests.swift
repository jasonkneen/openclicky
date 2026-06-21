import Foundation
import Testing
@testable import OpenClicky

struct OpenClickyProfileTests {
    private func freshDefaults(_ name: String) -> UserDefaults {
        let suite = "OpenClickyProfileTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func catalogExposesThreeProfiles() {
        let ids = OpenClickyProfileCatalog.all.map(\.id)
        #expect(ids == ["local", "realtime", "quality"])
        #expect(OpenClickyProfileCatalog.defaultProfileID == "local")
    }

    @Test func profileLookupFallsBackToDefaultForUnknownID() {
        #expect(OpenClickyProfileCatalog.profile(withID: "realtime").id == "realtime")
        #expect(OpenClickyProfileCatalog.profile(withID: nil).id == "local")
        #expect(OpenClickyProfileCatalog.profile(withID: "nope").id == "local")
    }

    @Test func applyingLocalProfileWritesExpectedKeys() {
        let defaults = freshDefaults("local")
        OpenClickyProfileCatalog.apply(.init(
            id: OpenClickyProfileCatalog.local.id,
            displayName: OpenClickyProfileCatalog.local.displayName,
            sttProvider: OpenClickyProfileCatalog.local.sttProvider,
            responseModelID: OpenClickyProfileCatalog.local.responseModelID,
            ttsProvider: OpenClickyProfileCatalog.local.ttsProvider,
            activationMode: OpenClickyProfileCatalog.local.activationMode,
            ttsVoiceID: OpenClickyProfileCatalog.local.ttsVoiceID,
            agentModelID: OpenClickyProfileCatalog.local.agentModelID
        ), defaults: defaults)

        #expect(defaults.string(forKey: OpenClickyProfileCatalog.activeProfileDefaultsKey) == "local")
        #expect(defaults.string(forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey) == "parakeet")
        #expect(defaults.string(forKey: OpenClickyProfileCatalog.voiceResponseModelDefaultsKey) == "claude-haiku-4-5")
        #expect(defaults.string(forKey: AppBundleConfiguration.userTTSProviderDefaultsKey) == "microsoft_edge")
        #expect(defaults.string(forKey: AppBundleConfiguration.userVoiceActivationModeDefaultsKey) == "push_to_talk")
    }

    @Test func applyingRealtimeProfileSelectsSpeechToSpeechStack() {
        let defaults = freshDefaults("realtime")
        OpenClickyProfileCatalog.apply(OpenClickyProfileCatalog.realtime, defaults: defaults)

        #expect(defaults.string(forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey) == "openai")
        #expect(defaults.string(forKey: OpenClickyProfileCatalog.voiceResponseModelDefaultsKey) == OpenClickyModelCatalog.defaultSpeechModelID)
        #expect(defaults.string(forKey: AppBundleConfiguration.userTTSProviderDefaultsKey) == "openai_realtime")
    }

    @Test func applyingQualityProfileSelectsCloudStack() {
        let defaults = freshDefaults("quality")
        OpenClickyProfileCatalog.apply(OpenClickyProfileCatalog.quality, defaults: defaults)

        #expect(defaults.string(forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey) == "deepgram")
        #expect(defaults.string(forKey: AppBundleConfiguration.userTTSProviderDefaultsKey) == "elevenlabs")
        #expect(OpenClickyProfileCatalog.activeProfile(defaults: defaults).id == "quality")
    }

    @Test func optionalFieldsDoNotClobberUnrelatedKeysWhenNil() {
        let defaults = freshDefaults("optional")
        defaults.set("existing-codex-model", forKey: "clickyCodexModel")
        defaults.set("existing-eleven-voice", forKey: AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey)

        // Built-in profiles carry nil agentModelID / ttsVoiceID, so applying
        // them must leave those unrelated keys intact.
        OpenClickyProfileCatalog.apply(OpenClickyProfileCatalog.local, defaults: defaults)

        #expect(defaults.string(forKey: "clickyCodexModel") == "existing-codex-model")
        #expect(defaults.string(forKey: AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey) == "existing-eleven-voice")
    }
}
