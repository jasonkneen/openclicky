//
//  OpenClickyVisualIntelligenceWorkspace.swift
//  cursor-buddy
//
//  A native workspace for camera-based visual understanding and meeting notes.
//  It is intentionally additive: the existing fast push-to-talk voice path stays
//  unchanged unless the user enables camera context in Settings or this workspace.
//

import AppKit
@preconcurrency import AVFoundation
@preconcurrency import Combine
import Speech
import SwiftUI

@MainActor
final class OpenClickyVisualIntelligenceWindowManager {
    private var panel: NSPanel?

    func show(companionManager: CompanionManager) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "OpenClicky Visual Intelligence"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 860, height: 580)
        panel.center()
        panel.contentView = NSHostingView(
            rootView: OpenClickyVisualIntelligenceWorkspaceView(companionManager: companionManager)
        )
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private enum OpenClickyVisualWorkspaceTab: String, CaseIterable, Identifiable {
    case camera
    case meeting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: return "Visual Intelligence Playground"
        case .meeting: return "Meeting Notes Playground"
        }
    }

    var systemImageName: String {
        switch self {
        case .camera: return "camera.viewfinder"
        case .meeting: return "person.2.wave.2"
        }
    }
}

struct OpenClickyVisualIntelligenceWorkspaceView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var cameraController = OpenClickyCameraCaptureController.shared
    @StateObject private var meetingController: OpenClickyMeetingNotesController
    @AppStorage(AppBundleConfiguration.userCameraVoiceContextEnabledDefaultsKey) private var includeCameraInVoiceContext = false
    @State private var selectedTab: OpenClickyVisualWorkspaceTab = .camera
    @State private var cameraPrompt = "Describe what you can see. Identify objects, visible text, important details, and anything I should notice."
    @State private var cameraAnalysisText = ""
    @State private var isAnalyzingCamera = false
    @State private var cameraAnalysisError: String?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _meetingController = StateObject(wrappedValue: OpenClickyMeetingNotesController(companionManager: companionManager))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                sidebar
                Divider().opacity(0.5)
                Group {
                    switch selectedTab {
                    case .camera:
                        cameraWorkspace
                    case .meeting:
                        meetingWorkspace
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DS.Colors.background)
        .onAppear {
            cameraController.refreshAvailableCameras()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DS.Colors.accent.opacity(0.18))
                Image(systemName: "eye.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(selectedTab.title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Camera understanding, OCR, object identification, and meeting notes with mic/camera/screen/computer-audio inputs.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            if cameraController.isRunning {
                statusPill("camera live", systemImageName: "camera.fill", color: DS.Colors.success)
            }
            if meetingController.isRecording {
                statusPill("meeting active", systemImageName: "record.circle", color: .red)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(OpenClickyVisualWorkspaceTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.systemImageName)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 18)
                        Text(tab.title)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    .foregroundColor(selectedTab == tab ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selectedTab == tab ? DS.Colors.accent.opacity(0.16) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Label("Experimental screens", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("These are experimental screens testing features.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(cardBackground(cornerRadius: 14))
        }
        .padding(14)
        .frame(width: 210)
    }

    private var cameraWorkspace: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                cameraPreviewCard
                cameraControlsCard
            }
            .frame(width: 430)
            .padding(18)

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 14) {
                Text("Ask about the camera")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                TextEditor(text: $cameraPrompt)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(DS.Colors.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 112, maxHeight: 145)
                    .background(cardBackground(cornerRadius: 14))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    quickCameraPromptButton("Describe scene", prompt: "Describe the camera scene. Identify people, objects, the setting, visible actions, and anything unusual or important.")
                    quickCameraPromptButton("Scan text", prompt: "Read any visible text in the camera image. Extract names, labels, prices, codes, dates, warnings, addresses, or other important information.")
                    quickCameraPromptButton("Identify objects", prompt: "Identify the objects and items shown. For each important item, say what it likely is, how confident you are, and what details support the identification.")
                    quickCameraPromptButton("Lookup items", prompt: "Identify any products, devices, books, documents, logos, or notable objects shown. Give likely names, useful search terms, distinguishing details, and what I should verify if I look them up.")
                }

                Button {
                    analyzeCamera()
                } label: {
                    HStack(spacing: 8) {
                        if isAnalyzingCamera {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isAnalyzingCamera ? "Analyzing…" : "Analyze camera")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAnalyzingCamera || cameraPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let cameraAnalysisError {
                    warningText(cameraAnalysisError)
                }

                ScrollView {
                    Text(cameraAnalysisText.isEmpty ? "Camera analysis will stream here." : cameraAnalysisText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(cameraAnalysisText.isEmpty ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                        .padding(14)
                }
                .background(cardBackground(cornerRadius: 16))
            }
            .padding(18)
        }
    }

    private var cameraPreviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Camera", systemImage: "camera.viewfinder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                statusPill(cameraController.isRunning ? "live" : "idle", systemImageName: cameraController.isRunning ? "dot.radiowaves.left.and.right" : "pause.circle", color: cameraController.isRunning ? DS.Colors.success : DS.Colors.textTertiary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.42))
                if let image = cameraController.latestPreviewImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 394, height: 252)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: cameraController.authorizationStatus == .denied ? "camera.badge.ellipsis" : "camera")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text(cameraController.authorizationStatus == .denied ? "Camera permission needed" : "Start camera preview")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
            }
            .frame(width: 394, height: 252)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .padding(14)
        .background(cardBackground(cornerRadius: 20))
    }

    private var cameraControlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Camera", selection: $cameraController.selectedCameraID) {
                ForEach(cameraController.availableCameras) { camera in
                    Text(camera.displayName).tag(camera.id)
                }
                if cameraController.availableCameras.isEmpty {
                    Text("No camera found").tag("")
                }
            }
            .pickerStyle(.menu)

            Toggle("Include camera in voice visual context", isOn: $includeCameraInVoiceContext)
                .font(.system(size: 12, weight: .medium))
                .toggleStyle(.switch)

            Text("When enabled, visual voice questions can include a webcam frame alongside screenshots. Camera is still opt-in and controlled here.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(cameraController.isRunning ? "Stop" : "Start") {
                    if cameraController.isRunning {
                        cameraController.stopCaptureSession()
                    } else {
                        cameraController.startCaptureSession()
                    }
                }
                .buttonStyle(.bordered)

                Button("Refresh devices") {
                    cameraController.refreshAvailableCameras()
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            if let error = cameraController.lastErrorMessage {
                warningText(error)
            }
        }
        .padding(14)
        .background(cardBackground(cornerRadius: 18))
    }

    private var meetingWorkspace: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                meetingControlsCard
                meetingArtifactsCard
            }
            .frame(width: 355)
            .padding(18)

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Live meeting intelligence")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Refresh now") {
                        meetingController.refreshIntelligence(reason: "manual")
                    }
                    .disabled(meetingController.isAnalyzing)
                }

                HStack(spacing: 12) {
                    meetingTextPanel(title: "Transcript", text: meetingController.combinedTranscriptText, placeholder: "Meeting transcript will appear here.")
                    meetingTextPanel(title: "Notes / relevant info", text: meetingController.liveInsightsText, placeholder: "OpenClicky will summarize, extract action items, scan visible text, and suggest useful lookups here.")
                }

                if let error = meetingController.lastErrorMessage {
                    warningText(error)
                }
            }
            .padding(18)
        }
    }

    private var meetingControlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Capture sources", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                statusPill(meetingController.isRecording ? "recording" : "ready", systemImageName: meetingController.isRecording ? "record.circle" : "checkmark.circle", color: meetingController.isRecording ? .red : DS.Colors.success)
            }

            Toggle("Microphone", isOn: $meetingController.includeMicrophone).toggleStyle(.switch)
            Toggle("Camera snapshots", isOn: $meetingController.includeCamera).toggleStyle(.switch)
            Toggle("Screen snapshots", isOn: $meetingController.includeScreen).toggleStyle(.switch)
            Toggle("Computer audio", isOn: $meetingController.includeSystemAudio).toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Analysis cadence")
                    Spacer()
                    Text("\(Int(meetingController.analysisIntervalSeconds))s")
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .font(.system(size: 12, weight: .medium))
                Slider(value: $meetingController.analysisIntervalSeconds, in: 15...90, step: 5)
            }

            Button {
                if meetingController.isRecording {
                    meetingController.stopMeeting()
                } else {
                    meetingController.startMeeting()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: meetingController.isRecording ? "stop.fill" : "record.circle")
                    Text(meetingController.isRecording ? "Stop meeting notes" : "Start meeting notes")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
            }
            .buttonStyle(.borderedProminent)

            if meetingController.isAnalyzing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing latest context…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(14)
        .background(cardBackground(cornerRadius: 18))
    }

    private var meetingArtifactsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Session artifacts", systemImage: "folder")
                .font(.system(size: 13, weight: .semibold))

            valueLine("Status", meetingController.statusText)
            valueLine("Mic audio", meetingController.microphoneAudioURL?.lastPathComponent ?? "not recording")
            valueLine("System audio", meetingController.systemAudioURL?.lastPathComponent ?? "not recording")
            valueLine("Snapshots", "\(meetingController.snapshotCount)")

            if let folder = meetingController.sessionFolderURL {
                Button("Open session folder") {
                    NSWorkspace.shared.open(folder)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(cardBackground(cornerRadius: 18))
    }

    private func quickCameraPromptButton(_ title: String, prompt: String) -> some View {
        Button {
            cameraPrompt = prompt
            analyzeCamera()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
        }
        .buttonStyle(.bordered)
        .disabled(isAnalyzingCamera)
    }

    private func analyzeCamera() {
        guard !isAnalyzingCamera else { return }
        let prompt = cameraPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isAnalyzingCamera = true
        cameraAnalysisError = nil
        cameraAnalysisText = ""
        Task {
            do {
                let frame = try await cameraController.captureJPEGFrame(labelPrefix: "camera view")
                let response = try await companionManager.analyzeVisualWorkspace(
                    images: [(data: frame.data, label: frame.label)],
                    userPrompt: prompt,
                    source: "camera_workspace",
                    onTextChunk: { text in
                        cameraAnalysisText = text
                    }
                )
                cameraAnalysisText = response.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                cameraAnalysisError = error.localizedDescription
            }
            isAnalyzingCamera = false
        }
    }

    private func meetingTextPanel(title: String, text: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            ScrollView {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? placeholder : text)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(cardBackground(cornerRadius: 16))
        }
    }

    private func valueLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            Text(value)
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11, weight: .medium))
    }

    private func statusPill(_ title: String, systemImageName: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImageName)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.12))
        )
    }

    private func warningText(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground(cornerRadius: 12))
    }

    private func cardBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(DS.Colors.isDarkMode ? 0.055 : 0.72))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
            )
    }
}

