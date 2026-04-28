import Foundation

nonisolated enum CodexRuntimeLocator {
    struct CodexRuntimeVersion: Comparable, Equatable {
        let major: Int
        let minor: Int
        let patch: Int
        let prerelease: String?

        static func < (lhs: CodexRuntimeVersion, rhs: CodexRuntimeVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

            switch (lhs.prerelease, rhs.prerelease) {
            case (nil, nil):
                return false
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case let (left?, right?):
                return left.localizedStandardCompare(right) == .orderedAscending
            }
        }
    }

    nonisolated enum LocatorError: LocalizedError {
        case codexExecutableNotFound

        var errorDescription: String? {
            switch self {
            case .codexExecutableNotFound:
                return "OpenClicky could not find a bundled, installed, or PATH Codex executable."
            }
        }
    }

    static func codexExecutableURL(bundle: Bundle = .main, fileManager: FileManager = .default) throws -> URL {
        let candidates = codexExecutableCandidates(bundle: bundle, fileManager: fileManager)
        guard !candidates.isEmpty else { throw LocatorError.codexExecutableNotFound }
        return newestCodexExecutableURL(from: candidates) ?? candidates[0]
    }

    static func codexExecutableCandidates(bundle: Bundle = .main, fileManager: FileManager = .default) -> [URL] {
        var candidates: [URL] = []
        if let bundled = bundledCodexExecutableURL(bundle: bundle, fileManager: fileManager) {
            candidates.append(bundled)
        }
        if let source = sourceCodexExecutableURL(fileManager: fileManager) {
            candidates.append(source)
        }
        candidates.append(contentsOf: installedCodexAppExecutableURLs(fileManager: fileManager))
        if let pathCodex = pathCodexExecutableURL(fileManager: fileManager) {
            candidates.append(pathCodex)
        }
        return deduplicated(candidates)
    }

    static func bundledCodexExecutableURL(bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        guard let runtime = bundle.url(forResource: "CodexRuntime", withExtension: nil) else { return nil }
        let executable = runtime.appendingPathComponent("bin/codex", isDirectory: false)
        return fileManager.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    static func sourceCodexExecutableURL(fileManager: FileManager = .default) -> URL? {
        guard let sourceResources = sourceAppResourcesDirectory(fileManager: fileManager) else { return nil }
        let executable = sourceResources
            .appendingPathComponent("CodexRuntime", isDirectory: true)
            .appendingPathComponent("bin/codex", isDirectory: false)
        return fileManager.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    static func installedCodexAppExecutableURLs(fileManager: FileManager = .default) -> [URL] {
        [
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/Applications/Codex.app/Contents/Resources/codex"
        ]
        .map { URL(fileURLWithPath: $0, isDirectory: false) }
        .filter { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func sourceAppResourcesDirectory(fileManager: FileManager = .default) -> URL? {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let sourceRoot = sourceFile.deletingLastPathComponent().deletingLastPathComponent()
        let packageRoot = sourceRoot.deletingLastPathComponent()
        let bundle = Bundle.main
        var candidates: [URL] = [
            sourceRoot
                .appendingPathComponent("AppResources", isDirectory: true)
                .appendingPathComponent("OpenClicky", isDirectory: true),
            sourceRoot
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("OpenClicky", isDirectory: true),
            packageRoot
                .appendingPathComponent("AppResources", isDirectory: true)
                .appendingPathComponent("OpenClicky", isDirectory: true),
            packageRoot
                .appendingPathComponent("Muxy", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("OpenClicky", isDirectory: true),
        ]

        if let bundledOpenClicky = bundle.url(forResource: "OpenClicky", withExtension: nil) {
            candidates.append(bundledOpenClicky)
        }
        if let resourceURL = bundle.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("OpenClicky", isDirectory: true))
            candidates.append(
                resourceURL
                    .appendingPathComponent("Muxy_Muxy.bundle", isDirectory: true)
                    .appendingPathComponent("OpenClicky", isDirectory: true)
            )
        }
        candidates.append(
            bundle.bundleURL
                .appendingPathComponent("Muxy_Muxy.bundle", isDirectory: true)
                .appendingPathComponent("OpenClicky", isDirectory: true)
        )
        candidates.append(
            bundle.bundleURL
                .appendingPathComponent("Contents/Resources/Muxy_Muxy.bundle", isDirectory: true)
                .appendingPathComponent("OpenClicky", isDirectory: true)
        )

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }

        return nil
    }

    static func pathCodexExecutableURL(fileManager: FileManager = .default) -> URL? {
        let rawPath = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in rawPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("codex", isDirectory: false)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func pathByPrependingBundledRuntimePaths(existingPath: String?, runtimeExecutableURL: URL) -> String {
        let runtimeDirectory = runtimeExecutableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let architecture = currentCodexVendorArchitecture()
        let vendorPath = runtimeDirectory
            .appendingPathComponent("vendor", isDirectory: true)
            .appendingPathComponent(architecture, isDirectory: true)
            .appendingPathComponent("path", isDirectory: true)
            .path
        let basePath = existingPath ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return "\(vendorPath):\(basePath)"
    }

    static func parsedVersion(from versionOutput: String) -> CodexRuntimeVersion? {
        let pattern = #"(\d+)\.(\d+)\.(\d+)(?:-([A-Za-z0-9.\-]+))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: versionOutput,
                range: NSRange(versionOutput.startIndex..<versionOutput.endIndex, in: versionOutput)
              ),
              let majorRange = Range(match.range(at: 1), in: versionOutput),
              let minorRange = Range(match.range(at: 2), in: versionOutput),
              let patchRange = Range(match.range(at: 3), in: versionOutput),
              let major = Int(versionOutput[majorRange]),
              let minor = Int(versionOutput[minorRange]),
              let patch = Int(versionOutput[patchRange]) else {
            return nil
        }

        let prerelease: String?
        if match.range(at: 4).location != NSNotFound,
           let prereleaseRange = Range(match.range(at: 4), in: versionOutput) {
            prerelease = String(versionOutput[prereleaseRange])
        } else {
            prerelease = nil
        }

        return CodexRuntimeVersion(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    private static func newestCodexExecutableURL(from candidates: [URL]) -> URL? {
        candidates
            .compactMap { candidate -> (url: URL, version: CodexRuntimeVersion)? in
                guard let version = codexVersion(executableURL: candidate) else { return nil }
                return (candidate, version)
            }
            .max { first, second in first.version < second.version }?
            .url
    }

    private static func codexVersion(executableURL: URL) -> CodexRuntimeVersion? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--version"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData + errorData, encoding: .utf8) ?? ""
        return parsedVersion(from: output)
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        var uniqueURLs: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }
            uniqueURLs.append(url)
        }
        return uniqueURLs
    }

    private static func currentCodexVendorArchitecture() -> String {
        #if arch(arm64)
        return "aarch64-apple-darwin"
        #else
        return "x86_64-apple-darwin"
        #endif
    }
}
