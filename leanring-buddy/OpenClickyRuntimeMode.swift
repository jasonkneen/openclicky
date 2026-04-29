import Foundation

enum OpenClickyRuntimeMode {
    /// Bundle IDs for shipped OpenClicky and local forks (must stay in sync with the app target’s `PRODUCT_BUNDLE_IDENTIFIER`).
    private static let knownAppBundleIdentifiers: Set<String> = [
        "com.jkneen.openclicky",
        "com.heyitsaif.openclicky",
    ]

    static var isOpenClickyBundle: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return knownAppBundleIdentifiers.contains(id)
    }

    static var isDevelopmentBuild: Bool {
        #if DEBUG
        return true
        #else
        return isOpenClickyBundle
        #endif
    }

    static var stableApplicationPath: String {
        "/Applications/OpenClicky.app"
    }
}
