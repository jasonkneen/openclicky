import Foundation
import Testing
@testable import OpenClicky

@MainActor
struct ClickyAPIKeyStoreTests {

    @Test func everyIdentifierHasNonEmptyDisplayName() throws {
        for identifier in ClickyAPIKeyIdentifier.allCases {
            #expect(!identifier.displayName.isEmpty)
        }
    }

    @Test func everyIdentifierHasReachableHTTPSHelpURL() throws {
        for identifier in ClickyAPIKeyIdentifier.allCases {
            let helpURL = try #require(identifier.helpURL)
            #expect(helpURL.scheme == "https")
            #expect(!(helpURL.host ?? "").isEmpty)
        }
    }

    /// The store relies on `legacyUserDefaultsKey` to copy plaintext
    /// values out of `UserDefaults` into the Keychain on first launch.
    /// Pin each mapping so a future hand-edit on either side surfaces
    /// here instead of silently orphaning a user's pasted key.
    @Test func legacyUserDefaultsKeyPointsAtTheMatchingAppBundleConstant() throws {
        #expect(
            ClickyAPIKeyIdentifier.anthropicAPIKey.legacyUserDefaultsKey
                == AppBundleConfiguration.userAnthropicAPIKeyDefaultsKey
        )
        #expect(
            ClickyAPIKeyIdentifier.openAIAPIKey.legacyUserDefaultsKey
                == AppBundleConfiguration.userCodexAgentAPIKeyDefaultsKey
        )
        #expect(
            ClickyAPIKeyIdentifier.assemblyAIAPIKey.legacyUserDefaultsKey
                == AppBundleConfiguration.userAssemblyAIAPIKeyDefaultsKey
        )
        #expect(
            ClickyAPIKeyIdentifier.deepgramAPIKey.legacyUserDefaultsKey
                == AppBundleConfiguration.userDeepgramAPIKeyDefaultsKey
        )
        #expect(
            ClickyAPIKeyIdentifier.elevenLabsAPIKey.legacyUserDefaultsKey
                == AppBundleConfiguration.userElevenLabsAPIKeyDefaultsKey
        )
        #expect(
            ClickyAPIKeyIdentifier.elevenLabsVoiceID.legacyUserDefaultsKey
                == AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey
        )
        #expect(
            ClickyAPIKeyIdentifier.cartesiaAPIKey.legacyUserDefaultsKey
                == AppBundleConfiguration.userCartesiaAPIKeyDefaultsKey
        )
        #expect(
            ClickyAPIKeyIdentifier.cartesiaVoiceID.legacyUserDefaultsKey
                == AppBundleConfiguration.userCartesiaVoiceIDDefaultsKey
        )
    }

    /// Keychain account names are persisted on disk; renaming an
    /// identifier's raw value would orphan every existing user's pasted
    /// key. Pin the wire format so refactors trip this test before
    /// shipping a silent migration regression.
    @Test func rawIdentifierValuesAreStableAcrossReleases() throws {
        #expect(ClickyAPIKeyIdentifier.anthropicAPIKey.rawValue == "anthropic_api_key")
        #expect(ClickyAPIKeyIdentifier.openAIAPIKey.rawValue == "openai_api_key")
        #expect(ClickyAPIKeyIdentifier.assemblyAIAPIKey.rawValue == "assemblyai_api_key")
        #expect(ClickyAPIKeyIdentifier.deepgramAPIKey.rawValue == "deepgram_api_key")
        #expect(ClickyAPIKeyIdentifier.elevenLabsAPIKey.rawValue == "elevenlabs_api_key")
        #expect(ClickyAPIKeyIdentifier.elevenLabsVoiceID.rawValue == "elevenlabs_voice_id")
        #expect(ClickyAPIKeyIdentifier.cartesiaAPIKey.rawValue == "cartesia_api_key")
        #expect(ClickyAPIKeyIdentifier.cartesiaVoiceID.rawValue == "cartesia_voice_id")
    }

    /// Sanity check that every identifier appears in `allCases` so the
    /// migration loop and tests that fan out over `allCases` can't
    /// silently skip a newly added key.
    @Test func allCasesEnumeratesEveryIdentifier() throws {
        let expectedIdentifierCount = 8
        #expect(ClickyAPIKeyIdentifier.allCases.count == expectedIdentifierCount)

        let uniqueRawValues = Set(ClickyAPIKeyIdentifier.allCases.map { $0.rawValue })
        #expect(uniqueRawValues.count == expectedIdentifierCount)
    }
}
