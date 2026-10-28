import Foundation

/// How a lyrics document is timed. Mirrors Spicy Lyrics' `Syllable` / `Line` / `Static` types.
enum LyricsKind: String, Codable {
    case syllable = "Syllable"
    case line = "Line"
    case `static` = "Static"
}

/// One timed piece of text. All times are in seconds.
struct LyricSyllable: Codable, Hashable {
    var text: String
    var romanized: String?
    var start: Double
    var end: Double
    /// The next syllable belongs to the same word (no space between them).
    var joinsNext: Bool
}

struct LyricLine: Codable, Hashable {
    var start: Double
    var end: Double
    /// Duet partner: drawn on the opposite side.
    var oppositeAligned: Bool
    /// Plain text for `line` / `static` documents.
    var text: String
    var romanizedText: String?
    /// Word-timed lead vocal (only for `syllable` documents).
    var lead: [LyricSyllable]
    /// Word-timed background vocals, all groups flattened (kept for lyrics cached before
    /// `backgroundGroups` existed).
    var background: [LyricSyllable]
    /// Each background group on its own: the extension gives every one its own `bg-line`, so a
    /// line can have two background vocals one after the other.
    var backgroundGroups: [[LyricSyllable]]? = nil

    var backgroundVocals: [[LyricSyllable]] {
        backgroundGroups ?? (background.isEmpty ? [] : [background])
    }
}

/// A person credited for a sync (Spicy Lyrics' `UploadAttribution` / `TTMLUploadMetadata`).
struct LyricsContributor: Codable, Hashable {
    var name: String
    var profileURL: URL?
    var avatarURL: URL?
}

/// The attribution shown after the lyrics, as the Spicy Lyrics API asks clients to.
/// Optional fields so lyrics cached before they existed still decode.
struct LyricsCredits: Codable, Hashable {
    /// The catalogue that answered: "Apple Music", "Spotify", "Spicy Lyrics", "LRCLIB"…
    var providedBy: String?
    /// A Spicy Lyrics community sync ("These lyrics have been provided by our community").
    var isCommunity: Bool?
    var maker: LyricsContributor?
    var uploader: LyricsContributor?
    /// Where the provider got them, e.g. "lrc.red" (the extension's `source_via`).
    var via: String?
    var viaURL: URL?
}

struct LyricsDocument: Codable, Hashable {
    var kind: LyricsKind
    var lines: [LyricLine]
    var songwriters: [String]
    /// Human readable provider, e.g. "Spicy Lyrics · Apple Music".
    var sourceName: String
    var credits: LyricsCredits? = nil

    var hasRomanization: Bool {
        lines.contains { line in
            line.romanizedText != nil
                || line.lead.contains { $0.romanized != nil }
                || line.background.contains { $0.romanized != nil }
        }
    }
}

// MARK: - Prepared (render-ready) model

/// A letter of an emphasized ("letter capable") syllable, with its own slice of the syllable's time.
struct PreparedLetter: Hashable {
    var text: String
    var start: Double
    var end: Double
}

struct PreparedSyllable: Hashable {
    var text: String
    var start: Double
    var end: Double
    /// Non-nil when the syllable is long enough to animate letter by letter.
    var letters: [PreparedLetter]?
}

/// Syllables that are glued together into one word and must never wrap apart.
struct PreparedWord: Hashable {
    var syllables: [PreparedSyllable]
}

enum PreparedLineKind: Hashable {
    case syllable(lead: [PreparedWord], background: [PreparedWord])
    case line(text: String)
    case `static`(text: String)
    /// "• • •" shown during instrumental gaps.
    case interlude(dots: [PreparedLetter])
}

