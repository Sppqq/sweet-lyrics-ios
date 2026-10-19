import Foundation

enum LyricsLookupResult {
    case found(LyricsDocument)
    case notFound
    case failed(LyricsFailure)
    case cancelled
}

/// Keeps source-specific caches while resolving online lyrics by metadata when needed.
@MainActor
final class LyricsService {
    private let settings: AppSettings
    private let auth: SpotifyAuth
    private let cache = LyricsDiskCache()
    private let session: URLSession
    private var memory: [String: LyricsDocument] = [:]
    private let spotify: SpotifyAPI
    private var spotifyMatches: [String: String]
    private var spotifyMisses: Set<String> = []
    private static let matchesKey = "appleMusicSpotifyMatches.v1"

    private static let spicyHost = URL(string: "https://api.spicylyrics.org")!
    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private let local: LocalLyricsStore

    init(settings: AppSettings, auth: SpotifyAuth, local: LocalLyricsStore) {
        self.settings = settings
        self.auth = auth
        self.local = local
        spotify = SpotifyAPI(auth: auth)
        spotifyMatches = UserDefaults.standard.dictionary(forKey: Self.matchesKey) as? [String: String] ?? [:]
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = RemoteConfig.shared.values.lyricsTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        let cache = cache
        Task.detached(priority: .background) { cache.prune() }
    }

    func lyrics(for track: TrackInfo, ignoreCache: Bool = false) async -> LyricsLookupResult {
        // The user's own TTML wins over every online source (the extension's Local DB).
        if let document = local.document(for: track.id) { return .found(document) }
        if !ignoreCache {
            if let hit = memory[track.id] {
                if !hit.isNoLyricsPlaceholder { return .found(hit) }
                memory.removeValue(forKey: track.id)
            }
            // Off the main thread: a big document takes a moment to decode.
            let cache = cache, id = track.id
            switch await Task.detached(priority: .userInitiated, operation: { cache.read(id) }).value {
            case .hit(let document):
                memory[track.id] = document
                return .found(document)
            case .miss:
                return .notFound
            case .none:
                break
            }
        }

        /// Each source that failed, in the order asked; the first one's cause is the notice.
        var failures: [(notice: LyricsNotice, line: String)] = []
        var confirmedInstrumental = false

        let appleMusic = track.id.hasPrefix("am:")
        let spicyID: String? = appleMusic ? await spotifyID(for: track) : track.id
        if !track.isLocal, let spicyID {
            do {
                if let document = try await fetchSpicy(trackID: spicyID) {
                    // Spicy Lyrics answered "no words": a later LRCLIB failure must not turn it into an error.
                    if document.isNoLyricsPlaceholder { confirmedInstrumental = true } else {
                        remember(document, for: track.id)
                        return .found(document)
                    }
                }
            } catch is CancellationError {
                return .cancelled
            } catch {
                failures.append((LyricsNotice.classify(error), "Spicy Lyrics: \(error.localizedDescription)"))
            }
        }

        if settings.useLRCLibFallback || appleMusic {
            do {
                switch try await fetchLRCLib(track) {
                case .document(let document) where !document.isNoLyricsPlaceholder:
                    remember(document, for: track.id)
                    return .found(document)
                case .instrumental:
                    confirmedInstrumental = true
                case .document, .missing:
                    break
                }
            } catch is CancellationError {
                return .cancelled
            } catch {
                // LRCLIB is only a fallback. When Spicy Lyrics already said "no lyrics", an LRCLIB
                // outage (e.g. HTTP 503) is not a failure: say "not found" and don't cache a miss, so
                // the next attempt asks again.
                SyncLog.shared.add("lyrics", "LRCLIB unavailable: \(error.localizedDescription)")
                if failures.isEmpty { return .notFound }
                failures.append((LyricsNotice.classify(error), "LRCLIB: \(error.localizedDescription)"))
            }
        }

        if failures.isEmpty || confirmedInstrumental {
            let cache = cache, id = track.id
            Task.detached(priority: .utility) { cache.writeMiss(id) }
            return .notFound
        }
        let first = failures[0]
        return .failed(LyricsFailure(notice: first.notice, detail: failures.map(\.line).joined(separator: "\n"),
                                     source: first.line.components(separatedBy: ":").first))
    }

