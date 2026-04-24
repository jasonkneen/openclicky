import AppKit
import SwiftUI

struct CodexAgentModePanelSection: View {
    @ObservedObject var session: CodexAgentSession
    var knowledgeIndex: WikiManager.Index
    var responseCard: ClickyResponseCard?
    var transcriptionProviderDisplayName: String
    var transcriptionProviderID: String
    var setVoiceTranscriptionProvider: (String) -> Void
    var isClickyCursorEnabled: Bool
    var setClickyCursorEnabled: (Bool) -> Void
    var isTutorModeEnabled: Bool
    var setTutorModeEnabled: (Bool) -> Void
    var selectedCompanionModelID: String
    var setSelectedCompanionModel: (String) -> Void
    var selectedComputerUseModelID: String
    var setSelectedComputerUseModel: (String) -> Void
    var submitAgentPrompt: (String) -> Void
    var setAnthropicAPIKey: (String) -> Void
    var setElevenLabsAPIKey: (String) -> Void
    var setElevenLabsVoiceID: (String) -> Void
    var setAssemblyAIAPIKey: (String) -> Void
    var setDeepgramAPIKey: (String) -> Void
    var setCodexAgentAPIKey: (String) -> Void
    var replayOnboarding: () -> Void
    var quitClicky: () -> Void
    var openHUD: () -> Void
    var openMemory: () -> Void
    var dismissResponseCard: () -> Void
    var runSuggestedNextAction: (String) -> Void
    var prepareVoiceFollowUp: () -> Void
    var openFeedback: () -> Void
    var showSettings: () -> Void
    @State private var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.55), radius: 4)

                Text("Ask Agent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Text(session.status.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Text(summaryText)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Ask OpenClicky to do something...", text: $prompt, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
                .onSubmit(runPrompt)

            if let error = visibleInlineErrorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.destructiveText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if shouldShowInlineAgentResponse {
                inlineAgentResponse
            }

            HStack(spacing: 8) {
                Button(action: openHUD) {
                    Label("Dashboard", systemImage: "rectangle.grid.2x2")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .foregroundColor(DS.Colors.textSecondary)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )

                Button(action: runPrompt) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 42, height: 30)
                }
                .buttonStyle(.plain)
                .pointerCursor(isEnabled: canRun)
                .foregroundColor(DS.Colors.textOnAccent)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(canRun ? DS.Colors.accent : DS.Colors.accent.opacity(0.35))
                )
                .disabled(!canRun)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private var canRun: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowInlineAgentResponse: Bool {
        inlineAgentResponseText != nil || session.status == .starting || session.status == .running
    }

    private var inlineAgentResponseText: String? {
        session.entries.last(where: { entry in
            switch entry.role {
            case .assistant, .plan, .command, .system:
                return !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .user:
                return false
            }
        })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var inlineAgentResponse: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(inlineAgentResponseLabel)
                .font(.system(size: 9, weight: .heavy))
                .foregroundColor(DS.Colors.textTertiary)
                .kerning(0.45)

            Text(inlineAgentResponseText ?? inlineAgentPlaceholder)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 0.5)
        )
    }

    private var inlineAgentResponseLabel: String {
        switch session.status {
        case .starting:
            return "STARTING"
        case .running:
            return "WORKING"
        case .failed:
            return "NEEDS ATTENTION"
        case .ready:
            return "AGENT"
        case .stopped:
            return "OFFLINE"
        }
    }

    private var inlineAgentPlaceholder: String {
        switch session.status {
        case .starting:
            return "Starting the agent..."
        case .running:
            return "Working through the task..."
        case .failed:
            return "Open the dashboard for details."
        case .ready:
            return "Ready."
        case .stopped:
            return "Agent is offline."
        }
    }

    private var summaryText: String {
        if visibleInlineErrorMessage != nil {
            return "Agent needs attention. Open the dashboard for details."
        }
        return "Ask for coding, research, writing, or app tasks."
    }

    private var visibleInlineErrorMessage: String? {
        guard let lastErrorMessage = session.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lastErrorMessage.isEmpty else {
            return nil
        }

        let foldedMessage = lastErrorMessage.lowercased()
        if foldedMessage.contains("agent session token") || foldedMessage.contains("sync keys") {
            return nil
        }

        return lastErrorMessage
    }

    private var statusColor: Color {
        switch session.status {
        case .ready: return DS.Colors.accentText
        case .running, .starting: return Color.yellow
        case .failed: return DS.Colors.destructiveText
        case .stopped: return DS.Colors.textTertiary
        }
    }

    private func runPrompt() {
        guard canRun else { return }
        let submitted = prompt
        prompt = ""
        submitAgentPrompt(submitted)
    }
}

