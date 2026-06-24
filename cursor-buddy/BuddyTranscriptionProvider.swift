//
//  BuddyTranscriptionProvider.swift
//  cursor-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

enum BuddyTranscriptionProviderID: String, CaseIterable, Identifiable {
    case automatic = "automatic"
    case parakeet = "parakeet"
    case appleSpeech = "apple"
    case assemblyAI = "assemblyai"
    case deepgram = "deepgram"
    case openAI = "openai"
    case cloudflareGateway = "cloudflare_gateway"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .parakeet:
            return "Parakeet"
        case .appleSpeech:
            return "Apple Speech"
        case .assemblyAI:
            return "AssemblyAI"
        case .deepgram:
            return "Deepgram"
        case .openAI:
            return "Whisper"
        case .cloudflareGateway:
            return "Cloudflare"
        }
    }

    var subtitle: String {
        switch self {
        case .automatic:
            return "Best configured"
        case .parakeet:
            return "Local Parakeet"
        case .appleSpeech:
            return "On-device Apple"
        case .assemblyAI:
            return "Streaming"
        case .deepgram:
            return "Streaming"
        case .openAI:
            return "OpenAI listening"
        case .cloudflareGateway:
            return "AI Gateway"
        }
    }
}

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var shouldStartAudioCaptureBeforeProviderReady: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

extension BuddyTranscriptionProvider {
    var shouldStartAudioCaptureBeforeProviderReady: Bool { true }
}

