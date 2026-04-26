//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import OpenClicky

@MainActor
struct leanring_buddyTests {

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
}
