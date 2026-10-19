import Foundation
import QuartzCore

struct TrackInfo: Equatable, Hashable {
    var id: String
    var uri: String
    var title: String
    var artists: [String]
    var album: String
    var duration: Double
    var artworkURL: URL?
    var isLocal: Bool

    var artistLine: String { artists.joined(separator: ", ") }
}

/// A track in a list (queue, history, search results).
struct TrackSummary: Identifiable, Hashable {
    /// Unique within one list (the same track can appear twice in a queue or history).
    var id: String
    var uri: String
    var title: String
    var artists: [String]
    var albumURI: String?
    var duration: Double
    var thumbnailURL: URL?
    /// Album or playlist this entry was played from (history only).
    var contextURI: String?

    var artistLine: String { artists.joined(separator: ", ") }
}

struct PlaybackSnapshot {
    enum Content: Equatable {
        case track(TrackInfo)
        case episode(title: String, show: String, artworkURL: URL?)
        case ad
        case unknown
    }

    var content: Content
    var isPlaying: Bool
    var progress: Double
    /// When the progress value was valid, in `CACurrentMediaTime()` seconds (latency compensated).
    var measuredAt: CFTimeInterval
    /// How long the answering request took: `measuredAt` is only this exact (± half of it).
    var roundTrip: Double
    /// The album / playlist / artist being played, e.g. `spotify:playlist:…`.
    var contextURI: String?
    var deviceName: String?
    /// Spotify Connect device type, e.g. "Smartphone", "Computer", "Speaker".
    var deviceType: String?
    /// `timestamp`: when the playback state last changed (play, pause, seek, new song), Unix seconds.
    var stateChangedAt: Double?
}

enum SpotifyAPIError: LocalizedError {
    case premiumRequired
    case noActiveDevice
    case restrictedAction
    case rateLimited(retryAfter: Double)
    /// The shared quota of the Client ID ran out (HTTP 429 `QUOTA_EXCEEDED`).
    case quotaExceeded(retryAfter: Double)
    /// The account isn't in the Client ID's User Management list (Development Mode).
    case userNotRegistered
    case missingScope
    case network(URLError)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .premiumRequired: return String(localized: "Управление воспроизведением через Web API доступно только с Spotify Premium.")
        case .noActiveDevice: return String(localized: "Нет активного устройства Spotify. Включите музыку в приложении Spotify.")
        case .restrictedAction: return String(localized: "Spotify не может выполнить это действие для текущего трека или устройства.")
        case .rateLimited: return String(localized: "Spotify временно ограничил запросы, повторим позже.")
        case .quotaExceeded:
            return String(localized: "У вашего Client ID закончился лимит запросов Spotify. Подождите немного.")
        case .userNotRegistered:
            return String(localized: "Этот аккаунт Spotify не добавлен в ваше приложение Spotify. В developer.spotify.com откройте приложение → Settings → User Management и добавьте e-mail этого аккаунта.")
        case .missingScope: return String(localized: "Нужно заново войти в Spotify, чтобы выдать приложению новое разрешение.")
        case .network(let error):
            switch error.code {
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return String(localized: "Не удалось установить защищённое соединение (TLS) со Spotify. Если включён VPN или прокси, попробуйте переподключить его.")
            case .notConnectedToInternet:
                return String(localized: "Нет подключения к интернету.")
            case .timedOut:
                return String(localized: "Spotify не ответил вовремя. Попробуйте ещё раз.")
            default:
                return String(localized: "Не удалось связаться со Spotify: \(error.localizedDescription)")
            }
        case .http(let code, _) where code >= 500:
            return String(localized: "Spotify сейчас не отвечает (ошибка \(code)). Попробуйте чуть позже.")
        case .http(let code, let message):
            return message.isEmpty ? String(localized: "Spotify вернул ошибку \(code).")
                                   : String(localized: "Spotify вернул ошибку \(code): \(message)")
        }
    }
}

/// The handful of Web API endpoints the app needs.
@MainActor
final class SpotifyAPI {
    private let auth: SpotifyAuth
    private var session: URLSession