enum BuddyTranscriptionProviderFactory {
    struct ProviderSelection {
        let requestedProviderID: BuddyTranscriptionProviderID
        let displayedProviderID: BuddyTranscriptionProviderID
        let provider: any BuddyTranscriptionProvider
    }

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let selection = resolveProviderSelection(preferredProvider: selectedProviderID())
        print("Transcription: using \(selection.provider.displayName)")
        return selection.provider
    }

    static func makeProvider(preferredProviderID: String) -> any BuddyTranscriptionProvider {
        let selection = resolveProviderSelection(
            preferredProvider: BuddyTranscriptionProviderID(rawValue: preferredProviderID)
        )
        print("Transcription: using \(selection.provider.displayName)")
        return selection.provider
    }

    static func currentProviderSelection() -> ProviderSelection {
        resolveProviderSelection(preferredProvider: selectedProviderID())
    }

    static func providerSelection(preferredProviderID: String) -> ProviderSelection {
        resolveProviderSelection(
            preferredProvider: BuddyTranscriptionProviderID(rawValue: preferredProviderID)
        )
    }

    static func providerIDsForSelectionGrid() -> [BuddyTranscriptionProviderID] {
        BuddyTranscriptionProviderID.allCases.filter { providerID in
            switch providerID {
            case .parakeet:
                return FreeSpeechParakeetTranscriptionProvider().isConfigured || OpenClickyParakeetTranscriptionProvider().isConfigured
            default:
                return true
            }
        }
    }

    static func selectedProviderID() -> BuddyTranscriptionProviderID {
        let rawValue = UserDefaults.standard.string(forKey: AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey)
            ?? AppBundleConfiguration.stringValue(forKey: "VoiceTranscriptionProvider")
            ?? (FreeSpeechParakeetTranscriptionProvider.isLocallyAvailable || OpenClickyParakeetTranscriptionProvider().isConfigured
                ? BuddyTranscriptionProviderID.parakeet.rawValue
                : BuddyTranscriptionProviderID.automatic.rawValue)
        return BuddyTranscriptionProviderID(rawValue: rawValue.lowercased()) ?? .automatic
    }

    private static func resolveProviderSelection(preferredProvider: BuddyTranscriptionProviderID? = nil) -> ProviderSelection {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        let resolvedPreferredProvider = preferredProvider ?? preferredProviderRawValue.flatMap(BuddyTranscriptionProviderID.init(rawValue:))

        let parakeetProvider = resolvedParakeetProvider()
        let assemblyAIProvider = AssemblyAIStreamingTranscriptionProvider()
        let deepgramProvider = DeepgramStreamingTranscriptionProvider()
        let openAIProvider = OpenAIAudioTranscriptionProvider()
        let cloudflareProvider = CloudflareAIGatewayTranscriptionProvider()

        if resolvedPreferredProvider == .appleSpeech {
            return ProviderSelection(
                requestedProviderID: .appleSpeech,
                displayedProviderID: .appleSpeech,
                provider: AppleSpeechTranscriptionProvider()
            )
        }

        if resolvedPreferredProvider == .parakeet {
            if parakeetProvider.isConfigured {
                return ProviderSelection(
                    requestedProviderID: .parakeet,
                    displayedProviderID: .parakeet,
                    provider: parakeetProvider
                )
            }

            print("Transcription: Parakeet preferred but not available, falling back")
            let fallback = configuredFallback(
                excluding: .parakeet,
                parakeetProvider: parakeetProvider,
                assemblyAIProvider: assemblyAIProvider,
                deepgramProvider: deepgramProvider,
                openAIProvider: openAIProvider,
                cloudflareProvider: cloudflareProvider
            )
            return ProviderSelection(
                requestedProviderID: .parakeet,
                displayedProviderID: fallback.0,
                provider: fallback.1
            )
        }

        if resolvedPreferredProvider == .assemblyAI {
            if assemblyAIProvider.isConfigured {
                return ProviderSelection(
                    requestedProviderID: .assemblyAI,
                    displayedProviderID: .assemblyAI,
                    provider: assemblyAIProvider
                )
            }

            print("Transcription: AssemblyAI preferred but not configured, falling back")
            let fallback = configuredFallback(
                excluding: .assemblyAI,
                parakeetProvider: parakeetProvider,
                assemblyAIProvider: assemblyAIProvider,
                deepgramProvider: deepgramProvider,
                openAIProvider: openAIProvider,
                cloudflareProvider: cloudflareProvider
            )
            return ProviderSelection(
                requestedProviderID: .assemblyAI,
                displayedProviderID: fallback.0,
                provider: fallback.1
            )
        }

        if resolvedPreferredProvider == .deepgram {
            if deepgramProvider.isConfigured {
                return ProviderSelection(
                    requestedProviderID: .deepgram,
                    displayedProviderID: .deepgram,
                    provider: deepgramProvider
                )
            }

            print("Transcription: Deepgram preferred but not configured, falling back")
            let fallback = configuredFallback(
                excluding: .deepgram,
                parakeetProvider: parakeetProvider,
                assemblyAIProvider: assemblyAIProvider,
                deepgramProvider: deepgramProvider,
                openAIProvider: openAIProvider,
                cloudflareProvider: cloudflareProvider
            )
            return ProviderSelection(
                requestedProviderID: .deepgram,
                displayedProviderID: fallback.0,
                provider: fallback.1
            )
        }

        if resolvedPreferredProvider == .openAI {
            if openAIProvider.isConfigured {
                return ProviderSelection(
                    requestedProviderID: .openAI,
                    displayedProviderID: .openAI,
                    provider: openAIProvider
                )
            }

            print("Transcription: OpenAI preferred but not configured, falling back")
            let fallback = configuredFallback(
                excluding: .openAI,
                parakeetProvider: parakeetProvider,
                assemblyAIProvider: assemblyAIProvider,
                deepgramProvider: deepgramProvider,
                openAIProvider: openAIProvider,
                cloudflareProvider: cloudflareProvider
            )
            return ProviderSelection(
                requestedProviderID: .openAI,
                displayedProviderID: fallback.0,
                provider: fallback.1
            )
        }

        if resolvedPreferredProvider == .cloudflareGateway {
            if cloudflareProvider.isConfigured {
                return ProviderSelection(
                    requestedProviderID: .cloudflareGateway,
                    displayedProviderID: .cloudflareGateway,
                    provider: cloudflareProvider
                )
            }

            print("Transcription: Cloudflare Gateway preferred but not configured, falling back")
            let fallback = configuredFallback(
                excluding: .cloudflareGateway,
                parakeetProvider: parakeetProvider,
                assemblyAIProvider: assemblyAIProvider,
                deepgramProvider: deepgramProvider,
                openAIProvider: openAIProvider,
                cloudflareProvider: cloudflareProvider
            )
            return ProviderSelection(
                requestedProviderID: .cloudflareGateway,
                displayedProviderID: fallback.0,
                provider: fallback.1
            )
        }

        let fallback = configuredFallback(
            excluding: nil,
            parakeetProvider: parakeetProvider,
            assemblyAIProvider: assemblyAIProvider,
            deepgramProvider: deepgramProvider,
            openAIProvider: openAIProvider,
            cloudflareProvider: cloudflareProvider
        )
        return ProviderSelection(
            requestedProviderID: .automatic,
            displayedProviderID: fallback.0,
            provider: fallback.1
        )
    }

    private static func resolvedParakeetProvider() -> any BuddyTranscriptionProvider {
        let freeSpeechProvider = FreeSpeechParakeetTranscriptionProvider()
        if freeSpeechProvider.isConfigured {
            return freeSpeechProvider
        }
        return OpenClickyParakeetTranscriptionProvider()
    }

    private static func configuredFallback(
        excluding excludedProvider: BuddyTranscriptionProviderID?,
        parakeetProvider: any BuddyTranscriptionProvider,
        assemblyAIProvider: AssemblyAIStreamingTranscriptionProvider,
        deepgramProvider: DeepgramStreamingTranscriptionProvider,
        openAIProvider: OpenAIAudioTranscriptionProvider,
        cloudflareProvider: CloudflareAIGatewayTranscriptionProvider
    ) -> (BuddyTranscriptionProviderID, any BuddyTranscriptionProvider) {
        if excludedProvider != .parakeet, parakeetProvider.isConfigured {
            print("Transcription: using Parakeet as fallback")
            return (.parakeet, parakeetProvider)
        }

        if excludedProvider != .cloudflareGateway, cloudflareProvider.isConfigured {
            print("Transcription: using Cloudflare Gateway as fallback")
            return (.cloudflareGateway, cloudflareProvider)
        }

        if excludedProvider != .assemblyAI, assemblyAIProvider.isConfigured {
            print("Transcription: using AssemblyAI as fallback")
            return (.assemblyAI, assemblyAIProvider)
        }

        if excludedProvider != .deepgram, deepgramProvider.isConfigured {
            print("Transcription: using Deepgram as fallback")
            return (.deepgram, deepgramProvider)
        }

        if excludedProvider != .openAI, openAIProvider.isConfigured {
            print("Transcription: using OpenAI as fallback")
            return (.openAI, openAIProvider)
        }

        print("Transcription: using Apple Speech as fallback")
        return (.appleSpeech, AppleSpeechTranscriptionProvider())
    }
}