@MainActor
final class OpenClickyMeetingNotesController: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    
    @Published var includeMicrophone = true
    @Published var includeCamera = true
    @Published var includeScreen = true
    @Published var includeSystemAudio = false
    @Published var analysisIntervalSeconds: Double = 30
    @Published private(set) var isRecording = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var statusText = "Ready"
    @Published private(set) var microphoneTranscriptText = ""
    @Published private(set) var systemAudioTranscriptText = ""
    @Published private(set) var liveInsightsText = ""
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var sessionFolderURL: URL?
    @Published private(set) var microphoneAudioURL: URL?
    @Published private(set) var systemAudioURL: URL?
    @Published private(set) var snapshotCount = 0

    private weak var companionManager: CompanionManager?
    private let cameraController = OpenClickyCameraCaptureController.shared
    private let systemAudioCaptureController = OpenClickySystemAudioCaptureController()
    private let audioEngine = AVAudioEngine()
    private var activeMicrophoneTranscriptionSession: (any BuddyStreamingTranscriptionSession)?
    private var activeSystemAudioTranscriptionSession: (any BuddyStreamingTranscriptionSession)?
    private var microphoneAudioFile: AVAudioFile?
    private var hasInstalledMicrophoneTap = false
    private var analysisLoopTask: Task<Void, Never>?
    private var lastAnalysisTranscriptFingerprint = ""
    private var startedAt: Date?

    var combinedTranscriptText: String {
        let mic = microphoneTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = systemAudioTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if mic.isEmpty && system.isEmpty { return "" }
        if system.isEmpty { return mic }
        if mic.isEmpty { return "Computer audio:\n\(system)" }
        return "Microphone:\n\(mic)\n\nComputer audio:\n\(system)"
    }

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func startMeeting() {
        guard !isRecording else { return }
        lastErrorMessage = nil
        liveInsightsText = ""
        microphoneTranscriptText = ""
        systemAudioTranscriptText = ""
        snapshotCount = 0
        startedAt = Date()

        Task {
            do {
                let folder = try Self.makeSessionFolder()
                sessionFolderURL = folder
                statusText = "Starting capture…"

                if includeCamera {
                    cameraController.startCaptureSession()
                }
                if includeMicrophone {
                    try await startMicrophoneCapture(in: folder)
                }
                if includeSystemAudio {
                    try await startSystemAudioCapture(in: folder)
                }

                isRecording = true
                statusText = "Recording"
                saveNotesMarkdown()
                startAnalysisLoop()
                refreshIntelligence(reason: "meeting_started")
            } catch {
                lastErrorMessage = error.localizedDescription
                statusText = "Failed to start"
                stopMeeting()
            }
        }
    }

    func stopMeeting() {
        guard isRecording || audioEngine.isRunning || activeMicrophoneTranscriptionSession != nil || activeSystemAudioTranscriptionSession != nil else { return }
        analysisLoopTask?.cancel()
        analysisLoopTask = nil
        isRecording = false
        statusText = "Stopping…"

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledMicrophoneTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledMicrophoneTap = false
        }
        microphoneAudioFile = nil
        activeMicrophoneTranscriptionSession?.requestFinalTranscript()
        activeMicrophoneTranscriptionSession?.cancel()
        activeMicrophoneTranscriptionSession = nil
        activeSystemAudioTranscriptionSession?.requestFinalTranscript()
        activeSystemAudioTranscriptionSession?.cancel()
        activeSystemAudioTranscriptionSession = nil

        Task {
            await systemAudioCaptureController.stop()
            await MainActor.run {
                statusText = "Stopped"
                saveNotesMarkdown()
            }
        }
    }

    func refreshIntelligence(reason: String) {
        guard !isAnalyzing else { return }
        guard let companionManager else { return }

        let transcript = combinedTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcriptFingerprint = String(transcript.suffix(1800)) + "|snapshots:\(snapshotCount)|reason:\(reason)"
        if reason == "interval", transcriptFingerprint == lastAnalysisTranscriptFingerprint {
            return
        }
        lastAnalysisTranscriptFingerprint = transcriptFingerprint

        isAnalyzing = true
        if liveInsightsText.isEmpty {
            liveInsightsText = "Gathering meeting context…"
        }

        Task {
            do {
                var images: [(data: Data, label: String)] = []
                if includeCamera {
                    if let cameraFrame = try? await cameraController.captureJPEGFrame(labelPrefix: "meeting camera") {
                        images.append((data: cameraFrame.data, label: cameraFrame.label))
                        try? saveSnapshot(data: cameraFrame.data, prefix: "camera")
                    }
                }
                if includeScreen {
                    if let screenCaptures = try? await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG(),
                       let screenCapture = screenCaptures.first {
                        let label = screenCapture.label + " (image dimensions: \(screenCapture.screenshotWidthInPixels)x\(screenCapture.screenshotHeightInPixels) pixels)"
                        images.append((data: screenCapture.imageData, label: label))
                        try? saveSnapshot(data: screenCapture.imageData, prefix: "screen")
                    }
                }

                let prompt = Self.meetingAnalysisPrompt(
                    transcript: transcript,
                    priorNotes: liveInsightsText,
                    includeMicrophone: includeMicrophone,
                    includeCamera: includeCamera,
                    includeScreen: includeScreen,
                    includeSystemAudio: includeSystemAudio,
                    reason: reason
                )

                let response = try await companionManager.analyzeVisualWorkspace(
                    images: images,
                    userPrompt: prompt,
                    source: "meeting_notes",
                    onTextChunk: { [weak self = self] text in
                        self?.liveInsightsText = text
                    }
                )
                liveInsightsText = response.trimmingCharacters(in: .whitespacesAndNewlines)
                saveNotesMarkdown()
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    private func startMicrophoneCapture(in folder: URL) async throws {
        guard await requestMicrophonePermission() else {
            throw NSError(domain: "OpenClickyMeetingNotes", code: -10, userInfo: [
                NSLocalizedDescriptionKey: "Microphone permission is required for meeting notes."
            ])
        }
        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider()
        try await requestSpeechRecognitionPermissionIfNeeded(for: provider)

        let transcriptionSession = try await provider.startStreamingSession(
            keyterms: [],
            onTranscriptUpdate: { [weak self] transcript in
                Task { @MainActor in
                    self?.microphoneTranscriptText = transcript
                    self?.saveNotesMarkdown()
                }
            },
            onFinalTranscriptReady: { [weak self] transcript in
                Task { @MainActor in
                    if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self?.microphoneTranscriptText = transcript
                    }
                    self?.saveNotesMarkdown()
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.lastErrorMessage = error.localizedDescription
                }
            }
        )
        activeMicrophoneTranscriptionSession = transcriptionSession

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let audioURL = folder.appendingPathComponent("microphone-audio.caf")
        microphoneAudioURL = audioURL
        microphoneAudioFile = try AVAudioFile(forWriting: audioURL, settings: inputFormat.settings)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.activeMicrophoneTranscriptionSession?.appendAudioBuffer(buffer)
            if let file = self?.microphoneAudioFile {
                try? file.write(from: buffer)
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func startSystemAudioCapture(in folder: URL) async throws {
        let provider = BuddyTranscriptionProviderFactory.makeDefaultProvider()
        let transcriptionSession = try? await provider.startStreamingSession(
            keyterms: [],
            onTranscriptUpdate: { [weak self] transcript in
                Task { @MainActor in
                    self?.systemAudioTranscriptText = transcript
                    self?.saveNotesMarkdown()
                }
            },
            onFinalTranscriptReady: { [weak self] transcript in
                Task { @MainActor in
                    if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self?.systemAudioTranscriptText = transcript
                    }
                    self?.saveNotesMarkdown()
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.lastErrorMessage = "Computer-audio transcription: \(error.localizedDescription)"
                }
            }
        )
        activeSystemAudioTranscriptionSession = transcriptionSession

        let audioURL = folder.appendingPathComponent("computer-audio.mov")
        systemAudioURL = audioURL
        try await systemAudioCaptureController.start(
            outputURL: audioURL,
            onStateChanged: { [weak self] state in
                self?.systemAudioURL = state.outputURL
                if let errorMessage = state.errorMessage {
                    self?.lastErrorMessage = errorMessage
                }
            },
            onAudioBuffer: { buffer in
                transcriptionSession?.appendAudioBuffer(buffer)
            }
        )
    }

    private func startAnalysisLoop() {
        analysisLoopTask?.cancel()
        analysisLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                let delaySeconds = await MainActor.run { self?.analysisIntervalSeconds ?? 30 }
                try? await Task.sleep(nanoseconds: UInt64(max(15.0, delaySeconds) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.refreshIntelligence(reason: "interval")
                }
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestSpeechRecognitionPermissionIfNeeded(for provider: any BuddyTranscriptionProvider) async throws {
        guard provider.requiresSpeechRecognitionPermission else { return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            guard status == .authorized else {
                throw NSError(domain: "OpenClickyMeetingNotes", code: -11, userInfo: [
                    NSLocalizedDescriptionKey: "Speech Recognition permission is required for the selected transcription provider."
                ])
            }
        case .denied, .restricted:
            throw NSError(domain: "OpenClickyMeetingNotes", code: -12, userInfo: [
                NSLocalizedDescriptionKey: "Speech Recognition permission is blocked in macOS Privacy settings."
            ])
        @unknown default:
            throw NSError(domain: "OpenClickyMeetingNotes", code: -13, userInfo: [
                NSLocalizedDescriptionKey: "Speech Recognition permission is unavailable."
            ])
        }
    }

    private func saveSnapshot(data: Data, prefix: String) throws {
        guard let sessionFolderURL else { return }
        let snapshotsFolder = sessionFolderURL.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotsFolder, withIntermediateDirectories: true)
        let fileURL = snapshotsFolder.appendingPathComponent("\(prefix)-\(Self.timestampForFilename()).jpg")
        try data.write(to: fileURL, options: [.atomic])
        snapshotCount += 1
    }

    private func saveNotesMarkdown() {
        guard let sessionFolderURL else { return }
        let notesURL = sessionFolderURL.appendingPathComponent("notes.md")
        let content = """
        # OpenClicky Meeting Notes

        Started: \(startedAt?.formatted(date: .abbreviated, time: .standard) ?? "unknown")
        Updated: \(Date().formatted(date: .abbreviated, time: .standard))

        ## Capture sources

        - Microphone: \(includeMicrophone ? "on" : "off")
        - Camera snapshots: \(includeCamera ? "on" : "off")
        - Screen snapshots: \(includeScreen ? "on" : "off")
        - Computer audio: \(includeSystemAudio ? "on" : "off")
        - Snapshot count: \(snapshotCount)

        ## Live transcript

        \(microphoneTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "_No microphone transcript yet._" : microphoneTranscriptText)

        ## Computer audio transcript

        \(systemAudioTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "_No computer-audio transcript yet._" : systemAudioTranscriptText)

        ## Notes / relevant information

        \(liveInsightsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "_No notes generated yet._" : liveInsightsText)
        """
        try? content.write(to: notesURL, atomically: true, encoding: .utf8)
    }

    private static func meetingAnalysisPrompt(
        transcript: String,
        priorNotes: String,
        includeMicrophone: Bool,
        includeCamera: Bool,
        includeScreen: Bool,
        includeSystemAudio: Bool,
        reason: String
    ) -> String {
        let boundedTranscript = String(transcript.suffix(7_000))
        let boundedPriorNotes = String(priorNotes.suffix(3_000))
        return """
        You are OpenClicky's live meeting-notes copilot. Use the transcript and any attached camera/screen images to help the user during a meeting.

        Capture state:
        - microphone: \(includeMicrophone ? "on" : "off")
        - camera snapshots: \(includeCamera ? "on" : "off")
        - screen snapshots: \(includeScreen ? "on" : "off")
        - computer audio recording/transcription: \(includeSystemAudio ? "on" : "off")
        - refresh reason: \(reason)

        Latest transcript tail:
        \(boundedTranscript.isEmpty ? "No transcript yet." : boundedTranscript)

        Previous notes tail:
        \(boundedPriorNotes.isEmpty ? "No previous notes yet." : boundedPriorNotes)

        Return concise but useful markdown with these sections:
        - Current gist: what is being discussed right now.
        - Decisions / facts: important information stated or visible.
        - Action items: owner + action when inferable.
        - Useful lookups: names, products, docs, objects, visible text, acronyms, or claims worth looking up. Include likely search terms and why they matter.
        - Visual notes: any important objects, scenes, situations, or text from camera/screen images.
        - Suggested assists: one or two things OpenClicky could quietly find or prepare next.

        If there is not enough information yet, say what is missing and keep it short.
        """
    }

    private static func makeSessionFolder() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("OpenClicky Meeting Notes", isDirectory: true)
        let folder = root.appendingPathComponent(timestampForFilename(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func timestampForFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.string(from: Date())
    }
}
