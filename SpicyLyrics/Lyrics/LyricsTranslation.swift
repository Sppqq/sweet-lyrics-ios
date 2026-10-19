import NaturalLanguage
import SwiftUI
import Translation

/// Where lyric translations come from.
enum TranslationProvider: String, CaseIterable, Identifiable {
    /// Apple's Translation framework, on the device (iOS 18+).
    case apple
    /// The app's own server (sweet.sppq.dev): Google behind a cache every install shares.
    case server
    /// Google Translate's free web endpoint.
    case google
    /// Yandex Translate's free web endpoint.
    case yandex
    /// DeepL with the user's own API key (the free plan is enough).
    case deepl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return String(localized: "Apple (на устройстве)")
        case .server: return String(localized: "Sweet Lyrics (сервер)")
        case .google: return "Google"
        case .yandex: return String(localized: "Яндекс")
        case .deepl: return "DeepL"
        }
    }

    var isAvailable: Bool {
        guard self == .apple else { return true }
        if #available(iOS 18.0, *) { return true }
        return false
    }

    var isOnline: Bool { self != .apple }

    /// The shared cache answers most songs at once, so the server comes first.
    static var defaultProvider: TranslationProvider { .server }
}

/// Translates the current lyrics and hands the result to the player; the lyrics show it under
/// each line (or instead of it). Apple's Translation framework works on the device (iOS 18+;
/// the first use of a language pair makes iOS offer to download its model), the others ask a
/// web service.
struct LyricsTranslation: ViewModifier {
    let player: PlayerModel
    let settings: AppSettings

    func body(content: Content) -> some View {
        let online = content.modifier(OnlineTranslationDriver(player: player, settings: settings))
        if #available(iOS 18.0, *) {
            online.modifier(TranslationDriver(player: player, settings: settings))
        } else {
            online
        }
    }

    /// Languages offered in settings (every provider supports these).
    static let languages: [(id: String, name: String)] = [
        ("ru", "Русский"), ("en", "English"), ("uk", "Українська"), ("de", "Deutsch"),
        ("fr", "Français"), ("es", "Español"), ("it", "Italiano"), ("pt", "Português"),
        ("pl", "Polski"), ("tr", "Türkçe"), ("ja", "日本語"), ("ko", "한국어"), ("zh-Hans", "简体中文"),
    ]
}

/// What both drivers share: which lines need translating and what counts as a translation.
@MainActor
private enum TranslationJob {
    static func targetCode(_ settings: AppSettings) -> String {
        Locale.Language(identifier: settings.translationLanguage).languageCode?.identifier ?? settings.translationLanguage
    }

    /// Unique texts of the lines that are not already in the target language.
    static func pendingTexts(_ player: PlayerModel, _ settings: AppSettings) -> [String] {
        guard settings.translateLyrics, case .loaded(let lyrics) = player.lyricsState else { return [] }
        let texts = Set(lyrics.lines
            // Backing vocals are lines of their own and get translated too.
            .filter { !$0.isInterlude }
            .map(\.sourceText)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        let code = targetCode(settings)
        return texts.filter { !isWritten(in: code, $0) }.sorted()
    }

    /// A line counts as already translated when the recognizer is fairly sure of the target language.
    private static func isWritten(in code: String, _ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let likely = recognizer.languageHypotheses(withMaximum: 3)
            .first { $0.key.rawValue.hasPrefix(code) }?.value ?? 0
        return likely > 0.5
    }

    static func sourceLanguage(of texts: [String]) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(texts.joined(separator: "\n"))
        return recognizer.dominantLanguage
    }

    /// Nothing to translate: no lines, or the song is already in the target language.
    static func nothingToDo(_ texts: [String], source: NLLanguage?, _ settings: AppSettings) -> Bool {
        texts.isEmpty || source.map { $0.rawValue.hasPrefix(targetCode(settings)) } == true
    }

    /// Letters only, so "Hello!" and "hello" compare equal.
    private static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.letters.contains).map(Character.init))
    }

    /// A "translation" that only repeats the line adds nothing under it.
    static func cleaned(_ pairs: [String: String]) -> [String: String] {
        pairs.filter { source, translation in
            !translation.trimmingCharacters(in: .whitespaces).isEmpty && normalized(translation) != normalized(source)
        }
    }
}

