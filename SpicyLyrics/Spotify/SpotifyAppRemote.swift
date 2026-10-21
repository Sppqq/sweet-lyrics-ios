import Foundation
import Observation
import QuartzCore
import SpotifyiOS
import UIKit

/// Reads the playback position straight from the Spotify app on this phone (App Remote).
///
/// The Web API answers over the internet, so its position is only as exact as half a round
/// trip and some devices only refresh it on play / pause / seek. App Remote talks to the local
/// Spotify app: every play, pause, seek and new track arrives as an event carrying the exact
/// position, and a quick local query between events keeps the clock honest. The Web API stays
/// in charge of everything else (and of the clock whenever App Remote is not connected).
@MainActor
@Observable
final class SpotifyAppRemote: NSObject {
    enum Status: Equatable {
        /// Switched off, or the app is not following Spotify right now.
        case off
        /// The login predates the `app-remote-control` scope.
        case needsLogin
        case connecting
        case connected
        /// Spotify is not running (or refused): the Web API keeps the clock.
        case unavailable
    }

    private(set) var status: Status = .off
    /// Why the last attempt failed, as Spotify put it (shown in settings and on the sync badge).
    private(set) var lastError: String?

    @ObservationIgnored private let auth: SpotifyAuth
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private weak var player: PlayerModel?
    @ObservationIgnored private var remote: SPTAppRemote?
    @ObservationIgnored private var remoteClientID: String?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    /// Gives up on a connection attempt Spotify never answers.
    @ObservationIgnored private var connectTimeout: Task<Void, Never>?
    /// `connect()` is between its start and `remote.connect()` (getting a token).
    @ObservationIgnored private var connectStarting = false
    /// Token handed back by Spotify after "wake Spotify", used for the next connection.
    @ObservationIgnored private var wakeToken: String?
    /// Gives up on a wake that never came back with a token.
    @ObservationIgnored private var wakeTimeout: Task<Void, Never>?
    @ObservationIgnored private var coverURI: String?
    /// Failed attempts in a row: retries back off from 8 s to a minute.
    @ObservationIgnored private var failures = 0
    /// When Spotify was last woken automatically, and whether that wake is still waiting for a
    /// connection (another one only follows a connection that worked).
    @ObservationIgnored private var lastAutoWakeAt: CFTimeInterval = -.infinity
    @ObservationIgnored private var autoWakePending = false
    private static let autoWakeCooldown: CFTimeInterval = 120

    static let scope = "app-remote-control"

    init(auth: SpotifyAuth, settings: AppSettings) {
        self.auth = auth
        self.settings = settings
    }

    /// Starts following the Spotify app (while the app follows Spotify at all).
    func start(player: PlayerModel) {
        guard settings.playbackSource == .spotify else { stop(); return }
        self.player = player
        player.onRemoteStale = { [weak self] in self?.reconnect() }
        player.onRemoteQueryNow = { [weak self] in self?.query() }
        player.onRemoteCommand = { [weak self] command in await self?.run(command) ?? false }
        wanted = true
        // Called on every scene change; a second `connect()` mid-attempt cancels the first.
        guard remote?.isConnected != true, status != .connecting else { return }
        Task { await connect() }
    }

    func stop() {
        wanted = false
        retryTask?.cancel()
        retryTask = nil
        queryTask?.cancel()
        queryTask = nil
        connectTimeout?.cancel()
        connectTimeout = nil
        wakeTimeout?.cancel()
        wakeTimeout = nil
        if remote?.isConnected == true { remote?.disconnect() }
        player?.setRemoteConnected(false)
        status = .off
    }

    /// The setting or the login changed.
    func refresh() {
        guard let player else { return }
        if !settings.useAppRemote {
            stop()
            return
        }
        // Switched back on: `stop()` cleared `wanted`, so start again right away.
        start(player: player)
    }

