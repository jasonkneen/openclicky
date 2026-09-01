//
//  CompanionManager+BrowserWorkspaceDictation.swift
//  cursor-buddy
//

@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreAudio
import Foundation
import os
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import OCCore
import OCUI
@preconcurrency import OCBrowser
import OCMarkdown
import OCMemory

extension CompanionManager {

    // MARK: - Voice dictation for the Browser Workspace

    public func isBrowserWorkspaceDictationActive() -> Bool {
        buddyDictationManager.isRecordingFromMicrophoneButton
            || buddyDictationManager.isPreparingToRecord
            || buddyDictationManager.isFinalizingTranscript
    }

    public func startBrowserWorkspaceDictation(
        currentDraft: String,
        updateDraft: @escaping @MainActor (String) -> Void,
        submitDraft: @escaping @MainActor (String) -> Void
    ) {
        Task { @MainActor in
            await self.buddyDictationManager.startAutoSubmittingDictationFromMicrophoneButton(
                currentDraftText: currentDraft,
                updateDraftText: { text in
                    Task { @MainActor in updateDraft(text) }
                },
                submitDraftText: { text in
                    Task { @MainActor in submitDraft(text) }
                }
            )
        }
    }

    public func stopBrowserWorkspaceDictation() {
        buddyDictationManager.stopPersistentDictationFromMicrophoneButton()
    }
}
