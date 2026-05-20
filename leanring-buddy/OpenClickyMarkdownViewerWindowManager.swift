//
//  OpenClickyMarkdownViewerWindowManager.swift
//  leanring-buddy
//
//  A first-party Markdown document window for OpenClicky-owned notes,
//  memories, agent outputs, and files found by Agent Mode.
//

import AppKit
import SwiftUI

@MainActor
final class OpenClickyMarkdownViewerWindowManager {
    static let shared = OpenClickyMarkdownViewerWindowManager()

    private var window: NSWindow?

    func show(fileURL: URL) {
        let standardizedURL = fileURL.standardizedFileURL

        if window == nil {
            window = makeWindow(fileURL: standardizedURL)
        } else {
            updateWindow(fileURL: standardizedURL)
        }

        window?.title = standardizedURL.lastPathComponent
        OpenClickyWindowLevels.applyPanelDialogLevel(to: window)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateWindow(fileURL: URL) {
        guard let hostingView: NSHostingView<OpenClickyMarkdownViewerView> = OpenClickyLiquidGlassWindowSurface.hostingView(in: window) else {
            window?.contentView = NSHostingView(rootView: OpenClickyMarkdownViewerView(fileURL: fileURL))
            return
        }

        hostingView.rootView = OpenClickyMarkdownViewerView(fileURL: fileURL)
    }

    private func makeWindow(fileURL: URL) -> NSWindow {
        let hostingView = NSHostingView(rootView: OpenClickyMarkdownViewerView(fileURL: fileURL))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = fileURL.lastPathComponent
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor.clear
        window.isReleasedWhenClosed = false
        OpenClickyWindowLevels.applyPanelDialogLevel(to: window)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.center()
        window.minSize = NSSize(width: 720, height: 460)
        window.contentMinSize = NSSize(width: 720, height: 460)
        OpenClickyLiquidGlassWindowSurface.install(
            hostingView: hostingView,
            in: window,
            frame: NSRect(origin: .zero, size: NSSize(width: 1040, height: 760)),
            cornerRadius: 22,
            strength: .expanded
        )
        return window
    }
}

private struct OpenClickyMarkdownViewerView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case preview = "Preview"
        case raw = "Raw"
        case split = "Split"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .preview: "doc.richtext"
            case .raw: "chevron.left.forwardslash.chevron.right"
            case .split: "rectangle.split.2x1"
            }
        }
    }

    let fileURL: URL

    @State private var mode: Mode = .preview
    @State private var documentText = ""
    @State private var lastSavedText = ""
    @State private var statusText = ""
    @State private var loadError: String?

    private var hasUnsavedChanges: Bool {
        documentText != lastSavedText
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()
                .overlay(Color.white.opacity(0.08))

            Group {
                if let loadError {
                    errorPane(loadError)
                } else {
                    contentPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
        .onAppear(perform: loadDocument)
        .onChange(of: fileURL) { _ in
            loadDocument()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if hasUnsavedChanges {
                        Text("Edited")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule(style: .continuous).fill(Color.orange.opacity(0.14)))
                    }
                }

                Text(fileURL.path)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            Picker("Markdown view", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Image(systemName: mode.systemImage)
                        .help(mode.rawValue)
                        .tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 132)
            .help("Markdown view")

            Button(action: revealInFinder) {
                Label("Reveal", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")

            Button(action: reloadDocument) {
                Label("Reload", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Reload")

            Button(action: saveDocument) {
                Label("Save", systemImage: "square.and.arrow.down")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasUnsavedChanges)
            .help("Save")
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var contentPane: some View {
        VStack(spacing: 0) {
            switch mode {
            case .preview:
                markdownPreview(documentText)
            case .raw:
                rawEditor
            case .split:
                HStack(spacing: 0) {
                    rawEditor
                    Divider()
                    markdownPreview(documentText)
                }
            }

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.08))
            }
        }
    }

    private var rawEditor: some View {
        TextEditor(text: $documentText)
            .font(.system(size: 13, design: .monospaced))
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.08))
            .padding(14)
    }

    private func markdownPreview(_ markdown: String) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(OpenClickyMarkdownBlock.blocks(from: markdown)) { block in
                    markdownBlockView(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
    }

    @ViewBuilder
    private func markdownBlockView(_ block: OpenClickyMarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            inlineMarkdownText(block.text)
                .font(.system(size: headingFontSize(for: level), weight: .bold))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        case .paragraph:
            inlineMarkdownText(block.text)
                .font(.system(size: 14))
                .lineSpacing(5)
                .foregroundColor(.primary)
                .textSelection(.enabled)
        case .bullet:
            HStack(alignment: .top, spacing: 9) {
                Text("•")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.top, 1)
                inlineMarkdownText(block.text)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
        case .numbered(let ordinal):
            HStack(alignment: .top, spacing: 9) {
                Text("\(ordinal).")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.top, 1)
                inlineMarkdownText(block.text)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3)
                inlineMarkdownText(block.text)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        case .code:
            Text(block.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.16))
                )
        case .rule:
            Divider()
                .padding(.vertical, 6)
        }
    }

    private func errorPane(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(.orange)
            Text("OpenClicky couldn't open this Markdown file.")
                .font(.system(size: 18, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("Try again", action: loadDocument)
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inlineMarkdownText(_ markdown: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }

        return Text(markdown)
    }

    private func headingFontSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 28
        case 2: return 23
        case 3: return 19
        default: return 16
        }
    }

    private func loadDocument() {
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            documentText = text
            lastSavedText = text
            loadError = nil
            statusText = "Loaded \(fileURL.lastPathComponent)"
        } catch {
            loadError = error.localizedDescription
            statusText = ""
        }
    }

    private func reloadDocument() {
        loadDocument()
    }

    private func saveDocument() {
        do {
            try documentText.write(to: fileURL, atomically: true, encoding: .utf8)
            lastSavedText = documentText
            loadError = nil
            statusText = "Saved \(fileURL.lastPathComponent)"
        } catch {
            statusText = "Save failed: \(error.localizedDescription)"
        }
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

private struct OpenClickyMarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int)
        case paragraph
        case bullet
        case numbered(Int)
        case quote
        case code
        case rule
    }

    let id: Int
    let kind: Kind
    let text: String

    static func blocks(from markdown: String) -> [OpenClickyMarkdownBlock] {
        var blocks: [OpenClickyMarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var isInsideCodeFence = false
        var nextID = 0

        func appendBlock(kind: Kind, text: String) {
            blocks.append(OpenClickyMarkdownBlock(id: nextID, kind: kind, text: text))
            nextID += 1
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            appendBlock(kind: .paragraph, text: paragraphLines.joined(separator: " "))
            paragraphLines.removeAll()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if isInsideCodeFence {
                    appendBlock(kind: .code, text: codeLines.joined(separator: "\n"))
                    codeLines.removeAll()
                    isInsideCodeFence = false
                } else {
                    flushParagraph()
                    isInsideCodeFence = true
                }
                continue
            }

            if isInsideCodeFence {
                codeLines.append(rawLine)
                continue
            }

            guard !trimmed.isEmpty else {
                flushParagraph()
                continue
            }

            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), trimmed.count >= 3 {
                flushParagraph()
                appendBlock(kind: .rule, text: "")
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                appendBlock(kind: .heading(level: heading.level), text: heading.text)
                continue
            }

            if let bullet = bulletText(from: trimmed) {
                flushParagraph()
                appendBlock(kind: .bullet, text: bullet)
                continue
            }

            if let numbered = numberedItem(from: trimmed) {
                flushParagraph()
                appendBlock(kind: .numbered(numbered.ordinal), text: numbered.text)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                appendBlock(kind: .quote, text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            paragraphLines.append(trimmed)
        }

        if isInsideCodeFence {
            appendBlock(kind: .code, text: codeLines.joined(separator: "\n"))
        }
        flushParagraph()

        if blocks.isEmpty {
            appendBlock(kind: .paragraph, text: "This Markdown file is empty.")
        }

        return blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let markerCount = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markerCount),
              line.dropFirst(markerCount).first == " " else {
            return nil
        }

        return (markerCount, String(line.dropFirst(markerCount + 1)))
    }

    private static func bulletText(from line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numberedItem(from line: String) -> (ordinal: Int, text: String)? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let prefix = line[..<dotIndex]
        guard let ordinal = Int(prefix),
              line.index(after: dotIndex) < line.endIndex,
              line[line.index(after: dotIndex)] == " " else {
            return nil
        }

        return (ordinal, String(line[line.index(dotIndex, offsetBy: 2)...]))
    }
}