struct CodexAgentModeSettingsSheet: View {
    @ObservedObject var session: CodexAgentSession
    @AppStorage(ClickyAccentTheme.userDefaultsKey) private var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue
    @AppStorage(AppBundleConfiguration.userAnthropicAPIKeyDefaultsKey) private var userAnthropicAPIKey = ""
    @AppStorage(AppBundleConfiguration.userElevenLabsAPIKeyDefaultsKey) private var userElevenLabsAPIKey = ""
    @AppStorage(AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey) private var userElevenLabsVoiceID = ""
    @AppStorage(AppBundleConfiguration.userCodexAgentAPIKeyDefaultsKey) private var userCodexAgentAPIKey = ""
    @AppStorage(AppBundleConfiguration.userAssemblyAIAPIKeyDefaultsKey) private var userAssemblyAIAPIKey = ""
    @AppStorage(AppBundleConfiguration.userDeepgramAPIKeyDefaultsKey) private var userDeepgramAPIKey = ""
    var knowledgeIndex: WikiManager.Index
    var responseCard: ClickyResponseCard?
    var transcriptionProviderDisplayName: String
    var transcriptionProviderID: String
    var setVoiceTranscriptionProvider: (String) -> Void
    var isClickyCursorEnabled: Bool
    var setClickyCursorEnabled: (Bool) -> Void
    var isTutorModeEnabled: Bool
    var setTutorModeEnabled: (Bool) -> Void
    var selectedCompanionModelID: String
    var setSelectedCompanionModel: (String) -> Void
    var selectedComputerUseModelID: String
    var setSelectedComputerUseModel: (String) -> Void
    var setAnthropicAPIKey: (String) -> Void
    var setElevenLabsAPIKey: (String) -> Void
    var setElevenLabsVoiceID: (String) -> Void
    var setAssemblyAIAPIKey: (String) -> Void
    var setDeepgramAPIKey: (String) -> Void
    var setCodexAgentAPIKey: (String) -> Void
    var replayOnboarding: () -> Void
    var quitClicky: () -> Void
    var openHUD: () -> Void
    var openMemory: () -> Void
    var dismissResponseCard: () -> Void
    var runSuggestedNextAction: (String) -> Void
    var prepareVoiceFollowUp: () -> Void
    var openFeedback: () -> Void
    var closeSettings: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader

            settingsDivider

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    settingsSection(
                        title: "Voice response model",
                        subtitle: "Used for spoken OpenClicky replies. Claude can use local Claude Code sign-in when no Anthropic key is set."
                    ) {
                        modelOptionGrid(
                            options: OpenClickyModelCatalog.voiceResponseModels,
                            selectedModelID: selectedCompanionModelID,
                            select: setSelectedCompanionModel
                        )
                    }

                    settingsSection(
                        title: "Screen pointing model",
                        subtitle: "Used for cursor pointing. Claude uses Anthropic Computer Use; Codex uses local Codex sign-in and image input."
                    ) {
                        modelOptionGrid(
                            options: OpenClickyModelCatalog.computerUseModels,
                            selectedModelID: selectedComputerUseModelID,
                            select: setSelectedComputerUseModel
                        )
                    }