struct PreparedLine: Identifiable, Hashable {
    let id: Int
    var start: Double
    var end: Double
    var oppositeAligned: Bool
    var kind: PreparedLineKind
    /// A background vocal (`.line.bg-line`): its own row under its lead line, smaller and dimmer.
    var isBackground = false
    /// The actual singing end, retained when Minimal Lyrics Mode extends visual timing.
    var vocalEnd: Double? = nil
    var singingEnd: Double { vocalEnd ?? end }
    /// For background rows: the lead line they belong to.
    var leadID: Int?
    /// The line in its original language and script, what gets translated.
    var sourceText = ""

    var isInterlude: Bool {
        if case .interlude = kind { return true }
        return false
    }

    /// The line as plain text (copy / share).
    var plainText: String {
        switch kind {
        case .syllable(let lead, let background):
            return (lead + background).map { $0.syllables.map(\.text).joined() }.joined(separator: " ")
        case .line(let text), .static(let text):
            return text
        case .interlude:
            return ""
        }
    }
}

struct PreparedLyrics: Hashable {
    var kind: LyricsKind
    var lines: [PreparedLine]
    var songwriters: [String]
    var sourceName: String
    var credits: LyricsCredits

    /// Gap (seconds) that earns an interlude, like Spicy Lyrics' `getLyricsBetweenShow()`.
    static let interludeThreshold: Double = 3
    static let minimalInterludeThreshold: Double = 5
    /// Refreshed Simple Lyrics splits only words of this many letters (`IsLetterCapable.ts`).
    static let refreshedLetterRange = 2...7
    /// The dots finish this long before the next line (Spicy's `preHiddenDotLineMs + 50`).
    static let interludePadding: Double = 0.55
    /// Syllables at least this long are animated per letter (Spicy's `IsLetterCapable`).
    static let letterCapableDuration: Double = 1.0
    /// Emphasized letters end early so the last one gets to breathe (Spicy's `Emphasize`).
    static let emphasisEndSubtraction: Double = 0.25

