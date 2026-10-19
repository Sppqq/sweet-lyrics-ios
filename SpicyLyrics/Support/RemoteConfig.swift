import Foundation

/// Request cadence, timeouts and cache lifetimes served by the Sweet Lyrics server
/// (`/v1/config`), so they can change without a new build, as Spicy Lyrics' `remoteConfig.ts`
/// does: during an incident the server can ask every install to poll less or give up sooner.
///
/// The last answer is kept and read back synchronously at launch, so a launch without network
/// keeps what it last knew. Every key stands on its own: one that is missing, of the wrong type
/// or out of its bounds keeps its compiled default while the rest still apply.
@MainActor
final class RemoteConfig {
    static let shared = RemoteConfig()

    struct Values: Equatable {
        /// Seconds a lyrics request may take.
        var lyricsTimeout: Double = 15
        /// Upcoming songs looked up ahead of time (with and without auto-skip).
        var lookaheadDepth = 2
        var lookaheadDepthSkipping = 6
        /// Seconds after a song starts before the queue is looked at.
        var lookaheadDelay: Double = 1.5
        /// Days found lyrics are kept, hours a "no lyrics" answer and LRCLIB lyrics are kept.
        var lyricsCacheDays: Double = 7
        var missCacheHours: Double = 24
        var lrclibCacheHours: Double = 24
        /// The Web API is never polled more often than this while a song plays, whatever the setting.
        var minWebPollInterval: Double = 0
        /// Kill switches.
        var autoReports = true
        var canvas = true
    }

    private(set) var values: Values

    /// Read without an actor hop by the lyrics cache, which runs off the main thread.
    nonisolated static var current: Values {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return Values() }
        return parse(data) ?? Values()
    }

    private static let storeKey = "remoteConfig.v1"
    private static let endpoint = URL(string: "https://sweet.sppq.dev/v1/config")!
    /// Asked at launch, then at most this often when the app comes back.
    private static let refreshInterval: TimeInterval = 30 * 60
    private var lastFetch: Date = .distantPast
    private var fetching = false

    private init() {
        values = UserDefaults.standard.data(forKey: Self.storeKey).flatMap(Self.parse) ?? Values()
    }

    /// Fetches the config unless it was fetched recently; quietly keeps the last one on failure.
    func refresh(force: Bool = false) async {
        guard !fetching, force || Date().timeIntervalSince(lastFetch) > Self.refreshInterval else { return }
        fetching = true
        defer { fetching = false }
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 10
        request.setValue("SweetLyrics-iOS/\(AppVersion.display)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = Self.parse(data)
        else { return }
        lastFetch = Date()
        UserDefaults.standard.set(data, forKey: Self.storeKey)
        if parsed != values {
            values = parsed
            SyncLog.log("config", "updated from the server")
        }
    }

    /// Each key on its own: unusable ones keep their default.
    nonisolated private static func parse(_ data: Data) -> Values? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var values = Values()
        func number(_ key: String, _ range: ClosedRange<Double>) -> Double? {
            guard let value = root[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let double = value.doubleValue
            return range.contains(double) ? double : nil
        }
        func flag(_ key: String) -> Bool? {
            guard let value = root[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return value.boolValue
        }
        if let v = number("lyricsTimeout", 3...60) { values.lyricsTimeout = v }
        if let v = number("lookaheadDepth", 0...10) { values.lookaheadDepth = Int(v) }
        if let v = number("lookaheadDepthSkipping", 0...20) { values.lookaheadDepthSkipping = Int(v) }
        if let v = number("lookaheadDelay", 0...60) { values.lookaheadDelay = v }
        if let v = number("lyricsCacheDays", 0.1...60) { values.lyricsCacheDays = v }
        if let v = number("missCacheHours", 0...240) { values.missCacheHours = v }
        if let v = number("lrclibCacheHours", 0...720) { values.lrclibCacheHours = v }
        if let v = number("minWebPollInterval", 0...60) { values.minWebPollInterval = v }
        if let v = flag("autoReports") { values.autoReports = v }
        if let v = flag("canvas") { values.canvas = v }
        return values
    }
}
