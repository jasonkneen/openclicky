//
//  ClickyBuddyPet.swift
//  OpenClicky
//
//  Loads custom "buddy" pets produced by the hatch-pet Codex skill.
//
//  Contract (from ~/.codex/skills/hatch-pet/references/codex-pet-contract.md):
//    ${CODEX_HOME:-$HOME/.codex}/pets/<pet-name>/
//    ├── pet.json        { id, displayName, description, spritesheetPath }
//    └── spritesheet.webp  // 1536x1872, 8 cols x 9 rows, 192x208 cells
//
//  Frame counts and per-frame durations are fixed in animation-rows.md;
//  pet.json does not carry them. We bake that table here as a Swift constant.
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Atlas geometry

nonisolated enum ClickyBuddyPetAtlas {
    static let cellWidth: Int = 192
    static let cellHeight: Int = 208
    static let columns: Int = 8
    static let rows: Int = 9
    static let totalWidth: Int = cellWidth * columns   // 1536
    static let totalHeight: Int = cellHeight * rows    // 1872
}

// MARK: - Animation rows

/// One row of the atlas. Order MUST match `animation-rows.md` row indices 0...8.
nonisolated enum ClickyBuddyAnimationRow: Int, CaseIterable {
    case idle           = 0
    case runningRight   = 1
    case runningLeft    = 2
    case waving         = 3
    case jumping        = 4
    case failed         = 5
    case waiting        = 6
    case running        = 7
    case review         = 8

    /// Per-frame durations in seconds. Final entry is the "hold" frame.
    var frameDurations: [TimeInterval] {
        switch self {
        case .idle:         return [0.280, 0.110, 0.110, 0.140, 0.140, 0.320]
        case .runningRight: return [0.120, 0.120, 0.120, 0.120, 0.120, 0.120, 0.120, 0.220]
        case .runningLeft:  return [0.120, 0.120, 0.120, 0.120, 0.120, 0.120, 0.120, 0.220]
        case .waving:       return [0.140, 0.140, 0.140, 0.280]
        case .jumping:      return [0.140, 0.140, 0.140, 0.140, 0.280]
        case .failed:       return [0.140, 0.140, 0.140, 0.140, 0.140, 0.140, 0.140, 0.240]
        case .waiting:      return [0.150, 0.150, 0.150, 0.150, 0.150, 0.260]
        case .running:      return [0.120, 0.120, 0.120, 0.120, 0.120, 0.220]
        case .review:       return [0.150, 0.150, 0.150, 0.150, 0.150, 0.280]
        }
    }

    var frameCount: Int { frameDurations.count }
}

// MARK: - On-disk manifest

nonisolated struct ClickyBuddyPetManifest: Decodable {
    let id: String
    let displayName: String
    let description: String
    let spritesheetPath: String
}

// MARK: - Loaded pet

/// A loaded pet with its atlas decoded and sliced into per-frame `CGImage`s.
nonisolated final class ClickyBuddyPet: Identifiable, Equatable {
    let id: String
    let displayName: String
    let petDescription: String
    let bundleURL: URL

    /// Per-row sliced frames (row index ➝ ordered cells).
    /// Only the non-empty cells defined in `frameDurations` are sliced.
    let frames: [ClickyBuddyAnimationRow: [CGImage]]

    init(
        id: String,
        displayName: String,
        description: String,
        bundleURL: URL,
        frames: [ClickyBuddyAnimationRow: [CGImage]]
    ) {
        self.id = id
        self.displayName = displayName
        self.petDescription = description
        self.bundleURL = bundleURL
        self.frames = frames
    }

    static func == (lhs: ClickyBuddyPet, rhs: ClickyBuddyPet) -> Bool {
        lhs.id == rhs.id && lhs.bundleURL == rhs.bundleURL
    }

    /// First frame of the idle row, suitable for thumbnails / picker tiles.
    var thumbnailFrame: CGImage? {
        frames[.idle]?.first ?? frames.values.first?.first
    }

    func frame(row: ClickyBuddyAnimationRow, index: Int) -> CGImage? {
        guard let row = frames[row] else { return nil }
        guard !row.isEmpty else { return nil }
        return row[index % row.count]
    }
}

// MARK: - Loader

nonisolated enum ClickyBuddyPetLoaderError: Error {
    case missingManifest
    case malformedManifest(underlying: Error)
    case missingSpritesheet
    case spritesheetDecodeFailed
    case spritesheetUnexpectedSize(width: Int, height: Int)
}

