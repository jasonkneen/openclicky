//
//  OpenClickyTTSSettingsCatalog.swift
//  leanring-buddy
//
//  Preset model/voice identifiers for Text-to-speech settings UI. Matches
//  OpenAI Speech API, Gemini speech-generation, Deepgram Aura branding, etc.
//

import Foundation

/// Centralized TTS presets for Settings pickers. Saved custom IDs are merged in via `merged(...)`.
enum OpenClickyTTSSettingsCatalog {

    // MARK: - OpenAI Speech (`/v1/audio/speech`)

    static let openAISpeechVoiceChoices: [(id: String, label: String)] = [
        (id: "alloy", label: "Alloy"),
        (id: "echo", label: "Echo"),
        (id: "fable", label: "Fable"),
        (id: "onyx", label: "Onyx"),
        (id: "nova", label: "Nova"),
        (id: "shimmer", label: "Shimmer"),
    ]

    /// Models supported by the Speech API; some orgs disable legacy `tts-*`.
    static let openAISpeechModelChoices: [(id: String, label: String)] = [
        (id: "gpt-4o-mini-tts", label: "gpt-4o-mini-tts (recommended)"),
        (id: "tts-1", label: "tts-1 (legacy)"),
        (id: "tts-1-hd", label: "tts-1-hd (legacy)"),
    ]

    // MARK: - Gemini speech (`…/models/{id}:generateContent` + audio)

    static let geminiModelChoices: [(id: String, label: String)] = [
        (id: "gemini-2.5-flash-preview-tts", label: "Gemini 2.5 Flash — TTS (preview)"),
        (id: "gemini-3-flash-preview-tts", label: "Gemini 3 Flash — TTS (preview)"),
        (id: "gemini-3.1-flash-preview-tts", label: "Gemini 3.1 Flash — TTS (preview)"),
    ]

    static let geminiVoiceChoices: [(id: String, label: String)] = [
        (id: "Kore", label: "Kore"),
        (id: "Puck", label: "Puck"),
        (id: "Charon", label: "Charon"),
        (id: "Fenrir", label: "Fenrir"),
        (id: "Aoede", label: "Aoede"),
        (id: "Leda", label: "Leda"),
        (id: "Orbit", label: "Orbit"),
        (id: "Sol", label: "Sol"),
    ]

    // MARK: - Deepgram Aura (TTS voice id)

    static let deepgramTTSVoiceChoices: [(id: String, label: String)] = [
        (id: "aura-2-thalia-en", label: "aura-2-thalia-en (Thalia EN)"),
        (id: "aura-2-orion-en", label: "aura-2-orion-en (Orion EN)"),
        (id: "aura-2-luna-en", label: "aura-2-luna-en (Luna EN)"),
        (id: "aura-2-stella-en", label: "aura-2-stella-en (Stella EN)"),
        (id: "aura-2-atlas-en", label: "aura-2-atlas-en (Atlas EN)"),
        (id: "aura-2-helios-en", label: "aura-2-helios-en (Helios EN)"),
    ]

    // MARK: Merge helpers (unknown saved values stay selectable)

    static func mergedOpenAIVoiceRows(saved: String) -> [(id: String, label: String)] {
        merged(saved: saved, into: openAISpeechVoiceChoices)
    }

    static func mergedOpenAIModelRows(saved: String) -> [(id: String, label: String)] {
        merged(saved: saved, into: openAISpeechModelChoices)
    }

    static func mergedGeminiModelRows(saved: String) -> [(id: String, label: String)] {
        merged(saved: saved, into: geminiModelChoices)
    }

    static func mergedGeminiVoiceRows(saved: String) -> [(id: String, label: String)] {
        merged(saved: saved, into: geminiVoiceChoices)
    }

    static func mergedDeepgramTTSVoiceRows(saved: String) -> [(id: String, label: String)] {
        merged(saved: saved, into: deepgramTTSVoiceChoices)
    }

    private static func merged(saved: String, into catalog: [(id: String, label: String)]) -> [(id: String, label: String)] {
        let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return catalog }
        if catalog.contains(where: { $0.id == trimmed }) { return catalog }
        return [(id: trimmed, label: "Current: \(trimmed)")] + catalog
    }
}
