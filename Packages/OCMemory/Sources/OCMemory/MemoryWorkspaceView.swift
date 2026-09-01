import SwiftUI
import AppKit
import OCCore
import OCUI

@MainActor
public final class WikiViewerPanelManager {
    public typealias CreateMemoryHandler = (String, String) throws -> WikiManager.Article

    private var panel: NSWindow?

    public init() {}

    public func show(
        index: WikiManager.Index,
        sourceRootURL: URL?,
        onCreateMemory: CreateMemoryHandler? = nil
    ) {
        if panel == nil {
            panel = makePanel(index: index, sourceRootURL: sourceRootURL, onCreateMemory: onCreateMemory)
        } else {
            updatePanel(index: index, sourceRootURL: sourceRootURL, onCreateMemory: onCreateMemory)
        }

        OpenClickyWindowLevels.applyPanelDialogLevel(to: panel)
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updatePanel(
        index: WikiManager.Index,
        sourceRootURL: URL?,
        onCreateMemory: CreateMemoryHandler?
    ) {
        guard let hostingView: NSHostingView<ClickyMemoryWindowView> = OpenClickyLiquidGlassWindowSurface.hostingView(in: panel) else {
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
        OpenClickyWindowLevels.applyPanelDialogLevel(to: window)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.center()
        window.setContentSize(NSSize(width: 1180, height: 860))
        window.minSize = NSSize(width: 760, height: 520)
        window.contentMinSize = NSSize(width: 760, height: 520)
        OpenClickyLiquidGlassWindowSurface.install(
            hostingView: hostingView,
            in: window,
            frame: NSRect(origin: .zero, size: NSSize(width: 1180, height: 860)),
            cornerRadius: 22,
            strength: .expanded
        )
        return window
    }
}

public struct ClickyMemoryWindowView: View {
    public var index: WikiManager.Index
    public var sourceRootURL: URL?
    public var onCreateMemory: WikiViewerPanelManager.CreateMemoryHandler?

    @State private var searchText = ""
    @State private var selectedEntryID: WikiViewerEntry.ID?
    @State private var createdArticles: [WikiManager.Article] = []
    @State private var isCreatingMemory = false
    @State private var newMemoryTitle = ""
    @State private var newMemoryBody = ""
    @State private var createMemoryError: String?

    public init(
        index: WikiManager.Index,
        sourceRootURL: URL?,
        onCreateMemory: WikiViewerPanelManager.CreateMemoryHandler? = nil
    ) {
        self.index = index
        self.sourceRootURL = sourceRootURL
        self.onCreateMemory = onCreateMemory
    }

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

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 330)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
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
        .glassEffect(
            .regular.tint(DS.Colors.accent.opacity(0.045)),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .padding(10)
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