    /// Opens Spotify so it starts (and resumes playback), then comes back with a token.
    func wakeSpotify() {
        guard settings.playbackSource == .spotify else { return }
        guard let remote = makeRemote() else {
            lastError = String(localized: "Нет Client ID")
            return
        }
        SyncLog.shared.add("remote", "waking Spotify")
        status = .connecting
        wakeTimeout?.cancel()
        wakeTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.status == .connecting, self.remote?.isConnected != true else { return }
            self.status = .unavailable
            self.lastError = String(localized: "Spotify не вернул подтверждение. Попробуйте ещё раз.")
            SyncLog.shared.add("remote", "Spotify never came back with a token")
            // A missed wake callback must not strand App Remote in `.unavailable`. The login
            // may already have the app-remote scope, so try the normal connection path again;
            // if not, `connect()` will surface `.needsLogin` as usual.
            self.scheduleRetry(after: 2)
        }
        remote.authorizeAndPlayURI("") { [weak self] success in
            Task { @MainActor in
                guard !success else { return }
                self?.wakeTimeout?.cancel()
                self?.status = .unavailable
                self?.lastError = String(localized: "Не удалось открыть Spotify. Он установлен?")
                SyncLog.shared.add("remote", "could not open Spotify")
            }
        }
    }

    /// The `spicylyrics-ios://callback` URL Spotify opens after `wakeSpotify()`.
    func handle(_ url: URL) {
        guard settings.playbackSource == .spotify else { return }
        guard let parameters = remote?.authorizationParameters(from: url) else { return }
        wakeTimeout?.cancel()
        if let token = parameters[SPTAppRemoteAccessTokenKey] {
            wakeToken = token
            failures = 0
            SyncLog.shared.add("remote", "Spotify handed back a token")
            status = .off
            Task { await connect() }
        } else if let message = parameters[SPTAppRemoteErrorDescriptionKey] {
            lastError = message
            status = .unavailable
            SyncLog.shared.add("remote", "Spotify refused: \(message)")
        }
    }

    // MARK: Connection

    private func makeRemote() -> SPTAppRemote? {
        let clientID = settings.effectiveSpotifyClientID
        guard settings.hasValidClientID, let redirect = URL(string: SpotifyAuth.redirectURI) else { return nil }
        if let remote, remoteClientID == clientID { return remote }
        remote?.disconnect()
        let configuration = SPTConfiguration(clientID: clientID, redirectURL: redirect)
        let remote = SPTAppRemote(configuration: configuration, logLevel: .error)
        remote.delegate = self
        self.remote = remote
        remoteClientID = clientID
        return remote
    }

    private func connect() async {
        // Two scene changes a moment apart started two attempts at once (both refused).
        guard !connectStarting else { return }
        connectStarting = true
        defer { connectStarting = false }
        retryTask?.cancel()
        retryTask = nil
        guard settings.playbackSource == .spotify, wanted, settings.useAppRemote, auth.isLoggedIn else {
            status = .off
            return
        }
        guard auth.hasScope(Self.scope) || wakeToken != nil else {
            if status != .needsLogin { SyncLog.shared.add("remote", "the login lacks \(Self.scope): sign in again") }
            status = .needsLogin
            return
        }
        let token: String
        if let wakeToken {
            token = wakeToken
            self.wakeToken = nil
        } else {
            do {
                token = try await auth.accessToken()
            } catch {
                lastError = error.localizedDescription
                SyncLog.shared.add("remote", "no token: \(error.localizedDescription)")
                scheduleRetry(after: 10)
                return
            }
        }
        guard wanted, let remote = makeRemote() else { return }
        if remote.isConnected { return }
        remote.connectionParameters.accessToken = token
        status = .connecting
        SyncLog.shared.add("remote", "connecting")
        remote.connect()
        connectTimeout?.cancel()
        connectTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.status == .connecting else { return }
            self.remote?.disconnect()
            self.didDrop(nil, reason: String(localized: "Spotify не ответил за 15 секунд"))
        }
    }

    /// The connection looks alive but Spotify stopped answering truthfully: start over.
    private func reconnect() {
        guard wanted else { return }
        queryTask?.cancel()
        queryTask = nil
        player?.setRemoteConnected(false)
        status = .connecting
        SyncLog.shared.add("remote", "stale, reconnecting")
        remote?.disconnect()
        scheduleRetry(after: 2)
    }

    private func scheduleRetry(after seconds: Double) {
        retryTask?.cancel()
        guard wanted else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }

    private func didConnect() {
        guard let remote, wanted else {
            remote?.disconnect()
            return
        }
        connectTimeout?.cancel()
        connectTimeout = nil
        wakeTimeout?.cancel()
        status = .connected
        failures = 0
        autoWakePending = false
        lastError = nil
        SyncLog.shared.add("remote", "connected")
        player?.setRemoteConnected(true)
        remote.playerAPI?.delegate = self
        remote.playerAPI?.subscribe(toPlayerState: { _, _ in })
        query()
        queryTask?.cancel()
        queryTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.settings.remoteQueryInterval ?? 1.5
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.query()
            }
        }
    }

    private func didDrop(_ error: Error?, reason: String? = nil) {
        queryTask?.cancel()
        queryTask = nil
        connectTimeout?.cancel()
        connectTimeout = nil
        player?.setRemoteConnected(false)
        let message = reason ?? error.map(Self.describe) ?? "disconnected"
        // The sync log keeps the SDK's own words; the screen gets a plain explanation.
        lastError = reason ?? error.flatMap(Self.explain) ?? message
        SyncLog.shared.add("remote", "no connection: \(message)")
        guard wanted else { return }
        status = .unavailable
        failures += 1
        // Spotify refuses apps it was not woken by: after two refusals, wake it (if allowed).
        if failures >= 2, autoWakeAllowed {
            autoWakePending = true
            lastAutoWakeAt = CACurrentMediaTime()
            SyncLog.shared.add("remote", "refused \(failures)×, waking Spotify")
            wakeSpotify()
            return
        }
        scheduleRetry(after: min(60, 8 * pow(2, Double(min(failures, 4) - 1))))
    }

    /// Waking Spotify takes the user over to it and back, and starts its playback: only when they
    /// asked for it, a song is playing on this phone and its timing is needed, not more than once
    /// per cooldown, and not again until a wake has led to a connection.
    private var autoWakeAllowed: Bool {
        guard settings.autoWakeSpotify, !autoWakePending,
              UIApplication.shared.applicationState == .active,
              let player, player.isPlaying, player.isPlayingOnThisPhone, !player.lyricsAreStatic
        else { return false }
        return CACurrentMediaTime() - lastAutoWakeAt > Self.autoWakeCooldown
    }

    /// What the usual App Remote refusals mean, in words (nil for the rest).
    private static func explain(_ error: Error) -> String? {
        let ns = error as NSError
        guard ns.domain == "com.spotify.app-remote" else { return nil }
        switch ns.code {
        case -1000:
            return String(localized: "Spotify сейчас не принимает подключения: он в фоне или закрыт. Нажмите «Открыть Spotify и подключиться».")
        case -1002:
            return String(localized: "Spotify оборвал связь, подключаюсь заново.")
        default:
            return nil
        }
    }

    /// The SDK's errors say little on their own; the domain, code and the underlying error tell
    /// "Spotify is not running" from "this app is not allowed".
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " ← \(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)]"
        }
        return text
    }

    private func query() {
        guard let playerAPI = remote?.playerAPI, remote?.isConnected == true else { return }
        let sentAt = CACurrentMediaTime()
        playerAPI.getPlayerState { [weak self] result, _ in
            let receivedAt = CACurrentMediaTime()
            guard let state = result as? SPTAppRemotePlayerState else { return }
            let sample = Sample(state, at: sentAt + (receivedAt - sentAt) / 2, event: false,
                                roundTrip: receivedAt - sentAt)
            Task { @MainActor in self?.player?.applyRemote(sample) }
        }
    }

    /// A playback control for the Spotify app on this phone.
    enum Command: Sendable {
        case play, pause, next, previous
        case seek(Double)
    }

    /// Sends `command` straight to the Spotify app (no internet, no Web API quota). False when
    /// not connected or Spotify refused it: the caller then goes through the Web API.
    func run(_ command: Command) async -> Bool {
        guard status == .connected, let remote, remote.isConnected, let playerAPI = remote.playerAPI else { return false }
        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let done: SPTAppRemoteCallback = { _, error in once.resume(error == nil) }
            switch command {
            case .play: playerAPI.resume(done)
            case .pause: playerAPI.pause(done)
            case .next: playerAPI.skip(toNext: done)
            case .previous: playerAPI.skip(toPrevious: done)
            case .seek(let seconds): playerAPI.seek(toPosition: max(0, Int(seconds * 1000)), callback: done)
            }
            // No answer: it most likely went through (sending it again could skip twice).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { once.resume(true) }
        }
        SyncLog.shared.add("remote", "control \(command) → \(ok ? "done" : "refused, using the Web API")")
        return ok
    }

    /// The cover straight from the Spotify app (works offline), once per track.
    private func fetchCover(_ track: SPTAppRemoteTrack, uri: String) {
        guard coverURI != uri, let imageAPI = remote?.imageAPI else { return }
        coverURI = uri
        imageAPI.fetchImage(forItem: track, with: CGSize(width: 640, height: 640)) { [weak self] result, _ in
            guard let image = result as? UIImage else { return }
            Task { @MainActor in self?.player?.setRemoteArtwork(image, uri: uri) }
        }
    }

    /// One reading of the Spotify app's player.
    struct Sample: Sendable {
        var uri: String
        var name: String
        var artist: String
        var album: String
        var duration: Double
        /// A song (not a podcast episode or an ad).
        var isTrack: Bool
        /// Seconds, valid at `measuredAt`.
        var position: Double
        var paused: Bool
        var measuredAt: CFTimeInterval
        /// Pushed by Spotify on a change (exact), rather than asked for.
        var event: Bool
        /// Queries: how long the answer took (`measuredAt` is only this exact).
        var roundTrip: Double

        init(_ state: SPTAppRemotePlayerState, at time: CFTimeInterval, event: Bool, roundTrip: Double = 0) {
            uri = state.track.uri
            name = state.track.name
            artist = state.track.artist.name
            album = state.track.album.name
            duration = Double(state.track.duration) / 1000
            isTrack = !state.track.isEpisode && !state.track.isPodcast && !state.track.isAdvertisement
                && uri.hasPrefix("spotify:track:")
            position = Double(state.playbackPosition) / 1000
            paused = state.isPaused
            measuredAt = time
            self.event = event
            self.roundTrip = roundTrip
        }

        /// What App Remote knows of the song, enough for lyrics (the cover comes separately).
        var trackInfo: TrackInfo? {
            guard isTrack, let id = uri.split(separator: ":").last.map(String.init) else { return nil }
            return TrackInfo(id: id, uri: uri, title: name, artists: artist.isEmpty ? [] : [artist], album: album,
                             duration: duration, artworkURL: nil, isLocal: false)
        }
    }
}