nonisolated enum ClickyBuddyPetLoader {
    /// Loads a single pet bundle directory.
    nonisolated static func loadPet(at bundleURL: URL) throws -> ClickyBuddyPet {
        let manifestURL = bundleURL.appendingPathComponent("pet.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ClickyBuddyPetLoaderError.missingManifest
        }

        let manifestData: Data
        let manifest: ClickyBuddyPetManifest
        do {
            manifestData = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(ClickyBuddyPetManifest.self, from: manifestData)
        } catch let decode as DecodingError {
            throw ClickyBuddyPetLoaderError.malformedManifest(underlying: decode)
        } catch {
            throw ClickyBuddyPetLoaderError.malformedManifest(underlying: error)
        }

        // Resolve spritesheet path. Manifest typically lists "spritesheet.webp"
        // (relative). Fall back to either webp or png in the bundle dir.
        let spritesheetURL = resolveSpritesheetURL(bundleURL: bundleURL, manifest: manifest)
        guard let spritesheetURL else {
            throw ClickyBuddyPetLoaderError.missingSpritesheet
        }

        let atlas = try decodeAtlas(at: spritesheetURL)
        let frames = sliceFrames(from: atlas)

        return ClickyBuddyPet(
            id: manifest.id,
            displayName: manifest.displayName,
            description: manifest.description,
            bundleURL: bundleURL,
            frames: frames
        )
    }

    /// CGImageSource handles WebP natively on macOS 11+ and avoids the
    /// flakiness of `NSImage(contentsOf:)` for `.webp` files.
    nonisolated private static func decodeAtlas(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ClickyBuddyPetLoaderError.spritesheetDecodeFailed
        }

        // Validate atlas size once — a wrong-sized sheet would silently
        // mis-slice every frame, so fail loudly instead.
        if image.width != ClickyBuddyPetAtlas.totalWidth ||
            image.height != ClickyBuddyPetAtlas.totalHeight {
            throw ClickyBuddyPetLoaderError.spritesheetUnexpectedSize(
                width: image.width, height: image.height
            )
        }
        return image
    }

    nonisolated private static func sliceFrames(from atlas: CGImage) -> [ClickyBuddyAnimationRow: [CGImage]] {
        let cellW = ClickyBuddyPetAtlas.cellWidth
        let cellH = ClickyBuddyPetAtlas.cellHeight
        var result: [ClickyBuddyAnimationRow: [CGImage]] = [:]

        for row in ClickyBuddyAnimationRow.allCases {
            var rowFrames: [CGImage] = []
            rowFrames.reserveCapacity(row.frameCount)
            for col in 0..<row.frameCount {
                let rect = CGRect(
                    x: col * cellW,
                    y: row.rawValue * cellH,
                    width: cellW,
                    height: cellH
                )
                if let cell = atlas.cropping(to: rect) {
                    rowFrames.append(cell)
                }
            }
            result[row] = rowFrames
        }
        return result
    }

    nonisolated private static func resolveSpritesheetURL(
        bundleURL: URL,
        manifest: ClickyBuddyPetManifest
    ) -> URL? {
        let fm = FileManager.default
        // 1. Whatever the manifest says (treated as relative to bundle dir).
        let preferred = bundleURL.appendingPathComponent(manifest.spritesheetPath)
        if fm.fileExists(atPath: preferred.path) { return preferred }
        // 2. Conventional names.
        for name in ["spritesheet.webp", "spritesheet.png"] {
            let url = bundleURL.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

// MARK: - Library (filesystem watcher + cache)

/// Discovers and watches the canonical pets directory at `~/.codex/pets/`.
///
/// `~/.codex/pets/` is the canonical location read by Codex itself and any
/// other app that supports hatch-pet pets — that's where the library
/// displays from.
///
/// The hatch-pet skill, however, writes its packaged output to
/// `${CODEX_HOME}/pets/`, and OpenClicky exports `CODEX_HOME` to a sandboxed
/// app-support directory so its agent sessions don't pollute the user's
/// `~/.codex/`. To make pets hatched inside OpenClicky visible to the rest
/// of the system, we run a small "mirror" watcher on the sandbox pets dir
/// and copy any new bundles into `~/.codex/pets/`. The library's own watcher
/// then picks the copied bundle up just like any externally-installed pet.
@MainActor
final class ClickyBuddyPetLibrary: ObservableObject {
    static let shared = ClickyBuddyPetLibrary()

    @Published private(set) var pets: [ClickyBuddyPet] = []
    @Published private(set) var lastLoadError: String?

    /// Canonical pets directory — `~/.codex/pets/` (or `$CODEX_HOME/pets/`
    /// when the user has set `CODEX_HOME` for their shell). Pets shown in
    /// the picker come from here.
    let petsRootURL: URL

    /// Optional source directory mirrored into `petsRootURL`. When OpenClicky's
    /// agent writes a pet under its sandboxed `CODEX_HOME`, it lands here;
    /// the mirror copies it across so canonical readers see it too.
    let mirrorSourceURL: URL?

    private var displayWatcher: DispatchSourceFileSystemObject?
    private var mirrorWatcher: DispatchSourceFileSystemObject?
    private var watchedFDs: [CInt] = []
    private var refreshTask: Task<Void, Never>?
    private var mirrorTask: Task<Void, Never>?

    init(
        petsRootURL: URL = ClickyBuddyPetLibrary.defaultCanonicalPetsRootURL(),
        mirrorSourceURL: URL? = ClickyBuddyPetLibrary.defaultMirrorSourceURL()
    ) {
        self.petsRootURL = petsRootURL
        // Skip the mirror entirely if the source resolves to the canonical
        // root (would produce a self-copying loop).
        if let mirror = mirrorSourceURL,
           mirror.standardizedFileURL.path != petsRootURL.standardizedFileURL.path {
            self.mirrorSourceURL = mirror
        } else {
            self.mirrorSourceURL = nil
        }
        ensureRootsExist()
        // Run an initial mirror pass so any pet already sitting in the sandbox
        // (from a previous run) gets propagated to canonical on startup.
        scheduleMirror(delay: 0)
        scheduleRefresh(delay: 0)
        startWatching()
    }

    deinit {
        displayWatcher?.cancel()
        mirrorWatcher?.cancel()
        watchedFDs.forEach { close($0) }
    }

    /// `${CODEX_HOME:-$HOME/.codex}/pets/` — the canonical location.
    /// Uses the SHELL's `CODEX_HOME`, NOT OpenClicky's sandboxed override.
    nonisolated static func defaultCanonicalPetsRootURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        let codexHome: URL
        if let override = env["CODEX_HOME"], !override.isEmpty {
            codexHome = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            codexHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return codexHome.appendingPathComponent("pets", isDirectory: true)
    }

    /// `<OpenClicky app support>/CodexHome/pets/` — where in-app hatches
    /// land. Returned even if the directory doesn't exist yet; the watcher
    /// will create it.
    nonisolated static func defaultMirrorSourceURL() -> URL? {
        let openClickyCodexHome = CodexHomeManager
            .defaultApplicationSupportDirectory()
            .appendingPathComponent("CodexHome", isDirectory: true)
        return openClickyCodexHome.appendingPathComponent("pets", isDirectory: true)
    }

    func pet(withID id: String) -> ClickyBuddyPet? {
        pets.first { $0.id == id }
    }

    func refreshNow() {
        scheduleMirror(delay: 0)
        scheduleRefresh(delay: 0)
    }

    // MARK: - Private

    private func ensureRootsExist() {
        let fm = FileManager.default
        for url in [petsRootURL, mirrorSourceURL].compactMap({ $0 }) {
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    /// Coalesces rapid filesystem events (the hatch-pet finalizer drops several
    /// files in close succession) into a single reload after `delay` seconds.
    private func scheduleRefresh(delay: TimeInterval = 0.4) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
            }
            await self?.reload()
        }
    }

    private func reload() async {
        let url = petsRootURL
        let result: ([ClickyBuddyPet], String?) = await Task.detached(priority: .utility) {
            ClickyBuddyPetLibrary.scanPets(at: url)
        }.value

        self.pets = result.0.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        self.lastLoadError = result.1
    }

    nonisolated private static func scanPets(at root: URL) -> ([ClickyBuddyPet], String?) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], nil)
        }

        // Load every directory that has a valid bundle, then de-dupe by `id`.
        // Two folders can legitimately share an id when the user (or a buggy
        // tool) created a copy under a different folder name. We pick a
        // canonical winner instead of rendering both:
        //   1. Prefer the folder whose name matches the id (true canonical).
        //   2. Otherwise prefer the most recently modified.
        var byID: [String: (pet: ClickyBuddyPet, mtime: Date)] = [:]
        var firstError: String?

        for child in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
            do {
                let pet = try ClickyBuddyPetLoader.loadPet(at: child)
                let mtime = (try? fm.attributesOfItem(atPath: child.path)[.modificationDate]) as? Date ?? .distantPast

                if let existing = byID[pet.id] {
                    let existingIsCanonical = existing.pet.bundleURL.lastPathComponent == existing.pet.id
                    let candidateIsCanonical = pet.bundleURL.lastPathComponent == pet.id
                    let shouldReplace: Bool
                    if existingIsCanonical != candidateIsCanonical {
                        shouldReplace = candidateIsCanonical
                    } else {
                        shouldReplace = mtime > existing.mtime
                    }
                    if shouldReplace {
                        byID[pet.id] = (pet, mtime)
                    }
                } else {
                    byID[pet.id] = (pet, mtime)
                }
            } catch {
                if firstError == nil {
                    firstError = "Skipped \(child.lastPathComponent): \(error)"
                }
            }
        }
        return (byID.values.map(\.pet), firstError)
    }

    private func startWatching() {
        let queue = DispatchQueue.global(qos: .utility)

        // 1. Display watcher on the canonical root.
        if let source = makeWatcher(at: petsRootURL, queue: queue, onChange: { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }) {
            self.displayWatcher = source
        }

        // 2. Mirror watcher on the sandbox source — propagates new bundles
        //    into the canonical root.
        if let mirror = mirrorSourceURL,
           let source = makeWatcher(at: mirror, queue: queue, onChange: { [weak self] in
               Task { @MainActor in self?.scheduleMirror() }
           }) {
            self.mirrorWatcher = source
        }
    }

    private func makeWatcher(
        at url: URL,
        queue: DispatchQueue,
        onChange: @escaping () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        watchedFDs.append(fd)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        return source
    }

    // MARK: - Mirror

    private func scheduleMirror(delay: TimeInterval = 0.6) {
        guard let mirror = mirrorSourceURL else { return }
        mirrorTask?.cancel()
        let destination = petsRootURL
        mirrorTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
            }
            let copiedAny: Bool = await Task.detached(priority: .utility) {
                ClickyBuddyPetLibrary.mirrorPets(from: mirror, to: destination)
            }.value
            if copiedAny {
                self?.scheduleRefresh(delay: 0.1)
            }
        }
    }

    /// Copies every well-formed pet bundle in `source` into `destination`,
    /// overwriting on slug collision (the hatched bundle is presumed newer
    /// and authoritative). Returns true if anything was copied.
    nonisolated private static func mirrorPets(from source: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        var copiedAny = false
        for child in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
            // Only mirror complete bundles — pet.json + a sprite sheet must
            // both exist, otherwise the run is mid-finalize.
            let manifest = child.appendingPathComponent("pet.json")
            let webp = child.appendingPathComponent("spritesheet.webp")
            let png = child.appendingPathComponent("spritesheet.png")
            guard fm.fileExists(atPath: manifest.path),
                  fm.fileExists(atPath: webp.path) || fm.fileExists(atPath: png.path) else {
                continue
            }

            let target = destination.appendingPathComponent(child.lastPathComponent, isDirectory: true)
            do {
                if !shouldCopy(source: child, target: target, fileManager: fm) {
                    continue
                }
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
                try fm.copyItem(at: child, to: target)
                copiedAny = true
            } catch {
                NSLog("[ClickyBuddyPetLibrary] mirror copy failed for \(child.lastPathComponent): \(error)")
            }
        }
        return copiedAny
    }

    /// Skip the copy if the destination is byte-for-byte already up to date,
    /// to avoid churning the canonical-root watcher every startup.
    nonisolated private static func shouldCopy(
        source: URL,
        target: URL,
        fileManager fm: FileManager
    ) -> Bool {
        guard fm.fileExists(atPath: target.path) else { return true }

        // Compare manifest content + spritesheet size as a cheap "same enough"
        // probe. A real diff is overkill — collisions on 1.6MB sprite sheets
        // are vanishingly unlikely.
        let srcManifest = source.appendingPathComponent("pet.json")
        let dstManifest = target.appendingPathComponent("pet.json")
        guard let a = try? Data(contentsOf: srcManifest),
              let b = try? Data(contentsOf: dstManifest),
              a == b else { return true }

        for sheet in ["spritesheet.webp", "spritesheet.png"] {
            let s = source.appendingPathComponent(sheet)
            let d = target.appendingPathComponent(sheet)
            let sExists = fm.fileExists(atPath: s.path)
            let dExists = fm.fileExists(atPath: d.path)
            if sExists != dExists { return true }
            if sExists,
               let sSize = (try? fm.attributesOfItem(atPath: s.path)[.size]) as? Int,
               let dSize = (try? fm.attributesOfItem(atPath: d.path)[.size]) as? Int,
               sSize != dSize {
                return true
            }
        }
        return false
    }
}
