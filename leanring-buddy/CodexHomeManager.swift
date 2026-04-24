import Foundation

struct CodexHomeLayout: Equatable {
    let homeDirectory: URL
    let configFile: URL
    let modelInstructionsFile: URL
    let bundledSkillsDirectory: URL
    let bundledWikiSeedDirectory: URL
}

final class CodexHomeManager {
    let modelInstructionsFileName = "OpenClickyModelInstructions.md"
    let bundledSkillsDirectoryName = "OpenClickyBundledSkills"
    let bundledWikiSeedDirectoryName = "OpenClickyBundledWikiSeed"

    let fileManager: FileManager
    let applicationSupportDirectory: URL
    let workerBaseURL: URL
    var model: String
    var reasoningEffort: String

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil,
        workerBaseURL: URL = ClickyCodexBackend.configuredWorkerBaseURL(),
        model: String = OpenClickyModelCatalog.codexActionsModel(
            withID: UserDefaults.standard.string(forKey: "clickyCodexModel") ?? OpenClickyModelCatalog.defaultCodexActionsModelID
        ).id,
        reasoningEffort: String = UserDefaults.standard.string(forKey: "clickyCodexReasoningEffort") ?? "medium"
    ) {
        self.fileManager = fileManager
        self.applicationSupportDirectory = applicationSupportDirectory ?? CodexHomeManager.defaultApplicationSupportDirectory(fileManager: fileManager)
        self.workerBaseURL = workerBaseURL
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    var codexHomeDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("CodexHome", isDirectory: true)
    }

    var memoriesDirectory: URL {
        codexHomeDirectory.appendingPathComponent("memories", isDirectory: true)
    }

    var modelProviderID: String {
        ClickyCodexBackend.isDefaultOpenAIBaseURL(workerBaseURL)
            ? ClickyCodexConfigTemplate.defaultModelProviderID
            : ClickyCodexConfigTemplate.customModelProviderID
    }

    func prepare(bundle: Bundle = .main) throws -> CodexHomeLayout {
        let home = codexHomeDirectory
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home.appendingPathComponent("sessions", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: memoriesDirectory, withIntermediateDirectories: true)

        let modelInstructions = home.appendingPathComponent(modelInstructionsFileName, isDirectory: false)
        if let source = resourceURL(named: modelInstructionsFileName, bundle: bundle) {
            try copyReplacingItem(at: source, to: modelInstructions)
        } else if !fileManager.fileExists(atPath: modelInstructions.path) {
            try "You are OpenClicky, a friendly macOS cursor companion with Codex Agent Mode.\n".write(to: modelInstructions, atomically: true, encoding: .utf8)
        }

        let skills = home.appendingPathComponent(bundledSkillsDirectoryName, isDirectory: true)
        if let source = resourceURL(named: bundledSkillsDirectoryName, bundle: bundle) {
            try copyReplacingItem(at: source, to: skills)
        } else {
            try fileManager.createDirectory(at: skills, withIntermediateDirectories: true)
        }

        let wikiSeed = home.appendingPathComponent(bundledWikiSeedDirectoryName, isDirectory: true)
        if let source = resourceURL(named: bundledWikiSeedDirectoryName, bundle: bundle) {
            try copyReplacingItem(at: source, to: wikiSeed)
        } else {
            try fileManager.createDirectory(at: wikiSeed, withIntermediateDirectories: true)
        }

        if let agentsSource = resourceURL(named: "AGENTS.md", bundle: bundle) {
            try copyReplacingItem(at: agentsSource, to: home.appendingPathComponent("AGENTS.md", isDirectory: false))
        }

        let config = ClickyCodexConfigTemplate(
            model: model,
            reasoningEffort: reasoningEffort,
            workerBaseURL: workerBaseURL,
            modelInstructionsFileName: modelInstructionsFileName,
            bundledSkillsDirectoryName: bundledSkillsDirectoryName,
            includeOpenAIDeveloperDocsMCP: true
        )
        let configFile = home.appendingPathComponent("config.toml", isDirectory: false)
        try config.render().write(to: configFile, atomically: true, encoding: .utf8)
        try copyDefaultCodexAuthIfAvailable(to: home)

        return CodexHomeLayout(
            homeDirectory: home,
            configFile: configFile,
            modelInstructionsFile: modelInstructions,
            bundledSkillsDirectory: skills,
            bundledWikiSeedDirectory: wikiSeed
        )
    }

    @discardableResult
    func saveMemory(title: String, body: String, createdAt: Date = Date()) throws -> WikiManager.Article {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty else {
            throw NSError(domain: "OpenClicky.Memory", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "OpenClicky needs a title before it can save a memory."
            ])
        }

        guard !trimmedBody.isEmpty else {
            throw NSError(domain: "OpenClicky.Memory", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "OpenClicky needs some memory content before saving."
            ])
        }

        try fileManager.createDirectory(at: memoriesDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        let slug = Self.slug(from: trimmedTitle)
        let baseFilename = "\(formatter.string(from: createdAt))-\(slug)"
        let destinationURL = uniqueMemoryFileURL(baseFilename: baseFilename)
        let markdown = """
        ---
        title: "\(Self.escapeFrontmatterValue(trimmedTitle))"
        created: \(isoFormatter.string(from: createdAt))
        ---

        # \(trimmedTitle)

        \(trimmedBody)
        """

        try markdown.write(to: destinationURL, atomically: true, encoding: .utf8)

        return WikiManager.Article(
            relativePath: destinationURL.lastPathComponent,
            title: trimmedTitle,
            body: markdown,
            aliases: []
        )
    }

    private func resourceURL(named name: String, bundle: Bundle) -> URL? {
        if let bundled = bundle.url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension.isEmpty ? nil : (name as NSString).pathExtension) {
            return bundled
        }

        if let sourceResources = CodexRuntimeLocator.sourceAppResourcesDirectory(fileManager: fileManager) {
            let candidate = sourceResources.appendingPathComponent(name, isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private func copyDefaultCodexAuthIfAvailable(to home: URL) throws {
        guard ClickyCodexBackend.isDefaultOpenAIBaseURL(workerBaseURL) else { return }
        guard AppBundleConfiguration.openAIAPIKey() == nil else { return }

        let destination = home.appendingPathComponent("auth.json", isDirectory: false)
        guard !fileManager.fileExists(atPath: destination.path) else { return }

        let source = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
        guard fileManager.fileExists(atPath: source.path) else { return }

        try fileManager.copyItem(at: source, to: destination)
    }

    private func copyReplacingItem(at source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func uniqueMemoryFileURL(baseFilename: String) -> URL {
        var attempt = 0
        while true {
            let suffix = attempt == 0 ? "" : "-\(attempt + 1)"
            let candidate = memoriesDirectory.appendingPathComponent("\(baseFilename)\(suffix).md", isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    private static func slug(from title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let lowered = folded.lowercased()
        let pieces = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return pieces.isEmpty ? "memory" : pieces.joined(separator: "-")
    }

    private static func escapeFrontmatterValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func defaultApplicationSupportDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("AgentMode", isDirectory: true)
    }
}
