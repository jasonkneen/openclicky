//
//  ClickyPetSpriteView.swift
//  OpenClicky
//
//  Renders a hatch-pet pet bound to the cursor. Picks the row from a
//  high-level animation state and ticks frames using the per-frame
//  durations baked into `ClickyBuddyAnimationRow`.
//

import CoreGraphics
import SwiftUI

// MARK: - High-level animation state

/// Translates OpenClicky's existing buddy state machine + cursor velocity
/// into a row of the atlas.
enum ClickyBuddyAnimationState: Equatable {
    case idle
    case waiting
    case runningRight
    case runningLeft
    case running       // generic / vertical
    case waving
    case jumping
    case failed
    case review

    var row: ClickyBuddyAnimationRow {
        switch self {
        case .idle:         return .idle
        case .waiting:      return .waiting
        case .runningRight: return .runningRight
        case .runningLeft:  return .runningLeft
        case .running:      return .running
        case .waving:       return .waving
        case .jumping:      return .jumping
        case .failed:       return .failed
        case .review:       return .review
        }
    }
}

// MARK: - View

struct ClickyPetSpriteView: View {
    let pet: ClickyBuddyPet
    let animationState: ClickyBuddyAnimationState

    /// Optional accent color used for an under-glow halo. Pets are
    /// pre-colored, so we never tint the sprite itself.
    var haloColor: Color? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            let frame = currentFrame(for: context.date)
            ZStack {
                if let haloColor = haloColor {
                    Circle()
                        .fill(haloColor.opacity(0.18))
                        .blur(radius: 10)
                }
                if let frame = frame {
                    Image(decorative: frame, scale: 1.0, orientation: .up)
                        .resizable()
                        .interpolation(.none) // preserve crisp pixel-art edges
                        .scaledToFit()
                } else {
                    // No frames decoded — render a faint placeholder so we
                    // don't silently disappear.
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Frame timing

    private func currentFrame(for date: Date) -> CGImage? {
        let row = animationState.row
        guard let frames = pet.frames[row], !frames.isEmpty else { return nil }
        let durations = row.frameDurations
        let total = durations.reduce(0, +)
        guard total > 0 else { return frames.first }

        // Use a state-stable epoch so changing rows resets the cycle on the
        // next render. We key off the row identity by combining elapsed time
        // with the current row — when the row changes, the modulo is computed
        // against new durations and we naturally restart at frame 0.
        let elapsed = date.timeIntervalSince(Self.epoch)
        let phase = elapsed.truncatingRemainder(dividingBy: total)

        var accumulated: TimeInterval = 0
        for (idx, dur) in durations.enumerated() {
            accumulated += dur
            if phase < accumulated {
                return frames[min(idx, frames.count - 1)]
            }
        }
        return frames.last
    }

    /// Stable epoch shared across all instances. Using a fixed reference date
    /// rather than `.now` means switching state doesn't introduce a frame
    /// jitter from a re-anchored clock.
    private static let epoch = Date(timeIntervalSince1970: 0)
}

// MARK: - Convenience: thumbnail tile (idle frame 0)

struct ClickyPetThumbnailView: View {
    let pet: ClickyBuddyPet

    var body: some View {
        if let cg = pet.thumbnailFrame {
            Image(decorative: cg, scale: 1.0, orientation: .up)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Image(systemName: "pawprint")
                .foregroundStyle(.secondary)
        }
    }
}
