//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

enum BuddyTranscriptionProviderID: String, CaseIterable, Identifiable {
    case automatic = "automatic"
    case appleSpeech = "apple"
    case assemblyAI = "assemblyai"
    case deepgram = "deepgram"
    case openAI = "openai"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .appleSpeech:
            return "Apple"
        case .assemblyAI:
            return "AssemblyAI"
        case .deepgram:
            return "Deepgram"
        case .openAI:
            return "OpenAI"
        }
    }

    var subtitle: String {
        switch self {
        case .automatic:
            return "Best configured"
        case .appleSpeech:
            return "Local"
        case .assemblyAI:
            return "Streaming"
        case .deepgram:
            return "Streaming"
        case .openAI:
            return "Upload"
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
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    static func makeProvider(preferredProviderID: String) -> any BuddyTranscriptionProvider {
        let preferredProvider = BuddyTranscriptionProviderID(rawValue: preferredProviderID)
        let provider = resolveProvider(preferredProvider: preferredProvider)
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    static func selectedProviderID() -> BuddyTranscriptionProviderID {
        let rawValue = AppBundleConfiguration.voiceTranscriptionProviderRaw()
            ?? BuddyTranscriptionProviderID.automatic.rawValue
        return BuddyTranscriptionProviderID(rawValue: rawValue.lowercased()) ?? .automatic
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        resolveProvider(preferredProvider: selectedProviderID())
    }

    private static func resolveProvider(preferredProvider: BuddyTranscriptionProviderID?) -> any BuddyTranscriptionProvider {
        let preferredProviderRawValue = AppBundleConfiguration.voiceTranscriptionProviderRaw()?.lowercased()
        let resolvedPreferredProvider = preferredProvider ?? preferredProviderRawValue.flatMap(BuddyTranscriptionProviderID.init(rawValue:))

        let assemblyAIProvider = AssemblyAIStreamingTranscriptionProvider()
        let deepgramProvider = DeepgramStreamingTranscriptionProvider()
        let openAIProvider = OpenAIAudioTranscriptionProvider()

        if resolvedPreferredProvider == .appleSpeech {
            return AppleSpeechTranscriptionProvider()
        }

        if resolvedPreferredProvider == .assemblyAI {
            if assemblyAIProvider.isConfigured {
                return assemblyAIProvider
            }

            print("⚠️ Transcription: AssemblyAI preferred but not configured, falling back")
            return configuredFallback(
                excluding: .assemblyAI,
                assemblyAIProvider: assemblyAIProvider,
                deepgramProvider: deepgramProvider,
                openAIProvider: openAIProvider
            )
        }

        if resolvedPreferredProvider == .deepgram {
            if deepgramProvider.isConfigured {
                return deepgramProvider
            }

            print("⚠️ Transcription: Deepgram preferred but not configured, falling back")
            return configuredFallback(
                excluding: .deepgram,
                assemblyAIProvider: assemblyAIProvider,
                deepgramProvider: deepgramProvider,
                openAIProvider: openAIProvider
            )
        }

        if resolvedPreferredProvider == .openAI {
            if openAIProvider.isConfigured {
                return openAIProvider
            }

            print("⚠️ Transcription: OpenAI preferred but not configured, falling back")
            return configuredFallback(
                excluding: .openAI,
                assemblyAIProvider: assemblyAIProvider,
                deepgramProvider: deepgramProvider,
                openAIProvider: openAIProvider
            )
        }

        return configuredFallback(
            excluding: nil,
            assemblyAIProvider: assemblyAIProvider,
            deepgramProvider: deepgramProvider,
            openAIProvider: openAIProvider
        )
    }

    private static func configuredFallback(
        excluding excludedProvider: BuddyTranscriptionProviderID?,
        assemblyAIProvider: AssemblyAIStreamingTranscriptionProvider,
        deepgramProvider: DeepgramStreamingTranscriptionProvider,
        openAIProvider: OpenAIAudioTranscriptionProvider
    ) -> any BuddyTranscriptionProvider {
        if excludedProvider != .assemblyAI, assemblyAIProvider.isConfigured {
            print("⚠️ Transcription: using AssemblyAI as fallback")
            return assemblyAIProvider
        }

        if excludedProvider != .deepgram, deepgramProvider.isConfigured {
            print("⚠️ Transcription: using Deepgram as fallback")
            return deepgramProvider
        }

        if excludedProvider != .openAI, openAIProvider.isConfigured {
            print("⚠️ Transcription: using OpenAI as fallback")
            return openAIProvider
        }

        print("⚠️ Transcription: using Apple Speech as fallback")
        return AppleSpeechTranscriptionProvider()
    }
}
