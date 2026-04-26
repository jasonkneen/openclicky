import Foundation

struct CodexHomeLayout: Equatable {
    let homeDirectory: URL
    let configFile: URL
    let soulFile: URL
    let modelInstructionsFile: URL
    let runtimeMapFile: URL
    let bundledSkillsDirectory: URL
    let learnedSkillsDirectory: URL
    let bundledWikiSeedDirectory: URL
    let persistentMemoryFile: URL
    let archivesDirectory: URL
}

final class CodexHomeManager {
    let soulFileName = "SOUL.md"
    let modelInstructionsFileName = "OpenClickyModelInstructions.md"
    let runtimeMapFileName = "OpenClickyRuntimeMap.md"
    let bundledSkillsDirectoryName = "OpenClickyBundledSkills"
    let learnedSkillsDirectoryName = "OpenClickyLearnedSkills"
    let bundledWikiSeedDirectoryName = "OpenClickyBundledWikiSeed"
    let persistentMemoryFileName = "memory.md"

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

    var learnedSkillsDirectory: URL {
        codexHomeDirectory.appendingPathComponent(learnedSkillsDirectoryName, isDirectory: true)
    }

    var archivesDirectory: URL {
        codexHomeDirectory.appendingPathComponent("archives", isDirectory: true)
    }

    var persistentMemoryFile: URL {
        codexHomeDirectory.appendingPathComponent(persistentMemoryFileName, isDirectory: false)
    }

    var runtimeMapFile: URL {
        codexHomeDirectory.appendingPathComponent(runtimeMapFileName, isDirectory: false)
    }

    var soulFile: URL {
        codexHomeDirectory.appendingPathComponent(soulFileName, isDirectory: false)
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
        try fileManager.createDirectory(at: learnedSkillsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: archivesDirectory, withIntermediateDirectories: true)
        OpenClickyMessageLogStore.shared.ensureAgentReviewCommentsFile()
        try ensurePersistentMemoryFile()

        let soul = soulFile
        if let source = resourceURL(named: soulFileName, bundle: bundle) {
            try copyReplacingItem(at: source, to: soul)
        } else if !fileManager.fileExists(atPath: soul.path) {
            try "OpenClicky is a voice-first macOS companion with durable memory and background Agent Mode.\n".write(to: soul, atomically: true, encoding: .utf8)
        }

        let modelInstructions = home.appendingPathComponent(modelInstructionsFileName, isDirectory: false)
        if let source = resourceURL(named: modelInstructionsFileName, bundle: bundle) {
            try copyReplacingItem(at: source, to: modelInstructions)
        } else if !fileManager.fileExists(atPath: modelInstructions.path) {
            try "You are OpenClicky, a friendly macOS cursor companion with Codex Agent Mode.\n".write(to: modelInstructions, atomically: true, encoding: .utf8)
        }

        let skills = home.appendingPathComponent(bundledSkillsDirectoryName, isDirectory: true)
        if let source = resourceURL(named: bundledSkillsDirectoryName, bundle: bundle) {
            try copyDirectoryIfMissing(at: source, to: skills)
        } else {
            try fileManager.createDirectory(at: skills, withIntermediateDirectories: true)
        }

        let wikiSeed = home.appendingPathComponent(bundledWikiSeedDirectoryName, isDirectory: true)
        if let source = resourceURL(named: bundledWikiSeedDirectoryName, bundle: bundle) {
            try copyDirectoryIfMissing(at: source, to: wikiSeed)
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
            learnedSkillsDirectoryName: learnedSkillsDirectoryName,
            includeOpenAIDeveloperDocsMCP: true
        )
        let configFile = home.appendingPathComponent("config.toml", isDirectory: false)
        try config.render().write(to: configFile, atomically: true, encoding: .utf8)
        try writeRuntimeMap(
            home: home,
            configFile: configFile,
            soulFile: soul,
            modelInstructionsFile: modelInstructions,
            bundledSkillsDirectory: skills,
            learnedSkillsDirectory: learnedSkillsDirectory,
            bundledWikiSeedDirectory: wikiSeed
        )
        try copyDefaultCodexAuthIfAvailable(to: home)

        return CodexHomeLayout(
            homeDirectory: home,
            configFile: configFile,
            soulFile: soul,
            modelInstructionsFile: modelInstructions,
            runtimeMapFile: runtimeMapFile,
            bundledSkillsDirectory: skills,
            learnedSkillsDirectory: learnedSkillsDirectory,
            bundledWikiSeedDirectory: wikiSeed,
            persistentMemoryFile: persistentMemoryFile,
            archivesDirectory: archivesDirectory
        )
    }

