//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @AppStorage(ClickyAccentTheme.userDefaultsKey) private var selectedAccentThemeID = ClickyAccentTheme.blue.rawValue
    @State private var isPanelPinned: Bool
    @State private var isShowingSettings = false
    private let setPanelPinned: (Bool) -> Void

    private var isReadyForFirstOnboarding: Bool {
        !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted
    }

    private var isPermissionOnboardingActive: Bool {
        !companionManager.hasCompletedOnboarding && !companionManager.allPermissionsGranted
    }

    init(
        companionManager: CompanionManager,
        isPanelPinned: Bool = false,
        setPanelPinned: @escaping (Bool) -> Void = { _ in }
    ) {
        self.companionManager = companionManager
        self._isPanelPinned = State(initialValue: isPanelPinned)
        self.setPanelPinned = setPanelPinned
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isShowingSettings {
                settingsSubscreen
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                mainPanelContent
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(
            minWidth: 356,
            maxWidth: .infinity,
            minHeight: 428,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(panelBackground)
        .onChange(of: isShowingSettings) { _ in
            schedulePanelContentSizeRefresh(isShowingSettings: isShowingSettings)
        }
        .animation(.easeOut(duration: 0.16), value: isShowingSettings)
        .animation(.none, value: selectedAccentThemeID)
    }

    private var mainPanelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 12)

            if isPermissionOnboardingActive {
                permissionOnboardingScreen
                    .padding(.top, 15)
                    .padding(.horizontal, 14)
            } else {
                permissionsCopySection
                    .padding(.top, 15)
                    .padding(.horizontal, 14)
            }

            if !companionManager.allPermissionsGranted && !isPermissionOnboardingActive {
                Spacer()
                    .frame(height: 12)

                ClickyPermissionGuideSection(viewState: companionManager.permissionGuideViewState)
                    .padding(.horizontal, 14)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                CodexAgentModePanelSection(
                    session: companionManager.codexAgentSession,
                    knowledgeIndex: companionManager.bundledKnowledgeIndex,
                    responseCard: companionManager.latestResponseCard,
                    transcriptionProviderDisplayName: companionManager.buddyDictationManager.transcriptionProviderDisplayName,
                    isClickyCursorEnabled: companionManager.isClickyCursorEnabled,
                    setClickyCursorEnabled: { companionManager.setClickyCursorEnabled($0) },
                    selectedCompanionModelID: companionManager.selectedModel,
                    setSelectedCompanionModel: { companionManager.setSelectedModel($0) },
                    selectedComputerUseModelID: companionManager.selectedComputerUseModel,
                    setSelectedComputerUseModel: { companionManager.setSelectedComputerUseModel($0) },
                    setAnthropicAPIKey: { companionManager.setAnthropicAPIKey($0) },
                    setElevenLabsAPIKey: { companionManager.setElevenLabsAPIKey($0) },
                    setElevenLabsVoiceID: { companionManager.setElevenLabsVoiceID($0) },
                    setCodexAgentAPIKey: { companionManager.setCodexAgentAPIKey($0) },
                    replayOnboarding: {},
                    quitClicky: { NSApp.terminate(nil) },
                    openHUD: { companionManager.showCodexHUD() },
                    openMemory: { companionManager.showMemoryWindow() },
                    dismissResponseCard: { companionManager.dismissLatestResponseCard() },
                    runSuggestedNextAction: { companionManager.runSuggestedNextAction($0) },
                    prepareVoiceFollowUp: { companionManager.prepareForVoiceFollowUp() },
                    openFeedback: openFeedbackInbox,
                    showSettings: showSettingsPanel
                )
                .padding(.horizontal, 14)
            }

            if !companionManager.allPermissionsGranted && !isPermissionOnboardingActive {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 14)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 14)
            }

            // Show OpenClicky toggle - hidden for now
            // if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showClickyCursorToggleRow
            //         .padding(.horizontal, 16)
            // }

            Spacer()
                .frame(height: 14)

            bottomClickyControlsSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var panelHeader: some View {
        if isReadyForFirstOnboarding {
            return AnyView(firstOnboardingHeader)
        }

        return AnyView(fullPanelHeader)
    }

    private var firstOnboardingHeader: some View {
        HStack {
            Text("OpenClicky")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            if !isPanelPinned {
                closePanelButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var fullPanelHeader: some View {
        HStack {
            HStack(spacing: 6) {
                Text("OpenClicky")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusDotColor.opacity(0.7), radius: 3.5)
            }
            Spacer()

            Text(statusText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                let nextPinnedState = !isPanelPinned
                isPanelPinned = nextPinnedState
                setPanelPinned(nextPinnedState)
            }) {
                Image(systemName: isPanelPinned ? "pin.fill" : "pin")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(isPanelPinned ? DS.Colors.accentText : DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(isPanelPinned ? DS.Colors.accentSubtle : Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(isPanelPinned ? "Unpin panel" : "Pin and detach panel")

            if !isPanelPinned {
                closePanelButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var closePanelButton: some View {
        Button(action: {
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        }) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
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

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if isReadyForFirstOnboarding {
            VStack(alignment: .leading, spacing: 4) {
                Text("We're set")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("Turn your sound on and tap Meet OpenClicky.")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text("Hold")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(DS.Colors.textSecondary)

                    keyChip(symbol: "⌃", label: "control")

                    Text("+")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(DS.Colors.textTertiary)

                    keyChip(symbol: "⌥", label: "option")

                    Text("to talk.")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Text("Ask OpenClicky about anything on your screen.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)

                Text("Or, say \"Hey Agent...\" or \"Hey OpenClicky Agent...\" to spawn an agent that can do whatever task you want like doing research, writing posts for social media, even building apps.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Also, you can press Control twice to enter text mode.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using OpenClicky.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Jason. This is OpenClicky.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("A side project I made for fun to help me learn stuff as I use my computer.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Nothing runs in the background. OpenClicky will only take a screenshot when you press the hot key. So, you can give that permission in peace. If you are still sus, eh, I can't do much there champ.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keyChip(symbol: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(symbol)
                .font(.system(size: 10, weight: .bold, design: .monospaced))

            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    // MARK: - Start Button

    @ViewBuilder
    private var startButton: some View {
        if isReadyForFirstOnboarding {
            Button(action: {
                companionManager.triggerOnboarding()
            }) {
                Text("Meet OpenClicky")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Permissions

    private struct PermissionOnboardingStep {
        let currentIndex: Int
        let totalCount: Int
        let title: String
        let detail: String
        let actionTitle: String
        let action: () -> Void
    }

    private var currentPermissionOnboardingStep: PermissionOnboardingStep {
        if !companionManager.hasMicrophonePermission {
            return PermissionOnboardingStep(
                currentIndex: 1,
                totalCount: 3,
                title: "I need your mic.",
                detail: "Let me hear you when you hold Control and Option.",
                actionTitle: "Open",
                action: { requestMicrophonePermissionForOnboarding() }
            )
        }

        if !companionManager.hasAccessibilityPermission {
            return PermissionOnboardingStep(
                currentIndex: 2,
                totalCount: 3,
                title: "I need accessibility.",
                detail: "Drag me into the Accessibility list.",
                actionTitle: "Open",
                action: { showAccessibilityPermissionDragAssistant() }
            )
        }

        return PermissionOnboardingStep(
            currentIndex: 3,
            totalCount: 3,
            title: "I need screen share.",
            detail: companionManager.hasScreenRecordingPermission
                ? "Let me verify screen capture access."
                : "Drag me into the Screen Recording list.",
            actionTitle: "Open",
            action: { showScreenSharePermissionForOnboarding() }
        )
    }

    private var permissionOnboardingScreen: some View {
        let step = currentPermissionOnboardingStep

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(step.detail)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()

                permissionOnboardingProgress(step: step)
                    .padding(.top, 8)
            }

            Button(action: step.action) {
                Text(step.actionTitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 23)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionOnboardingProgress(step: PermissionOnboardingStep) -> some View {
        HStack(spacing: 5) {
            Text("\(step.currentIndex) of \(step.totalCount)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(DS.Colors.textTertiary)

            HStack(spacing: 4) {
                ForEach(1...step.totalCount, id: \.self) { stepIndex in
                    Capsule()
                        .fill(stepIndex == step.currentIndex ? DS.Colors.accent : DS.Colors.accent.opacity(0.42))
                        .frame(width: stepIndex == step.currentIndex ? 12 : 4, height: 4)
                }
            }
        }
    }

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 4) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        showAccessibilityPermissionDragAssistant()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        showAccessibilityPermissionDragAssistantWithFinder()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        showScreenRecordingPermissionDragAssistant()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        showScreenRecordingPermissionDragAssistantWithFinder()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 4) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 4) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func showAccessibilityPermissionDragAssistant() {
        WindowPositionManager.guideAccessibilityPermissionWithDragAssistant()
        companionManager.pointAtPermissionDragAssistant()
    }

    private func requestMicrophonePermissionForOnboarding() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else if let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(microphoneSettingsURL)
        }
    }

    private func showAccessibilityPermissionDragAssistantWithFinder() {
        guard let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        WindowPositionManager.showAppInPermissionsListDragAssistant(settingsURL: accessibilitySettingsURL)
        companionManager.pointAtPermissionDragAssistant()
    }

    private func showScreenRecordingPermissionDragAssistant() {
        WindowPositionManager.guideScreenRecordingPermissionWithDragAssistant()
        companionManager.pointAtPermissionDragAssistant()
    }

    private func showScreenSharePermissionForOnboarding() {
        if companionManager.hasScreenRecordingPermission {
            companionManager.requestScreenContentPermission()
        } else {
            showScreenRecordingPermissionDragAssistant()
        }
    }

    private func showScreenRecordingPermissionDragAssistantWithFinder() {
        guard let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        WindowPositionManager.showAppInPermissionsListDragAssistant(settingsURL: screenRecordingSettingsURL)
        companionManager.pointAtPermissionDragAssistant()
    }

    private var settingsSubscreen: some View {
        CodexAgentModeSettingsSheet(
            session: companionManager.codexAgentSession,
            knowledgeIndex: companionManager.bundledKnowledgeIndex,
            responseCard: companionManager.latestResponseCard,
            transcriptionProviderDisplayName: companionManager.buddyDictationManager.transcriptionProviderDisplayName,
            isClickyCursorEnabled: companionManager.isClickyCursorEnabled,
            setClickyCursorEnabled: { companionManager.setClickyCursorEnabled($0) },
            selectedCompanionModelID: companionManager.selectedModel,
            setSelectedCompanionModel: { companionManager.setSelectedModel($0) },
            selectedComputerUseModelID: companionManager.selectedComputerUseModel,
            setSelectedComputerUseModel: { companionManager.setSelectedComputerUseModel($0) },
            setAnthropicAPIKey: { companionManager.setAnthropicAPIKey($0) },
            setElevenLabsAPIKey: { companionManager.setElevenLabsAPIKey($0) },
            setElevenLabsVoiceID: { companionManager.setElevenLabsVoiceID($0) },
            setCodexAgentAPIKey: { companionManager.setCodexAgentAPIKey($0) },
            replayOnboarding: {},
            quitClicky: { NSApp.terminate(nil) },
            openHUD: { companionManager.showCodexHUD() },
            openMemory: { companionManager.showMemoryWindow() },
            dismissResponseCard: { companionManager.dismissLatestResponseCard() },
            runSuggestedNextAction: { companionManager.runSuggestedNextAction($0) },
            prepareVoiceFollowUp: { companionManager.prepareForVoiceFollowUp() },
            openFeedback: openFeedbackInbox,
            closeSettings: hideSettingsPanel
        )
    }

    private func showSettingsPanel() {
        withAnimation(.easeOut(duration: 0.16)) {
            isShowingSettings = true
        }
        schedulePanelContentSizeRefresh(isShowingSettings: true)
    }

    private func hideSettingsPanel() {
        withAnimation(.easeOut(duration: 0.16)) {
            isShowingSettings = false
        }
        schedulePanelContentSizeRefresh(isShowingSettings: false)
    }

    private func schedulePanelContentSizeRefresh(isShowingSettings: Bool) {
        let userInfo = ["isShowingSettings": isShowingSettings]
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .clickyPanelContentSizeDidChange,
                object: nil,
                userInfo: userInfo
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            NotificationCenter.default.post(
                name: .clickyPanelContentSizeDidChange,
                object: nil,
                userInfo: userInfo
            )
        }
    }



    // MARK: - Show OpenClicky Cursor Toggle

    private var showClickyCursorToggleRow: some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show OpenClicky")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isClickyCursorEnabled },
                set: { companionManager.setClickyCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Transcription provider")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Bottom Controls

    private var bottomClickyControlsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isReadyForFirstOnboarding {
                firstOnboardingFooterSection
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    cursorColorSection
                    compactFooterSection
                }
                .padding(.horizontal, 14)
                .padding(.top, 13)
                .padding(.bottom, 10)
            }
        }
    }

    private var firstOnboardingFooterSection: some View {
        VStack(spacing: 9) {
            Divider()
                .background(DS.Colors.borderSubtle)

            HStack {
                Text(appVersionText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)

                Spacer()

                footerIconButton(
                    systemImageName: "gearshape.fill",
                    helpText: "Settings",
                    action: { showSettingsPanel() }
                )
            }
        }
    }

    private var cursorColorSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Cursor color")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            HStack(spacing: 4) {
                ForEach(cursorColorThemeOrder) { accentTheme in
                    cursorColorButton(accentTheme)
                }
            }
        }
    }

    private var cursorColorThemeOrder: [ClickyAccentTheme] {
        [.rose, .blue, .amber, .mint]
    }

    private func cursorColorButton(_ accentTheme: ClickyAccentTheme) -> some View {
        let isSelected = selectedAccentThemeID == accentTheme.rawValue

        return Button(action: {
            selectedAccentThemeID = accentTheme.rawValue
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? accentTheme.cursorColor.opacity(0.16) : Color.white.opacity(0.055))

                Triangle()
                    .fill(accentTheme.cursorColor)
                    .frame(width: 15, height: 15)
                    .rotationEffect(.degrees(-35))
                    .shadow(color: accentTheme.cursorColor.opacity(0.72), radius: 7, x: 0, y: 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 39)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isSelected ? accentTheme.cursorColor : DS.Colors.borderSubtle, lineWidth: isSelected ? 1.5 : 0.6)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(accentTheme.title)
    }

    private var compactFooterSection: some View {
        VStack(spacing: 9) {
            Divider()
                .background(DS.Colors.borderSubtle)

            HStack {
                Text(appVersionText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)

                Spacer()

                HStack(spacing: 9) {
                    if companionManager.hasCompletedOnboarding {
                        footerIconButton(
                            systemImageName: "books.vertical",
                            helpText: "Open memory",
                            action: { companionManager.showMemoryWindow() }
                        )
                    }

                    if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                        footerIconButton(
                            systemImageName: "gearshape.fill",
                            helpText: "Settings",
                            action: { showSettingsPanel() }
                        )
                    }

                    footerIconButton(
                        systemImageName: "power",
                        helpText: "Quit OpenClicky",
                        action: { NSApp.terminate(nil) }
                    )
                }
            }
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return "v\(version)"
    }

    private func footerIconButton(
        systemImageName: String,
        helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(helpText)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit OpenClicky")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

    private func openFeedbackInbox() {
        guard let url = URL(string: "https://github.com/jkneen/openclicky/issues") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

}