                    settingsSection(
                        title: "Coding and actions model",
                        subtitle: "Used when you say \"Hey Agent\", \"Clicky Agent\", or \"OpenClicky Agent\". The bundled Codex runtime uses local ChatGPT sign-in when no OpenAI key is set."
                    ) {
                        modelOptionGrid(
                            options: OpenClickyModelCatalog.codexActionsModels,
                            selectedModelID: session.model,
                            select: session.setModel
                        )
                    }

                    settingsSection(
                        title: "API keys",
                        subtitle: "Optional overrides. Leave Anthropic or Codex blank to use local Claude Code or Codex sign-in when available."
                    ) {
                        VStack(spacing: 7) {
                            settingsSecureField(
                                label: "Anthropic key",
                                placeholder: "Voice responses",
                                systemImage: "waveform",
                                value: Binding(
                                    get: { userAnthropicAPIKey },
                                    set: { newValue in
                                        userAnthropicAPIKey = newValue
                                        setAnthropicAPIKey(newValue)
                                    }
                                )
                            )

                            settingsSecureField(
                                label: "ElevenLabs key",
                                placeholder: "Voice playback",
                                systemImage: "speaker.wave.2",
                                value: Binding(
                                    get: { userElevenLabsAPIKey },
                                    set: { newValue in
                                        userElevenLabsAPIKey = newValue
                                        setElevenLabsAPIKey(newValue)
                                    }
                                )
                            )

                            settingsSecureField(
                                label: "AssemblyAI key",
                                placeholder: "Streaming transcription",
                                systemImage: "waveform",
                                value: Binding(
                                    get: { userAssemblyAIAPIKey },
                                    set: { newValue in
                                        userAssemblyAIAPIKey = newValue
                                        setAssemblyAIAPIKey(newValue)
                                    }
                                )
                            )

                            settingsSecureField(
                                label: "Deepgram key",
                                placeholder: "Streaming transcription",
                                systemImage: "waveform",
                                value: Binding(
                                    get: { userDeepgramAPIKey },
                                    set: { newValue in
                                        userDeepgramAPIKey = newValue
                                        setDeepgramAPIKey(newValue)
                                    }
                                )
                            )

                            settingsTextField(
                                label: "ElevenLabs voice ID",
                                placeholder: "Voice ID",
                                systemImage: "person.wave.2",
                                value: Binding(
                                    get: { userElevenLabsVoiceID },
                                    set: { newValue in
                                        userElevenLabsVoiceID = newValue
                                        setElevenLabsVoiceID(newValue)
                                    }
                                )
                            )

                            settingsSecureField(
                                label: "Codex/OpenAI key",
                                placeholder: "Coding and actions",
                                systemImage: "terminal",
                                value: Binding(
                                    get: { userCodexAgentAPIKey },
                                    set: { newValue in
                                        userCodexAgentAPIKey = newValue
                                        setCodexAgentAPIKey(newValue)
                                    }
                                )
                            )
                        }
                    }

                    settingsSection(
                        title: "Companion",
                        subtitle: "The passive companion controls now live here instead of taking up room in the main panel."
                    ) {
                        VStack(spacing: 8) {
                            settingsValueRow(
                                label: "Transcription provider",
                                systemImage: "waveform",
                                value: transcriptionProviderDisplayName
                            )

                            transcriptionProviderGrid

                            clickyCursorToggleRow
                            tutorModeToggleRow
                        }
                    }

                    ClickyKnowledgeIndexSummaryView(index: knowledgeIndex, openMemory: openMemory)

                    if let responseCard {
                        ClickyResponseCardCompactView(
                            card: responseCard,
                            actionHandlers: ClickyResponseCardActionHandlers(
                                dismiss: dismissResponseCard,
                                runSuggestedNextAction: { actionTitle in
                                    dismissSettings()
                                    runSuggestedNextAction(actionTitle)
                                },
                                openTextFollowUp: {
                                    dismissSettings()
                                    openHUD()
                                },
                                openVoiceFollowUp: {
                                    dismissSettings()
                                    prepareVoiceFollowUp()
                                }
                            )
                        )
                    }

                    settingsActionButton(
                        title: "Report issues and star on GitHub",
                        systemImage: "star.bubble",
                        action: openFeedback
                    )