// MARK: - Apple (on device)

@available(iOS 18.0, *)
@MainActor
private struct TranslationDriver: ViewModifier {
    let player: PlayerModel
    let settings: AppSettings
    @State private var configuration: TranslationSession.Configuration?

    /// Changes whenever there is something new to translate.
    private var key: String {
        "\(settings.translateLyrics)|\(settings.translationReplaces)|\(settings.translationLanguage)|\(settings.provider.rawValue)|\(player.documentRevision)"
    }

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                await translate(with: session)
            }
            .onChange(of: key, initial: true) { _, _ in reconfigure() }
    }

    private func reconfigure() {
        guard settings.provider == .apple else { return }
        let texts = TranslationJob.pendingTexts(player, settings)
        let target = Locale.Language(identifier: settings.translationLanguage)
        let source = TranslationJob.sourceLanguage(of: texts)
        // A song already in the target language needs no translation; drop any left from before.
        if TranslationJob.nothingToDo(texts, source: source, settings) {
            if !player.translations.isEmpty { player.setTranslations([:], revision: player.documentRevision) }
            return
        }
        let sourceLanguage = source.map { Locale.Language(identifier: $0.rawValue) }
        if configuration?.source == sourceLanguage, configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: sourceLanguage, target: target)
        }
    }

    private func translate(with session: TranslationSession) async {
        guard settings.provider == .apple else { return }
        let texts = TranslationJob.pendingTexts(player, settings)
        guard !texts.isEmpty else { return }
        let revision = player.documentRevision
        let requests = texts.map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
        do {
            var result: [String: String] = [:]
            for response in try await session.translations(from: requests) {
                if let id = response.clientIdentifier { result[id] = response.targetText }
            }
            player.setTranslations(TranslationJob.cleaned(result), revision: revision)
            player.translationError = nil
        } catch {
            // An unsupported language pair or a declined download: show the lyrics untranslated.
            SyncLog.shared.add("translate", "apple failed: \(error.localizedDescription)")
            player.translationError = error.localizedDescription
        }
    }
}

// MARK: - Web services

@MainActor
private struct OnlineTranslationDriver: ViewModifier {
    let player: PlayerModel
    let settings: AppSettings

    private var key: String {
        "\(settings.translateLyrics)|\(settings.translationReplaces)|\(settings.translationLanguage)|\(settings.provider.rawValue)|\(settings.deeplKey.hashValue)|\(player.documentRevision)"
    }

    func body(content: Content) -> some View {
        content.task(id: key) { await run() }
    }

    private func run() async {
        let provider = settings.provider
        guard settings.translateLyrics, provider.isOnline else { return }
        let texts = TranslationJob.pendingTexts(player, settings)
        let source = TranslationJob.sourceLanguage(of: texts)
        if TranslationJob.nothingToDo(texts, source: source, settings) {
            if !player.translations.isEmpty { player.setTranslations([:], revision: player.documentRevision) }
            return
        }
        let revision = player.documentRevision
        let target = settings.translationLanguage
        let key = settings.deeplKey
        // A dropped connection (often right after returning to the app) gets two more tries.
        for attempt in 1...3 {
            do {
                let result = try await OnlineTranslator.shared.translate(
                    texts, source: source?.rawValue, target: target, provider: provider, deeplKey: key)
                guard !Task.isCancelled else { return }
                SyncLog.shared.add("translate", "\(provider.rawValue): \(result.count)/\(texts.count) lines")
                player.setTranslations(TranslationJob.cleaned(result), revision: revision)
                player.translationError = nil
                return
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                SyncLog.shared.add("translate", "\(provider.rawValue) failed (\(attempt)): \(error.localizedDescription)")
                if attempt == 3 || (error as? OnlineTranslator.Failure)?.isFinal == true {
                    player.translationError = error.localizedDescription
                    return
                }
                try? await Task.sleep(for: .seconds(Double(attempt) * 2))
            }
        }
    }
}

