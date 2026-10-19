import Foundation

/// Turns a Spicy Lyrics API body (`{ Type, Content, Lines, StartTime, SongWriters, source }`)
/// into a `LyricsDocument`. Times in the API are seconds.
enum SpicyLyricsParser {
    static func parse(body: [String: Any]) -> LyricsDocument? {
        let type = JSONLoose.string(body["Type"]) ?? ""
        let songwriters = (body["SongWriters"] as? [Any])?.compactMap { $0 as? String } ?? []
        let rawSource = JSONLoose.string(body["source"])
        let sourceName = "Spicy Lyrics · " + originName(rawSource)
        let credits = parseCredits(body, rawSource: rawSource)

        switch type.lowercased() {
        case "syllable":
            let lines = parseSyllableLines(JSONLoose.objects(body["Content"]))
            guard !lines.isEmpty else { return nil }
            return LyricsDocument(kind: .syllable, lines: lines, songwriters: songwriters, sourceName: sourceName, credits: credits)
        case "line":
            let lines = parseLineLines(JSONLoose.objects(body["Content"]))
            guard !lines.isEmpty else { return nil }
            return LyricsDocument(kind: .line, lines: lines, songwriters: songwriters, sourceName: sourceName, credits: credits)
        default:
            let staticLines = JSONLoose.objects(body["Lines"]).compactMap { item -> LyricLine? in
                guard let text = JSONLoose.string(item["Text"]) else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                return LyricLine(start: 0, end: 0, oppositeAligned: false, text: trimmed,
                                 romanizedText: JSONLoose.string(item["TransliteratedText"]),
                                 lead: [], background: [])
            }
            guard !staticLines.isEmpty else { return nil }
            return LyricsDocument(kind: .static, lines: staticLines, songwriters: songwriters, sourceName: sourceName, credits: credits)
        }
    }

    private static func parseSyllables(_ raw: Any?) -> [LyricSyllable] {
        JSONLoose.objects(raw).compactMap { item in
            guard let text = JSONLoose.string(item["Text"]),
                  let start = JSONLoose.double(item["StartTime"]),
                  let end = JSONLoose.double(item["EndTime"])
            else { return nil }
            return LyricSyllable(
                text: text,
                romanized: JSONLoose.string(item["TransliteratedText"])?.nilIfBlank,
                start: start,
                end: max(end, start),
                joinsNext: JSONLoose.bool(item["IsPartOfWord"]) ?? false
            )
        }
    }