    /// `replacements` maps a line's original text to what to show instead (a translation); the
    /// new words are re-timed over the original line's syllables.
    /// `joinSplit` puts a word sung in evenly paced parts back into one syllable (the extension's
    /// Join Split Words), so it fills as one word. `minimal` (Minimal Lyrics Mode) keeps a line
    /// lit until the next one starts when the gap is short, and only longer gaps get dots.
    /// `refreshed` (Refreshed Simple Lyrics) splits only short held words into letters.
    init(document: LyricsDocument, romanized: Bool, simple: Bool = false, joinSplit: Bool = false,
         minimal: Bool = false, refreshed: Bool = false, replacements: [String: String] = [:]) {
        let refreshed = simple && refreshed
        // `getLyricsBetweenShow()`: 5 s in Minimal Lyrics Mode.
        let interludeThreshold = minimal ? Self.minimalInterludeThreshold : Self.interludeThreshold
        kind = document.kind
        songwriters = document.songwriters
        sourceName = document.sourceName
        credits = document.credits ?? LyricsCredits(providedBy: document.sourceName)

        // Romanization: the API's own where it has one, otherwise done on the device.
        let script = romanized ? Romanizer.script(of: document) : nil
        func roman(_ text: String, _ fromAPI: String?) -> String {
            guard romanized else { return text }
            return fromAPI ?? script.map { Romanizer.romanize(text, script: $0) } ?? text
        }

        var result: [PreparedLine] = []
        func append(_ start: Double, _ end: Double, _ opposite: Bool, _ kind: PreparedLineKind, source: String = "") {
            result.append(PreparedLine(id: result.count, start: start, end: end, oppositeAligned: opposite, kind: kind,
                                       sourceText: source))
        }

        let source = document.lines
        switch document.kind {
        case .static:
            for line in source {
                append(0, 0, line.oppositeAligned,
                       .static(text: replacements[line.text] ?? roman(line.text, line.romanizedText)), source: line.text)
            }
        case .line, .syllable:
            if let first = source.first, first.start >= interludeThreshold {
                append(0, first.start, first.oppositeAligned, .interlude(dots: Self.dots(from: 0, to: first.start)))
            }
            // A long line (e.g. a trailing backing vocal) can outlast the lines after it, so a
            // gap only counts once every line before it has finished.
            var latestEnd = 0.0
            for (index, line) in source.enumerated() {
                latestEnd = max(latestEnd, line.end)
                if document.kind == .syllable {
                    // The lead and each background group become rows of their own, timed by their
                    // own syllables (`Applyer/Synced/Syllable.ts`).
                    var leadID: Int?
                    let leadText = Self.plain(line.lead)
                    let leadSyllables = joinSplit ? Self.joinSplitWords(line.lead) : line.lead
                    let lead = replacements[leadText].map { Self.retimed($0, over: leadSyllables, simple: simple) }
                        ?? Self.words(from: leadSyllables, simple: simple, refreshed: refreshed) { roman($0.text, $0.romanized) }
                    if !lead.isEmpty {
                        leadID = result.count
                        append(line.lead.map(\.start).min() ?? line.start, line.lead.map(\.end).max() ?? line.end,
                               line.oppositeAligned, .syllable(lead: lead, background: []), source: leadText)
                    }
                    for original in line.backgroundVocals {
                        let group = joinSplit ? Self.joinSplitWords(original) : original
                        let words = replacements[Self.plain(group)].map { Self.retimed($0, over: group, simple: simple) }
                            ?? Self.words(from: group, simple: simple, refreshed: refreshed) { roman($0.text, $0.romanized) }
                        guard !words.isEmpty, let start = group.map(\.start).min(), let end = group.map(\.end).max() else { continue }
                        result.append(PreparedLine(id: result.count, start: start, end: end,
                                                   oppositeAligned: line.oppositeAligned,
                                                   kind: .syllable(lead: words, background: []),
                                                   isBackground: true, leadID: leadID, sourceText: Self.plain(group)))
                    }
                } else {
                    append(line.start, line.end, line.oppositeAligned,
                           .line(text: replacements[line.text] ?? roman(line.text, line.romanizedText)),
                           source: line.text)
                }
                if index + 1 < source.count {
                    let next = source[index + 1]
                    if next.start - latestEnd >= interludeThreshold {
                        append(latestEnd, next.start, next.oppositeAligned,
                               .interlude(dots: Self.dots(from: latestEnd, to: next.start)))
                    }
                }
            }
        }
        if minimal { Self.holdUntilNext(&result, threshold: interludeThreshold) }
        lines = result
    }

    /// Minimal Lyrics Mode (`Syllable.ts`): a sung line would fade out in every short breath, so
    /// it stays lit until the next line starts when the gap is shorter than an interlude.
    private static func holdUntilNext(_ lines: inout [PreparedLine], threshold: Double) {
        let leads = lines.indices.filter { !lines[$0].isBackground && !lines[$0].isInterlude }
        for (index, next) in zip(leads, leads.dropFirst()) {
            let gap = lines[next].start - lines[index].end
            if gap > 0, gap < threshold {
                lines[index].vocalEnd = lines[index].singingEnd
                lines[index].end = lines[next].start
            }
        }
    }

    /// The three dots' timing, exactly as `Applyer/Synced/Syllable.ts` lays them out: thirds of the
    /// gap, each pulled earlier by a third of the padding, the last one ending `padding` early.
    private static func dots(from start: Double, to end: Double) -> [PreparedLetter] {
        let total = end - start
        let third = total / 3
        let padding = interludePadding / 3
        let dot1 = max(start, start + third - padding)
        let dot2 = max(dot1, start + third * 2 - padding * 2)
        let dot3 = max(dot2, start + total - interludePadding)
        return [
            PreparedLetter(text: "•", start: start, end: dot1),
            PreparedLetter(text: "•", start: dot1, end: dot2),
            PreparedLetter(text: "•", start: dot2, end: dot3),
        ]
    }

