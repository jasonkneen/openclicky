//
//  OpenClickyJSONFileStore.swift
//  OCFoundation
//
//  Shared helpers for small JSON-file-backed stores: resolve the user's
//  Application Support directory (with a home-directory fallback), create
//  directories, and encode/decode Codable values atomically.
//
//  This type is deliberately product-neutral. Product-specific directory
//  layout (for example an app-named subfolder) belongs in the host app as an
//  extension on this enum.
//

import Foundation

public enum OpenClickyJSONFileStore {
    /// The user's Application Support directory, falling back to
    /// ~/Library/Application Support if FileManager can't resolve it.
    nonisolated public static func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    @discardableResult
    nonisolated public static func ensureDirectoryExists(_ url: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated public static var defaultEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    nonisolated public static var defaultDecoder: JSONDecoder {
        JSONDecoder()
    }

    /// Encodes `value` and writes it atomically to `fileURL`, creating the
    /// parent directory first.
    nonisolated public static func write<T: Encodable>(
        _ value: T,
        to fileURL: URL,
        fileManager: FileManager = .default,
        encoder: JSONEncoder = OpenClickyJSONFileStore.defaultEncoder
    ) throws {
        try ensureDirectoryExists(fileURL.deletingLastPathComponent(), fileManager: fileManager)
        let data = try encoder.encode(value)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Decodes `T` from `fileURL`, returning `nil` if the file is missing or
    /// decoding fails.
    nonisolated public static func read<T: Decodable>(
        _ type: T.Type,
        from fileURL: URL,
        fileManager: FileManager = .default,
        decoder: JSONDecoder = OpenClickyJSONFileStore.defaultDecoder
    ) -> T? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }
}