    func appendPersistentMemoryEvent(userRequest: String, agentResponse: String, createdAt: Date = Date()) throws {
        try fileManager.createDirectory(at: codexHomeDirectory, withIntermediateDirectories: true)
        try ensurePersistentMemoryFile()

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let entry = """

        ## \(isoFormatter.string(from: createdAt)) - Agent task

        - User asked: \(Self.singleLineSnippet(from: userRequest, maxLength: 320))
        - Result: \(Self.singleLineSnippet(from: agentResponse, maxLength: 520))
        """

        let fileHandle = try FileHandle(forWritingTo: persistentMemoryFile)
        defer { try? fileHandle.close() }
        try fileHandle.seekToEnd()
        if let data = entry.data(using: .utf8) {
            try fileHandle.write(contentsOf: data)
        }
    }

    func persistentMemoryContext(maxCharacters: Int = 6_000) -> String {
        do {
            try ensurePersistentMemoryFile()
            let text = try String(contentsOf: persistentMemoryFile, encoding: .utf8)
            guard text.count > maxCharacters else { return text }
            let startIndex = text.index(text.endIndex, offsetBy: -maxCharacters)
            return String(text[startIndex...])
        } catch {
            return "OpenClicky persistent memory is not available yet: \(error.localizedDescription)"
        }
    }

