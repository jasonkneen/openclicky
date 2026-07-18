//
//  ResponseOverlayAutoHidePolicy.swift
//  cursor-buddy
//
//  Pure policy for the interactive response bubble auto-hide timer.
//  Separated from AppKit so unit tests can prove cancel-before-reschedule
//  without spinning NSPanel.
//

import Foundation

/// Tracks auto-hide generations so only the latest scheduled hide may fire.
/// Used by `CompanionResponseOverlayManager` and covered by unit tests.
nonisolated struct ResponseOverlayAutoHidePolicy: Equatable, Sendable {
    static let defaultHoldSeconds: TimeInterval = 6

    /// Bumped on every cancel or schedule. A hide callback must match this
    /// generation or it is ignored as stale.
    private(set) var generation: UInt64 = 0

    /// Absolute time of the currently scheduled hide, if any.
    private(set) var scheduledHideAt: TimeInterval?

    mutating func cancel() {
        generation &+= 1
        scheduledHideAt = nil
    }

    /// Cancel any prior schedule, then schedule a hide at `now + holdSeconds`.
    /// Returns the generation that owns the new schedule.
    @discardableResult
    mutating func schedule(now: TimeInterval, holdSeconds: TimeInterval = defaultHoldSeconds) -> UInt64 {
        cancel()
        let g = generation
        scheduledHideAt = now + max(0, holdSeconds)
        return g
    }

    /// Whether a hide scheduled under `generation` is still the active one.
    func isCurrent(_ candidateGeneration: UInt64) -> Bool {
        candidateGeneration == generation && scheduledHideAt != nil
    }

    /// Whether hide should fire at `now` for the given generation.
    func shouldHide(now: TimeInterval, generation candidate: UInt64) -> Bool {
        guard isCurrent(candidate), let scheduledHideAt else { return false }
        return now >= scheduledHideAt
    }
}
