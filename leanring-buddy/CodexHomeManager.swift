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
    let modelProviderID = ClickyCodexConfigTemplate.defaultModelProviderID

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

    func prepare(bundle: Bundle = .main) throws -> CodexHomeLayout {
        let home = codexHomeDirectory
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home.appendingPathComponent("sessions", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home.appendingPathComponent("memories", isDirectory: true), withIntermediateDirectories: true)

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

        return CodexHomeLayout(
            homeDirectory: home,
            configFile: configFile,
            modelInstructionsFile: modelInstructions,
            bundledSkillsDirectory: skills,
            bundledWikiSeedDirectory: wikiSeed
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

    private func copyReplacingItem(at source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func defaultApplicationSupportDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("AgentMode", isDirectory: true)
    }
}
