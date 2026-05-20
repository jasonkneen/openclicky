import AppKit
import Foundation
import Combine

nonisolated struct OpenPetsCatalogPet: Identifiable, Decodable, Equatable {
    let id: String
    let displayName: String
    let description: String
    let thumbnail: String?
    let preview: String?
    let spritesheet: String?
    let zip: String
    let category: String?
    let original: Bool?
    let featured: Bool?

    var previewURL: URL? {
        if let thumbnail, let url = URL(string: thumbnail) { return url }
        if let preview, let url = URL(string: preview) { return url }
        if let spritesheet, let url = URL(string: spritesheet) { return url }
        return nil
    }
}

nonisolated private struct OpenPetsCatalogV3Index: Decodable {
    let version: Int
    let total: Int
    let pages: [String]
}

nonisolated private struct OpenPetsCatalogV3Page: Decodable {
    let version: Int
    let page: Int
    let pets: [OpenPetsCatalogPet]
}

nonisolated private struct OpenPetsCatalogV2: Decodable {
    let version: Int
    let pets: [OpenPetsCatalogPet]
}

nonisolated enum OpenPetsCatalogInstallerError: LocalizedError {
    case invalidCatalogURL
    case catalogUnavailable
    case invalidZipURL
    case zipTooLarge
    case zipListingFailed
    case unsafeZipContents
    case extractionFailed
    case manifestMismatch
    case installTargetExists
    case missingInstalledPet

    var errorDescription: String? {
        switch self {
        case .invalidCatalogURL: return "OpenPets catalog URL is invalid."
        case .catalogUnavailable: return "OpenPets catalog is unavailable."
        case .invalidZipURL: return "OpenPets zip URL is not from zip.openpets.dev."
        case .zipTooLarge: return "OpenPets pet zip is too large."
        case .zipListingFailed: return "OpenPets pet zip could not be inspected."
        case .unsafeZipContents: return "OpenPets pet zip contains unexpected paths."
        case .extractionFailed: return "OpenPets pet zip could not be extracted."
        case .manifestMismatch: return "OpenPets pet manifest did not match the selected catalog pet."
        case .installTargetExists: return "That pet is already installed."
        case .missingInstalledPet: return "The installed pet bundle was not found after installation."
        }
    }
}

