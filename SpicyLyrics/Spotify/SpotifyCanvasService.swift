import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Same lookup protocol as spicylyrics/mobile's SpotifyCanvasFinder. No user token is sent.
actor SpotifyCanvasService {
    static let shared = SpotifyCanvasService()
    private struct Entry {
        let url: URL?
        let expires: Date
    }
    enum LookupError: Error {
        case invalidResponse
        case http(Int)
        case retryLater(TimeInterval)
    }

    private let session: URLSession
    private let retryDelay: UInt64
    private var memo: [String: Entry] = [:]
    private var pausedUntil = Date.distantPast
    private var failurePause: TimeInterval = 0

    init(session: URLSession = .shared, retryDelay: UInt64 = 1_500_000_000) {
        self.session = session
        self.retryDelay = retryDelay
    }

    func find(trackID: String) async throws -> URL? {
        guard Self.isTrackID(trackID) else { return nil }
        if let cached = memo[trackID], cached.expires > Date() { return cached.url }
        guard Date() >= pausedUntil else {
            throw LookupError.retryLater(pausedUntil.timeIntervalSinceNow)
        }
        for attempt in 0..<2 {
            do {
                if attempt > 0 { try await Task.sleep(nanoseconds: retryDelay) }
                let url = try await lookup(trackID: trackID)
                try Task.checkCancellation()
                failurePause = 0
                if memo.count >= 100 { memo.removeAll() }
                memo[trackID] = Entry(url: url, expires: Date().addingTimeInterval(url == nil ? 86_400 : 604_800))
                return url
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                if case LookupError.retryLater(let seconds) = error {
                    pause(min(1800, max(60, seconds)))
                    throw error
                }
                if attempt == 1 {
                    pause(min(1800, max(60, failurePause * 2)))
                    throw error
                }
            }
        }
        throw LookupError.invalidResponse
    }

    private func pause(_ seconds: TimeInterval) {
        failurePause = seconds
        pausedUntil = Date().addingTimeInterval(seconds)
    }

    private func lookup(trackID: String) async throws -> URL? {
        let endpoint = URL(string: "https://regional.canvasstore.slnode.spicylyrics.org/provider/canvaslist")!
        var request = URLRequest(url: endpoint.appendingPathComponent(trackID))
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw LookupError.invalidResponse }
        if response.statusCode == 400 { return nil }
        guard (200..<300).contains(response.statusCode) else {
            if let raw = response.value(forHTTPHeaderField: "Retry-After"),
               let seconds = TimeInterval(raw), seconds.isFinite, seconds > 0 {
                throw LookupError.retryLater(seconds)
            }
            throw LookupError.http(response.statusCode)
        }
        return try Self.parse(data, trackID: trackID)
    }

    static func isTrackID(_ id: String) -> Bool {
        id.utf8.count == 22 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    /// A missing track or an error is a lookup failure, not a cached "no Canvas".
    static func parse(_ data: Data, trackID: String) throws -> URL? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [String: Any], let entry = entries[trackID]
        else { throw LookupError.invalidResponse }
        if entry is NSNull { return nil }
        guard let canvas = entry as? [String: Any], canvas["error"] == nil else {
            throw LookupError.invalidResponse
        }
        guard let raw = canvas["url"] as? String, let url = URL(string: raw),
              url.scheme == "https", url.host != nil, url.pathExtension.lowercased() == "mp4"
        else { return nil }
        return url
    }
}
