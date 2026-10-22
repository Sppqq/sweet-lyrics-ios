import Foundation
import Observation
import UIKit

/// Sends reports (the log, a note, a few photos) to the developer's Cloudflare Worker
/// (`cloudflare/`), by hand from Settings → Reports or, if the user agreed, by itself when
/// something fails. Nothing identifies the person: only a random per-install id.
@MainActor
@Observable
final class ReportService {
    static let shared = ReportService()

    static let endpoint = URL(string: "https://sweet.sppq.dev/v1/report")!

    enum SendError: LocalizedError {
        case notReady
        case rejected(Int)

        var errorDescription: String? {
            switch self {
            case .notReady: return String(localized: "Приложение ещё запускается, попробуйте позже.")
            case .rejected(0): return String(localized: "Нет связи с сервером. Проверьте интернет.")
            case .rejected(429): return String(localized: "Слишком много отчётов подряд, попробуйте через час.")
            case .rejected(let code): return String(localized: "Сервер не принял отчёт (\(code)).")
            }
        }
    }

    @ObservationIgnored private weak var settings: AppSettings?
    @ObservationIgnored private weak var player: PlayerModel?
    @ObservationIgnored private weak var appRemote: SpotifyAppRemote?
    /// Errors already reported since launch, so one failing thing is one report.
    @ObservationIgnored private var reported: Set<String> = []
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var lastAutoAt: Date = .distantPast

    private static let autoPerDay = 5
    private static let autoGap: TimeInterval = 300
    /// Waits a little after an error so the report carries what happened next too.
    private static let autoDelay: Double = 20

    func attach(settings: AppSettings, player: PlayerModel, appRemote: SpotifyAppRemote) {
        self.settings = settings
        self.player = player
        self.appRemote = appRemote
    }

    // MARK: Sending

