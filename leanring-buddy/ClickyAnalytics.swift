//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  Analytics wrapper. PostHog has been removed; the static API is preserved
//  as no-ops so existing call sites compile without churn. Reintroduce a
//  provider here if/when telemetry is wanted again.
//

import Foundation

enum ClickyAnalytics {

    static var isEnabled: Bool { false }

    private static func capture(_ event: String, properties: [String: Any]? = nil) {
        // no-op
        _ = event
        _ = properties
    }

    // MARK: - Setup

    static func configure() {
        // no-op
    }

    // MARK: - App Lifecycle

    static func trackAppOpened() {
        capture("app_opened")
    }

    // MARK: - Onboarding

    static func trackOnboardingStarted() {
        capture("onboarding_started")
    }

    static func trackOnboardingReplayed() {
        capture("onboarding_replayed")
    }

    static func trackOnboardingVideoCompleted() {
        capture("onboarding_video_completed")
    }

    static func trackOnboardingDemoTriggered() {
        capture("onboarding_demo_triggered")
    }

    // MARK: - Permissions

    static func trackAllPermissionsGranted() {
        capture("all_permissions_granted")
    }

    static func trackPermissionGranted(permission: String) {
        capture("permission_granted", properties: ["permission": permission])
    }

    // MARK: - Voice Interaction

    static func trackPushToTalkStarted() {
        capture("push_to_talk_started")
    }

    static func trackPushToTalkReleased() {
        capture("push_to_talk_released")
    }

    static func trackUserMessageSent(transcript: String) {
        capture("user_message_sent", properties: [
            "transcript": transcript,
            "character_count": transcript.count
        ])
    }

    static func trackAIResponseReceived(response: String) {
        capture("ai_response_received", properties: [
            "response": response,
            "character_count": response.count
        ])
    }

    static func trackElementPointed(elementLabel: String?) {
        capture("element_pointed", properties: [
            "element_label": elementLabel ?? "unknown"
        ])
    }

    // MARK: - Errors

    static func trackResponseError(error: String) {
        capture("response_error", properties: ["error": error])
    }

    static func trackTTSError(error: String) {
        capture("tts_error", properties: ["error": error])
    }
}
