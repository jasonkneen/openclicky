import AppKit
import SwiftUI

struct ClickyKnowledgeIndexSummaryView: View {
    var index: WikiManager.Index
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
                Text(displayText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineSpacing(4)
                    .lineLimit(4)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)
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

@MainActor
final class WikiViewerPanelManager {
    typealias CreateMemoryHandler = (String, String) throws -> WikiManager.Article

    private var panel: NSWindow?

    func show(
        index: WikiManager.Index,
        sourceRootURL: URL?,
        onCreateMemory: CreateMemoryHandler? = nil
    ) {
        if panel == nil {
            panel = makePanel(index: index, sourceRootURL: sourceRootURL, onCreateMemory: onCreateMemory)
        } else {
            updatePanel(index: index, sourceRootURL: sourceRootURL, onCreateMemory: onCreateMemory)
        }

        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updatePanel(
        index: WikiManager.Index,
        sourceRootURL: URL?,
        onCreateMemory: CreateMemoryHandler?
    ) {
        guard let hostingView = panel?.contentView as? NSHostingView<ClickyMemoryWindowView> else {
            return
        }

        hostingView.rootView = ClickyMemoryWindowView(
            index: index,
            sourceRootURL: sourceRootURL,
            onCreateMemory: onCreateMemory
        )
    }

    private func makePanel(
        index: WikiManager.Index,
        sourceRootURL: URL?,
        onCreateMemory: CreateMemoryHandler?
    ) -> NSWindow {
        let hostingView = NSHostingView(rootView: ClickyMemoryWindowView(
            index: index,
            sourceRootURL: sourceRootURL,
            onCreateMemory: onCreateMemory
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Memory"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor.clear
        window.isReleasedWhenClosed = false
        window.center()
        window.setContentSize(NSSize(width: 1180, height: 860))
        window.minSize = NSSize(width: 760, height: 520)
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.contentView = hostingView
        return window
    }
}

private struct ClickyMemoryWindowView: View {
    var index: WikiManager.Index
    var sourceRootURL: URL?
    var onCreateMemory: WikiViewerPanelManager.CreateMemoryHandler?

    @State private var searchText = ""
    @State private var selectedEntryID: WikiViewerEntry.ID?
    @State private var createdArticles: [WikiManager.Article] = []
    @State private var isCreatingMemory = false
    @State private var newMemoryTitle = ""
    @State private var newMemoryBody = ""
    @State private var createMemoryError: String?

    private var entries: [WikiViewerEntry] {
        index
            .combined(with: WikiManager.Index(articles: createdArticles, skills: []))
            .viewerEntries
    }

    private var filteredEntries: [WikiViewerEntry] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearchText.isEmpty else {
            return entries
        }

        return entries.filter { entry in
            entry.searchableText.localizedCaseInsensitiveContains(trimmedSearchText)
        }
    }

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedEntry: WikiViewerEntry? {
        if isCreatingMemory {
            return nil
        }

        if let selectedEntryID {
            return filteredEntries.first(where: { $0.id == selectedEntryID })
                ?? entries.first(where: { $0.id == selectedEntryID })
        }
        return filteredEntries.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 330)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Colors.background)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Memory")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Text("\(filteredEntries.count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)

                if onCreateMemory != nil {
                    Button(action: beginCreatingMemory) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                Button(action: revealInFinder) {
                    Image(systemName: "folder")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 14)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)

                        TextField("Search memory", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    .padding(.horizontal, 10)
                )
                .frame(height: 38)
                .padding(.horizontal, 18)
                .padding(.bottom, 16)

            if filteredEntries.isEmpty {
                memoryEmptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredEntries) { entry in
                            memoryEntryRow(entry)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(Color.white.opacity(0.02))
    }

    private func memoryEntryRow(_ entry: WikiViewerEntry) -> some View {
        Button(action: { selectedEntryID = entry.id }) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(entry.kind == .article ? DS.Colors.accentText : DS.Colors.warning.opacity(0.9))
                    .frame(width: 9, height: 9)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)

                    Text(entry.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selectedEntry?.id == entry.id ? DS.Colors.accent.opacity(0.16) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var memoryEmptyState: some View {
        VStack(spacing: 10) {
            Spacer()

            Image(systemName: "archivebox")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(Color.white.opacity(0.18))

            Text(isSearchActive ? "No matches found" : "No articles yet")
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            Text(isSearchActive ? "Try a different search" : "Say \"save\" to start")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary.opacity(0.8))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailPane: some View {
        if isCreatingMemory {
            createMemoryPane
        } else if let selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Text(selectedEntry.kind.label.uppercased())
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundColor(selectedEntry.kind == .article ? DS.Colors.accentText : DS.Colors.warning)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.06)))

                        Text(selectedEntry.relativePath)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                            .textSelection(.enabled)

                        Spacer()
                    }

                    Text(selectedEntry.title)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(selectedEntry.body)
                        .font(.system(size: 14))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 30)
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "doc")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(Color.white.opacity(0.12))

                Text("Select an article")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var createMemoryPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text("NEW MEMORY")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(DS.Colors.accentText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.06)))

                Spacer()

                Button("Cancel", action: cancelCreatingMemory)
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.textSecondary)

                Button("Save", action: saveMemory)
                    .buttonStyle(.borderedProminent)
                    .disabled(newMemoryTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || newMemoryBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextField("Title", text: $newMemoryTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.vertical, 8)

            TextEditor(text: $newMemoryBody)
                .font(.system(size: 14))
                .foregroundColor(DS.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(minHeight: 360)

            if let createMemoryError {
                Text(createMemoryError)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.destructiveText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 30)
    }

    private func beginCreatingMemory() {
        isCreatingMemory = true
        selectedEntryID = nil
        createMemoryError = nil
    }

    private func cancelCreatingMemory() {
        isCreatingMemory = false
        newMemoryTitle = ""
        newMemoryBody = ""
        createMemoryError = nil
    }

    private func saveMemory() {
        guard let onCreateMemory else { return }

        do {
            let article = try onCreateMemory(newMemoryTitle, newMemoryBody)
            createdArticles.append(article)
            selectedEntryID = article.id
            isCreatingMemory = false
            newMemoryTitle = ""
            newMemoryBody = ""
            createMemoryError = nil
        } catch {
            createMemoryError = error.localizedDescription
        }
    }

    private func revealInFinder() {
        guard let sourceRootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([sourceRootURL])
    }
}
