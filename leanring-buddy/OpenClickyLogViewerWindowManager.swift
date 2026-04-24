import AppKit
import SwiftUI

@MainActor
final class OpenClickyLogViewerWindowManager {
    private var window: NSWindow?
    private let windowSize = NSSize(width: 1120, height: 720)
    private let minimumWindowSize = NSSize(width: 940, height: 580)

    func show() {
        if window == nil {
            createWindow()
        } else if let hostingView = window?.contentView as? NSHostingView<OpenClickyLogViewerView> {
            hostingView.rootView = OpenClickyLogViewerView()
        }

        guard let logWindow = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        logWindow.center()
        logWindow.orderFrontRegardless()
        logWindow.makeKeyAndOrderFront(nil)
        logWindow.makeMain()
    }

    private func createWindow() {
        let logWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        logWindow.title = "OpenClicky Logs"
        logWindow.minSize = minimumWindowSize
        logWindow.isReleasedWhenClosed = false
        logWindow.titlebarAppearsTransparent = true
        logWindow.toolbarStyle = .unified
        logWindow.collectionBehavior.insert(.moveToActiveSpace)
        logWindow.center()

        let hostingView = NSHostingView(rootView: OpenClickyLogViewerView())
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]
        logWindow.contentView = hostingView

        window = logWindow
    }
}

private struct OpenClickyLogViewerEntry: Identifiable, Equatable {
    let id: String
    let sourceFileURL: URL
    let sourceLineNumber: Int
    let timestamp: String
    let lane: String
    let direction: String
    let event: String
    let fieldsText: String
    let rawJSON: String

    var searchableText: String {
        "\(timestamp) \(lane) \(direction) \(event) \(fieldsText) \(rawJSON)"
    }
}

private struct OpenClickyLogReviewComment: Identifiable, Equatable {
    let id: String
    let createdAt: String
    let event: String
    let source: String
    let comment: String
}

struct OpenClickyLogViewerView: View {
    @State private var logFiles: [URL] = []
    @State private var selectedLogFile: URL?
    @State private var entries: [OpenClickyLogViewerEntry] = []
    @State private var selectedEntryID: String?
    @State private var searchText = ""
    @State private var laneFilter = "All"
    @State private var directionFilter = "All"
    @State private var eventFilter = ""
    @State private var commentText = ""
    @State private var reviewComments: [OpenClickyLogReviewComment] = []
    @State private var statusMessage = ""

    private let laneOptions = ["All", "voice", "agent", "app"]
    private let directionOptions = ["All", "outgoing", "incoming", "internal"]

    private var filteredEntries: [OpenClickyLogViewerEntry] {
        entries.filter { entry in
            let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let eventSearch = eventFilter.trimmingCharacters(in: .whitespacesAndNewlines)

            if laneFilter != "All", entry.lane != laneFilter {
                return false
            }
            if directionFilter != "All", entry.direction != directionFilter {
                return false
            }
            if !eventSearch.isEmpty, !entry.event.localizedCaseInsensitiveContains(eventSearch) {
                return false
            }
            if !search.isEmpty, !entry.searchableText.localizedCaseInsensitiveContains(search) {
                return false
            }
            return true
        }
    }

    private var selectedEntry: OpenClickyLogViewerEntry? {
        guard let selectedEntryID else { return filteredEntries.first }
        return entries.first { $0.id == selectedEntryID } ?? filteredEntries.first
    }

