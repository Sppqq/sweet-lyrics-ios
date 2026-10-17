import Foundation

/// Version info stamped in by the build (see `.github/workflows/ios-build.yml`).
enum AppVersion {
    static var marketing: String { info("CFBundleShortVersionString") ?? "0" }
    static var build: String { info("CFBundleVersion") ?? "0" }
    /// `release`, `alpha`, `pr` or `dev` (local Xcode builds).
    static var channel: String { info("SpicyLyricsChannel") ?? "dev" }

    /// e.g. "0.2.0 (57)" for releases, "0.2.1-alpha.57" for alphas.
    static var display: String {
        switch channel {
        case "release": return "\(marketing) (\(build))"
        case "alpha", "pr": return "\(marketing)-\(channel).\(build)"
        default: return "\(marketing) (\(build), dev)"
        }
    }

    private static func info(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.nilIfBlank
    }
}

enum AppLinks {
    /// This app's repository: the star row in Settings and Settings → About open it.
    static let repository = URL(string: "https://github.com/Sppqq/sweet-lyrics-ios")!
}