    /// Silence between two parts of a word beyond which one fill would run through it.
    private static let maxJoinGap = 0.1
    /// A part sung this many times faster or slower per character than the word as a whole stays
    /// split, since a joined word fills at one steady pace.
    private static let maxPaceRatio = 3.0

    /// `JoinSplitWords.ts`: the parts of a split word back into one syllable. A word that doesn't
    /// join cleanly (a gap, an uneven pace, a space inside, a trailing dash) stays split.
    static func joinSplitWords(_ syllables: [LyricSyllable]) -> [LyricSyllable] {
        var joined: [LyricSyllable] = []
        var index = 0
        while index < syllables.count {
            var end = index
            while syllables[end].joinsNext, end + 1 < syllables.count { end += 1 }
            let run = Array(syllables[index...end])
            if run.count > 1, canJoin(run) {
                let romanized = run.contains { $0.romanized != nil }
                    ? run.map { $0.romanized ?? $0.text }.joined() : nil
                joined.append(LyricSyllable(text: run.map(\.text).joined(), romanized: romanized,
                                            start: run[0].start, end: run.map(\.end).max() ?? run[0].end,
                                            joinsNext: run[run.count - 1].joinsNext))
            } else {
                joined.append(contentsOf: run)
            }
            index = end + 1
        }
        return joined
    }