                    settingsSection(
                        title: "App",
                        subtitle: "Low-frequency app actions stay tucked away here."
                    ) {
                        VStack(spacing: 7) {
                            settingsActionButton(
                                title: "Play onboarding again",
                                systemImage: "play.circle",
                                isDisabled: true,
                                action: {}
                            )

                            settingsActionButton(
                                title: "Quit OpenClicky",
                                systemImage: "power",
                                isDestructive: true,
                                action: quitClicky
                            )
                        }
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 7)
            }
        }
        .frame(
            minWidth: 356,
            maxWidth: .infinity,
            minHeight: 319,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DS.Colors.background)
        )
        .animation(.easeOut(duration: 0.15), value: selectedAccentThemeID)
    }

    private var settingsHeader: some View {
        HStack(spacing: 8) {
            Button(action: dismissSettings) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Text("Settings")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            Button(action: dismissSettings) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 7)
        .padding(.top, 12)
        .padding(.bottom, 11)
    }

    private func dismissSettings() {
        if let closeSettings {
            closeSettings()
        } else {
            dismiss()
        }
    }

    private var settingsDivider: some View {
        Divider()
            .background(DS.Colors.borderSubtle)
            .padding(.horizontal, 12)
    }

    private func settingsSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 1)
        )
    }

    private func modelOptionGrid(
        options: [OpenClickyModelOption],
        selectedModelID: String,
        select: @escaping (String) -> Void
    ) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(options) { option in
                modelOptionButton(option: option, isSelected: selectedModelID == option.id) {
                    select(option.id)
                }
            }
        }
    }

    private func modelOptionButton(
        option: OpenClickyModelOption,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(option.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Spacer(minLength: 4)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(DS.Colors.accentText)
                    }
                }

                Text(option.provider.displayName)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? DS.Colors.accentText.opacity(0.14) : Color.white.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? DS.Colors.accentText.opacity(0.7) : DS.Colors.borderSubtle.opacity(0.75), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var transcriptionProviderGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(BuddyTranscriptionProviderID.allCases) { option in
                Button {
                    setVoiceTranscriptionProvider(option.rawValue)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(option.label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(transcriptionProviderID == option.rawValue ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            if transcriptionProviderID == option.rawValue {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(DS.Colors.accentText)
                            }
                        }

                        Text(option.subtitle)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(transcriptionProviderID == option.rawValue ? DS.Colors.accentText.opacity(0.14) : Color.white.opacity(0.055))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(transcriptionProviderID == option.rawValue ? DS.Colors.accentText.opacity(0.7) : DS.Colors.borderSubtle.opacity(0.75), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private func settingsSecureField(label: String, placeholder: String, systemImage: String, value: Binding<String>) -> some View {
        settingsEditableField(label: label, placeholder: placeholder, systemImage: systemImage) {
            SecureField(placeholder, text: value)
                .textFieldStyle(.plain)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
        }
    }

    private func settingsTextField(label: String, placeholder: String, systemImage: String, value: Binding<String>) -> some View {
        settingsEditableField(label: label, placeholder: placeholder, systemImage: systemImage) {
            TextField(placeholder, text: value)
                .textFieldStyle(.plain)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
        }
    }

    private func settingsEditableField<Field: View>(
        label: String,
        placeholder: String,
        systemImage: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 13)

                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            field()
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 1)
                )
        }
    }

    private func settingsValueRow(label: String, systemImage: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 14)

            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            Text(value)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    private var clickyCursorToggleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 14)

            Text("Show OpenClicky")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            Toggle("", isOn: Binding(
                get: { isClickyCursorEnabled },
                set: { setClickyCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.7)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    private var tutorModeToggleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "graduationcap")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text("Tutor mode")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Guides you after short pauses")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isTutorModeEnabled },
                set: { setTutorModeEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.7)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    private func settingsActionButton(
        title: String,
        systemImage: String,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        showsChevron: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundColor(isDestructive ? Color(hex: "#FF6369") : DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1.0)
        .pointerCursor(isEnabled: !isDisabled)
    }
}