/// The app's server, Google and Yandex through their free web endpoints, DeepL with the user's key. Lines go in
/// batches; answers are kept on disk (Caches), so switching modes, coming back to a song or
/// the next launch costs no requests.
actor OnlineTranslator {
    static let shared = OnlineTranslator()

    enum Failure: LocalizedError {
        case missingKey
        case http(Int, TranslationProvider)
        case unreadable

        /// Retrying will not help.
        var isFinal: Bool {
            switch self {
            case .missingKey: return true
            case .http(let status, _): return status == 401 || status == 403 || status == 456
            case .unreadable: return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return String(localized: "Нужен ключ DeepL API")
            case .http(let status, let provider):
                if provider == .deepl, status == 401 || status == 403 { return String(localized: "DeepL не принял ключ") }
                if provider == .deepl, status == 456 { return String(localized: "Лимит DeepL на этот месяц исчерпан") }
                if status == 429 { return String(localized: "Слишком много запросов к переводчику, попробуйте позже") }
                return String(localized: "Переводчик ответил ошибкой \(status)")
            case .unreadable:
                return String(localized: "Переводчик прислал непонятный ответ")
            }
        }
    }

    private lazy var cache: [String: String] = Self.loadCache()
    private var saveTask: Task<Void, Never>?
    private static let cacheLimit = 5000
    private static let cacheFile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("translations-v1.json")
    /// Yandex wants a session id with every request.
    private let yandexSession = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    /// `texts` translated into `target` (an id from `LyricsTranslation.languages`), keyed by text.
    func translate(_ texts: [String], source: String?, target: String, provider: TranslationProvider,
                   deeplKey: String) async throws -> [String: String] {
        let prefix = "\(provider.rawValue)|\(target)|"
        var result: [String: String] = [:]
        var missing: [String] = []
        for text in texts {
            if let hit = cache[prefix + text] { result[text] = hit } else { missing.append(text) }
        }
        guard !missing.isEmpty else { return result }
        let fresh: [String: String]
        switch provider {
        case .server: fresh = try await server(missing, source: source, target: target)
        case .google: fresh = try await google(missing, target: target)
        case .yandex: fresh = try await yandex(missing, source: source, target: target)
        case .deepl: fresh = try await deepl(missing, target: target, key: deeplKey)
        case .apple: fresh = [:]
        }
        if cache.count > Self.cacheLimit { cache.removeAll() }
        for (text, translation) in fresh {
            cache[prefix + text] = translation
            result[text] = translation
        }
        if !fresh.isEmpty { scheduleSave() }
        return result
    }

    private static func loadCache() -> [String: String] {
        guard let data = try? Data(contentsOf: cacheFile),
              let stored = try? JSONDecoder().decode([String: String].self, from: data),
              stored.count <= cacheLimit
        else { return [:] }
        return stored
    }

    /// Written a moment after the last translation, once per song rather than per batch.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(cache) else { return }
            try? data.write(to: Self.cacheFile, options: .atomic)
        }
    }

    // MARK: Sweet Lyrics server

    private static let serverURL = URL(string: "https://sweet.sppq.dev/v1/translate")!
    /// The server's limits per request.
    private static let serverLineLimit = 500

    /// The server translates with Google and keeps every answer for all installs: a song someone
    /// already listened to comes back without waiting on Google. Over its hourly limit it still
    /// sends what it has cached (`limited`); the rest is asked for again next time.
    private func server(_ texts: [String], source: String?, target: String) async throws -> [String: String] {
        var result: [String: String] = [:]
        for chunk in Self.chunks(texts.filter { $0.count <= Self.serverLineLimit }, characters: 40_000, count: 250) {
            var request = URLRequest(url: Self.serverURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["target": target, "lines": chunk]
            if let source { body["source"] = source }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            guard let object = try await load(request, provider: .server) as? [String: Any],
                  let rows = object["translations"] as? [String: String] else {
                throw Failure.unreadable
            }
            if let cached = object["cached"] as? Int {
                SyncLog.log("translate", "server: \(cached)/\(chunk.count) from its cache"
                    + ((object["limited"] as? Bool) == true ? ", limited" : ""))
            }
            result.merge(rows) { _, new in new }
        }
        return result
    }

    // MARK: Google

    private func google(_ texts: [String], target: String) async throws -> [String: String] {
        var result: [String: String] = [:]
        for chunk in Self.chunks(texts, characters: 3500, count: 80) {
            // One request per chunk, a line per row; if the rows don't come back one for one,
            // ask for each line on its own.
            let rows = try await googleRequest(chunk.joined(separator: "\n"), target: target)
            if rows.count == chunk.count {
                for (text, row) in zip(chunk, rows) { result[text] = row }
            } else {
                for text in chunk {
                    result[text] = try await googleRequest(text, target: target).joined(separator: " ")
                }
            }
        }
        return result
    }

    private func googleRequest(_ text: String, target: String) async throws -> [String] {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target == "zh-Hans" ? "zh-CN" : target),
            URLQueryItem(name: "dt", value: "t"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form([("q", text)])
        // [[["перевод\n", "original\n", …], …], …]: the translated pieces, in order.
        guard let root = try await load(request, provider: .google) as? [Any], let pieces = root.first as? [Any] else {
            throw Failure.unreadable
        }
        let joined = pieces.compactMap { ($0 as? [Any])?.first as? String }.joined()
        return joined.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Yandex

    private func yandex(_ texts: [String], source: String?, target: String) async throws -> [String: String] {
        let to = target == "zh-Hans" ? "zh" : target
        let from = source.map { code in String(code.prefix { $0 != "-" }) }
        var result: [String: String] = [:]
        for chunk in Self.chunks(texts, characters: 4000, count: 60) {
            var components = URLComponents(string: "https://translate.yandex.net/api/v1/tr.json/translate")!
            components.queryItems = [
                URLQueryItem(name: "id", value: yandexSession + "-0-0"),
                URLQueryItem(name: "srv", value: "android"),
            ]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
            let direction = from.map { $0 == to ? to : "\($0)-\(to)" } ?? to
            request.httpBody = Self.form([("lang", direction)] + chunk.map { ("text", $0) })
            guard let object = try await load(request, provider: .yandex) as? [String: Any],
                  let rows = object["text"] as? [String], rows.count == chunk.count else {
                throw Failure.unreadable
            }
            for (text, row) in zip(chunk, rows) { result[text] = row }
        }
        return result
    }

    // MARK: DeepL

    private func deepl(_ texts: [String], target: String, key: String) async throws -> [String: String] {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Failure.missingKey }
        // Free-plan keys end in ":fx" and have their own host.
        let host = key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        let language: String
        switch target {
        case "en": language = "EN-US"
        case "pt": language = "PT-BR"
        case "zh-Hans": language = "ZH-HANS"
        default: language = target.uppercased()
        }
        var result: [String: String] = [:]
        for chunk in Self.chunks(texts, characters: 20_000, count: 50) {
            var request = URLRequest(url: URL(string: "https://\(host)/v2/translate")!)
            request.httpMethod = "POST"
            request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["text": chunk, "target_lang": language])
            guard let object = try await load(request, provider: .deepl) as? [String: Any],
                  let rows = object["translations"] as? [[String: Any]], rows.count == chunk.count else {
                throw Failure.unreadable
            }
            for (text, row) in zip(chunk, rows) {
                if let translation = row["text"] as? String { result[text] = translation }
            }
        }
        return result
    }

    // MARK: Plumbing

    private func load(_ request: URLRequest, provider: TranslationProvider) async throws -> Any {
        var request = request
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status, provider) }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Splits `texts` into batches of at most `count` lines and about `characters` characters.
    private static func chunks(_ texts: [String], characters: Int, count: Int) -> [[String]] {
        var chunks: [[String]] = []
        var current: [String] = []
        var length = 0
        for text in texts {
            if !current.isEmpty, current.count >= count || length + text.count > characters {
                chunks.append(current)
                current = []
                length = 0
            }
            current.append(text)
            length += text.count + 1
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static let formAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func form(_ fields: [(String, String)]) -> Data {
        fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? "")"
        }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
    }
}
