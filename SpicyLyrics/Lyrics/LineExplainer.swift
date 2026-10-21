import Foundation

/// "What does this line mean": the app's server asks Mercury, which reads the whole song and the
/// artists' bios (`cloudflare/src/explain.js`). Answers are kept for the session, so switching
/// between a line and the whole song is instant the second time.
struct LineExplanation: Decodable, Equatable {
    struct Note: Decodable, Equatable, Hashable {
        var phrase: String
        var note: String
    }
    struct Artist: Decodable, Equatable, Hashable {
        var name: String
        var summary: String
        var description: String?
        var url: String?
    }

    var summary: String
    var meaning: String
    var notes: [Note]
    var artists: [Artist]
    /// The server's name for this answer, for a complaint about it.
    var id: String?
}

/// Why a listener says an answer is no good.
enum ExplanationComplaint: String, CaseIterable, Identifiable {
    case wrong, language, offensive, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wrong: return String(localized: "Неправда или выдумка")
        case .language: return String(localized: "Не на моём языке")
        case .offensive: return String(localized: "Грубо или неуместно")
        case .other: return String(localized: "Другое…")
        }
    }

    var symbol: String {
        switch self {
        case .wrong: return "xmark.seal"
        case .language: return "character.bubble"
        case .offensive: return "hand.raised"
        case .other: return "ellipsis.bubble"
        }
    }

    /// The server drops the answer: asking again gets a new one.
    var replacesAnswer: Bool { self == .wrong || self == .language }
}

/// What to explain: a song, and one of its lines or none (the whole song).
struct ExplainRequest: Identifiable, Hashable {
    var track: TrackInfo
    /// The song's lines in their own language, interludes left out.
    var lines: [String]
    /// The line asked about, in `lines`; nil for the whole song.
    var index: Int?
    /// The asked-about line as it is on screen (romanized or translated, perhaps).
    var shownLine: String?

    var id: String { "\(track.id):\(index.map(String.init) ?? "song")" }

    /// Nil for songs with nothing to explain (no words in them).
    init?(track: TrackInfo, lyrics: PreparedLyrics, line: PreparedLine? = nil) {
        var lines: [String] = []
        var index: Int?
        for prepared in lyrics.lines where !prepared.isInterlude {
            let text = (prepared.sourceText.isEmpty ? prepared.plainText : prepared.sourceText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if prepared.id == line?.id { index = lines.count }
            lines.append(String(text.prefix(LineExplainer.maxLine)))
        }
        guard !lines.isEmpty, line == nil || index != nil else { return nil }
        self.track = track
        self.lines = Array(lines.prefix(LineExplainer.maxLines))
        self.index = index.flatMap { $0 < LineExplainer.maxLines ? $0 : nil }
        if line != nil && self.index == nil { return nil }
        self.shownLine = line?.plainText
    }

    /// The same song, about another line (or the whole song).
    func with(index: Int?) -> ExplainRequest {
        var copy = self
        copy.index = index
        if index == nil { copy.shownLine = nil }
        return copy
    }
}

@MainActor
enum LineExplainer {
    enum Failure: LocalizedError {
        case unavailable, limited, server, offline

        var errorDescription: String? {
            switch self {
            case .unavailable: return String(localized: "Объяснения сейчас недоступны.")
            case .limited: return String(localized: "Слишком много вопросов за час. Попробуйте чуть позже.")
            case .server: return String(localized: "Не получилось объяснить. Попробуйте ещё раз.")
            case .offline: return String(localized: "Нет соединения с интернетом.")
            }
        }
    }

    /// The server's limits.
    static let maxLines = 400
    static let maxLine = 500
    private static var endpoint: URL {
        #if DEBUG
        // A local copy of the Worker (`-explainEndpoint http://127.0.0.1:8787/v1/explain`).
        if let custom = UserDefaults.standard.string(forKey: "explainEndpoint").flatMap(URL.init(string:)) { return custom }
        #endif
        return URL(string: "https://sweet.sppq.dev/v1/explain")!
    }
    private static var cache: [String: LineExplanation] = [:]

    /// The answer in the app's language; the server only knows the translators' languages.
    static var language: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return AppSettings.translationLanguages.contains(code) ? code : "en"
    }

    static func cached(_ request: ExplainRequest) -> LineExplanation? {
        cache[key(request)]
    }

    static func explain(_ request: ExplainRequest) async throws -> LineExplanation {
        let key = key(request)
        if let hit = cache[key] { return hit }
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 30)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "track": ["title": request.track.title, "artists": request.track.artists, "album": request.track.album],
            "lines": request.lines,
            "index": request.index.map { $0 as Any } ?? NSNull(),
            "language": language,
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(error.code) {
            throw Failure.offline
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SyncLog.log("explain", "request failed: \(error.localizedDescription)")
            throw Failure.server
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 429: throw Failure.limited
        case 503: throw Failure.unavailable
        default:
            SyncLog.log("explain", "HTTP \(status)")
            throw Failure.server
        }
        guard let answer = try? JSONDecoder().decode(LineExplanation.self, from: data), !answer.meaning.isEmpty else {
            throw Failure.server
        }
        cache[key] = answer
        return answer
    }

    /// Tells the server what is wrong with an answer. A wrong or wrong-language one is forgotten
    /// here too, so the next look asks for a new one.
    static func report(_ answer: LineExplanation, for request: ExplainRequest, reason: ExplanationComplaint,
                       comment: String, installID: String) async throws {
        guard let id = answer.id else { throw Failure.server }
        var urlRequest = URLRequest(url: endpoint.appending(path: "report"), timeoutInterval: 20)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(installID, forHTTPHeaderField: "X-Install-Id")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "reason": reason.rawValue, "comment": comment])
        let (_, response) = try await URLSession.shared.data(for: urlRequest)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 429: throw Failure.limited
        default: throw Failure.server
        }
        if reason.replacesAnswer { cache[key(request)] = nil }
    }

    private static func key(_ request: ExplainRequest) -> String {
        "\(language):\(request.id):\(request.lines.count)"
    }
}