    var body: some View {
        HStack(spacing: 0) {
            fileSidebar

            Divider()

            VStack(spacing: 0) {
                filterBar
                Divider()

                HStack(spacing: 0) {
                    entryList
                        .frame(minWidth: 340, idealWidth: 420, maxWidth: 480)

                    Divider()

                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 940, minHeight: 580)
        .onAppear {
            reloadAll()
        }
    }

    private var fileSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Log Files")
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(logFiles, id: \.path) { fileURL in
                        Button {
                            selectLogFile(fileURL)
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 13, weight: .medium))
                                Text(fileURL.lastPathComponent)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .foregroundColor(selectedLogFile == fileURL ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selectedLogFile == fileURL ? Color.accentColor.opacity(0.16) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    reloadAll()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    NSWorkspace.shared.open(OpenClickyMessageLogStore.shared.logDirectory)
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                Button {
                    OpenClickyMessageLogStore.shared.ensureAgentReviewCommentsFile()
                    NSWorkspace.shared.open(OpenClickyMessageLogStore.shared.agentReviewCommentsFile)
                } label: {
                    Label("Agent Comments", systemImage: "checklist")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: 210)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Search logs", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)

                TextField("Event filter", text: $eventFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Picker("Lane", selection: $laneFilter) {
                    ForEach(laneOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .frame(width: 130)

                Picker("Direction", selection: $directionFilter) {
                    ForEach(directionOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .frame(width: 150)
            }

            HStack {
                Text("\(filteredEntries.count) of \(entries.count) entries")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var entryList: some View {
        List(selection: $selectedEntryID) {
            ForEach(filteredEntries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(entry.event)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(entry.direction)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 8) {
                        Text(entry.lane)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.accentColor.opacity(0.14))
                            )
                        Text(entry.timestamp)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
                .tag(entry.id)
            }
        }
        .listStyle(.inset)
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let entry = selectedEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(for: entry)
                        jsonBlock(title: "Fields", text: entry.fieldsText)
                        jsonBlock(title: "Raw JSONL Entry", text: entry.rawJSON)
                        commentEditor(for: entry)
                        reviewCommentList
                    }
                    .padding(18)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundColor(.secondary)
                    Text("No log entry selected")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(for entry: OpenClickyLogViewerEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.event)
                .font(.system(size: 18, weight: .semibold))
            HStack(spacing: 8) {
                metadataPill(entry.lane)
                metadataPill(entry.direction)
                metadataPill("\(entry.sourceFileURL.lastPathComponent):\(entry.sourceLineNumber)")
            }
            Text(entry.timestamp)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
        }
    }

    private func metadataPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color(nsColor: .controlBackgroundColor))
            )
            .foregroundColor(.secondary)
    }

    private func jsonBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            ScrollView(.horizontal) {
                Text(text.isEmpty ? "{}" : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func commentEditor(for entry: OpenClickyLogViewerEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Flag For Agent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            TextEditor(text: $commentText)
                .font(.system(size: 12, weight: .regular))
                .frame(minHeight: 82)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            HStack {
                Text("Saved comments are written to \(OpenClickyMessageLogStore.shared.agentReviewCommentsFile.path)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
                Button {
                    saveComment(for: entry)
                } label: {
                    Label("Save Comment", systemImage: "flag")
                }
                .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var reviewCommentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Comments")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            if reviewComments.isEmpty {
                Text("No flagged log comments yet.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.secondary)
            } else {
                ForEach(reviewComments.prefix(6)) { comment in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(comment.event)
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(comment.source)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(.secondary)
                        }
                        Text(comment.comment)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.primary)
                        Text(comment.createdAt)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
            }
        }
    }

    private func reloadAll() {
        logFiles = OpenClickyMessageLogStore.shared.availableMessageLogFiles()
        if selectedLogFile == nil {
            selectedLogFile = logFiles.first
        }
        if let selectedLogFile {
            loadEntries(from: selectedLogFile)
        }
        loadReviewComments()
    }

    private func selectLogFile(_ fileURL: URL) {
        selectedLogFile = fileURL
        selectedEntryID = nil
        commentText = ""
        loadEntries(from: fileURL)
    }

    private func loadEntries(from fileURL: URL) {
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            entries = lines.enumerated().compactMap { index, line in
                parseEntry(rawLine: String(line), sourceFileURL: fileURL, sourceLineNumber: index + 1)
            }
            selectedEntryID = filteredEntries.first?.id
            statusMessage = "Loaded \(entries.count) entries"
        } catch {
            entries = []
            selectedEntryID = nil
            statusMessage = "Could not load log: \(error.localizedDescription)"
        }
    }

    private func parseEntry(rawLine: String, sourceFileURL: URL, sourceLineNumber: Int) -> OpenClickyLogViewerEntry? {
        guard let data = rawLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return OpenClickyLogViewerEntry(
                id: "\(sourceFileURL.path):\(sourceLineNumber)",
                sourceFileURL: sourceFileURL,
                sourceLineNumber: sourceLineNumber,
                timestamp: "",
                lane: "unknown",
                direction: "unknown",
                event: "invalid-json",
                fieldsText: rawLine,
                rawJSON: rawLine
            )
        }

        let fields = object["fields"] ?? [:]
        let fieldsText = prettyJSONString(fields)
        return OpenClickyLogViewerEntry(
            id: "\(sourceFileURL.path):\(sourceLineNumber)",
            sourceFileURL: sourceFileURL,
            sourceLineNumber: sourceLineNumber,
            timestamp: object["timestamp"] as? String ?? "",
            lane: object["lane"] as? String ?? "unknown",
            direction: object["direction"] as? String ?? "unknown",
            event: object["event"] as? String ?? "unknown",
            fieldsText: fieldsText,
            rawJSON: prettyJSONString(object, fallback: rawLine)
        )
    }

    private func saveComment(for entry: OpenClickyLogViewerEntry) {
        OpenClickyMessageLogStore.shared.appendReviewComment(
            sourceLogFile: entry.sourceFileURL,
            sourceLineNumber: entry.sourceLineNumber,
            entryID: entry.id,
            entryTimestamp: entry.timestamp,
            lane: entry.lane,
            direction: entry.direction,
            event: entry.event,
            rawEntry: entry.rawJSON,
            comment: commentText
        )
        commentText = ""
        loadReviewComments()
        statusMessage = "Saved comment for \(entry.event)"
    }

    private func loadReviewComments() {
        let fileURL = OpenClickyMessageLogStore.shared.reviewCommentsFile
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            reviewComments = []
            return
        }

        reviewComments = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .reversed()
            .compactMap { line in
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                let sourcePath = object["sourceLogFile"] as? String ?? ""
                let sourceLine = object["sourceLineNumber"] as? Int ?? 0
                return OpenClickyLogReviewComment(
                    id: object["id"] as? String ?? UUID().uuidString,
                    createdAt: object["createdAt"] as? String ?? "",
                    event: object["event"] as? String ?? "unknown",
                    source: "\(URL(fileURLWithPath: sourcePath).lastPathComponent):\(sourceLine)",
                    comment: object["comment"] as? String ?? ""
                )
            }
    }

    private func prettyJSONString(_ value: Any, fallback: String = "") -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return text
    }
}
