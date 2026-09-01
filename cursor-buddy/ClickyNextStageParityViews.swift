import AppKit
import SwiftUI
import OCCore

struct ClickyKnowledgeIndexSummaryView: View {
    var index: OCCore.WikiManager.Index
    var openMemory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bundled knowledge")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("\(index.articles.count) wiki pages • \(index.skills.count) skills")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()

                Button(action: openMemory) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if !index.skills.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(index.skills.prefix(3))) { skill in
                        Text(skill.identifier)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.055)))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }
}

struct ClickyPermissionGuideSection: View {
    var viewState: PermissionGuideAssistant.ViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewState.headline)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(viewState.summary)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 4) {
                ForEach(viewState.steps) { step in
                    HStack(spacing: 8) {
                        Image(systemName: step.systemImageName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(step.status == .granted ? DS.Colors.success : DS.Colors.warning)
                            .frame(width: 15)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DS.Colors.textSecondary)
                            if viewState.primaryStep?.kind == step.kind {
                                Text(step.detail)
                                    .font(.system(size: 9))
                                    .foregroundColor(DS.Colors.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(step.status == .granted ? "Granted" : "Needed")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(step.status == .granted ? DS.Colors.success : DS.Colors.warning)
                    }
                    .padding(.vertical, 4)
                }
            }

            if let primaryStep = viewState.primaryStep {
                Button(action: { NSWorkspace.shared.open(primaryStep.settingsURL) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                        Text("Open \(primaryStep.title)")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }
}

struct ClickyResponseCardActionHandlers {
    var dismiss: (() -> Void)? = nil
    var runSuggestedNextAction: ((String) -> Void)? = nil
    var openTextFollowUp: (() -> Void)? = nil
    var openVoiceFollowUp: (() -> Void)? = nil
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = makeRows(
            proposalWidth: proposal.width,
            subviews: subviews
        )
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.reduce(CGFloat.zero) { partial, row in
            partial + row.height
        } + rowSpacing * CGFloat(max(rows.count - 1, 0))

        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = makeRows(
            proposalWidth: bounds.width,
            subviews: subviews
        )

        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func makeRows(proposalWidth: CGFloat?, subviews: Subviews) -> [FlowRow] {
        let availableWidth = max(1, proposalWidth ?? CGFloat.greatestFiniteMagnitude)
        var rows: [FlowRow] = []
        var currentItems: [FlowItem] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let itemWidth = min(size.width, availableWidth)
            let itemSize = CGSize(width: itemWidth, height: size.height)
            let proposedWidth = currentItems.isEmpty ? itemWidth : currentWidth + spacing + itemWidth

            if proposedWidth > availableWidth, !currentItems.isEmpty {
                rows.append(FlowRow(items: currentItems, width: currentWidth, height: currentHeight))
                currentItems = [FlowItem(subview: subview, size: itemSize)]
                currentWidth = itemWidth
                currentHeight = itemSize.height
            } else {
                currentItems.append(FlowItem(subview: subview, size: itemSize))
                currentWidth = proposedWidth
                currentHeight = max(currentHeight, itemSize.height)
            }
        }

        if !currentItems.isEmpty {
            rows.append(FlowRow(items: currentItems, width: currentWidth, height: currentHeight))
        }

        return rows
    }

    private struct FlowItem {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct FlowRow {
        let items: [FlowItem]
        let width: CGFloat
        let height: CGFloat
    }
}

struct ClickyResponseCardCompactView: View {
    var card: ClickyResponseCard
    var actionHandlers = ClickyResponseCardActionHandlers()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Text(card.displayTitle)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundColor(DS.Colors.textSecondary.opacity(0.96))
                    .lineLimit(1)
                    .kerning(0.35)

                Spacer()

                if let dismiss = actionHandlers.dismiss {
                    Button(action: dismiss) {
                        Text(card.completionLabel)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(DS.Colors.accentText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(DS.Colors.accent.opacity(0.22)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Dismiss")
                } else {
                    Text(card.completionLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.accentText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(DS.Colors.accent.opacity(0.22)))
                }

                if let dismiss = actionHandlers.dismiss {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Dismiss")
                }
            }

            if let displayText = sanitizedDisplayText(card.displayText) {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(displayText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineSpacing(4)
                        .lineLimit(nil)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220, alignment: .top)
                .mask(ClickyResponseCardScrollFadeMask())
            }

            if !openableLinks.isEmpty {
                FlowLayout(spacing: 8, rowSpacing: 8) {
                    ForEach(openableLinks) { link in
                        responseActionPill(
                            title: link.buttonTitle,
                            systemImageName: link.systemImageName,
                            foregroundColor: DS.Colors.textPrimary,
                            backgroundColor: Color.white.opacity(0.08)
                        ) {
                            NSWorkspace.shared.open(link.url)
                        }
                    }
                }
            }

            if !card.suggestedNextActions.isEmpty {
                FlowLayout(spacing: 8, rowSpacing: 8) {
                    ForEach(card.suggestedNextActions, id: \.self) { actionTitle in
                        responseActionPill(
                            title: actionTitle,
                            systemImageName: nil,
                            foregroundColor: DS.Colors.textPrimary,
                            backgroundColor: Color.white.opacity(0.08)
                        ) {
                            actionHandlers.runSuggestedNextAction?(actionTitle)
                        }
                    }
                }
            }

            if actionHandlers.openTextFollowUp != nil || actionHandlers.openVoiceFollowUp != nil {
                FlowLayout(spacing: 8, rowSpacing: 8) {
                    if let openTextFollowUp = actionHandlers.openTextFollowUp {
                        responseActionPill(
                            title: "AI Text",
                            systemImageName: "character.cursor.ibeam",
                            foregroundColor: DS.Colors.textPrimary,
                            backgroundColor: Color.white.opacity(0.08),
                            action: openTextFollowUp
                        )
                    }

                    if let openVoiceFollowUp = actionHandlers.openVoiceFollowUp {
                        responseActionPill(
                            title: "Voice",
                            systemImageName: "mic",
                            foregroundColor: DS.Colors.textPrimary,
                            backgroundColor: Color.white.opacity(0.08),
                            action: openVoiceFollowUp
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.13, blue: 0.20),
                            Color(red: 0.09, green: 0.11, blue: 0.17)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.32), radius: 24, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }


    private var openableLinks: [OpenClickyOpenableLink] {
        OpenClickyOpenableLinkExtractor.links(in: card.rawText, limit: 3)
    }

    private func sanitizedDisplayText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No response text yet." }
        let lowered = trimmed.lowercased()
        if lowered == "checking the work" || lowered == "check the work" {
            return nil
        }
        return trimmed
    }

    private func responseActionPill(
        title: String,
        systemImageName: String?,
        foregroundColor: Color,
        backgroundColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImageName {
                    Image(systemName: systemImageName)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(backgroundColor))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

private struct ClickyResponseCardScrollFadeMask: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black, location: 0.045),
                .init(color: .black, location: 0.955),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct ClickyHandoffQueueView: View {
    var queuedRegion: HandoffQueuedRegionScreenshot?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: queuedRegion == nil ? "rectangle.dashed" : "rectangle.and.hand.point.up.left.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(queuedRegion == nil ? DS.Colors.textTertiary : DS.Colors.accentText)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text("Handoff")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private var subtitle: String {
        guard let queuedRegion else {
            return "Region payload state ready"
        }
        let rect = queuedRegion.selection.captureRect
        return "\(Int(rect.width))×\(Int(rect.height)) region • \(queuedRegion.imageByteCount) bytes"
    }
}
