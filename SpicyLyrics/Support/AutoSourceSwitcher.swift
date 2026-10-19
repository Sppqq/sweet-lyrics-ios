import MediaPlayer
import QuartzCore

/// The "Auto" player choice: the lyrics follow whichever of Spotify and Apple Music is playing.
///
/// Apple Music is read straight from the system player once a second (a property read, no
/// request). Spotify is asked through the Web API only while Apple Music is the source and is not
/// playing: Spotify on this phone cannot play over Music, and Spotify somewhere else gives way to
/// the phone. While Spotify is the source, its own polling says whether it plays.
///
/// A switch only sets `AppSettings.playbackSource`; the app reacts to that as to a manual change.
@MainActor
final class AutoSourceSwitcher {
    private let settings: AppSettings
    private let auth: SpotifyAuth
    private let api: SpotifyAPI
    private weak var player: PlayerModel?
    private let music = MPMusicPlayerController.systemMusicPlayer
    private var task: Task<Void, Never>?
    private var spotifyCheck: Task<Void, Never>?

    /// Music's position at the last look: a "playing" state whose position does not move is stale
    /// (the system player reports one after interruptions).
    private var lastMusic: (position: Double, at: CFTimeInterval)?
    /// Since when Music has been seen moving.
    private var musicSince: CFTimeInterval?
    private var spotifyCheckedAt: CFTimeInterval = -.infinity
    private var spotifyBackoffUntil: CFTimeInterval = 0
    private var switchedAt: CFTimeInterval = -.infinity

    /// Music has to play this long before it takes over: a tap on play by mistake, a short
    /// preview or a stale state do not switch.
    private static let confirm = 1.5
    /// No switch back within this long of the last one (no flapping while one player pauses
    /// and the other starts).
    private static let hold = 4.0
    /// How often Spotify is asked while Apple Music is the source and silent.
    private static let spotifyInterval = 5.0

    init(settings: AppSettings, auth: SpotifyAuth, api: SpotifyAPI) {
        self.settings = settings
        self.auth = auth
        self.api = api
    }

    /// Apple Music can be followed: set up in onboarding, or library access granted.
    var appleMusicReady: Bool {
        settings.appleMusicOnboarded || MPMediaLibrary.authorizationStatus() == .authorized
    }

    /// Something to follow under the current choice.
    var anySourceReady: Bool {
        switch settings.playerChoice {
        case .automatic: return auth.isLoggedIn || appleMusicReady
        case .spotify: return auth.isLoggedIn
        case .appleMusic: return settings.appleMusicOnboarded
        }
    }

    /// In automatic mode, moves off a player that cannot be followed (signed out of Spotify,
    /// no library access) onto the other one, if that one can.
    func preferReadySource() {
        guard settings.playerChoice == .automatic else { return }
        switch settings.playbackSource {
        case .spotify where !auth.isLoggedIn && appleMusicReady:
            switchTo(.appleMusic, reason: "not signed in to Spotify")
        case .appleMusic where !appleMusicReady && auth.isLoggedIn:
            switchTo(.spotify, reason: "no access to Music")
        default:
            break
        }
    }

    func start(player: PlayerModel) {
        self.player = player
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        spotifyCheck?.cancel()
        spotifyCheck = nil
        lastMusic = nil
        musicSince = nil
    }

    private func tick() {
        guard settings.playerChoice == .automatic, let player else { return }
        let now = MediaClock.now()
        let musicPlaying = musicIsPlaying(at: now)
        guard now - switchedAt >= Self.hold else { return }
        switch settings.playbackSource {
        case .spotify:
            // Spotify on this phone stops when Music starts: a moving Music under a Spotify that
            // still plays here is not real yet (or Spotify has not reported its pause).
            if musicPlaying, !(player.isPlaying && player.isPlayingOnThisPhone) {
                switchTo(.appleMusic, reason: "Apple Music is playing")
            }
        case .appleMusic:
            guard !musicPlaying, auth.isLoggedIn, spotifyCheck == nil,
                  now - spotifyCheckedAt >= Self.spotifyInterval, now >= spotifyBackoffUntil else { return }
            spotifyCheckedAt = now
            spotifyCheck = Task { [weak self] in
                await self?.checkSpotify()
                self?.spotifyCheck = nil
            }
        }
    }

    private func checkSpotify() async {
        do {
            guard let snapshot = try await api.playbackState(), snapshot.isPlaying else { return }
            guard !Task.isCancelled, settings.playerChoice == .automatic, settings.playbackSource == .appleMusic,
                  !musicIsPlaying(at: MediaClock.now()) else { return }
            switchTo(.spotify, reason: "Spotify is playing on \(snapshot.deviceType ?? "a device")")
        } catch SpotifyAPIError.rateLimited(let retryAfter) {
            spotifyBackoffUntil = MediaClock.now() + max(retryAfter, 30)
        } catch SpotifyAPIError.quotaExceeded(let retryAfter) {
            spotifyBackoffUntil = MediaClock.now() + max(retryAfter, 60)
        } catch {
            // Offline or signed out: try again later, quietly.
            spotifyBackoffUntil = MediaClock.now() + 15
        }
    }

    /// Music is playing and its position moves, for at least `confirm` seconds.
    private func musicIsPlaying(at now: CFTimeInterval) -> Bool {
        guard appleMusicReady, MPMediaLibrary.authorizationStatus() == .authorized,
              music.playbackState == .playing, music.nowPlayingItem != nil else {
            lastMusic = nil
            musicSince = nil
            return false
        }
        let position = music.currentPlaybackTime
        guard position.isFinite else { return false }
        defer { lastMusic = (position, now) }
        guard let last = lastMusic, now - last.at < 5 else { return false }
        // Moved at least half as fast as the clock (a new song starts back at 0: wait one more look).
        guard position - last.position > (now - last.at) * 0.5 else {
            musicSince = nil
            return false
        }
        if musicSince == nil { musicSince = last.at }
        return now - (musicSince ?? now) >= Self.confirm
    }

    private func switchTo(_ source: PlaybackSource, reason: String) {
        guard settings.playbackSource != source else { return }
        SyncLog.shared.add("source", "auto: \(reason) → \(source.title)")
        switchedAt = MediaClock.now()
        musicSince = nil
        if source == .appleMusic { settings.appleMusicOnboarded = true }
        settings.playbackSource = source
    }
}