    private static func canJoin(_ run: [LyricSyllable]) -> Bool {
        func hasSpace(_ text: String?) -> Bool { text?.contains { $0.isWhitespace } ?? false }
        guard run.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 && !hasSpace($0.text) && !hasSpace($0.romanized) })
        else { return false }
        // "Ah-" "ah-" "ah": a trailing dash marks a deliberate break.
        if run.dropLast().contains(where: { $0.text.last.map { "-‐‑‒–—―".contains($0) } ?? false }) { return false }
        // Scripts written without spaces: their "words" can run the whole line.
        if run.contains(where: { isUnspacedScript($0.text) }) { return false }
        for (previous, next) in zip(run, run.dropFirst()) where next.start - previous.end > maxJoinGap {
            return false
        }
        let duration = run[run.count - 1].end - run[0].start
        let characters = Double(run.reduce(0) { $0 + $1.text.count })
        guard duration > 0, characters > 0 else { return false }
        return run.allSatisfy { part in
            let timeShare = (part.end - part.start) / duration
            let charShare = Double(part.text.count) / characters
            return timeShare >= charShare / maxPaceRatio && timeShare <= charShare * maxPaceRatio
        }
    }

    /// Han, kana, Thai, Lao, Khmer and Myanmar.
    private static func isUnspacedScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0xFF66...0xFF9F, 0x20000...0x2FA1F, 0x0E00...0x0EFF, 0x1780...0x17FF, 0x19E0...0x19FF,
                 0x1000...0x109F:
                return true
            default:
                return false
            }
        }
    }

    /// Syllables as one string, spaced where words end.
    private static func plain(_ syllables: [LyricSyllable]) -> String {
        syllables.map { $0.text + ($0.joinsNext ? "" : " ") }.joined().trimmingCharacters(in: .whitespaces)
    }

    private static func words(from syllables: [LyricSyllable], simple: Bool, refreshed: Bool = false,
                              display: (LyricSyllable) -> String) -> [PreparedWord] {
        var words: [PreparedWord] = []
        var current: [PreparedSyllable] = []
        // Syllables are drawn left to right, so they must also light up left to right. Some
        // sources time a word slightly before the one in front of it; start it with that one
        // instead of lighting the line out of order.
        var earliestStart = -Double.infinity
        for syllable in syllables {
            let raw = display(syllable)
            let text = raw.replacingOccurrences(of: "\u{200B}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let start = max(syllable.start, earliestStart)
                earliestStart = start
                current.append(prepare(text: text, start: start, end: max(syllable.end, start), simple: simple,
                                       refreshed: refreshed))
            }
            if !syllable.joinsNext, !current.isEmpty {
                words.append(PreparedWord(syllables: current))
                current = []
            }
        }
        if !current.isEmpty { words.append(PreparedWord(syllables: current)) }
        return words
    }

    /// Words of `text` timed over the original syllables. Each word takes the share of the line
    /// its length is of the whole, measured along the original syllables by their length too:
    /// so the words follow the singer's pace and the pauses between the original syllables.
    static func retimed(_ text: String, over syllables: [LyricSyllable], simple: Bool) -> [PreparedWord] {
        func weight(_ string: String) -> Double {
            Double(max(1, string.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count))
        }
        let segments = syllables
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { (start: $0.start, end: max($0.end, $0.start), weight: weight($0.text)) }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !segments.isEmpty, !tokens.isEmpty else { return [] }
        let segmentTotal = segments.reduce(0) { $0 + $1.weight }

        /// The time at `fraction` of the original line. At a boundary between two syllables a
        /// word start takes the later one, so it does not light up during the pause.
        func time(at fraction: Double, starting: Bool) -> Double {
            var target = min(max(fraction, 0), 1) * segmentTotal
            for (index, segment) in segments.enumerated() {
                let isLast = index == segments.count - 1
                if target < segment.weight || (target == segment.weight && (!starting || isLast)) {
                    return segment.start + (segment.end - segment.start) * (target / segment.weight)
                }
                target -= segment.weight
            }
            return segments[segments.count - 1].end
        }

        let weights = tokens.map(weight)
        let tokenTotal = weights.reduce(0, +)
        var words: [PreparedWord] = []
        var covered = 0.0
        var earliest = -Double.infinity
        // Pauses in the original (between syllables) that a new word should not be sung across.
        let pauses = zip(segments, segments.dropFirst())
            .map { (start: $0.0.end, end: $0.1.start) }
            .filter { $0.end - $0.start >= 0.3 }
        for (token, w) in zip(tokens, weights) {
            var start = max(time(at: covered / tokenTotal, starting: true), earliest)
            covered += w
            var end = time(at: covered / tokenTotal, starting: false)
            // A word straddling a pause keeps to the side where most of it falls.
            for pause in pauses where pause.start > start && pause.end < end {
                if pause.start - start >= end - pause.end { end = pause.start } else { start = pause.end }
            }
            end = max(end, start + 0.05)
            earliest = start
            words.append(PreparedWord(syllables: [prepare(text: token, start: start, end: end, simple: simple)]))
        }
        return words
    }

    /// `IsLetterCapable` and `Emphasize`: long syllables animate per letter. Simple Lyrics Mode
    /// only does so for up to 12 letters lasting 1.05 s, and shifts the letters a little later.
    private static func prepare(text: String, start: Double, end: Double, simple: Bool,
                                refreshed: Bool = false) -> PreparedSyllable {
        let characters = text.map(String.init)
        let duration = end - start
        let capable: Bool
        if refreshed {
            capable = refreshedLetterRange.contains(characters.count) && !TextDirection.isRightToLeft(text)
                && duration >= letterCapableDuration
        } else {
            capable = characters.count > 1 && !TextDirection.isRightToLeft(text)
                && (simple ? characters.count <= 12 && duration >= 1.05 : duration >= letterCapableDuration)
        }
        guard capable else { return PreparedSyllable(text: text, start: start, end: end, letters: nil) }

        let letterStart = simple ? start + 0.021 : start
        let letterEnd = simple ? end + 0.04 : max(start + 0.05, end - emphasisEndSubtraction)
        let each = (letterEnd - letterStart) / Double(characters.count)
        let letters = characters.enumerated().map { index, character in
            PreparedLetter(text: character, start: letterStart + Double(index) * each,
                           end: letterStart + Double(index + 1) * each)
        }
        return PreparedSyllable(text: text, start: start, end: end, letters: letters)
    }
}

enum TextDirection {
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                return true
            default:
                continue
            }
        }
        return false
    }
}