    private static func parseSyllableLines(_ content: [[String: Any]]) -> [LyricLine] {
        let defaultAgent = content.lazy.compactMap { JSONLoose.string($0["Agent"]) }.first
        var lines: [LyricLine] = []
        for item in content {
            if JSONLoose.string(item["Type"])?.lowercased() == "interlude" { continue }
            guard let lead = item["Lead"] as? [String: Any] else { continue }
            let leadSyllables = parseSyllables(lead["Syllables"]).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            let backgroundGroups = JSONLoose.objects(item["Background"])
                .map { parseSyllables($0["Syllables"]).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
                .filter { !$0.isEmpty }
            let background = backgroundGroups.flatMap { $0 }
            if leadSyllables.isEmpty && background.isEmpty { continue }

            let all = leadSyllables + background
            let start = min(JSONLoose.double(lead["StartTime"]) ?? .infinity, all.map(\.start).min() ?? .infinity)
            let end = max(JSONLoose.double(lead["EndTime"]) ?? 0, all.map(\.end).max() ?? 0)
            let agent = JSONLoose.string(item["Agent"])
            let opposite = JSONLoose.bool(item["OppositeAligned"])
                ?? (agent != nil && defaultAgent != nil && agent != defaultAgent)

            lines.append(LyricLine(
                start: start.isFinite ? start : 0,
                end: end,
                oppositeAligned: opposite,
                text: leadSyllables.map(\.text).joined(separator: " "),
                romanizedText: nil,
                lead: leadSyllables,
                background: background,
                backgroundGroups: backgroundGroups
            ))
        }
        return lines.sorted { $0.start < $1.start }
    }

    private static func parseLineLines(_ content: [[String: Any]]) -> [LyricLine] {
        content.compactMap { item -> LyricLine? in
            if JSONLoose.string(item["Type"])?.lowercased() == "interlude" { return nil }
            guard let text = JSONLoose.string(item["Text"])?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
                  let start = JSONLoose.double(item["StartTime"]),
                  let end = JSONLoose.double(item["EndTime"])
            else { return nil }
            return LyricLine(
                start: start,
                end: max(end, start),
                oppositeAligned: JSONLoose.bool(item["OppositeAligned"]) ?? false,
                text: text,
                romanizedText: JSONLoose.string(item["TransliteratedText"])?.nilIfBlank,
                lead: [],
                background: []
            )
        }
        .sorted { $0.start < $1.start }
    }

    // MARK: Attribution

    /// "Provided by" plus the community maker / uploader, as the extension shows them
    /// (`ApplyProvider.ts`, `ApplyIsByCommunity.tsx`). The v1 API calls the block
    /// `UploadAttribution`; the `/query` payload calls it `TTMLUploadMetadata`.
    private static func parseCredits(_ body: [String: Any], rawSource: String?) -> LyricsCredits {
        let upload = (body["UploadAttribution"] as? [String: Any]) ?? (body["TTMLUploadMetadata"] as? [String: Any])
        let maker = contributor(upload?["Maker"])
        let uploader = contributor(upload?["Uploader"])
        let source = (rawSource ?? "").lowercased()
        let isCommunity = source.contains("spl") || source.contains("community")
            || ((maker != nil || uploader != nil) && !source.contains("aml") && !source.contains("spt"))
        let via = JSONLoose.string(body["source_via"]).flatMap { viaMap[$0] }
        return LyricsCredits(
            providedBy: providerLabel(rawSource),
            isCommunity: isCommunity,
            maker: maker,
            uploader: uploader,
            via: via?.label,
            viaURL: via?.url
        )
    }

    /// Spicy Lyrics' `ViaMap`: the utm_source lets the source tell visits that came from here.
    private static let viaMap: [String: (label: String, url: URL?)] = [
        "lrc-red": ("lrc.red", URL(string: "https://lrc.red/?utm_source=spicylyrics")),
    ]

    /// Spicy Lyrics' `ProviderMap`.
    private static func providerLabel(_ raw: String?) -> String {
        let source = (raw ?? "").lowercased()
        if source.contains("spt") || source.contains("spotify") { return "Spotify" }
        if source.contains("aml") || source.contains("apple") { return "Apple Music" }
        if source.contains("spl") || source.contains("spicy") || source.contains("community") { return "Spicy Lyrics" }
        if source.contains("ldb") { return "Local DB" }
        if source.contains("uns") { return "Unison" }
        return "Spicy Lyrics"
    }

    private static let trustedProfileHosts: Set<String> = ["spicylyrics.org", "www.spicylyrics.org", "github.com"]

    /// A maker / uploader: a bare name, or `{ username, id, avatar, url }` in any of the casings seen.
    static func contributor(_ value: Any?) -> LyricsContributor? {
        if let name = (value as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return LyricsContributor(name: name.hasPrefix("@") ? String(name.dropFirst()) : name)
        }
        guard let item = value as? [String: Any] else { return nil }
        func text(_ keys: [String]) -> String? {
            for key in keys {
                if let string = (item[key] as? String)?.trimmingCharacters(in: .whitespaces), !string.isEmpty { return string }
                if let number = item[key] as? NSNumber { return number.stringValue }
            }
            return nil
        }
        guard var name = text(["username", "Username", "name", "Name"]) else { return nil }
        if name.hasPrefix("@") { name.removeFirst() }

        var profile = text(["url", "Url", "profileUrl", "ProfileUrl"]).flatMap(URL.init(string:))
            .flatMap { url -> URL? in
                guard url.scheme == "https", let host = url.host?.lowercased(), trustedProfileHosts.contains(host) else { return nil }
                return url
            }
        if profile == nil, let id = text(["id", "Id", "uid", "userId"]),
           let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            profile = URL(string: "https://spicylyrics.org/uid/\(encoded)")
        }
        let avatar = text(["avatar", "Avatar", "avatarUrl"]).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return LyricsContributor(name: name, profileURL: profile, avatarURL: avatar)
    }

    static func originName(_ raw: String?) -> String {
        let key = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        switch key {
        case "apple", "apple_music", "am", "aml": return "Apple Music"
        case "spotify", "spotify_lyrics", "spt": return "Spotify"
        case "spicy", "spicy_lyrics", "community", "spl": return "Community"
        case "": return "API"
        default: return raw ?? "API"
        }
    }
}

/// Parses `[mm:ss.xx] text` LRC (as served by LRCLIB) into a line-timed document.
enum LRCParser {
    static func parse(_ lrc: String, duration: Double?, sourceName: String) -> LyricsDocument? {
        var timed: [(Double, String)] = []
        let tagPattern = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)

        for rawLine in lrc.components(separatedBy: .newlines) {
            let ns = rawLine as NSString
            let matches = tagPattern.matches(in: rawLine, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                timed.append((minutes * 60 + seconds, text))
            }
        }
        timed.sort { $0.0 < $1.0 }

        var lines: [LyricLine] = []
        for (index, entry) in timed.enumerated() where !entry.1.isEmpty {
            let nextStart = index + 1 < timed.count ? timed[index + 1].0 : (duration ?? entry.0 + 5)
            // A line ends where the next one starts, but a long gap still deserves an interlude.
            let end = nextStart - entry.0 > 10 ? entry.0 + 6 : nextStart
            lines.append(LyricLine(start: entry.0, end: max(end, entry.0 + 0.1), oppositeAligned: false,
                                   text: entry.1, romanizedText: nil, lead: [], background: []))
        }
        guard !lines.isEmpty else { return nil }
        return LyricsDocument(kind: .line, lines: lines, songwriters: [], sourceName: sourceName,
                              credits: LyricsCredits(providedBy: sourceName))
    }

    static func plain(_ text: String, sourceName: String) -> LyricsDocument? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LyricLine(start: 0, end: 0, oppositeAligned: false, text: $0, romanizedText: nil, lead: [], background: []) }
        guard !lines.isEmpty else { return nil }
        return LyricsDocument(kind: .static, lines: lines, songwriters: [], sourceName: sourceName,
                              credits: LyricsCredits(providedBy: sourceName))
    }
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
