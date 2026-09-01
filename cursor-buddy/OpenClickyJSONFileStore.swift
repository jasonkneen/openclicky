//
//  OpenClickyJSONFileStore.swift
//  OpenClicky
//
//  The generic JSON-file persistence helpers now live in the OCFoundation
//  package. This file keeps the one product-specific member — the shared
//  "OpenClicky" directory under Application Support — in the app, where the
//  product name belongs.
//

import Foundation
import OCFoundation

extension OpenClickyJSONFileStore {
    /// The shared "OpenClicky" directory under Application Support, with an
    /// optional relative subpath appended (e.g. ["Logs"], ["agents"]).
    nonisolated static func openClickyDirectory(fileManager: FileManager = .default, subpath: [String] = []) -> URL {
        var url = applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("OpenClicky", isDirectory: true)
        for component in subpath {
            url = url.appendingPathComponent(component, isDirectory: true)
        }
        return url
    }
}