extension SpotifyAppRemote: SPTAppRemoteDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in self.didConnect() }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        let message = error
        Task { @MainActor in self.didDrop(message) }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        let message = error
        Task { @MainActor in self.didDrop(message) }
    }
}

extension SpotifyAppRemote: SPTAppRemotePlayerStateDelegate {
    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        let sample = Sample(playerState, at: CACurrentMediaTime(), event: true)
        nonisolated(unsafe) let track = playerState.track
        Task { @MainActor in
            self.player?.applyRemote(sample)
            self.fetchCover(track, uri: sample.uri)
        }
    }
}

/// Resumes a continuation once: whichever comes first, Spotify's answer or the timeout.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

extension SpotifyAppRemote {
    /// The song plays on another device (computer, speaker). The Spotify app on this phone has nothing
    /// to report then, so being refused is expected and nothing is wrong.
    var otherDeviceActive: Bool {
        guard let player else { return false }
        return player.deviceName != nil && !player.isPlayingOnThisPhone
    }

    /// The connection state in words, for settings and the sync badge.
    var statusText: String {
        switch status {
        case .off: return String(localized: "Выключено")
        case .needsLogin: return String(localized: "Нужно войти заново")
        case .connecting: return String(localized: "Подключение…")
        case .connected: return String(localized: "Подключено")
        case .unavailable:
            return otherDeviceActive ? String(localized: "Не нужна: играет на другом устройстве")
                                     : String(localized: "Spotify не отвечает")
        }
    }
}
