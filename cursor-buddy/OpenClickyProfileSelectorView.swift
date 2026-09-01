//
//  OpenClickyProfileSelectorView.swift
//  cursor-buddy
//
//  The hero settings control: pick Local / Realtime / Quality and the whole
//  voice provider matrix flips at once. Applies live via
//  CompanionManager.applyProfile. Step 2 of the settings-profiles spec.
//

import SwiftUI
import OCUI

struct OpenClickyProfileSelectorView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var selectedProfileID: String

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _selectedProfileID = State(initialValue: OpenClickyProfileCatalog.activeProfile().id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("PROFILE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(DS.Colors.textTertiary)

            HStack(spacing: DS.Spacing.sm) {
                ForEach(OpenClickyProfileCatalog.all) { profile in
                    card(for: profile)
                }
            }
        }
    }

    private func card(for profile: OpenClickyProfile) -> some View {
        let isSelected = profile.id == selectedProfileID
        return Button {
            guard selectedProfileID != profile.id else { return }
            selectedProfileID = profile.id
            companionManager.applyProfile(profile)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textPrimary)
                Text(Self.tagline(for: profile.id))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            .padding(DS.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(isSelected ? DS.Colors.accentSubtle : DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .strokeBorder(
                        isSelected ? DS.Colors.accent : DS.Colors.edgeInset.opacity(0.6),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private static func tagline(for id: String) -> String {
        switch id {
        case "local":
            return "Private — on-device speech, no API keys"
        case "realtime":
            return "Lowest latency — speech-to-speech"
        case "quality":
            return "Best accuracy — premium STT & voice"
        default:
            return ""
        }
    }
}
