import Foundation

enum OpenClickyRuntimeMode {
    static var isOpenClickyBundle: Bool {
        Bundle.main.bundleIdentifier == "com.jkneen.openclicky"
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