    func createLearnedSkillIfNeeded(name: String, title: String, description: String, body: String) throws {
        let skillDirectory = learnedSkillsDirectory.appendingPathComponent(Self.slug(from: name).replacingOccurrences(of: "-", with: "_"), isDirectory: true)
        let skillFile = skillDirectory.appendingPathComponent("SKILL.md", isDirectory: false)
        guard !fileManager.fileExists(atPath: skillFile.path) else { return }

        try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        let skillMarkdown = """
        ---
        name: "\(Self.escapeFrontmatterValue(name))"
        description: "\(Self.escapeFrontmatterValue(description))"
        ---

        # \(title)

        \(body)
        """
        try skillMarkdown.write(to: skillFile, atomically: true, encoding: .utf8)
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
            guard try !itemsAppearEqual(source, destination) else { return }
            try archiveExistingItem(at: destination, reason: "runtime-replacement")
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func copyDirectoryIfMissing(at source: URL, to destination: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            // Avoid a full recursive directory comparison/copy on every new
            // Agent Mode session. The bundled skills/wiki seed trees can be
            // large, and the old `copyReplacingItem` path walked every file on
            // the main actor before Codex could start, which caused beachballs
            // and clipped the spoken acknowledgement. Existing directories are
            // durable runtime state; app updates can still refresh small files
            // above, while these heavy trees are seeded once.
            return
        }
        if fileManager.fileExists(atPath: destination.path) {
            try archiveExistingItem(at: destination, reason: "runtime-replacement")
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func itemsAppearEqual(_ first: URL, _ second: URL) throws -> Bool {
        var firstIsDirectory: ObjCBool = false
        var secondIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: first.path, isDirectory: &firstIsDirectory),
              fileManager.fileExists(atPath: second.path, isDirectory: &secondIsDirectory),
              firstIsDirectory.boolValue == secondIsDirectory.boolValue else {
            return false
        }

        guard firstIsDirectory.boolValue else {
            return fileManager.contentsEqual(atPath: first.path, andPath: second.path)
        }

        let firstSnapshot = try directorySnapshot(at: first)
        let secondSnapshot = try directorySnapshot(at: second)
        guard firstSnapshot == secondSnapshot else { return false }

        for relativePath in firstSnapshot where !relativePath.hasSuffix("/") {
            let firstFile = first.appendingPathComponent(relativePath, isDirectory: false)
            let secondFile = second.appendingPathComponent(relativePath, isDirectory: false)
            guard fileManager.contentsEqual(atPath: firstFile.path, andPath: secondFile.path) else {
                return false
            }
        }

        return true
    }

    private func directorySnapshot(at root: URL) throws -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            var relativePath = String(url.path.dropFirst(root.path.count))
            if relativePath.hasPrefix("/") {
                relativePath.removeFirst()
            }
            if values.isDirectory == true {
                relativePath += "/"
            }
            paths.append(relativePath)
        }
        return paths.sorted()
    }

    private func archiveExistingItem(at url: URL, reason: String) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }

        let archiveRoot = archivesDirectory.appendingPathComponent(reason, isDirectory: true)
        try fileManager.createDirectory(at: archiveRoot, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let baseName = url.lastPathComponent.isEmpty ? "item" : url.lastPathComponent
        var destination = archiveRoot.appendingPathComponent("\(formatter.string(from: Date()))-\(baseName)", isDirectory: false)
        var attempt = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = archiveRoot.appendingPathComponent("\(formatter.string(from: Date()))-\(attempt)-\(baseName)", isDirectory: false)
            attempt += 1
        }

        try fileManager.moveItem(at: url, to: destination)
    }

    private func ensurePersistentMemoryFile() throws {
        guard !fileManager.fileExists(atPath: persistentMemoryFile.path) else { return }

        let initialMemory = """
        # OpenClicky Persistent Memory

        This file is OpenClicky's durable memory for Agent Mode. Agents must read it before starting user tasks and update it when they learn stable facts, preferences, project context, or reusable workflow knowledge.

        ## Standing Rules

        - Do not tell the user that you cannot remember outside the current conversation. Read and update this file instead.
        - Store stable preferences, useful facts, active project context, and concise task outcomes.
        - Keep entries short and useful. Prefer durable context over raw logs.
        - When a task reveals a repeatable workflow, create or update a skill in `OpenClickyLearnedSkills/<workflow_name>/SKILL.md`.
        """

        try initialMemory.write(to: persistentMemoryFile, atomically: true, encoding: .utf8)
    }

    private func writeRuntimeMap(
        home: URL,
        configFile: URL,
        soulFile: URL,
        modelInstructionsFile: URL,
        bundledSkillsDirectory: URL,
        learnedSkillsDirectory: URL,
        bundledWikiSeedDirectory: URL
    ) throws {
        let sessionsDirectory = home.appendingPathComponent("sessions", isDirectory: true)
        let logs = OpenClickyMessageLogStore.shared
        let runtimeMap = """
        # OpenClicky Runtime Map

        This file tells OpenClicky Agent Mode where durable context, logs, skills, and app state live. Agents may read or edit these files when the user asks, subject to normal safety rules for destructive changes, credentials, and permissions.

        ## Agent Mode Home

        - Codex home: \(home.path)
        - Config: \(configFile.path)
        - Soul/persona: \(soulFile.path)
        - Model instructions: \(modelInstructionsFile.path)
        - Runtime map: \(runtimeMapFile.path)
        - Sessions: \(sessionsDirectory.path)
        - Archives: \(archivesDirectory.path)

        ## Memory And Skills

        - Persistent memory: \(persistentMemoryFile.path)
        - Memory articles: \(memoriesDirectory.path)
        - Bundled skills: \(bundledSkillsDirectory.path)
        - Learned workflow skills: \(learnedSkillsDirectory.path)
        - Bundled wiki seed: \(bundledWikiSeedDirectory.path)
        - Archives for replaced or optimized artifacts: \(archivesDirectory.path)

        ## Logs And Review Notes

        - Logs directory: \(logs.logDirectory.path)
        - Current message log: \(logs.currentLogFile.path)
        - Log review JSONL: \(logs.reviewCommentsFile.path)
        - Agent review comments: \(logs.agentReviewCommentsFile.path)

        ## Widgets

        - Widget snapshot: \(OpenClickyWidgetStateStore.snapshotURL.path)
        - App group identifier: \(AppBundleConfiguration.appGroupIdentifier)

        ## Operating Rules

        - Read `memory.md` before work and update it with stable user preferences, project facts, task outcomes, and useful workflow context.
        - Read `SOUL.md` before agent work. Treat it as OpenClicky's persona and operating identity.
        - Use or update learned skills when explicitly useful, especially when the user asks to inspect, optimize, or learn from skills/logs. Do not surface learned-skill work in normal task progress unless asked.
        - When optimizing skills, prompts, memory files, logs-derived notes, or other OpenClicky artifacts, archive the previous version under \(archivesDirectory.path) before replacing it. Do not delete old versions.
        - When learning from logs, create the needed memory entries, review notes, or learned skills, then archive superseded notes or skills instead of deleting them.
        - Read log review comments when the user asks to review, tune, or fix behavior from logs.
        - Read the widget snapshot when the user asks about widgets, active tasks, stats, or desktop status.
        - Do not claim OpenClicky cannot remember or cannot inspect its own logs, memory, skills, or runtime files. Use the paths above.
        """

        try runtimeMap.write(to: runtimeMapFile, atomically: true, encoding: .utf8)
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

    private static func singleLineSnippet(from text: String, maxLength: Int) -> String {
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard flattened.count > maxLength else { return flattened }
        let endIndex = flattened.index(flattened.startIndex, offsetBy: maxLength)
        let prefix = String(flattened[..<endIndex])
        if let lastSpace = prefix.lastIndex(of: " ") {
            return "\(prefix[..<lastSpace])..."
        }
        return "\(prefix)..."
    }

    private static func defaultApplicationSupportDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("AgentMode", isDirectory: true)
    }
}