@MainActor
final class OpenPetsCatalogStore: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    @Published private(set) var pets: [OpenPetsCatalogPet] = []
    @Published private(set) var totalCount: Int = 0
    @Published private(set) var loadedPageCount: Int = 0
    @Published private(set) var pageCount: Int = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var installingPetIDs: Set<String> = []
    @Published var searchText = ""

    private var catalogPageURLs: [String] = []
    private var loadedPages: Set<Int> = []
    private let decoder = JSONDecoder()

    var visiblePets: [OpenPetsCatalogPet] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return pets }
        return pets.filter { pet in
            pet.displayName.localizedCaseInsensitiveContains(query)
                || pet.id.localizedCaseInsensitiveContains(query)
                || pet.description.localizedCaseInsensitiveContains(query)
        }
    }

    func loadInitialCatalogIfNeeded() {
        guard pets.isEmpty, !isLoading else { return }
        Task { await loadCatalog(reset: true) }
    }

    func refreshCatalog() {
        Task { await loadCatalog(reset: true) }
    }

    func loadMore() {
        guard loadedPageCount < pageCount, !isLoading else { return }
        Task { await loadNextPage() }
    }

    func install(_ pet: OpenPetsCatalogPet) {
        install(pet, into: .shared)
    }

    func install(_ pet: OpenPetsCatalogPet, into library: ClickyBuddyPetLibrary) {
        guard !installingPetIDs.contains(pet.id) else { return }
        installingPetIDs.insert(pet.id)
        errorMessage = nil
        Task {
            do {
                try await Self.installPet(pet, into: library.petsRootURL)
                library.refreshNow()
            } catch {
                errorMessage = error.localizedDescription
            }
            installingPetIDs.remove(pet.id)
        }
    }

    private func loadCatalog(reset: Bool) async {
        isLoading = true
        errorMessage = nil
        if reset {
            pets = []
            totalCount = 0
            loadedPageCount = 0
            pageCount = 0
            catalogPageURLs = []
            loadedPages = []
        }
        do {
            let loaded = try await Self.fetchV3IndexAndFirstPage()
            catalogPageURLs = loaded.pages
            pageCount = loaded.pages.count
            totalCount = loaded.total
            pets = Self.deduplicated(loaded.pets)
            loadedPages = loaded.loadedPages
            loadedPageCount = loaded.loadedPages.count
        } catch {
            do {
                let fallback = try await Self.fetchV2Catalog()
                pets = Self.deduplicated(fallback)
                totalCount = fallback.count
                pageCount = 1
                loadedPageCount = 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func loadNextPage() async {
        guard let next = catalogPageURLs.indices.first(where: { !loadedPages.contains($0) }) else { return }
        isLoading = true
        errorMessage = nil
        do {
            let page = try await Self.fetchCatalogPage(urlString: catalogPageURLs[next], expectedPage: next)
            pets = Self.deduplicated(pets + page.pets)
            loadedPages.insert(next)
            loadedPageCount = loadedPages.count
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private static func fetchV3IndexAndFirstPage() async throws -> (total: Int, pages: [String], loadedPages: Set<Int>, pets: [OpenPetsCatalogPet]) {
        guard let url = URL(string: "https://openpets.dev/pets/catalog.v3.json") else { throw OpenPetsCatalogInstallerError.invalidCatalogURL }
        let index = try await fetchJSON(OpenPetsCatalogV3Index.self, from: url)
        guard index.version == 3, let first = index.pages.first else { throw OpenPetsCatalogInstallerError.catalogUnavailable }
        let page = try await fetchCatalogPage(urlString: first, expectedPage: 0)
        return (index.total, index.pages, [0], page.pets)
    }

    private static func fetchCatalogPage(urlString: String, expectedPage: Int) async throws -> OpenPetsCatalogV3Page {
        guard let url = URL(string: urlString), isAllowedCatalogURL(url, kind: .catalogPage) else { throw OpenPetsCatalogInstallerError.invalidCatalogURL }
        let page = try await fetchJSON(OpenPetsCatalogV3Page.self, from: url)
        guard page.version == 3, page.page == expectedPage else { throw OpenPetsCatalogInstallerError.catalogUnavailable }
        return page
    }

    private static func fetchV2Catalog() async throws -> [OpenPetsCatalogPet] {
        guard let url = URL(string: "https://openpets.dev/pets/catalog.v2.json") else { throw OpenPetsCatalogInstallerError.invalidCatalogURL }
        let catalog = try await fetchJSON(OpenPetsCatalogV2.self, from: url)
        guard catalog.version == 2 else { throw OpenPetsCatalogInstallerError.catalogUnavailable }
        return catalog.pets
    }

    private static func fetchJSON<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("OpenClicky/1.0", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 12 * 1024 * 1024 else {
            throw OpenPetsCatalogInstallerError.catalogUnavailable
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private enum CatalogURLKind { case catalogPage, zip }

    private static func isAllowedCatalogURL(_ url: URL, kind: CatalogURLKind) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else { return false }
        switch kind {
        case .catalogPage:
            return url.host == "openpets.dev" && url.path.hasPrefix("/pets/catalog.v3/page-") && url.path.hasSuffix(".json")
        case .zip:
            return url.host == "zip.openpets.dev" && url.path.hasPrefix("/pets/") && url.path.hasSuffix(".zip")
        }
    }

    private static func deduplicated(_ pets: [OpenPetsCatalogPet]) -> [OpenPetsCatalogPet] {
        var seen: Set<String> = []
        var result: [OpenPetsCatalogPet] = []
        for pet in pets where !seen.contains(pet.id) {
            seen.insert(pet.id)
            result.append(pet)
        }
        return result
    }

    private static func installPet(_ pet: OpenPetsCatalogPet, into petsRootURL: URL) async throws {
        guard let zipURL = URL(string: pet.zip), isAllowedCatalogURL(zipURL, kind: .zip) else {
            throw OpenPetsCatalogInstallerError.invalidZipURL
        }

        let fm = FileManager.default
        try fm.createDirectory(at: petsRootURL, withIntermediateDirectories: true)
        let finalURL = petsRootURL.appendingPathComponent(pet.id, isDirectory: true)
        if fm.fileExists(atPath: finalURL.path) {
            throw OpenPetsCatalogInstallerError.installTargetExists
        }

        let tempRoot = fm.temporaryDirectory.appendingPathComponent("OpenClickyOpenPets-")
            .appendingPathExtension(UUID().uuidString)
        let extractedURL = tempRoot.appendingPathComponent("extracted", isDirectory: true)
        let zipFileURL = tempRoot.appendingPathComponent("pet.zip")
        try fm.createDirectory(at: extractedURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        var request = URLRequest(url: zipURL)
        request.setValue("OpenClicky/1.0", forHTTPHeaderField: "User-Agent")
        let (zipData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenPetsCatalogInstallerError.catalogUnavailable
        }
        guard zipData.count > 0, zipData.count <= 100 * 1024 * 1024 else { throw OpenPetsCatalogInstallerError.zipTooLarge }
        try zipData.write(to: zipFileURL, options: .atomic)

        try validateZipListing(zipFileURL)
        try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", zipFileURL.path, extractedURL.path])
        try validateExtractedPet(at: extractedURL, expectedPetID: pet.id)

        let installedStagingURL = petsRootURL.appendingPathComponent(".")
            .appendingPathComponent("\(pet.id).installing-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: installedStagingURL, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: extractedURL.appendingPathComponent("pet.json"), to: installedStagingURL.appendingPathComponent("pet.json"))
            try fm.copyItem(at: extractedURL.appendingPathComponent("spritesheet.webp"), to: installedStagingURL.appendingPathComponent("spritesheet.webp"))
            try fm.moveItem(at: installedStagingURL, to: finalURL)
        } catch {
            try? fm.removeItem(at: installedStagingURL)
            throw error
        }

        guard fm.fileExists(atPath: finalURL.appendingPathComponent("pet.json").path),
              fm.fileExists(atPath: finalURL.appendingPathComponent("spritesheet.webp").path) else {
            throw OpenPetsCatalogInstallerError.missingInstalledPet
        }
    }

    private static func validateZipListing(_ zipFileURL: URL) throws {
        let output = try runProcess("/usr/bin/unzip", arguments: ["-Z1", zipFileURL.path])
        let entries = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !entries.isEmpty else { throw OpenPetsCatalogInstallerError.zipListingFailed }
        var leaves: Set<String> = []
        for entry in entries {
            if entry.hasPrefix("/") || entry.contains("..") || entry.hasSuffix("/") { throw OpenPetsCatalogInstallerError.unsafeZipContents }
            let leaf = (entry as NSString).lastPathComponent
            guard leaf == "pet.json" || leaf == "spritesheet.webp" else { throw OpenPetsCatalogInstallerError.unsafeZipContents }
            leaves.insert(leaf)
        }
        guard leaves == ["pet.json", "spritesheet.webp"] else { throw OpenPetsCatalogInstallerError.unsafeZipContents }
    }

    private static func validateExtractedPet(at url: URL, expectedPetID: String) throws {
        let petJSON = url.appendingPathComponent("pet.json")
        let spritesheet = url.appendingPathComponent("spritesheet.webp")
        guard let data = try? Data(contentsOf: petJSON), data.count <= 128 * 1024 else {
            throw OpenPetsCatalogInstallerError.manifestMismatch
        }
        let manifest = try JSONDecoder().decode(ClickyBuddyPetManifest.self, from: data)
        guard manifest.id == expectedPetID, manifest.spritesheetPath == "spritesheet.webp" else {
            throw OpenPetsCatalogInstallerError.manifestMismatch
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: spritesheet.path)
        let size = attrs[.size] as? NSNumber
        guard let size, size.intValue > 0, size.intValue <= 100 * 1024 * 1024 else {
            throw OpenPetsCatalogInstallerError.manifestMismatch
        }
        _ = try ClickyBuddyPetLoader.loadPet(at: url)
    }

    @discardableResult
    private static func runProcess(_ launchPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw OpenPetsCatalogInstallerError.extractionFailed }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
