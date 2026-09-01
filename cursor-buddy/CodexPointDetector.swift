//
//  CodexPointDetector.swift
//  OpenClicky
//
//  Uses the local Codex runtime and image input to produce OpenClicky
//  [POINT:x,y:label] tags without requiring an OpenAI API key in OpenClicky.
//

import CoreGraphics
import Foundation

final class CodexPointDetector {
    private static let codexRuntimeCompatibilityFallbackModel = "gpt-5.6-luna"

    private let model: String
    private let fileManager: FileManager
    private let homeManager: CodexHomeManager

    init(
        model: String,
        fileManager: FileManager = .default,
        homeManager: CodexHomeManager = CodexHomeManager()
    ) {
        self.model = model
        self.fileManager = fileManager
        self.homeManager = homeManager
    }

    func detectPointTag(
        screenshotData: Data,
        screenshotLabel: String,
        userQuestion: String,
        systemPrompt: String,
        displayWidthInPixels: Int,
        displayHeightInPixels: Int
    ) async throws -> String {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let imageURL = try writeImage(screenshotData, name: "screen", to: temporaryDirectory)

        let prompt = """
        \(systemPrompt)

        Screenshot label: \(screenshotLabel)
        Screenshot dimensions: \(displayWidthInPixels)x\(displayHeightInPixels) pixels.

        User request:
        \(userQuestion)

        Return only the final user-facing sentence plus exactly one [POINT:x,y:label] tag. Use [POINT:none] if there is no directly relevant visible target, the target is ambiguous, or the request is conceptual.
        """

        return try await runCodex(prompt: prompt, imageURLs: [imageURL], workingDirectory: temporaryDirectory)
    }

    func analyzeImageResponse(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        var imageURLs: [URL] = []
        var imageLines: [String] = []
        for (index, image) in images.enumerated() {
            let imageURL = try writeImage(image.data, name: "screen-\(index + 1)", to: temporaryDirectory)
            imageURLs.append(imageURL)
            imageLines.append("\(index + 1). \(image.label): \(imageURL.path)")
        }

        var historyLines: [String] = []
        for entry in conversationHistory {
            historyLines.append("User: \(entry.userPlaceholder)")
            historyLines.append("OpenClicky: \(entry.assistantResponse)")
        }

        let prompt = """
        \(systemPrompt)

        Recent conversation:
        \(historyLines.isEmpty ? "none" : historyLines.joined(separator: "\n"))

        Screen context:
        \(imageLines.isEmpty ? "No screenshots are attached." : imageLines.joined(separator: "\n"))

        User request:
        \(userPrompt)
        """

        let text = try await runCodex(prompt: prompt, imageURLs: imageURLs, workingDirectory: temporaryDirectory)
        await MainActor.run {
            onTextChunk(text)
        }
        return text
    }

