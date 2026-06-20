import Foundation

/// Persists local-model configuration. Base URL and numeric/boolean prefs live
/// in UserDefaults (not secret); the optional bearer token is keychain-backed
/// through `AppBundleConfiguration` (same mechanism as the other API secrets).
enum LocalModelSettingsStore {
    static let defaultBaseURLString = "http://localhost:11434/v1"

    private static let baseURLKey = "localModelBaseURL"
    private static let maxTokensKey = "localModelMaxOutputTokens"
    private static let foundationEnabledKey = "appleFoundationEnabled"

    static var baseURLString: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURLString }
        set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
    }

    /// A best-effort URL; falls back to the default if the stored string is invalid.
    static var baseURL: URL {
        URL(string: baseURLString) ?? URL(string: defaultBaseURLString)!
    }

    static var maxOutputTokens: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: maxTokensKey)
            return value > 0 ? value : 8_192
        }
        set { UserDefaults.standard.set(newValue, forKey: maxTokensKey) }
    }

    static var appleFoundationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: foundationEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: foundationEnabledKey) }
    }

    /// Optional bearer token (keychain-backed). Empty/nil clears it.
    static var token: String? {
        get { AppBundleConfiguration.localModelToken() }
        set {
            AppBundleConfiguration.persistSecret(
                newValue ?? "",
                defaultsKey: AppBundleConfiguration.userLocalModelTokenDefaultsKey)
        }
    }
}