    func send(kind: String, errorKind: String = "", message: String, photos: [Data], includeLog: Bool) async throws {
        guard let settings else { throw SendError.notReady }
        let device = UIDevice.current
        let meta: [String: String] = [
            "kind": kind,
            "errorKind": errorKind,
            "message": message,
            "appVersion": AppVersion.marketing,
            "build": AppVersion.build,
            "channel": AppVersion.channel,
            "os": device.systemVersion,
            "device": Self.deviceModel,
            "locale": Locale.current.identifier,
            "installId": settings.installID,
        ]
        var form = Multipart()
        form.field("meta", String(decoding: try JSONSerialization.data(withJSONObject: meta), as: UTF8.self))
        if includeLog { form.field("log", logText()) }
        for (index, photo) in photos.enumerated() {
            form.file("photo", filename: "photo\(index).jpg", mime: "image/jpeg", data: photo)
        }
        let body = form.finish()

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let status: Int
        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: body)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw SendError.rejected(0)
        }
        guard status == 200 else { throw SendError.rejected(status) }
        if kind == "manual" {
            Self.hasSentReports = true
            await refreshThreads(force: true)
        }
    }

    /// The log as it goes out: no names of the user's devices.
    func logText() -> String {
        guard let settings, let player, let appRemote else { return "" }
        let header = SyncLog.shared.header(settings: settings, player: player, appRemote: appRemote)
        return Self.sanitize(SyncLog.shared.text(header: header))
    }

    /// `on Smartphone "Vsevolod's iPhone"` becomes `on Smartphone "…"`, and a headphone name
    /// from older builds (`route AirPods Pro (Name), latency`) becomes `route …, latency`.
    nonisolated static func sanitize(_ text: String) -> String {
        let rules = [
            (#" on (\w+) "[^"\n]*""#, " on $1 \"…\""),
            (#"\broute [^\n]*?, latency"#, "route …, latency"),
        ]
        var result = text
        for (pattern, template) in rules {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return Mirror(reflecting: info.machine).children.reduce("") { id, element in
            guard let value = element.value as? Int8, value != 0 else { return id }
            return id + String(UnicodeScalar(UInt8(value)))
        }
    }

    // MARK: Threads

    /// A report the user sent by hand, with the developer's answers and their replies.
    struct Thread: Identifiable, Equatable, Decodable {
        struct Message: Identifiable, Equatable, Decodable {
            let id: Int
            let createdAt: Double
            /// "user" or "dev".
            let author: String
            let text: String

            var fromDeveloper: Bool { author == "dev" }
            var date: Date { Date(timeIntervalSince1970: createdAt) }
        }

        let id: String
        let createdAt: Double
        let status: String
        let note: String
        let messages: [Message]

        var date: Date { Date(timeIntervalSince1970: createdAt) }
        var isClosed: Bool { status == "closed" }
        var lastDeveloperMessage: Message? { messages.last(where: \.fromDeveloper) }
    }

    private(set) var threads: [Thread] = []
    /// The newest developer answer the user has not seen yet (for the notice at launch).
    var unreadAnswer: Thread? { threads.first(where: isUnread) }
    var unreadCount: Int { threads.filter(isUnread).count }

    func isUnread(_ thread: Thread) -> Bool { (thread.lastDeveloperMessage?.id ?? 0) > seenAnswerID }

    @ObservationIgnored private var lastThreadsFetch: Date = .distantPast
    private var seenAnswerID: Int = UserDefaults.standard.integer(forKey: "reportSeenAnswer") {
        didSet { UserDefaults.standard.set(seenAnswerID, forKey: "reportSeenAnswer") }
    }
    /// Only phones that ever sent a report ask for answers.
    private static var hasSentReports: Bool {
        get { UserDefaults.standard.bool(forKey: "reportSent") }
        set { UserDefaults.standard.set(newValue, forKey: "reportSent") }
    }
    private static let threadsURL = URL(string: "https://sweet.sppq.dev/v1/threads")!

    /// The user's reports and their answers: every 10 minutes at most after sending one, every
    /// 6 hours otherwise (reports sent before this existed are found that way), or now (`force`).
    func refreshThreads(force: Bool = false) async {
        guard let settings else { return }
        let interval: TimeInterval = Self.hasSentReports || !threads.isEmpty ? 600 : 6 * 3600
        guard force || Date().timeIntervalSince(lastThreadsFetch) > interval else { return }
        var request = URLRequest(url: Self.threadsURL, timeoutInterval: 20)
        request.setValue(settings.installID, forHTTPHeaderField: "X-Install-Id")
        struct Payload: Decodable { let threads: [Thread] }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        lastThreadsFetch = Date() // only an answer counts: a failed try is repeated sooner
        threads = payload.threads
        if !threads.isEmpty { Self.hasSentReports = true }
    }

    /// The user read the answers (opened the thread or dismissed the notice).
    func markAnswersSeen() {
        let newest = threads.compactMap { $0.lastDeveloperMessage?.id }.max() ?? 0
        if newest > seenAnswerID { seenAnswerID = newest }
    }

    /// A reply in a thread. Reopens it on the server if it was closed.
    func reply(to thread: Thread, text: String) async throws {
        guard let settings else { throw SendError.notReady }
        var request = URLRequest(url: Self.threadsURL.appendingPathComponent(thread.id).appendingPathComponent("messages"),
                                 timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(settings.installID, forHTTPHeaderField: "X-Install-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        let status: Int
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw SendError.rejected(0)
        }
        guard status == 200 else { throw SendError.rejected(status) }
        await refreshThreads(force: true)
    }

    // MARK: Errors

    /// Every `SyncLog` entry passes here; a failure the user agreed to report is sent after a
    /// short delay, at most once per kind per launch, one every five minutes and five a day.
    func noteError(source: String, message: String) {
        guard let settings, settings.reportConsent == 1, pending == nil, RemoteConfig.shared.values.autoReports,
              Self.isReportable(source, message) else { return }
        let key = source + ":" + message.prefix(40)
        guard !reported.contains(key), Date().timeIntervalSince(lastAutoAt) > Self.autoGap else { return }

        let defaults = UserDefaults.standard
        let today = Self.day(Date())
        let count = defaults.string(forKey: "autoReportDay") == today ? defaults.integer(forKey: "autoReportCount") : 0
        guard count < Self.autoPerDay else { return }

        reported.insert(key)
        let kind = "\(source): \(message.prefix(120))"
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoDelay))
            guard let self, !Task.isCancelled, self.settings?.reportConsent == 1 else {
                self?.pending = nil
                return
            }
            self.lastAutoAt = Date()
            defaults.set(today, forKey: "autoReportDay")
            defaults.set(count + 1, forKey: "autoReportCount")
            try? await self.send(kind: "auto", errorKind: kind, message: "", photos: [], includeLog: true)
            self.pending = nil
        }
    }

    /// Real failures only: not the App Remote refusals that are normal, not "not found".
    nonisolated static func isReportable(_ source: String, _ message: String) -> Bool {
        switch source {
        case "remote", "web", "control-expected":
            // App Remote refusals are normal; a failed poll is the network, retried in seconds.
            return false
        case "translate":
            // Only the last of three tries is a real failure.
            return message.contains("failed (3)")
        case "api":
            guard message.hasPrefix("HTTP "), let code = Int(message.dropFirst(5).prefix(3)) else { return false }
            return code >= 500
        default:
            return message.contains("failed")
        }
    }

    private static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}

/// A `multipart/form-data` body.
private struct Multipart {
    private let boundary = "SweetLyrics-" + UUID().uuidString
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    mutating func file(_ name: String, filename: String, mime: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    mutating func finish() -> Data {
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
