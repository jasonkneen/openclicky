import Foundation

struct OpenClickyGogCLIStatus: Equatable, Sendable {
    var isInstalled: Bool
    var executablePath: String?
    var version: String?
    var credentialsExist: Bool
    var accountEmail: String?
    var client: String?
    var configExists: Bool
    var configPath: String?
    var keyringBackend: String?
    var serviceAccountConfigured: Bool
    var needsKeyringPassphrase: Bool
    var errorMessage: String?

    nonisolated static let unknown = OpenClickyGogCLIStatus(
        isInstalled: false,
        executablePath: nil,
        version: nil,
        credentialsExist: false,
        accountEmail: nil,
        client: nil,
        configExists: false,
        configPath: nil,
        keyringBackend: nil,
        serviceAccountConfigured: false,
        needsKeyringPassphrase: false,
        errorMessage: nil
    )

    var readinessTitle: String {
        if !isInstalled { return "gogcli not found by OpenClicky" }
        if !credentialsExist { return "OAuth client needed" }
        if accountEmail?.isEmpty == false || serviceAccountConfigured { return "Connected locally" }
        return "Authorize an account"
    }

    var readinessDetail: String {
        if !isInstalled { return "OpenClicky could not see gog at /opt/homebrew/bin/gog, /usr/local/bin/gog, or OPENCLICKY_GOG_PATH." }
        if !credentialsExist { return "Add a Google Cloud Desktop OAuth client JSON with gog auth credentials." }
        if let accountEmail, !accountEmail.isEmpty {
            if needsKeyringPassphrase {
                return "Using \(accountEmail). gogcli may ask for its local file-keyring passphrase when an agent runs Google commands."
            }
            return "Using \(accountEmail) via \(keyringBackend ?? "local keyring")."
        }
        if let errorMessage, !errorMessage.isEmpty { return errorMessage }
        return "Credentials are present; run gog auth add for the Google account you want OpenClicky agents to use."
    }

    var isReadyForUserAccount: Bool {
        isInstalled && credentialsExist && (accountEmail?.isEmpty == false)
    }
}

enum OpenClickyGogCLIStatusResolver {
    nonisolated private static let overridePathEnvironmentKey = "OPENCLICKY_GOG_PATH"
    nonisolated private static let knownExecutablePaths = [
        "/opt/homebrew/bin/gog",
        "/usr/local/bin/gog",
        "/usr/bin/gog"
    ]

    nonisolated static func refresh() async -> OpenClickyGogCLIStatus {
        // Deliberately do not execute `gog` from Settings. Some gogcli auth
        // commands can prompt for the file-keyring passphrase and spin if run
        // from a GUI process. Settings only inspects local files and paths.
        await Task.detached(priority: .utility) {
            refreshSynchronously(fileManager: .default)
        }.value
    }

    nonisolated private static func refreshSynchronously(fileManager: FileManager) -> OpenClickyGogCLIStatus {
        var status = OpenClickyGogCLIStatus.unknown
        status.executablePath = resolveExecutablePath(fileManager: fileManager)
        status.isInstalled = status.executablePath != nil

        let supportDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/gogcli", isDirectory: true)
        let configURL = supportDirectory.appendingPathComponent("config.json")
        let defaultCredentialsURL = supportDirectory.appendingPathComponent("credentials.json")
        let keyringDirectory = supportDirectory.appendingPathComponent("keyring", isDirectory: true)

        status.configExists = fileManager.fileExists(atPath: configURL.path)
        status.configPath = status.configExists ? configURL.path : nil
        status.credentialsExist = fileManager.fileExists(atPath: defaultCredentialsURL.path)
        status.client = status.credentialsExist ? "default" : nil

        if let config = try? String(contentsOf: configURL, encoding: .utf8) {
            status.keyringBackend = jsonStringValue(for: "keyring_backend", in: config)
        }

        if let keyringItems = try? fileManager.contentsOfDirectory(atPath: keyringDirectory.path) {
            let tokenNames = keyringItems.filter { $0.hasPrefix("token:") }
            status.accountEmail = tokenNames
                .compactMap(accountEmailFromTokenFilename)
                .sorted()
                .first
            status.needsKeyringPassphrase = status.keyringBackend == "file" && status.accountEmail != nil
        }

        return status
    }

    nonisolated private static func resolveExecutablePath(fileManager: FileManager) -> String? {
        if let overridePath = normalized(ProcessInfo.processInfo.environment[overridePathEnvironmentKey]),
           fileManager.fileExists(atPath: overridePath) || fileManager.isExecutableFile(atPath: overridePath) {
            return overridePath
        }

        for path in knownExecutablePaths where fileManager.fileExists(atPath: path) || fileManager.isExecutableFile(atPath: path) {
            return path
        }

        return nil
    }

    nonisolated private static func accountEmailFromTokenFilename(_ filename: String) -> String? {
        let parts = filename.split(separator: ":").map(String.init)
        guard let candidate = parts.last, candidate.contains("@") else { return nil }
        return candidate
    }

    nonisolated private static func jsonStringValue(for key: String, in text: String) -> String? {
        let pattern = "\\\"\(NSRegularExpression.escapedPattern(for: key))\\\"\\s*:\\s*\\\"([^\\\"]+)\\\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }

    nonisolated private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