    func detectDisplayLocalPoint(
        screenshotData: Data,
        screenshotLabel: String,
        userQuestion: String,
        displayWidthInPixels: Int,
        displayHeightInPixels: Int,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int
    ) async -> CGPoint? {
        let systemPrompt = """
        You are OpenClicky's screen pointing detector. Look at the screenshot and identify the single visible UI element only when it directly answers the user's current request. Do not select unrelated, nearby, generic, decorative, stale, or merely available UI. If the request is conceptual, the target is not visible, or relevance is uncertain, return [POINT:none].

        Coordinates must use screenshot pixel space. Origin is top-left, x increases rightward, y increases downward. Return only this exact format:
        [POINT:x,y:label]
        """

        do {
            let response = try await detectPointTag(
                screenshotData: screenshotData,
                screenshotLabel: screenshotLabel,
                userQuestion: userQuestion,
                systemPrompt: systemPrompt,
                displayWidthInPixels: displayWidthInPixels,
                displayHeightInPixels: displayHeightInPixels
            )

            guard let point = Self.parsePoint(from: response) else { return nil }
            let clampedX = max(0, min(point.x, CGFloat(displayWidthInPixels)))
            let clampedY = max(0, min(point.y, CGFloat(displayHeightInPixels)))
            let scaledX = (clampedX / CGFloat(max(1, displayWidthInPixels))) * CGFloat(displayWidthInPoints)
            let scaledYTopLeftOrigin = (clampedY / CGFloat(max(1, displayHeightInPixels))) * CGFloat(displayHeightInPoints)
            let scaledYBottomLeftOrigin = CGFloat(displayHeightInPoints) - scaledYTopLeftOrigin
            return CGPoint(x: scaledX, y: scaledYBottomLeftOrigin)
        } catch {
            print("CodexPointDetector failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func writeImage(_ imageData: Data, name: String, to directory: URL) throws -> URL {
        let imageExtension = imageData.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
        let imageURL = directory.appendingPathComponent("\(name).\(imageExtension)", isDirectory: false)
        try imageData.write(to: imageURL, options: [.atomic])
        return imageURL
    }

    private func runCodex(prompt: String, imageURLs: [URL], workingDirectory: URL) async throws -> String {
        _ = try homeManager.prepare(bundle: .main)
        let executable = try CodexRuntimeLocator.codexExecutableURL(bundle: .main)
        let outputURL = workingDirectory.appendingPathComponent("codex-point-response.txt", isDirectory: false)

        var arguments = Self.codexExecArguments(
            model: model,
            imageURLs: imageURLs,
            workingDirectory: workingDirectory,
            outputURL: outputURL,
            prompt: prompt
        )

        let stdout: String
        do {
            stdout = try await Self.runCodexProcess(
                executableURL: executable,
                arguments: arguments,
                codexHome: homeManager.codexHomeDirectory,
                runtimeExecutableURL: executable
            )
        } catch {
            guard Self.shouldRetryWithCompatibilityFallback(error),
                  model != Self.codexRuntimeCompatibilityFallbackModel else {
                throw error
            }

            OpenClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "codex_point_detector.model_fallback",
                fields: [
                    "requestedModel": model,
                    "fallbackModel": Self.codexRuntimeCompatibilityFallbackModel,
                    "error": error.localizedDescription
                ]
            )
            arguments = argumentsWithModel(Self.codexRuntimeCompatibilityFallbackModel, from: arguments)
            stdout = try await Self.runCodexProcess(
                executableURL: executable,
                arguments: arguments,
                codexHome: homeManager.codexHomeDirectory,
                runtimeExecutableURL: executable
            )
        }
        let lastMessage = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return lastMessage?.isEmpty == false ? lastMessage! : stdout
    }

    private static func codexExecArguments(
        model: String,
        imageURLs: [URL],
        workingDirectory: URL,
        outputURL: URL,
        prompt: String
    ) -> [String] {
        var arguments = ["exec"]
        for imageURL in imageURLs {
            arguments.append(contentsOf: ["--image", imageURL.path])
        }
        arguments.append(contentsOf: [
            "--model", model,
            // SECURITY: the point detector's only job is to read the screenshot
            // and return a `[POINT:x,y]` coordinate. It previously ran with
            // `--sandbox danger-full-access` + `--dangerously-bypass-approvals-
            // and-sandbox`, granting arbitrary shell/filesystem reach to a
            // process driven by untrusted screen pixels (classic screenshot
            // prompt-injection → arbitrary command execution). `workspace-write`
            // scoped to the temp working dir is sufficient: it can read the
            // image args and write its `--output-last-message` file, nothing
            // else. approval_policy stays "never" (non-interactive subprocess).
            "--sandbox", "workspace-write",
            "-c", "approval_policy=\"never\"",
            "--skip-git-repo-check",
            "--cd", workingDirectory.path,
            "--output-last-message", outputURL.path,
            prompt
        ])
        return arguments
    }

    #if DEBUG
    static func testCodexExecArguments(model: String = "gpt-5.6-sol") -> [String] {
        let directory = URL(fileURLWithPath: "/tmp/OpenClickyCodexPointDetectorTest", isDirectory: true)
        return codexExecArguments(
            model: model,
            imageURLs: [directory.appendingPathComponent("screen.jpg", isDirectory: false)],
            workingDirectory: directory,
            outputURL: directory.appendingPathComponent("codex-point-response.txt", isDirectory: false),
            prompt: "click the target"
        )
    }
    #endif

    private static func shouldRetryWithCompatibilityFallback(_ error: Error) -> Bool {
        let message = error.localizedDescription
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return message.contains("requires a newer version of codex")
            || message.contains("please upgrade to the latest app or cli")
    }

    private func argumentsWithModel(_ replacementModel: String, from arguments: [String]) -> [String] {
        var updatedArguments = arguments
        guard let modelFlagIndex = updatedArguments.firstIndex(of: "--model"),
              updatedArguments.indices.contains(modelFlagIndex + 1) else {
            return updatedArguments
        }
        updatedArguments[modelFlagIndex + 1] = replacementModel
        return updatedArguments
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenClickyCodexPointDetector", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func runCodexProcess(
        executableURL: URL,
        arguments: [String],
        codexHome: URL,
        runtimeExecutableURL: URL
    ) async throws -> String {
        var environment = CodexProcessManager.baseEnvironment(
            codexHome: codexHome,
            runtimeExecutableURL: runtimeExecutableURL
        )
        if environment["OPENAI_API_KEY"]?.isEmpty != false,
           let configuredAPIKey = AppBundleConfiguration.openAIAPIKey(),
           !configuredAPIKey.isEmpty {
            environment["OPENAI_API_KEY"] = configuredAPIKey
        }
        return try await CodexProcessManager.runOneShotProcess(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            errorDomain: "CodexPointDetector"
        )
    }

    private static func parsePoint(from text: String) -> CGPoint? {
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::[^\]]*)?)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ).last else {
            return nil
        }

        guard match.numberOfRanges >= 3,
              match.range(at: 1).location != NSNotFound,
              match.range(at: 2).location != NSNotFound,
              let xRange = Range(match.range(at: 1), in: text),
              let yRange = Range(match.range(at: 2), in: text),
              let x = Double(text[xRange]),
              let y = Double(text[yRange]) else {
            return nil
        }

        return CGPoint(x: x, y: y)
    }
}
