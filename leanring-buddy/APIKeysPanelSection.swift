//
//  APIKeysPanelSection.swift
//  leanring-buddy
//
//  Lets the user paste their own API keys directly into the menu bar
//  panel without opening the full Settings window. Keys live in the
//  Keychain via `ClickyAPIKeyStore`. The full Settings window still
//  exposes every override (TTS provider, Cartesia, Deepgram TTS voice,
//  etc.); this section surfaces the most common keys so first-run is
//  inline.
//

import AppKit
import SwiftUI

struct APIKeysPanelSection: View {
    @ObservedObject var apiKeyStore: ClickyAPIKeyStore
    /// Companion manager is the source of truth for setter side effects
    /// (re-arming the active TTS / transcription clients with the new
    /// key). Bindings call into it instead of writing the store directly
    /// so a key change picks up the live providers immediately.
    @ObservedObject var companionManager: CompanionManager

    /// Controls whether the section is expanded. Collapsed by default
    /// once the minimum required key is present so the panel stays
    /// compact for the everyday "chat" state.
    @State private var isExpanded: Bool

    init(apiKeyStore: ClickyAPIKeyStore, companionManager: CompanionManager) {
        self.apiKeyStore = apiKeyStore
        self.companionManager = companionManager
        // Auto-expand on first launch when no Anthropic key is present —
        // the user needs to see the fields to get started.
        _isExpanded = State(initialValue: !apiKeyStore.hasAnthropicAPIKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if isExpanded {
                keyFieldsStack
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Header (tap to expand/collapse)

    private var header: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 6) {
                Text("API KEYS")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)

                statusBadge

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    /// Shows "Required" / "Ready" so users can tell at a glance whether
    /// they still need to paste a key without expanding the section.
    @ViewBuilder
    private var statusBadge: some View {
        if apiKeyStore.hasAnthropicAPIKey {
            HStack(spacing: 3) {
                Circle()
                    .fill(DS.Colors.success)
                    .frame(width: 5, height: 5)
                Text("Ready")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.success)
            }
        } else {
            HStack(spacing: 3) {
                Circle()
                    .fill(DS.Colors.warning)
                    .frame(width: 5, height: 5)
                Text("Required")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.warning)
            }
        }
    }

    // MARK: - Key Fields

    private var keyFieldsStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            APIKeyField(
                identifier: .anthropicAPIKey,
                subtitle: "Required — Claude voice responses and Computer Use pointing.",
                placeholder: "sk-ant-...",
                apiKeyStore: apiKeyStore,
                onSet: { companionManager.setAnthropicAPIKey($0) }
            )

            APIKeyField(
                identifier: .openAIAPIKey,
                subtitle: "Optional — Codex / Agent Mode. Local Codex sign-in is used when empty.",
                placeholder: "sk-...",
                apiKeyStore: apiKeyStore,
                onSet: { companionManager.setCodexAgentAPIKey($0) }
            )

            APIKeyField(
                identifier: .assemblyAIAPIKey,
                subtitle: "Optional — AssemblyAI streaming transcription.",
                placeholder: "AssemblyAI key",
                apiKeyStore: apiKeyStore,
                onSet: { companionManager.setAssemblyAIAPIKey($0) }
            )

            APIKeyField(
                identifier: .deepgramAPIKey,
                subtitle: "Optional — Deepgram streaming transcription. Falls back to Apple Speech if empty.",
                placeholder: "Deepgram key",
                apiKeyStore: apiKeyStore,
                onSet: { companionManager.setDeepgramAPIKey($0) }
            )

            APIKeyField(
                identifier: .elevenLabsAPIKey,
                subtitle: "Optional — voice replies. Text still streams when empty.",
                placeholder: "ElevenLabs key",
                apiKeyStore: apiKeyStore,
                onSet: { companionManager.setElevenLabsAPIKey($0) }
            )

            APIKeyField(
                identifier: .elevenLabsVoiceID,
                subtitle: "Voice ID from your ElevenLabs library. Only used when ElevenLabs voice replies are on.",
                placeholder: "e.g. 21m00Tcm4TlvDq8ikWAM",
                apiKeyStore: apiKeyStore,
                onSet: { companionManager.setElevenLabsVoiceID($0) },
                isSecure: false
            )

            Text("Keys live in your macOS Keychain. Nothing is sent anywhere except the provider you pasted the key for. Cartesia and Deepgram TTS voice live in Settings.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }
}

/// A single labeled field for entering one API key / voice ID. Supports
/// both secure (masked) and plain text modes so the voice ID can be
/// visible while actual secrets stay masked.
private struct APIKeyField: View {
    let identifier: ClickyAPIKeyIdentifier
    let subtitle: String
    let placeholder: String
    @ObservedObject var apiKeyStore: ClickyAPIKeyStore
    /// Side-effecting setter on the companion manager — re-arms live
    /// API clients after the new value is persisted.
    let onSet: (String) -> Void
    var isSecure: Bool = true

    /// Local editing state — only pushed to the key store on commit so
    /// every keystroke doesn't write to the Keychain. Initialized lazily
    /// from the published store value the first time the field appears.
    @State private var inputValue: String = ""
    @State private var hasLoadedInitialValue: Bool = false
    @State private var isRevealed: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(identifier.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                if let helpURL = identifier.helpURL {
                    Button(action: {
                        NSWorkspace.shared.open(helpURL)
                    }) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Open \(identifier.displayName) settings")
                }

                Spacer()

                // Allow users to toggle visibility on secure fields so
                // they can confirm what they pasted.
                if isSecure {
                    Button(action: {
                        isRevealed.toggle()
                    }) {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(isRevealed ? "Hide" : "Reveal")
                }
            }

            inputField

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            if !hasLoadedInitialValue {
                inputValue = apiKeyStore.value(for: identifier) ?? ""
                hasLoadedInitialValue = true
            }
        }
    }

    @ViewBuilder
    private var inputField: some View {
        Group {
            if isSecure && !isRevealed {
                SecureField(placeholder, text: $inputValue, onCommit: commitChange)
            } else {
                TextField(placeholder, text: $inputValue, onCommit: commitChange)
            }
        }
        .focused($isFocused)
        .textFieldStyle(.plain)
        .font(.system(size: 12, design: .monospaced))
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        // Persist on focus loss so paste-and-tab still saves without
        // writing to the Keychain on every keystroke.
        .onChange(of: isFocused) { wasFocused, nowFocused in
            if wasFocused && !nowFocused {
                commitChange()
            }
        }
    }

    private func commitChange() {
        onSet(inputValue)
    }
}