    func clearCache() {
        memory.removeAll()
        spotifyMatches.removeAll()
        spotifyMisses.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.matchesKey)
        cache.clear()
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func titleCore(_ text: String) -> String {
        let core = text.components(separatedBy: " - ").first ?? text
        let withoutVersion = core.replacingOccurrences(of: #"[\(\[].*$"#, with: "", options: .regularExpression)
        let withoutFeature = withoutVersion.replacingOccurrences(
            of: #"(?i)\b(?:feat\.?|ft\.?|featuring)\s+.*$"#, with: "", options: .regularExpression)
        return normalized(withoutFeature)
    }

    private static func firstArtist(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)\s*(?:&|,|\bfeat\.?\s|\bft\.?\s|\bfeaturing\s).*$"#,
                                  with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func spotifyID(for track: TrackInfo) async -> String? {
        let title = Self.titleCore(track.title)
        let artistLine = track.artists.joined(separator: ", ")
        let artist = Self.normalized(artistLine)
        guard !title.isEmpty, !artist.isEmpty, track.duration > 0 else { return nil }
        let key = "\(Self.normalized(track.title))|\(artist)|\(Int(track.duration.rounded()))"
        if let id = spotifyMatches[key], auth.isLoggedIn || settings.validSpicyKey != nil { return id }
        guard auth.isLoggedIn, !spotifyMisses.contains(key) else { return nil }
        let safeTitle = track.title.replacingOccurrences(of: "\"", with: " ")
        let safeArtist = artistLine.replacingOccurrences(of: "\"", with: " ")
        func bestMatch(in results: [TrackSummary]) -> TrackSummary? {
            results.filter { candidate in
                let candidateTitle = Self.titleCore(candidate.title)
                let titleMatches = candidateTitle == title || (min(candidateTitle.count, title.count) >= 3
                    && (candidateTitle.contains(title) || title.contains(candidateTitle)))
                let artistMatches = candidate.artists.enumerated().contains { index, name in
                    let candidateArtist = Self.normalized(name)
                    guard !candidateArtist.isEmpty else { return false }
                    return artist.contains(candidateArtist) || (index == 0 && candidateArtist.contains(artist))
                }
                return abs(candidate.duration - track.duration) <= 3 && titleMatches && artistMatches
                    && candidate.uri.hasPrefix("spotify:track:")
            }.min { abs($0.duration - track.duration) < abs($1.duration - track.duration) }
        }
        do {
            let results = try await spotify.search("track:\"\(safeTitle)\" artist:\"\(safeArtist)\"")
            guard !Task.isCancelled else { return nil }
            var match = bestMatch(in: results)
            if match == nil {
                let query = "\(title) \(Self.firstArtist(artistLine))"
                match = bestMatch(in: try await spotify.search(query))
            }
            guard !Task.isCancelled else { return nil }
            guard let match, let id = match.uri.split(separator: ":").last else {
                // Only completed lookups are misses; an outage must remain retryable.
                spotifyMisses.insert(key)
                return nil
            }
            if spotifyMatches.count >= 1000 { spotifyMatches.removeAll() }
            spotifyMatches[key] = String(id)
            UserDefaults.standard.set(spotifyMatches, forKey: Self.matchesKey)
            return String(id)
        } catch {
            SyncLog.shared.add("lyrics", "Apple Music match unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private func remember(_ document: LyricsDocument, for id: String) {
        memory[id] = document
        let cache = cache
        Task.detached(priority: .utility) { cache.write(document, for: id) }
    }

    // MARK: Spicy Lyrics

    private enum SpicyError: LocalizedError, HTTPStatusError {
        case http(Int, String?)
        case unauthorized
        case malformed

        var status: Int? {
            switch self {
            case .http(let code, _): return code
            case .unauthorized: return 401
            case .malformed: return nil
            }
        }

        var errorDescription: String? {
            switch self {
            case .http(let code, let message): return "HTTP \(code)" + (message.map { ": \($0)" } ?? "")
            case .unauthorized: return String(localized: "сервер не принял авторизацию (добавьте ключ sl_pk_ в настройках)")
            case .malformed: return String(localized: "непонятный ответ сервера")
            }
        }
    }

    /// With a personal client key this uses the public `/v1/lyrics/{id}` endpoint (what the
    /// Android app uses). Without one it falls back to the `/query` endpoint the Spicetify
    /// extension uses, authenticated by the user's Spotify token.
    private func fetchSpicy(trackID: String) async throws -> LyricsDocument? {
        for attempt in 0..<4 {
            let outcome: SpicyOutcome
            if let key = settings.validSpicyKey {
                outcome = try await spicyV1(trackID: trackID, key: key)
            } else {
                outcome = try await spicyQuery(trackID: trackID)
            }
            switch outcome {
            case .document(let document): return document
            case .missing: return nil
            case .queued(let wait):
                // The server accepted the request and is fetching the lyrics; poll again.
                guard attempt < 3 else { throw SpicyError.http(503, String(localized: "в очереди")) }
                try await Task.sleep(for: .seconds(min(max(wait, 2), 10)))
            }
        }
        return nil
    }

    private enum SpicyOutcome {
        case document(LyricsDocument)
        case missing
        case queued(Double)
    }

    private func spicyV1(trackID: String, key: String) async throws -> SpicyOutcome {
        var request = URLRequest(url: Self.spicyHost.appendingPathComponent("v1/lyrics").appendingPathComponent(trackID))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("SpicyLyrics-iOS/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        switch status {
        case 200:
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SpicyError.malformed }
            if let inner = JSONLoose.double(root["Status"]), Int(inner) != 200 { return .missing }
            guard let body = root["Body"] as? [String: Any] else { throw SpicyError.malformed }
            return SpicyLyricsParser.parse(body: body).map(SpicyOutcome.document) ?? .missing
        case 404:
            return .missing
        case 503:
            return .queued(Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 4)
        case 401, 403:
            throw SpicyError.unauthorized
        default:
            throw SpicyError.http(status, Self.apiMessage(data))
        }
    }

    private func spicyQuery(trackID: String) async throws -> SpicyOutcome {
        var token = try await auth.accessToken()
        for retry in 0..<2 {
            var request = URLRequest(url: Self.spicyHost.appendingPathComponent("query"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2", forHTTPHeaderField: "X-mode")
            request.setValue("ios-\(Self.appVersion)", forHTTPHeaderField: "SpicyLyrics-Version")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "SpicyLyrics-WebAuth")
            let body: [String: Any] = [
                "queries": [["operation": "lyrics", "variables": ["id": trackID, "auth": "SpicyLyrics-WebAuth"]]],
                "client": ["version": "ios-\(Self.appVersion)"],
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                // The token may have just expired on Spotify's side: one more try on a fresh one,
                // as the extension does since 6.3.
                if status == 401, retry == 0 {
                    token = try await auth.accessToken(forceRefresh: true)
                    continue
                }
                if status == 401 || status == 403 { throw SpicyError.unauthorized }
                throw SpicyError.http(status, Self.apiMessage(data))
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SpicyError.malformed }
            let jobs = JSONLoose.objects(root["queries"])
            guard let job = jobs.first(where: { ($0["operationId"] as? String) == "0" }) ?? jobs.first,
                  let result = job["result"] as? [String: Any]
            else { throw SpicyError.malformed }

            let innerStatus = Int(JSONLoose.double(result["httpStatus"]) ?? 0)
            switch innerStatus {
            case 200:
                var payload: Any? = result["data"]
                if let packed = payload as? [Any] { payload = try ObjPack.unpack(packed) }
                guard let lyrics = payload as? [String: Any] else { return .missing }
                return SpicyLyricsParser.parse(body: lyrics).map(SpicyOutcome.document) ?? .missing
            case 404:
                return .missing
            case 503:
                return .queued(4)
            case 401 where retry == 0:
                token = try await auth.accessToken(forceRefresh: true)
                continue
            case 401, 403:
                throw SpicyError.unauthorized
            default:
                throw SpicyError.http(innerStatus, nil)
            }
        }
        throw SpicyError.unauthorized
    }

    private static func apiMessage(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["Body"] as? [String: Any]
        else { return nil }
        return (body["message"] as? String) ?? (body["error"] as? String)
    }

    // MARK: LRCLIB

    private enum LRCLibOutcome {
        case document(LyricsDocument)
        case instrumental
        case missing
    }

    private func fetchLRCLib(_ track: TrackInfo) async throws -> LRCLibOutcome {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            .init(name: "track_name", value: track.title),
            .init(name: "artist_name", value: track.artists.first ?? ""),
            .init(name: "album_name", value: track.album),
            .init(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("SpicyLyrics-iOS/\(Self.appVersion) (https://github.com/Spikerko/spicy-lyrics)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return .missing }
        guard status == 200 else { throw SpicyError.http(status, nil) }

        struct Payload: Decodable {
            let syncedLyrics: String?
            let plainLyrics: String?
            let instrumental: Bool?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        if payload.instrumental == true {
            return .instrumental
        }
        if let synced = payload.syncedLyrics?.nilIfBlank,
           let document = LRCParser.parse(synced, duration: track.duration, sourceName: "LRCLIB") {
            return .document(document)
        }
        if let plain = payload.plainLyrics?.nilIfBlank {
            return LRCParser.plain(plain, sourceName: "LRCLIB").map(LRCLibOutcome.document) ?? .missing
        }
        return .missing
    }
}

private extension LyricsDocument {
    /// Some catalogue responses encode an empty result as a one-line static document.
    /// Treat only a document made entirely of known empty-result labels as not found, so
    /// ordinary lyrics that happen to contain similar words remain untouched.
    var isNoLyricsPlaceholder: Bool {
        guard kind == .static, !lines.isEmpty else { return false }
        let placeholders: Set<String> = [
            "нет текста", "нет текст", "текст не найден", "♪ без слов ♪",
            "no lyrics", "no lyrics found", "lyrics not found", "♪ instrumental ♪"
        ]
        return lines.allSatisfy { line in
            let normalized = line.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "ru"))
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: "!", with: "")
                .replacingOccurrences(of: "…", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return placeholders.contains(normalized)
        }
    }
}

/// Lyrics on disk, keyed by Spotify track ID. Spicy Lyrics hits live a week; misses and LRCLIB
/// stand-ins a day, so a sync added to Spicy Lyrics meanwhile shows up soon.
struct LyricsDiskCache {
    enum Entry {
        case hit(LyricsDocument)
        case miss
    }

    private struct Record: Codable {
        var savedAt: Date
        var document: LyricsDocument?
    }

    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("lyrics-v3", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func file(_ id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent(safe + ".json")
    }

    func read(_ id: String) -> Entry? {
        guard let data = try? Data(contentsOf: file(id)),
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return nil }
        let age = -record.savedAt.timeIntervalSinceNow
        if let document = record.document {
            if document.isNoLyricsPlaceholder {
                try? FileManager.default.removeItem(at: file(id))
                return nil
            }
            let config = RemoteConfig.current
            // Synced lyrics, from any source, are kept as long as the user chose.
            let lifetime: TimeInterval = document.kind != .static
                ? AppSettings.syncedLyricsCacheDaysStored * 86_400
                : document.sourceName.hasPrefix("LRCLIB") ? config.lrclibCacheHours * 3600 : config.lyricsCacheDays * 86_400
            return age < lifetime ? .hit(document) : nil
        }
        return age < RemoteConfig.current.missCacheHours * 3600 ? .miss : nil
    }

    private static var hitLifetime: TimeInterval {
        max(7, RemoteConfig.current.lyricsCacheDays, AppSettings.syncedLyricsCacheDaysStored) * 86_400
    }

    /// Deletes entries nothing would read any more, so the cache does not grow forever.
    func prune() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if -modified.timeIntervalSinceNow > Self.hitLifetime { try? manager.removeItem(at: file) }
        }
    }

    func write(_ document: LyricsDocument, for id: String) {
        save(Record(savedAt: Date(), document: document), id)
    }

    func writeMiss(_ id: String) {
        save(Record(savedAt: Date(), document: nil), id)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func save(_ record: Record, _ id: String) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: file(id), options: .atomic)
    }
}