    init(auth: SpotifyAuth) {
        self.auth = auth
        session = Self.makeSession()
    }

    /// A GET with the usual retries, for the endpoints kept in other files (`SpotifyVisuals`).
    func get(_ path: String) async throws -> (Data, Int) { try await send("GET", path) }

    func accessToken() async throws -> String { try await auth.accessToken() }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }

    // MARK: Playback state

    /// `nil` when nothing is playing (HTTP 204). Uses `/me/player`, whose `is_playing` follows
    /// pauses much more reliably than `/me/player/currently-playing`.
    func playbackState() async throws -> PlaybackSnapshot? {
        // Timed from the request that answered: a token refresh or a retry on a fresh connection
        // (both common right after returning to the app) must not count as network delay.
        var sentAt = CACurrentMediaTime()
        let (data, status) = try await send("GET", "/me/player?additional_types=track,episode",
                                            onRequest: { sentAt = $0 })
        let receivedAt = CACurrentMediaTime()
        if status == 204 || data.isEmpty { return nil }
        try check(status, data)

        let payload = try JSONDecoder().decode(PlaybackPayload.self, from: data)
        let content: PlaybackSnapshot.Content
        switch payload.currently_playing_type {
        case "ad":
            content = .ad
        case "episode":
            content = .episode(
                title: payload.item?.name ?? "",
                show: payload.item?.show?.name ?? "",
                artworkURL: payload.item?.images?.first.flatMap { URL(string: $0.url) }
            )
        default:
            if let item = payload.item, let info = Self.trackInfo(item) {
                content = .track(info)
            } else {
                content = .unknown
            }
        }
        // The server read the position roughly half way through the round trip.
        let measuredAt = sentAt + (receivedAt - sentAt) / 2
        return PlaybackSnapshot(
            content: content,
            isPlaying: payload.is_playing,
            progress: Double(payload.progress_ms ?? 0) / 1000,
            measuredAt: measuredAt,
            roundTrip: receivedAt - sentAt,
            contextURI: payload.context?.uri,
            deviceName: payload.device?.name,
            deviceType: payload.device?.type,
            stateChangedAt: payload.timestamp.map { Double($0) / 1000 }
        )
    }

    private static func trackInfo(_ item: ItemPayload) -> TrackInfo? {
        guard let uri = item.uri else { return nil }
        let images = item.album?.images ?? []
        return TrackInfo(
            id: item.id ?? uri,
            uri: uri,
            title: item.name ?? "",
            artists: item.artists?.map(\.name) ?? [],
            album: item.album?.name ?? "",
            duration: Double(item.duration_ms ?? 0) / 1000,
            artworkURL: (images.first { ($0.width ?? 0) >= 300 } ?? images.first).flatMap { URL(string: $0.url) },
            isLocal: item.is_local ?? false
        )
    }

    /// One song's details (cover, names), for a track App Remote announced.
    func track(id: String) async throws -> TrackInfo? {
        let (data, status) = try await send("GET", "/tracks/\(id)")
        try check(status, data)
        return Self.trackInfo(try JSONDecoder().decode(ItemPayload.self, from: data))
    }

    // MARK: Browsing

    /// Tracks coming up next (the user's queue, then the context).
    func queue() async throws -> [TrackSummary] {
        let (data, status) = try await send("GET", "/me/player/queue")
        if status == 204 || data.isEmpty { return [] }
        try check(status, data)
        struct Payload: Decodable { let queue: [ItemPayload?]? }
        let items = try JSONDecoder().decode(Payload.self, from: data).queue ?? []
        return items.enumerated().compactMap { index, item in
            item.flatMap { Self.summary($0, id: "\(index)") }
        }
    }

    /// Recently played tracks, newest first. Needs the `user-read-recently-played` scope.
    func recentlyPlayed() async throws -> [TrackSummary] {
        let (data, status) = try await send("GET", "/me/player/recently-played?limit=40")
        if status == 403 { throw SpotifyAPIError.missingScope }
        try check(status, data)
        struct Payload: Decodable {
            struct Entry: Decodable {
                let track: ItemPayload?
                let played_at: String?
                let context: ContextPayload?
            }
            let items: [Entry]?
        }
        var seen = Set<String>()
        return (try JSONDecoder().decode(Payload.self, from: data).items ?? []).compactMap { entry in
            guard let track = entry.track, var summary = Self.summary(track, id: entry.played_at ?? UUID().uuidString),
                  seen.insert(summary.uri).inserted
            else { return nil }
            summary.contextURI = entry.context?.uri
            return summary
        }
    }

    /// Track search. Development-mode apps get at most 10 results per page.
    func search(_ query: String, offset: Int = 0) async throws -> [TrackSummary] {
        var components = URLComponents()
        components.queryItems = [
            .init(name: "q", value: query),
            .init(name: "type", value: "track"),
            .init(name: "limit", value: "10"),
            .init(name: "offset", value: String(offset)),
        ]
        let (data, status) = try await send("GET", "/search?" + (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B"))
        try check(status, data)
        struct Payload: Decodable {
            struct Tracks: Decodable { let items: [ItemPayload?]? }
            let tracks: Tracks?
        }
        let items = try JSONDecoder().decode(Payload.self, from: data).tracks?.items ?? []
        return items.compactMap { item in item.flatMap { Self.summary($0, id: $0.uri ?? UUID().uuidString) } }
    }

    // MARK: Controls

    func play() async throws { try await control("PUT", "/me/player/play") }
    func pause() async throws { try await control("PUT", "/me/player/pause") }
    func next() async throws { try await control("POST", "/me/player/next", idempotent: false) }
    func previous() async throws { try await control("POST", "/me/player/previous", idempotent: false) }
    func seek(to seconds: Double) async throws {
        try await control("PUT", "/me/player/seek?position_ms=\(max(0, Int(seconds * 1000)))")
    }

    /// Starts `trackURI` inside an album or playlist, so playback continues from there.
    func play(trackURI: String, inContext contextURI: String) async throws {
        try await control("PUT", "/me/player/play", body: [
            "context_uri": contextURI,
            "offset": ["uri": trackURI],
        ])
    }

    func play(uris: [String]) async throws {
        try await control("PUT", "/me/player/play", body: ["uris": uris])
    }

    func addToQueue(_ uri: String) async throws {
        let encoded = uri.addingPercentEncoding(withAllowedCharacters: .formValueAllowed) ?? uri
        try await control("POST", "/me/player/queue?uri=\(encoded)", idempotent: false)
    }

    // MARK: Plumbing

    private func control(_ method: String, _ path: String, body: [String: Any]? = nil, idempotent: Bool = true) async throws {
        let json = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let (data, status) = try await send(method, path, body: json, idempotent: idempotent)
        try check(status, data)
    }

    private func check(_ status: Int, _ data: Data) throws {
        guard !(200..<300).contains(status) else { return }
        let error = (try? JSONDecoder().decode(ErrorPayload.self, from: data))?.error
        let message = error?.message ?? ""
        SyncLog.log("api", "HTTP \(status) \(error?.reason ?? "") \(message)")
        switch status {
        case 403 where message.lowercased().contains("premium") || error?.reason == "PREMIUM_REQUIRED":
            throw SpotifyAPIError.premiumRequired
        case 403 where message.localizedCaseInsensitiveContains("Restriction violated"):
            throw SpotifyAPIError.restrictedAction
        // "Check settings on developer.spotify.com/dashboard, the user may not be registered."
        case 403 where message.lowercased().contains("registered") || message.lowercased().contains("dashboard"):
            throw SpotifyAPIError.userNotRegistered
        case 404 where error?.reason == "NO_ACTIVE_DEVICE" || message.lowercased().contains("device"):
            throw SpotifyAPIError.noActiveDevice
        default: throw SpotifyAPIError.http(status, message)
        }
    }

    private func send(_ method: String, _ path: String, body: Data? = nil, idempotent: Bool = true,
                      retried: Bool = false, onRequest: (CFTimeInterval) -> Void = { _ in }) async throws -> (Data, Int) {
        let token = try await auth.accessToken()
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if method != "GET" {
            // Spotify wants a length on bodiless PUT/POST. Let URLSession write the header itself
            // (setting Content-Length by hand is unsupported and can break the connection).
            request.httpBody = body ?? Data()
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        }

        let (data, response) = try await perform(request, idempotent: idempotent || method == "GET", onRequest: onRequest)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 && !retried {
            _ = try await auth.accessToken(forceRefresh: true)
            return try await send(method, path, body: body, idempotent: idempotent, retried: true, onRequest: onRequest)
        }
        if status == 429 {
            let retryAfter = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
            let reason = (try? JSONDecoder().decode(ErrorPayload.self, from: data))?.error.reason
            if reason == "QUOTA_EXCEEDED" { throw SpotifyAPIError.quotaExceeded(retryAfter: max(retryAfter, 30)) }
            throw SpotifyAPIError.rateLimited(retryAfter: retryAfter)
        }
        return (data, status)
    }

    /// Runs a request, retrying transient connection failures (a dropped VPN, a stale pooled
    /// connection after the app was in the background, a failed TLS handshake) on a fresh session.
    private func perform(_ request: URLRequest, idempotent: Bool,
                         onRequest: (CFTimeInterval) -> Void = { _ in }) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            do {
                onRequest(CACurrentMediaTime())
                return try await session.data(for: request)
            } catch let error as URLError {
                attempt += 1
                guard attempt <= 2, Self.isRetryable(error, idempotent: idempotent) else {
                    throw SpotifyAPIError.network(error)
                }
                // Drop pooled connections: the next attempt does a brand new TLS handshake.
                session.finishTasksAndInvalidate()
                session = Self.makeSession()
                try await Task.sleep(for: .milliseconds(250 * attempt))
            }
        }
    }

    private static func isRetryable(_ error: URLError, idempotent: Bool) -> Bool {
        switch error.code {
        // The request never reached Spotify: always safe to send again.
        case .secureConnectionFailed, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        // It may have arrived, so only repeat requests that are harmless to repeat.
        case .networkConnectionLost, .timedOut:
            return idempotent
        default:
            return false
        }
    }

    private static func summary(_ item: ItemPayload, id: String) -> TrackSummary? {
        guard let uri = item.uri, item.type == nil || item.type == "track" || item.type == "episode" else { return nil }
        let images = item.album?.images ?? item.images ?? []
        let thumbnail = images.filter { ($0.width ?? 0) >= 64 }.min { ($0.width ?? 0) < ($1.width ?? 0) } ?? images.last
        return TrackSummary(
            id: id,
            uri: uri,
            title: item.name ?? "",
            artists: item.artists?.map(\.name) ?? item.show?.name.map { [$0] } ?? [],
            albumURI: item.album?.uri,
            duration: Double(item.duration_ms ?? 0) / 1000,
            thumbnailURL: thumbnail.flatMap { URL(string: $0.url) },
            contextURI: nil
        )
    }

    private struct ErrorPayload: Decodable {
        struct Inner: Decodable { let status: Int?; let message: String?; let reason: String? }
        let error: Inner
    }

    private struct ContextPayload: Decodable { let uri: String? }

    private struct ItemPayload: Decodable {
        struct Image: Decodable { let url: String; let width: Int? }
        struct Artist: Decodable { let name: String }
        struct Album: Decodable { let name: String?; let uri: String?; let images: [Image]? }
        struct Show: Decodable { let name: String? }
        let id: String?
        let uri: String?
        let type: String?
        let name: String?
        let duration_ms: Int?
        let is_local: Bool?
        let artists: [Artist]?
        let album: Album?
        let images: [Image]?
        let show: Show?
    }

    private struct PlaybackPayload: Decodable {
        struct Device: Decodable { let name: String?; let type: String? }
        let progress_ms: Int?
        let timestamp: Int64?
        let is_playing: Bool
        let currently_playing_type: String?
        let item: ItemPayload?
        let context: ContextPayload?
        let device: Device?
    }
}
