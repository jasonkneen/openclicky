import Foundation

enum CodexRuntimeLocator {
    enum LocatorError: LocalizedError {
        case codexExecutableNotFound

        var errorDescription: String? {
            switch self {
            case .codexExecutableNotFound:
                return "OpenClicky could not find the bundled Codex 0.121.0 executable or a codex executable on PATH."
            }
        }
    }

    static func codexExecutableURL(bundle: Bundle = .main, fileManager: FileManager = .default) throws -> URL {
        if let bundled = bundledCodexExecutableURL(bundle: bundle, fileManager: fileManager) {
            return bundled
        }

        if let source = sourceCodexExecutableURL(fileManager: fileManager) {
            return source
        }

        if let pathCodex = pathCodexExecutableURL(fileManager: fileManager) {
            return pathCodex
        }

        throw LocatorError.codexExecutableNotFound
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

    static func sourceAppResourcesDirectory(fileManager: FileManager = .default) -> URL? {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceFile.deletingLastPathComponent().deletingLastPathComponent()
        let candidate = repoRoot
            .appendingPathComponent("AppResources", isDirectory: true)
            .appendingPathComponent("OpenClicky", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return candidate
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

    private static func currentCodexVendorArchitecture() -> String {
        #if arch(arm64)
        return "aarch64-apple-darwin"
        #else
        return "x86_64-apple-darwin"
        #endif
    }
}
