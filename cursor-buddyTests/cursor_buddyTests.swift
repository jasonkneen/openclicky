//
//  cursor_buddyTests.swift
//  cursor-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import Foundation
import CoreGraphics
@testable import OpenClicky

@MainActor
struct cursor_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func agentRoutingHandlesNoisyAndTruncatedDelegationTranscripts() async throws {
        #expect(
            CompanionManager.agentTaskCreationInstruction(
                from: "Makesomething, ask an agent to review the OpenClicky code changes."
            ) == "review the OpenClicky code changes"
        )
        #expect(
            CompanionManager.agentTaskCreationInstruction(
                from: "—an agent to look at today's conversation logs, summarize findings, and look for areas of improvement."
            ) == "look at today's conversation logs, summarize findings, and look for areas of improvement"
        )
        #expect(
            CompanionManager.agentTaskCreationInstruction(
                from: "Question: Can you take a look at my desktop and see if there's any files that could be cleaned up?"
            ) == "take a look at my desktop and see if there's any files that could be cleaned up"
        )
        #expect(
            CompanionManager.agentTaskCreationInstruction(
                from: "That's great, but when I asked for the agent to be launched, it didn't zoom off to the corner of the screen. Why was that?"
            ) == nil
        )
        #expect(
            CompanionManager.agentTaskCreationInstruction(
                from: "How do I ask an agent to review logs?"
            ) == nil
        )
    }

    @Test func voiceResponseCompletionStateWaitsForPlaybackToFinish() async throws {
        #expect(
            CompanionManager.voiceResponseCompletionAudioPlaybackState(
                spokenText: "yes, i can hear you.",
                playbackFinished: true
            ) == "finished"
        )
        #expect(
            CompanionManager.voiceResponseCompletionAudioPlaybackState(
                spokenText: "yes, i can hear you.",
                playbackFinished: false
            ) == "interrupted"
        )
        #expect(
            CompanionManager.voiceResponseCompletionAudioPlaybackState(
                spokenText: "   ",
                playbackFinished: false
            ) == "empty"
        )
    }

    @Test func quickControlTapSilencesRealtimeNoAudioInterruptFault() async throws {
        let noAudioError = NSError(
            domain: "OpenClickyRealtime",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "OpenClicky could not detect usable microphone audio. Check the microphone input or macOS microphone permission and try again."
            ]
        )

        #expect(
            CompanionManager.shouldSilenceQuickRealtimeShortcutFailure(
                noAudioError,
                source: "keyboardShortcut",
                stage: "finish",
                captureStartedAt: Date().addingTimeInterval(-0.3),
                startedAsInterrupt: true
            )
        )
        #expect(
            !CompanionManager.shouldSilenceQuickRealtimeShortcutFailure(
                noAudioError,
                source: "keyboardShortcut",
                stage: "finish",
                captureStartedAt: Date().addingTimeInterval(-2.0),
                startedAsInterrupt: true
            )
        )
        #expect(
            !CompanionManager.shouldSilenceQuickRealtimeShortcutFailure(
                noAudioError,
                source: "keyboardShortcut",
                stage: "finish",
                captureStartedAt: Date().addingTimeInterval(-0.3),
                startedAsInterrupt: false
            )
        )
    }

    @Test func clearOverlayAnnotationsIntentMatcherIsAccurate() async throws {
        // Explicit noun forms match regardless of overlay state.
        #expect(
            CompanionManager.isClearOverlayAnnotationsRequest(
                "clear those rectangles", hasActiveOverlayAnnotation: false
            )
        )
        #expect(
            CompanionManager.isClearOverlayAnnotationsRequest(
                "hide the highlights", hasActiveOverlayAnnotation: false
            )
        )
        // Pronoun-only requires an active annotation.
        #expect(
            !CompanionManager.isClearOverlayAnnotationsRequest(
                "clear those", hasActiveOverlayAnnotation: false
            )
        )
        #expect(
            CompanionManager.isClearOverlayAnnotationsRequest(
                "clear those", hasActiveOverlayAnnotation: true
            )
        )
        // Agent phrasing should NOT match.
        #expect(
            !CompanionManager.isClearOverlayAnnotationsRequest(
                "dismiss those agents", hasActiveOverlayAnnotation: true
            )
        )
    }

    @Test func realtimeVoiceRouteDedupSuppressesFilleredDuplicates() async throws {
        // The exact logged dup pair: filler-stripped forms are prefix of each
        // other and both >= 3 words → suppressed.
        #expect(
            CompanionManager.isDuplicateRealtimeVoiceRouteFingerprint(
                CompanionManager.realtimeVoiceRouteFingerprint("Okay, you can clear those now."),
                CompanionManager.realtimeVoiceRouteFingerprint("ok you can clear those")
            )
        )
        // Distinct commands — not a dup.
        #expect(
            !CompanionManager.isDuplicateRealtimeVoiceRouteFingerprint(
                CompanionManager.realtimeVoiceRouteFingerprint("open safari"),
                CompanionManager.realtimeVoiceRouteFingerprint("close safari")
            )
        )
        // Short utterances under the 3-word minimum — not a dup even if similar.
        #expect(
            !CompanionManager.isDuplicateRealtimeVoiceRouteFingerprint(
                CompanionManager.realtimeVoiceRouteFingerprint("go"),
                CompanionManager.realtimeVoiceRouteFingerprint("go now")
            )
        )
    }

    @Test func voiceHealthChecksUseLocalFastPath() async throws {
        #expect(
            CompanionManager.quickLocalVoiceResponseText(
                for: "Learning Buddy, can you hear me?"
            ) == "yes, i can hear you."
        )
        #expect(
            CompanionManager.quickLocalVoiceResponseText(
                for: "Hey Clicky, are you there?"
            ) == "i'm here."
        )
        #expect(
            CompanionManager.quickLocalVoiceResponseText(
                for: "Can you hear me out before you answer?"
            ) == nil
        )
    }

    @Test func tutorTargetClickHitTestingUsesPointAndRectTolerance() async throws {
        #expect(TutorTargetClickTracker.isHit(
            clickPoint: CGPoint(x: 120, y: 120),
            targetPoint: CGPoint(x: 100, y: 100),
            targetRect: nil
        ))
        #expect(!TutorTargetClickTracker.isHit(
            clickPoint: CGPoint(x: 180, y: 180),
            targetPoint: CGPoint(x: 100, y: 100),
            targetRect: nil
        ))
        #expect(TutorTargetClickTracker.isHit(
            clickPoint: CGPoint(x: 49, y: 72),
            targetPoint: nil,
            targetRect: CGRect(x: 50, y: 70, width: 20, height: 20)
        ))
        #expect(!TutorTargetClickTracker.isHit(
            clickPoint: CGPoint(x: 30, y: 30),
            targetPoint: nil,
            targetRect: CGRect(x: 50, y: 70, width: 20, height: 20)
        ))
    }
}
