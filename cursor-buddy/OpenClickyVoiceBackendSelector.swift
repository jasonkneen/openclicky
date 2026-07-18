//
//  OpenClickyVoiceBackendSelector.swift
//  cursor-buddy
//
//  Compact Apple / Codex / Claude selector for the response bubble and notch.
//  Availability comes from OpenClickyProviderDiscovery (install probes only).
//

import SwiftUI

struct OpenClickyVoiceBackendSelector: View {
    @ObservedObject var companion: CompanionManager
    var style: Style = .compact
    @State private var availability: [OpenClickyProviderAvailability] = OpenClickyProviderDiscovery.availability()

    enum Style {
        /// Tiny chips for caption bubble / notch.
        case compact
        /// Slightly larger chips with status labels.
        case panel
    }

    var body: some View {
        HStack(spacing: style == .compact ? 4 : 6) {
            ForEach(OpenClickyVoiceBackendFamily.allCases, id: \.self) { family in
                chip(for: family)
            }
        }
        .onAppear { refreshAvailability() }
    }

    private func chip(for family: OpenClickyVoiceBackendFamily) -> some View {
        let status = availability.first { $0.family == family }
        let available = status?.isAvailable ?? false
        let selected = companion.selectedVoiceBackendFamily == family

        return Button {
            guard available else { return }
            companion.setSelectedVoiceBackendFamily(family)
        } label: {
            HStack(spacing: 3) {
                Circle()
                    .fill(dotColor(selected: selected, available: available))
                    .frame(width: 5, height: 5)
                Text(style == .compact ? family.shortLabel : family.displayName)
                    .font(.system(size: style == .compact ? 9 : 10, weight: .semibold, design: .rounded))
                if style == .panel, let status {
                    Text(status.statusLabel)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .foregroundColor(labelColor(selected: selected, available: available))
            .padding(.horizontal, style == .compact ? 6 : 8)
            .padding(.vertical, style == .compact ? 3 : 5)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? DS.Colors.accent.opacity(0.28) : Color.white.opacity(available ? 0.08 : 0.03))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        selected ? DS.Colors.accent.opacity(0.7) : Color.white.opacity(available ? 0.12 : 0.05),
                        lineWidth: 0.8
                    )
            )
            .opacity(available ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .help(helpText(for: family, status: status))
        .accessibilityLabel("\(family.displayName) backend")
        .accessibilityValue(selected ? "Selected" : (available ? "Available" : "Unavailable"))
    }

    private func refreshAvailability() {
        availability = OpenClickyProviderDiscovery.availability()
    }

    private func dotColor(selected: Bool, available: Bool) -> Color {
        if !available { return DS.Colors.textTertiary.opacity(0.5) }
        if selected { return DS.Colors.accent }
        return Color.green.opacity(0.85)
    }

    private func labelColor(selected: Bool, available: Bool) -> Color {
        if !available { return DS.Colors.textTertiary }
        if selected { return DS.Colors.accentText }
        return DS.Colors.textSecondary
    }

    private func helpText(for family: OpenClickyVoiceBackendFamily, status: OpenClickyProviderAvailability?) -> String {
        let base = status?.detail ?? family.displayName
        if companion.selectedVoiceBackendFamily == family {
            return "\(family.displayName) (active). \(base)"
        }
        return base
    }
}
