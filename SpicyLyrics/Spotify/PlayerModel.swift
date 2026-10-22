import Foundation
import AVFoundation
import Observation
import QuartzCore
import UIKit

/// Follows the selected player and keeps a smooth local clock between samples.
@MainActor
@Observable
final class PlayerModel {
    enum LyricsState: Equatable {
        case idle
        case loading
        case loaded(PreparedLyrics)
        case notFound
        case unavailable(LyricsNotice)
        case failed(LyricsFailure)
    }

    private(set) var content: PlaybackSnapshot.Content?
    private(set) var isPlaying = false {
        didSet { if !isPlaying { transitionRun.interrupt() } }
    }
    private(set) var artwork: UIImage?
    /// Small copy of the artwork for the animated background.
    private(set) var backgroundArtwork: UIImage?
    private(set) var artworkID = ""
    /// The first artist's photo, for the "Фото артиста" background (Spotify only).
    private(set) var artistImage: UIImage?
    /// The song's Canvas loop, for the "Canvas" background (Spotify only).
    private(set) var canvasURL: URL?
    @ObservationIgnored private var visualsTask: Task<Void, Never>?
    /// Style and track the background visuals were loaded for.
    @ObservationIgnored private var visualsKey = ""
    @ObservationIgnored private var artistImages: [String: UIImage] = [:]
    @ObservationIgnored private var canvasURLs: [String: URL?] = [:]
    /// Bumped whenever new lyrics are shown, so the lyrics view starts fresh.
    private(set) var lyricsRevision = 0
    private var currentLyricsState: LyricsState = .idle
    private(set) var lyricsState: LyricsState {
        get { outgoingLyrics.map { .loaded($0.lyrics) } ?? currentLyricsState }
        set { currentLyricsState = newValue }
    }
    private struct OutgoingLyrics {
        let lyrics: PreparedLyrics
        let position: Double
        let startedAt: CFTimeInterval
        let duration: Double
        let deadline: CFTimeInterval
        let translations: [String: String]
        let documentRevision: Int
    }
    private var outgoingLyrics: OutgoingLyrics?
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var manualChangeUntil: CFTimeInterval = 0
    @ObservationIgnored private var transitionRun = TransitionDetector.PlaybackRun()
    @ObservationIgnored private var appleSample: AppleMusicPlayer.Sample?
    @ObservationIgnored private var sourceGeneration = 0
    @ObservationIgnored let appleMusic = AppleMusicPlayer()
    var playbackSource: PlaybackSource { settings.playbackSource }
    var supportsSpotifyFeatures: Bool { playbackSource == .spotify }
    private var transitionWindow: Double { settings.effectiveTransitionWindow }
    private(set) var statusMessage: String?

    enum AccessProblem: Equatable {
        /// The account isn't on the Client ID's allowlist.
        case notRegistered
        case quotaExceeded
    }
    /// Why Spotify refuses this account, when the fix is the user's own Client ID.
    private(set) var accessProblem: AccessProblem?
    /// Album / playlist Spotify is playing from, used to keep context when picking a track.
    private(set) var contextURI: String?
    private(set) var deviceName: String?
    /// The round trip to Spotify's Web API on this connection, rounded to 10 ms: the quickest of
    /// the recent answers, i.e. the network itself without a busy server or phone on top.
    private(set) var spotifyPing: Double?
    @ObservationIgnored private var recentRoundTrips: [Double] = []
    var transientError: String?

    var track: TrackInfo? {
        if case .track(let track) = content { return track }
        return nil
    }

    @ObservationIgnored private let api: SpotifyAPI
    @ObservationIgnored private let lyrics: LyricsService
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var rawLyrics: LyricsDocument?
    @ObservationIgnored private var preparedRomanized = false
    @ObservationIgnored private var preparedSimple = false
    /// The other display settings the current lyrics were prepared with.
    @ObservationIgnored private var preparedShape = PreparedShape()

    private struct PreparedShape: Equatable {
        var joinSplit = false
        var minimal = false
        var refreshed = false
    }

    private var currentShape: PreparedShape {
        PreparedShape(joinSplit: settings.joinSplitWords, minimal: settings.minimalLyricsMode,
                      refreshed: settings.refreshedSimpleLyrics)
    }
    /// Translations the shown lyrics were built with (replace mode), to rebuild only on change.
    @ObservationIgnored private var preparedReplacements: [String: String] = [:]
    /// Changes only when different lyrics arrive; translations belong to one revision of these.
    private var currentDocumentRevision = 0
    var documentRevision: Int { outgoingLyrics?.documentRevision ?? currentDocumentRevision }
    @ObservationIgnored private var lastArtworkURL: URL?

    // Clock anchor: position `anchorPosition` was correct at `anchorTime`. `slew` is a small
    // correction blended in over `slewDuration`, so the clock never visibly jumps or runs backwards.
    @ObservationIgnored private var anchorPosition: Double = 0
    @ObservationIgnored private var anchorTime: CFTimeInterval = MediaClock.now()
    @ObservationIgnored private var slew: Double = 0
    @ObservationIgnored private var slewSpan: Double = 0.8
    /// The previous report, to tell a live position from a frozen one.
    @ObservationIgnored private var lastSample: (progress: Double, measuredAt: CFTimeInterval, stamp: Double?)?
    /// Spotify only updates this device's position on play / pause / seek (its phone app does
    /// this): between those, `progress_ms` stays put and must not be read as a pause.
    @ObservationIgnored private var frozenReports = false
    /// Consecutive live reports far behind our clock (a seek back on another device).
    @ObservationIgnored private var behindStreak = 0
    /// Consecutive live reports saying we are ahead, and the smallest of those leads.
    @ObservationIgnored private var aheadStreak = 0
    @ObservationIgnored private var aheadLead: Double = 0
    /// Quick follow-up polls left after the clock was set from a single report: one answer is
    /// only as exact as half its round trip, a few more narrow it down.
    @ObservationIgnored private var refineSamples = 0
    /// App Remote is connected: it keeps the clock, play / pause and the track.
    private(set) var remoteConnected = false
    /// The track App Remote last reported.
    @ObservationIgnored private var remoteURI: String?
    /// Its queried positions stopped moving while playing: only trust its events.
    @ObservationIgnored private var remoteQueriesFrozen = false
    /// Spotify's position for a song that just started runs ahead of the sound by about a second
    /// (seen in sync logs: the first pause, seek or stall afterwards showed the clock 0.5-1 s
    /// early, and everything after was exact). Until such an event re-bases it, the position of
    /// a fresh song is taken `startLead` seconds back. Learned from those events.
    @ObservationIgnored private(set) var startLead: Double = UserDefaults.standard.object(forKey: "startLead") as? Double ?? 0.9 {
        didSet { UserDefaults.standard.set(startLead, forKey: "startLead") }
    }
    @ObservationIgnored private var leadActive = false
    @ObservationIgnored private var trackStartedAt: CFTimeInterval = 0
    /// Web API reports in a row that contradict App Remote (play state or song).
    @ObservationIgnored private var remoteDisagreements = 0
    /// Asks App Remote to drop its connection and reconnect (set by `SpotifyAppRemote`).
    @ObservationIgnored var onRemoteStale: (() -> Void)?
    @ObservationIgnored private var lastRemoteQuery: (position: Double, at: CFTimeInterval)?
    @ObservationIgnored private var lastRemoteMismatch: String?
    @ObservationIgnored private var holdUntil: CFTimeInterval = 0
    @ObservationIgnored private var backoffUntil: CFTimeInterval = 0
    /// When App Remote last said anything (event or query), to notice it going quiet.
    @ObservationIgnored private var lastRemoteSampleAt: CFTimeInterval = 0
    /// Asks App Remote for the position right now (set by `SpotifyAppRemote`).
    @ObservationIgnored var onRemoteQueryNow: (() -> Void)?
    /// Sends a control to the Spotify app directly (set by `SpotifyAppRemote`); false if it can't.
    @ObservationIgnored var onRemoteCommand: ((SpotifyAppRemote.Command) async -> Bool)?
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    @ObservationIgnored private var lastWatch: (media: CFTimeInterval, wall: TimeInterval)?
    @ObservationIgnored private var resyncTask: Task<Void, Never>?
    @ObservationIgnored private var lastResyncAt: CFTimeInterval = -.infinity
    /// Bumped when what is on screen should jump to the clock instead of animating to it
    /// (the app or the floating window was just opened, the phone stalled).
    private(set) var snapToken = 0

    // Skipping songs without a Spicy Lyrics sync (`AppSettings.autoSkipMode`).
    /// Songs skipped in a row; past `autoSkipLimit` skipping pauses (a playlist of nothing synced).
    @ObservationIgnored private var autoSkipped = 0
    /// The song last checked, so each is judged (and skipped) once.
    @ObservationIgnored private var skipCheckedURI: String?
    /// The auto-skip mode `skipCheckedURI` was judged under: another mode judges the song again.
    @ObservationIgnored private var skipCheckedMode: String?
    /// A song the user picked or went back to: never skipped.
    @ObservationIgnored private var skipExemptURI: String?
    /// Until then the next new song counts as one the user went back to.
    @ObservationIgnored private var exemptNextSongUntil: CFTimeInterval = 0
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Spotify IDs of the songs queued after the current one, as last fetched.
    @ObservationIgnored private var upcomingIDs: [String] = []
    /// Songs whose lyrics were looked up ahead of time, by Spotify ID.
    @ObservationIgnored private var lookahead: [String: KnownLyrics] = [:]
    @ObservationIgnored private var lookaheadTask: Task<Void, Never>?
    /// Shown for a moment over the player after a song was skipped.
    private(set) var autoSkipNotice: String?
    static let autoSkipLimit = 12

    private static let slewDuration: Double = 0.8
    /// Being behind Spotify by more than this jumps instead of catching up smoothly.
    private static let resyncThreshold: Double = 1.0
    /// Being behind by less than this is noise.
    private static let catchUpThreshold: Double = 0.12
    /// While refining, smaller corrections count.
    private static let refineThreshold: Double = 0.03
    private static let refineCount = 3
    /// A live report this far behind us, twice in a row, is a seek back elsewhere.
    private static let seekBackThreshold: Double = 2.5
    /// Reports ahead of us are usually just late, but when this many in a row agree we are ahead
    /// by more than `aheadThreshold`, playback really fell behind (a buffering stall that was
    /// not a pause): ease back by the smallest lead they saw.
    private static let aheadThreshold: Double = 0.05
    private static let aheadCount = 3
    /// App Remote answers in a few milliseconds, so a lead this big, again and again, is a real
    /// desync (a stall that was not a pause), not noise: fix it without waiting for an event.
    private static let remoteAheadThreshold: Double = 0.08
    private static let remoteAheadCount = 3
    /// A normal round trip; anything slower (a stall, a refreshed token, a retried connection)
    /// makes the answer this much less certain, and only a fast answer may fine-tune the clock.
    private static let normalRoundTrip: Double = 0.3
    /// How much slower than this connection's ping an answer may be and still count as normal.
    private static let roundTripAllowance: Double = 0.15

    /// A normal round trip on this connection: the fixed one on Wi-Fi, more on a slow mobile
    /// network (with a 400 ms ping every answer used to count as slow, and the clock was never
    /// corrected).
    private var normalRoundTrip: Double {
        max(Self.normalRoundTrip, (spotifyPing ?? 0) + Self.roundTripAllowance)
    }

    /// Remembers how long Spotify took to answer; the quickest of the last few is the ping.
    private func notePing(_ roundTrip: Double) {
        guard roundTrip > 0, roundTrip < 5 else { return }
        recentRoundTrips.append(roundTrip)
        if recentRoundTrips.count > 12 { recentRoundTrips.removeFirst() }
        guard let quickest = recentRoundTrips.min() else { return }
        let rounded = (quickest * 100).rounded() / 100
        if spotifyPing != rounded { spotifyPing = rounded }
    }
    /// App Remote answers slower than this went through a busy main thread: not trusted.
    private static let remoteMaxRoundTrip: Double = 0.25
    /// A song counts as freshly started when App Remote first reports it this early.
    private static let leadMaxStart: Double = 1.5
    /// Events this long after the start are no longer part of it: they re-base Spotify's position.
    private static let leadSettle: Double = 2.0

    /// The user's saved TTML files.
    @ObservationIgnored let localLyrics: LocalLyricsStore
    /// TTML applied "just once": kept for its track until the app quits.
    @ObservationIgnored private var temporaryLyrics: [String: LyricsDocument] = [:]

    init(api: SpotifyAPI, lyrics: LyricsService, settings: AppSettings, localLyrics: LocalLyricsStore) {
        self.api = api
        self.lyrics = lyrics
        self.settings = settings
        self.localLyrics = localLyrics
        appleMusic.onSample = { [weak self] in self?.applyAppleMusic($0) }
        appleMusic.onArtwork = { [weak self] image, id in
            guard let self, self.playbackSource == .appleMusic, self.track?.id == id else { return }
            self.artwork = image
            self.backgroundArtwork = image.downscaled(to: 160)
            self.artworkID = id
        }
        outputLatency = AudioRoute.outputLatency
        // Headphones connected or removed: the delay changes now, not at the next Web API poll
        // (which App Remote slows to every 5 s).
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.outputLatency = AudioRoute.outputLatency
                SyncLog.shared.add("audio", "output \(AudioRoute.outputKind), latency \(self.outputLatency.signedMs)")
            }
        }
    }

    // MARK: Clock

    /// Lyrics clock in seconds at media time `now`: playback position plus the user's offset,
    /// minus the audio output's delay when Spotify plays on this phone (Bluetooth headphones).
    func position(at now: CFTimeInterval = MediaClock.now()) -> Double {
        if let outgoing = outgoingLyrics {
            return min(outgoing.duration, outgoing.position + max(0, min(now, outgoing.deadline) - outgoing.startedAt))
                + settings.timingOffsetMs / 1000 - appliedOutputLatency
        }
        return playbackPosition(at: now) + settings.timingOffsetMs / 1000 - appliedOutputLatency
    }

    @discardableResult
    private func holdPreviousLyrics(for incoming: PlaybackSnapshot.Content, startOffset: Double,
                                    playing: Bool, at now: CFTimeInterval) -> Bool {
        endTransition()
        guard now >= manualChangeUntil, isPlaying, playing, case .track(let next) = incoming,
              let track, next.id != track.id, track.duration.isFinite, track.duration > 0 else { return false }
        // Measured on Spotify's own position: the start lead was taken off our clock, not off its.
        // Measured on ours, the lead (0.3-0.9 s) looked like a crossfade, held the old lyrics,
        // turned the next song's lead off (its lyrics ran early) and taught the detector a
        // crossfade that was never set.
        let remaining = track.duration - rawPosition(at: now) - (leadActive ? startLead : 0)
        let natural = transitionRun.allowsMeasurement(trackID: track.id, at: now)
        if natural {
            SyncLog.shared.add("transition", "natural change, remaining \(remaining.s3) s, new starts at \(startOffset.s3) s")
            settings.recordTransition(remaining: remaining, startOffset: startOffset)
        }
        // Known to be gapless: a second of clock error is no crossfade.
        let gapless = settings.transitionMode == .automatic && settings.transitionEstimate.crossfadeSeconds == 0
            && !settings.effectiveAutoMix
        let observedOverlap = natural && remaining > (gapless ? 1.5 : 0.7) && remaining <= 14
        let hold: Double
        if settings.transitionMode == .automatic {
            // The first overlap is measurable even before there is an estimate.
            let autoMix = settings.effectiveAutoMix || (playbackSource == .appleMusic && startOffset > 1.5)
            hold = observedOverlap ? min(remaining, autoMix ? 10 : remaining) : 0
        } else {
            hold = transitionWindow > 0 && remaining > 0 && remaining <= transitionWindow + 2
                ? min(remaining, transitionWindow) : 0
        }
        guard hold > 0, case .loaded(let prepared) = currentLyricsState else { return observedOverlap }
        let position = playbackPosition(at: now)
        outgoingLyrics = OutgoingLyrics(lyrics: prepared, position: position, startedAt: now,
                                        duration: track.duration, deadline: now + hold,
                                        translations: currentTranslations, documentRevision: currentDocumentRevision)
        lyricsRevision += 1
        SyncLog.shared.add("transition", "holding previous lyrics \(hold.s3) s")
        transitionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled else { return }
            self?.endTransition()
        }
        return observedOverlap
    }

    private func endTransition() {
        transitionTask?.cancel()
        transitionTask = nil
        if outgoingLyrics != nil {
            outgoingLyrics = nil
            lyricsRevision += 1
            snapToken += 1
        }
    }

    private func manualTrackChange() {
        manualChangeUntil = MediaClock.now() + 5
        transitionRun.interrupt()
        endTransition()
    }

    func sourceChanged() {
        sourceGeneration += 1
        stopPolling()
        lyricsTask?.cancel()
        artworkTask?.cancel()
        lookaheadTask?.cancel()
        noticeTask?.cancel()
        autoSkipNotice = nil
        autoSkipped = 0
        skipCheckedURI = nil
        skipExemptURI = nil
        endTransition()
        content = nil
        lyricsState = .idle
        rawLyrics = nil
        currentDocumentRevision += 1
        translations = [:]
        artwork = nil
        backgroundArtwork = nil
        artworkID = ""
        lastArtworkURL = nil
        statusMessage = nil
        transientError = nil
        accessProblem = nil
        contextURI = nil
        deviceName = nil
        isPlaying = false
        isResyncing = false
        playingOnThisPhone = false
        remoteConnected = false
        leadActive = false
        lastSample = nil
        appleSample = nil
        holdUntil = 0
        backoffUntil = 0
        manualChangeUntil = 0
        transitionRun = TransitionDetector.PlaybackRun()
        setClock(0)
        lyricsRevision += 1
    }

    private func applyAppleMusic(_ sample: AppleMusicPlayer.Sample) {
        guard playbackSource == .appleMusic else { return }
        isResyncing = false
        playingOnThisPhone = true
        guard let info = sample.track else {
            endTransition()
            content = nil
            lyricsTask?.cancel()
            lyricsState = .idle
            isPlaying = false
            appleSample = nil
            artwork = nil
            backgroundArtwork = nil
            artworkID = ""
            statusMessage = String(localized: "Включите музыку в Apple Music и разрешите доступ к медиатеке в настройках.")
            return
        }
        statusMessage = nil
        let now = MediaClock.now()
        let measured = sample.position + (sample.paused ? 0 : max(0, now - sample.measuredAt))
        let predicted = rawPosition(at: now)
        let drift = measured - predicted
        let changed = track?.id != info.id
        if changed {
            holdPreviousLyrics(for: .track(info), startOffset: measured, playing: !sample.paused, at: now)
            content = .track(info)
            artwork = nil
            backgroundArtwork = nil
            artworkID = ""
            onContentChanged(playing: !sample.paused)
            setClock(measured, at: now, detectSeek: false)
        } else if sample.paused != !isPlaying || sample.paused {
            endTransition()
            setClock(measured, at: now)
        } else if now >= holdUntil {
            // Repeated stepwise readings must not drag a smoothly running clock backwards.
            let frozen = appleSample.map { abs($0.position - sample.position) < 0.01 } ?? false
            if !frozen {
                if abs(drift) > Self.resyncThreshold { setClock(measured, at: now) }
                else if abs(drift) > Self.catchUpThreshold { blend(to: measured, predicted: predicted, now: now) }
            }
        }
        if track?.id == info.id, track != info {
            let needsLyrics = track?.title != info.title || track?.artists != info.artists || track?.duration != info.duration
            content = .track(info)
            if needsLyrics { loadLyrics(force: false) }
        }
        isPlaying = !sample.paused
        appleSample = sample
        if changed { SyncLog.shared.add("apple", "new track \(info.id), set \(measured.s3)") }
        SyncLog.shared.synced("Apple Music", drift: changed ? 0 : drift)
    }

    /// True from (re)starting the poll until Spotify has answered: what is on screen may be an
    /// old track (the app was in the background while the song changed).
    private(set) var isResyncing = false
    /// On-device translations of the current lyrics, keyed by the original line text.
    private var currentTranslations: [String: String] = [:]
    private(set) var translations: [String: String] {
        get { outgoingLyrics?.translations ?? currentTranslations }
        set { currentTranslations = newValue }
    }
    /// Why the last translation failed (shown in settings).
    var translationError: String?
    @ObservationIgnored private var outputLatency: Double = 0
    @ObservationIgnored private var playingOnThisPhone = false
    @ObservationIgnored private var routeObserver: NSObjectProtocol?

    /// Spotify last reported the song playing on a phone (this one, almost always).
    var isPlayingOnThisPhone: Bool { playingOnThisPhone }

    /// The lyrics on screen have no timing, so the song's position is of no use right now.
    var lyricsAreStatic: Bool {
        if case .loaded(let lyrics) = lyricsState { return lyrics.kind == .static }
        return false
    }

    /// The headphone delay subtracted from the clock right now (0 when it does not apply).
    var appliedOutputLatency: Double {
        settings.compensateOutputLatency && playingOnThisPhone ? outputLatency : 0
    }

    /// Spotify's playback position in seconds at media time `now`.
    func playbackPosition(at now: CFTimeInterval = MediaClock.now()) -> Double {
        let duration = track?.duration ?? .infinity
        return min(max(0, rawPosition(at: now)), duration)
    }

    private func rawPosition(at now: CFTimeInterval) -> Double {
        guard isPlaying else { return anchorPosition }
        let elapsed = max(0, now - anchorTime)
        return anchorPosition + elapsed + slew * min(1, elapsed / slewSpan)
    }

    /// Re-anchors the clock at `position` right now, dropping any pending correction.
    private func setClock(_ position: Double, at now: CFTimeInterval = MediaClock.now(), detectSeek: Bool = true) {
        if detectSeek, track != nil, abs(position - rawPosition(at: now)) > Self.resyncThreshold {
            transitionRun.interrupt()
        }
        anchorPosition = position
        anchorTime = now
        slew = 0
        behindStreak = 0
        aheadStreak = 0
    }

    /// Blends the clock toward `target` over a short span instead of jumping (a jump back would
    /// re-light sung words, a jump forward skips them).
    private func blend(to target: Double, predicted: Double, now: CFTimeInterval) {
        anchorPosition = predicted
        anchorTime = now
        slew = target - predicted
        // At most ±50 % speed while correcting, so the clock never stalls or runs backwards.
        slewSpan = max(Self.slewDuration, abs(slew) * 2)
    }

    private func apply(_ snapshot: PlaybackSnapshot?, roundTrip: Double) {
        guard supportsSpotifyFeatures, !Task.isCancelled else { return }
        let log = SyncLog.shared
        guard let snapshot else {
            log.add("web", "204 nothing playing (rtt \(roundTrip.signedMs))")
            if remoteAuthority { return }
            // No active device. Keep the last track on screen, just stop the clock.
            if isPlaying {
                setClock(rawPosition(at: MediaClock.now()))
                isPlaying = false
            }
            lastSample = nil
            statusMessage = String(localized: "Сейчас ничего не играет в Spotify")
            return
        }
        statusMessage = nil
        notePing(roundTrip)
        contextURI = snapshot.contextURI
        deviceName = snapshot.deviceName
        // A "Smartphone" device is (almost always) this iPhone: its audio route delay applies.
        playingOnThisPhone = snapshot.deviceType?.lowercased() == "smartphone"
        outputLatency = AudioRoute.outputLatency

        let now = MediaClock.now()
        let sameItem = Self.sameItem(content, snapshot.content)
        let trackChanged = !sameItem
        let summary = "\(snapshot.isPlaying ? "playing" : "paused") \(snapshot.progress.s3)s "
            + "\(Self.shortID(snapshot.content)) on \(snapshot.deviceType ?? "?") \"\(snapshot.deviceName ?? "")\" "
            + "rtt \(roundTrip.signedMs) stamp \(snapshot.stateChangedAt.map { String(format: "%.3f", $0) } ?? "-")"

        // Same song, new details (cover, a name filled in): update without reloading lyrics.
        if sameItem, content != snapshot.content {
            content = snapshot.content
            loadArtwork()
        }

        // The Spotify app on this phone knows better, and the cloud copy goes stale whenever the
        // phone is offline: while App Remote is connected the Web API only fills in details.
        if remoteAuthority {
            // After Spotify sits in the background for a long time iOS can suspend its side of
            // App Remote: the connection looks alive but goes quiet or reports a stale pause.
            // Two Web API reports in a row that disagree mean App Remote is stale: take the Web
            // API's word and reconnect.
            var webURI: String?
            if case .track(let info) = snapshot.content { webURI = info.uri }
            let remoteSong = trackChanged && webURI != remoteURI
            if now >= holdUntil, snapshot.isPlaying != isPlaying || remoteSong {
                remoteDisagreements += 1
                guard remoteDisagreements >= 2 else {
                    log.add("web", "\(summary) → disagrees with App Remote (1)")
                    return
                }
                remoteDisagreements = 0
                let measured = snapshot.progress + (snapshot.isPlaying ? now - snapshot.measuredAt : 0)
                log.add("web", "\(summary) → App Remote is stale: set \(measured.s3), reconnecting")
                if trackChanged {
                    holdPreviousLyrics(for: snapshot.content, startOffset: measured, playing: snapshot.isPlaying, at: now)
                    content = snapshot.content
                    onContentChanged(playing: snapshot.isPlaying)
                }
                setClock(measured, at: now, detectSeek: !trackChanged)
                isPlaying = snapshot.isPlaying
                lastSample = (snapshot.progress, snapshot.measuredAt, snapshot.stateChangedAt)
                onRemoteStale?()
                return
            }
            remoteDisagreements = 0
            if trackChanged, case .track(let info) = snapshot.content, info.uri == remoteURI {
                log.add("web", "\(summary) → track details for the App Remote track")
                let measured = snapshot.progress + (snapshot.isPlaying ? max(0, now - snapshot.measuredAt) : 0)
                holdPreviousLyrics(for: snapshot.content, startOffset: measured, playing: snapshot.isPlaying, at: now)
                content = snapshot.content
                onContentChanged()
            } else {
                log.add("web", "\(summary) → ignored (App Remote keeps the clock)")
            }
            return
        }

        // Right after a control action, polls may still describe the old state.
        if now < holdUntil && !trackChanged {
            log.add("web", "\(summary) → ignored (right after a control)")
            return
        }

        // Live or frozen? A playing position that did not move between two reports is frozen:
        // Spotify only refreshes it on play / pause / seek for some devices (its phone app).
        var stampChanged = false
        if let last = lastSample, !trackChanged, snapshot.isPlaying, isPlaying {
            if snapshot.measuredAt - last.measuredAt > 0.8 {
                frozenReports = abs(snapshot.progress - last.progress) < 0.15
            }
            stampChanged = snapshot.stateChangedAt != nil && snapshot.stateChangedAt != last.stamp
        } else if trackChanged {
            frozenReports = false
        }
        lastSample = (snapshot.progress, snapshot.measuredAt, snapshot.stateChangedAt)

        let measured = snapshot.progress + (snapshot.isPlaying ? now - snapshot.measuredAt : 0)
        // On a frozen device `progress_ms` is the position at `timestamp` (the last state change).
        var stampEstimate: Double?
        if frozenReports, snapshot.isPlaying, let stamp = snapshot.stateChangedAt {
            let estimate = snapshot.progress + (Date().timeIntervalSince1970 - stamp)
            if estimate >= snapshot.progress, estimate <= (track?.duration ?? .infinity) + 1 {
                stampEstimate = estimate
            }
        }

        let stateChanged = isPlaying != snapshot.isPlaying
        let predicted = rawPosition(at: now)
        // Part of the previous correction not blended in yet: the clock is already heading there.
        let unapplied = isPlaying ? slew * (1 - min(1, max(0, now - anchorTime) / slewSpan)) : 0
        let target = predicted + unapplied
        let drift = (stampEstimate ?? measured) - target
        var decision: String

        if trackChanged || stateChanged || !snapshot.isPlaying || isResyncing {
            if trackChanged {
                holdPreviousLyrics(for: snapshot.content, startOffset: measured, playing: snapshot.isPlaying, at: now)
            }
            if !snapshot.isPlaying { endTransition() }
            // Play, pause, a new song or the first report after the background: Spotify's
            // position is exact at these moments.
            setClock(measured, at: now, detectSeek: !trackChanged)
            refineSamples = snapshot.isPlaying && !frozenReports ? Self.refineCount : 0
            decision = "set \(measured.s3) (\(trackChanged ? "new track" : stateChanged ? "play/pause" : isResyncing ? "resync" : "paused"))"
        } else if frozenReports {
            // Keep our own clock; the frozen value only says where the last change happened.
            decision = "frozen device, kept clock"
            if stampChanged, let stampEstimate {
                setClock(stampEstimate, at: now) // a seek elsewhere
                decision = "frozen device, seek → set \(stampEstimate.s3)"
            } else if let stampEstimate, stampEstimate - target > Self.catchUpThreshold {
                // Opened mid-song, the first report was the stale frozen value: catch up.
                if stampEstimate - target > Self.resyncThreshold {
                    setClock(stampEstimate, at: now)
                    decision = "frozen device, far behind → set \(stampEstimate.s3)"
                } else {
                    blend(to: stampEstimate, predicted: predicted, now: now)
                    decision = "frozen device, catch up → blend"
                }
            }
        } else if roundTrip > normalRoundTrip * 2, abs(drift) < max(Self.resyncThreshold, roundTrip) {
            // A slow answer (the phone lagged, a token was refreshed, the connection retried): its
            // position is off by up to half the round trip either way. Wait for a fast one. Even a
            // big drift is no proof while it is within that error: a 3 s answer once jumped the
            // clock 1.3 s ahead, and the next ones had to pull it back.
            refineSamples = max(refineSamples, 1)
            decision = "slow answer, kept clock"
        } else {
            // Spotify's position can only be late (a stale or cached answer), never early. So a
            // report ahead of us means we are behind; one behind us is old news, unless it is far
            // behind twice in a row (a seek back on another device).
            let refining = refineSamples > 0
            refineSamples = max(0, refineSamples - 1)
            decision = "kept clock"
            // Whatever a somewhat slow request adds to the uncertainty is not corrected for.
            let slack = max(0, roundTrip - normalRoundTrip) / 2
            if drift > Self.resyncThreshold {
                setClock(measured, at: now)
                decision = "far behind → set"
            } else if drift - slack > (refining ? Self.refineThreshold : Self.catchUpThreshold) {
                blend(to: measured - slack, predicted: predicted, now: now)
                behindStreak = 0
                aheadStreak = 0
                decision = refining ? "refine → blend" : "behind → blend"
            } else if drift < -Self.seekBackThreshold {
                aheadStreak = 0
                behindStreak += 1
                decision = "report far behind (\(behindStreak))"
                if behindStreak >= 2 {
                    setClock(measured, at: now)
                    decision = "seek back elsewhere → set"
                }
            } else if drift < -Self.aheadThreshold {
                behindStreak = 0
                aheadLead = aheadStreak == 0 ? -drift : min(aheadLead, -drift)
                aheadStreak += 1
                decision = "ahead (\(aheadStreak))"
                if aheadStreak >= Self.aheadCount {
                    blend(to: target - aheadLead, predicted: predicted, now: now)
                    decision = "ahead \(aheadStreak)× → ease back \(aheadLead.signedMs)"
                    aheadStreak = 0
                }
            } else {
                behindStreak = 0
                aheadStreak = 0
            }
        }
        log.add("web", "\(summary) drift \(drift.signedMs) → \(decision)")
        log.synced("Web API", drift: drift)

        if stateChanged { isPlaying = snapshot.isPlaying }
        if trackChanged {
            content = snapshot.content
            onContentChanged()
            checkAutoSkip()
        }
    }

    /// App Remote is connected and allowed to keep the clock.
    private var remoteAuthority: Bool { supportsSpotifyFeatures && remoteConnected && settings.useAppRemote }

    func setRemoteConnected(_ connected: Bool) {
        guard supportsSpotifyFeatures else { remoteConnected = false; return }
        guard remoteConnected != connected else { return }
        remoteConnected = connected
        remoteQueriesFrozen = false
        leadActive = false
        remoteDisagreements = 0
        lastRemoteQuery = nil
        lastRemoteSampleAt = connected ? MediaClock.now() : 0
        // Back to the Web API: take its next answer as it is.
        if !connected, content != nil { isResyncing = true }
    }

    /// Same song (or episode / ad), whatever details differ.
    private static func sameItem(_ a: PlaybackSnapshot.Content?, _ b: PlaybackSnapshot.Content) -> Bool {
        switch (a, b) {
        case (.track(let x), .track(let y)): return x.uri == y.uri
        case (.episode(let x, let xs, _), .episode(let y, let ys, _)): return x == y && xs == ys
        case (.ad, .ad), (.unknown, .unknown): return true
        default: return false
        }
    }

    private static func shortID(_ content: PlaybackSnapshot.Content) -> String {
        switch content {
        case .track(let info): return "track:\(info.id.prefix(8)) \"\(info.title.prefix(24))\""
        case .episode(let title, _, _): return "episode \"\(title.prefix(24))\""
        case .ad: return "ad"
        case .unknown: return "unknown"
        }
    }

    /// A reading from the Spotify app on this phone (App Remote): exact to a few milliseconds.
    func applyRemote(_ sample: SpotifyAppRemote.Sample) {
        guard supportsSpotifyFeatures else { return }
        let log = SyncLog.shared
        let now = MediaClock.now()
        let kind = sample.event ? "event" : "query"
        let summary = "\(kind) \(sample.paused ? "paused" : "playing") \(sample.position.s3)s "
            + "\(sample.uri.split(separator: ":").last.map { String($0.prefix(8)) } ?? "?") \"\(sample.name.prefix(24))\""
            + " age \(max(0, now - sample.measuredAt).signedMs)"
        remoteURI = sample.uri
        lastRemoteSampleAt = now
        let raw = sample.position + (sample.paused ? 0 : max(0, now - sample.measuredAt))

        if track?.uri != sample.uri {
            guard sample.isTrack, let info = sample.trackInfo else {
                // A podcast or an ad: the Web API describes those.
                log.add("remote", "\(summary) → not a song, asking the Web API")
                if lastRemoteMismatch != sample.uri {
                    lastRemoteMismatch = sample.uri
                    refreshNow()
                }
                return
            }
            // A new song, straight from the phone (works offline); the Web API adds the cover.
            // A song started by our own skip reports 0.000 s exactly: the lead belongs to songs
            // that start by themselves (reports: lyrics 0.2-0.4 s late until the first pause).
            let overlap = holdPreviousLyrics(for: .track(info), startOffset: raw, playing: !sample.paused, at: now)
            leadActive = transitionWindow == 0 && !(settings.transitionMode == .automatic && overlap)
                && !sample.paused && sample.position < Self.leadMaxStart && now >= holdUntil
            trackStartedAt = now
            let start = raw - (leadActive ? startLead : 0)
            log.add("remote", "\(summary) → new track, set \(start.s3)"
                + (leadActive ? " (start lead \(startLead.signedMs))" : ""))
            content = .track(info)
            onContentChanged(playing: !sample.paused)
            setClock(start, at: now, detectSeek: false)
            isPlaying = !sample.paused
            lastRemoteQuery = nil
            remoteQueriesFrozen = false
            fetchTrackDetails(info)
            checkAutoSkip()
            return
        }
        lastRemoteMismatch = nil
        // An event after the start re-bases Spotify's position: from here on it is exact.
        let rebase = leadActive && sample.event && now - trackStartedAt > Self.leadSettle
        let measured = raw - (leadActive && !rebase ? startLead : 0)
        // Events are the truth even right after our own play / pause; queries may lag behind it.
        if now < holdUntil, !sample.event {
            log.add("remote", "\(summary) → ignored (right after a control)")
            return
        }

        let predicted = rawPosition(at: now)
        let unapplied = isPlaying ? slew * (1 - min(1, max(0, now - anchorTime) / slewSpan)) : 0
        let drift = measured - (predicted + unapplied)

        if sample.event {
            if sample.paused || abs(drift) > Self.seekBackThreshold { endTransition() }
            // Pushed on play, pause, seek or skip: exact, and the only source of play / pause.
            var decision = "kept clock"
            var leadNote = ""
            if rebase {
                leadActive = false
                // An event not caused by our own controls shows how far ahead Spotify's position
                // really was. A pause made elsewhere (Spotify, the lock screen, headphones) counts
                // too: it carries the exact position. Leaving pauses out kept the lead stuck at
                // 635 ms while it really was ~260 ms (a report: lyrics late all song long).
                // A slightly negative estimate can be timing noise around zero lead.
                // Reject larger undershoots before clamping: a seek forward in Spotify
                // must not be learned as zero lead and corrupt the saved estimate.
                let observed = startLead - drift
                if now >= holdUntil, (-0.25...1.5).contains(observed) {
                    let observed = max(0, observed)
                    startLead = (startLead + observed) / 2
                    leadNote = " (start lead \(observed.signedMs) → now \(startLead.signedMs))"
                } else {
                    leadNote = " (start lead dropped)"
                }
            }
            if sample.paused == isPlaying {
                isPlaying = !sample.paused
                setClock(measured, at: now)
                decision = sample.paused ? "paused → set" : "resumed → set"
            } else if sample.paused || abs(drift) > 0.02 {
                setClock(measured, at: now)
                decision = "set"
                // The timeline may have jumped (a stall, a seek): the next query is not
                // comparable with the one before, or it would look like queries stopped moving.
                lastRemoteQuery = nil
            }
            log.add("remote", "\(summary) drift \(drift.signedMs) → \(decision)\(leadNote)")
            log.synced("App Remote", drift: drift)
            return
        }

        // Queries between events: Spotify may answer with the position of its last event, so
        // they only ever move the clock forward, and stop counting once they stop moving.
        guard isPlaying, !sample.paused else {
            log.add("remote", "\(summary) → ignored (not playing)")
            return
        }
        // The answer went through a busy main thread: when it was read is anyone's guess.
        guard sample.roundTrip <= Self.remoteMaxRoundTrip else {
            log.add("remote", "\(summary) drift \(drift.signedMs) → ignored (slow answer, rtt \(sample.roundTrip.signedMs))")
            return
        }
        if let last = lastRemoteQuery, sample.measuredAt - last.at > 0.8 {
            let frozen = sample.position - last.position < (sample.measuredAt - last.at) * 0.5
            if frozen != remoteQueriesFrozen {
                log.add("remote", frozen ? "queries stopped moving: using events only" : "queries move again")
            }
            remoteQueriesFrozen = frozen
        }
        lastRemoteQuery = (sample.position, sample.measuredAt)
        guard !remoteQueriesFrozen else {
            log.add("remote", "\(summary) drift \(drift.signedMs) → ignored (cached answer)")
            return
        }
        // Never backwards: Spotify's answers between events can lag behind its real position, so
        // a query that says we are ahead is old news (events set the clock exactly anyway).
        var decision = "kept clock"
        if drift > Self.resyncThreshold {
            setClock(measured, at: now)
            decision = "far behind → set"
        } else if drift > Self.refineThreshold {
            blend(to: measured, predicted: predicted, now: now)
            decision = "behind → blend"
        } else if drift < -Self.remoteAheadThreshold {
            aheadLead = aheadStreak == 0 ? -drift : min(aheadLead, -drift)
            aheadStreak += 1
            decision = "ahead (\(aheadStreak))"
            if aheadStreak >= Self.remoteAheadCount {
                blend(to: predicted + unapplied - aheadLead, predicted: predicted, now: now)
                decision = "out of sync \(aheadLead.signedMs) → fixed"
                aheadStreak = 0
            }
        } else {
            aheadStreak = 0
        }
        log.add("remote", "\(summary) drift \(drift.signedMs) → \(decision)")
        log.synced("App Remote", drift: drift)
    }

    /// Cover and full details of a song App Remote announced (needs the internet).
    private func fetchTrackDetails(_ info: TrackInfo) {
        Task { [weak self, api] in
            guard let full = try? await api.track(id: info.id) else { return }
            guard let self, self.track?.uri == info.uri else { return }
            SyncLog.shared.add("web", "details for \"\(full.title.prefix(24))\"")
            self.content = .track(full)
            self.loadArtwork()
        }
    }

    /// The cover App Remote sent, until (or instead of) the Web API's.
    func setRemoteArtwork(_ image: UIImage, uri: String) {
        // Unless the Web API's cover for this song is already on screen.
        guard track?.uri == uri, lastArtworkURL == nil || artworkID != lastArtworkURL?.absoluteString else { return }
        artwork = image
        backgroundArtwork = image.downscaled(to: 160)
        artworkID = "remote:" + uri
    }

    // MARK: Polling

    func startPolling() {
        if playbackSource == .appleMusic { appleMusic.start(); return }
        #if DEBUG
        if DemoTrack.current != nil { return }
        #endif
        guard pollTask == nil else { return }
        // Coming back from the background: the song may have changed meanwhile.
        if content != nil { isResyncing = true }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.pollOnce()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        startWatchdog()
    }

    func stopPolling() {
        transitionRun.interrupt()
        appleMusic.stop()
        pollTask?.cancel()
        pollTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        resyncTask?.cancel()
        resyncTask = nil
    }

    // MARK: Safety checks

    /// A moment the clock is most likely to be off (the app or the floating window opening or
    /// closing, a stall): check it against Spotify right away, then a few more times quickly.
    func resync(_ reason: String) {
        if playbackSource == .appleMusic { appleMusic.read(); return }
        guard pollTask != nil else { return }
        snapToken += 1
        let now = MediaClock.now()
        guard now - lastResyncAt > 0.5 else { return }
        lastResyncAt = now
        SyncLog.shared.add("check", "\(reason) → checking the time")
        if !remoteAuthority { refineSamples = Self.refineCount }
        resyncTask?.cancel()
        resyncTask = Task { [weak self] in
            for (step, delay) in [0.0, 0.4, 0.8, 1.6].enumerated() {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled, let self, self.pollTask != nil else { return }
                if self.remoteAuthority {
                    // App Remote is exact; the Web API only checks it has not gone stale.
                    self.onRemoteQueryNow?()
                    if step == 0 { _ = await self.pollOnce() }
                } else {
                    _ = await self.pollOnce()
                }
            }
        }
    }

    /// Twice a second while following Spotify: notices a stuck main thread, a phone that slept
    /// (the media clock stops, the wall clock does not) and App Remote going silent.
    private func startWatchdog() {
        watchdogTask?.cancel()
        lastWatch = nil
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.watch()
            }
        }
    }

    private func watch() {
        checkAutoSkip()
        let media = MediaClock.now()
        let wall = Date().timeIntervalSince1970
        defer { lastWatch = (media, wall) }
        guard let last = lastWatch else { return }
        let mediaGap = media - last.media
        let slept = (wall - last.wall) - mediaGap
        if abs(slept) > 0.75 {
            // The clock was extrapolated over time that did not pass for it: start over.
            if isPlaying, content != nil { isResyncing = true }
            resync("clock skipped \(slept.signedMs)")
        } else if mediaGap > 1.5 {
            resync("stall \(mediaGap.signedMs)")
        } else if remoteAuthority, isPlaying, lastRemoteSampleAt > 0,
                  media - lastRemoteSampleAt > max(6, settings.remoteQueryInterval * 4) {
            // Connected, but not a word from Spotify for a while: the connection went stale.
            SyncLog.shared.add("check", "App Remote silent for \(Int(media - lastRemoteSampleAt)) s")
            lastRemoteSampleAt = media
            onRemoteStale?()
        }
    }

    /// Returns how long to wait before the next poll.
    private func pollOnce() async -> Double {
        guard supportsSpotifyFeatures, !Task.isCancelled else { return 1 }
        let generation = sourceGeneration
        let now = MediaClock.now()
        if now < backoffUntil { return backoffUntil - now }
        do {
            let sentAt = MediaClock.now()
            let snapshot = try await api.playbackState()
            guard generation == sourceGeneration, !Task.isCancelled else { return 1 }
            apply(snapshot, roundTrip: snapshot?.roundTrip ?? MediaClock.now() - sentAt)
            accessProblem = nil
            isResyncing = false
            return nextPollInterval()
        } catch SpotifyAPIError.rateLimited(let retryAfter) {
            guard generation == sourceGeneration, !Task.isCancelled else { return 1 }
            SyncLog.shared.add("web", "rate limited, retry in \(Int(retryAfter))s")
            backoffUntil = now + retryAfter
            return retryAfter
        } catch SpotifyAPIError.quotaExceeded(let retryAfter) {
            guard generation == sourceGeneration, !Task.isCancelled else { return 1 }
            accessProblem = .quotaExceeded
            statusMessage = SpotifyAPIError.quotaExceeded(retryAfter: retryAfter).errorDescription
            backoffUntil = now + retryAfter
            return retryAfter
        } catch SpotifyAPIError.userNotRegistered {
            guard generation == sourceGeneration, !Task.isCancelled else { return 1 }
            accessProblem = .notRegistered
            statusMessage = SpotifyAPIError.userNotRegistered.errorDescription
            return 15
        } catch SpotifyAuthError.notLoggedIn {
            guard generation == sourceGeneration, !Task.isCancelled else { return 1 }
            statusMessage = SpotifyAuthError.notLoggedIn.errorDescription
            return 5
        } catch is CancellationError {
            return 1
        } catch {
            if Task.isCancelled || generation != sourceGeneration { return 1 }
            SyncLog.shared.add("web", "poll failed: \(error.localizedDescription)")
            // Offline is fine while the Spotify app on this phone keeps the time.
            if !remoteAuthority { statusMessage = error.localizedDescription }
            // Right after returning to the app the first request often hits a stale connection:
            // retry quickly instead of showing the old track for seconds.
            return isResyncing ? 0.6 : 4
        }
    }

    /// The local clock carries the position between polls, so Spotify is asked every 2 s while
    /// playing (the quota is shared by everyone on a Client ID) and sooner near the end of a track,
    /// so the next song is picked up promptly.
    private func nextPollInterval() -> Double {
        // App Remote keeps time: the Web API only fills in details, so ask it less often.
        if remoteAuthority { return 5 }
        guard isPlaying else {
            // Stopped at the very end of a song: Spotify is most likely between two songs, ask
            // again soon so the next one shows up right away.
            if let duration = track?.duration, duration > 0, duration - playbackPosition() < 3 { return 1 }
            return 3
        }
        if refineSamples > 0 { return 0.35 }
        if let duration = track?.duration, duration > 0 {
            let remaining = duration - playbackPosition()
            if remaining > 0, remaining < 2 { return max(0.5, remaining + 0.3) }
        }
        return max(settings.webPollInterval, RemoteConfig.shared.values.minWebPollInterval)
    }

    func refreshNow() {
        if playbackSource == .appleMusic { appleMusic.read(); return }
        Task { _ = await pollOnce() }
    }

    // MARK: Controls

    func togglePlay() {
        transitionRun.interrupt()
        endTransition()
        if playbackSource == .appleMusic { appleMusic.togglePlay(); return }
        let wasPlaying = isPlaying
        control("play/pause", { [weak self, api] in
            if await self?.viaRemote(wasPlaying ? .pause : .play) == true { return }
            if wasPlaying { try await api.pause() } else { try await api.play() }
        }, optimistic: { [weak self] in
            guard let self else { return }
            self.setClock(self.rawPosition(at: MediaClock.now()))
            self.isPlaying = !wasPlaying
        })
    }

    func next() {
        manualTrackChange()
        if playbackSource == .appleMusic { appleMusic.next(); return }
        control("next", { [weak self, api] in
            if await self?.viaRemote(.next) == true { return }
            try await api.next()
        })
    }

    func previous() {
        manualTrackChange()
        if playbackSource == .appleMusic { appleMusic.previous(); return }
        exemptNextSongUntil = MediaClock.now() + 5
        control("previous", { [weak self, api] in
            if await self?.viaRemote(.previous) == true { return }
            try await api.previous()
        })
    }

    func seekLyrics(to seconds: Double) {
        // A tap on outgoing lyrics must not seek the new song to the old song's timestamp.
        if outgoingLyrics != nil { endTransition(); return }
        seek(to: seconds)
    }

    func seek(to requested: Double) {
        manualTrackChange()
        // Never past the end: Spotify would refuse it or jump to the next song.
        let seconds = min(max(0, requested), track.map { $0.duration > 0 ? $0.duration : .infinity } ?? .infinity)
        if playbackSource == .appleMusic {
            setClock(seconds)
            holdUntil = MediaClock.now() + 1
            appleMusic.seek(to: seconds)
            return
        }
        control("seek", { [weak self, api] in
            if await self?.viaRemote(.seek(seconds)) == true { return }
            try await api.seek(to: seconds)
        }, optimistic: { [weak self] in
            self?.setClock(seconds)
        })
    }

    /// Controls go straight to the Spotify app on this phone when it is connected: no internet
    /// needed and no round trip. Otherwise (or if it refuses) through the Web API.
    private func viaRemote(_ command: SpotifyAppRemote.Command) async -> Bool {
        guard remoteAuthority, let onRemoteCommand else { return false }
        return await onRemoteCommand(command)
    }

    #if DEBUG
    /// README recordings: the demo song "plays" from its start time on the local clock.
    func startDemo(_ demo: DemoTrack) {
        guard track?.id != demo.info.id else { return }
        content = .track(demo.info)
        onContentChanged()
        setClock(demo.start)
        isPlaying = true
    }
    #endif

    /// Jumps to an upcoming track by skipping everything queued before it.
    func skipAhead(_ count: Int) {
        guard supportsSpotifyFeatures, count > 0 else { return }
        manualTrackChange()
        control("skip ahead (\(count))", { [weak self, api] in
            for index in 0..<count {
                if index > 0 { try await Task.sleep(for: .milliseconds(150)) }
                if await self?.viaRemote(.next) == true { continue }
                try await api.next()
            }
        })
    }

    /// Plays a song from the queue. A few steps ahead are skipped to (that keeps songs added to
    /// the queue by hand); further down, the song is started inside the album or playlist
    /// instead of firing a dozen skips that each play for a moment.
    func playFromQueue(_ track: TrackSummary, at index: Int) {
        guard supportsSpotifyFeatures else { return }
        skipExemptURI = track.uri
        if index < 3 || contextURI.map(Self.supportsOffset) != true {
            skipAhead(index + 1)
        } else {
            play(track, context: contextURI)
        }
    }

    /// Plays `track`, continuing with the album or playlist it came from when there is one.
    func play(_ track: TrackSummary, context: String?) {
        guard supportsSpotifyFeatures else { return }
        manualTrackChange()
        skipExemptURI = track.uri
        let contexts = [context, track.albumURI].compactMap { $0 }.filter(Self.supportsOffset)
        control("play selected track", { [api] in
            for contextURI in contexts {
                do {
                    try await api.play(trackURI: track.uri, inContext: contextURI)
                    return
                } catch SpotifyAPIError.http(let status, _) where status == 400 || status == 404 {
                    continue // The track isn't part of that context (or it is gone); try the next.
                }
            }
            try await api.play(uris: [track.uri])
        })
    }

    /// True once Spotify took it.
    @discardableResult
    func addToQueue(_ track: TrackSummary) async -> Bool {
        guard supportsSpotifyFeatures else { return false }
        let generation = sourceGeneration
        do {
            try await api.addToQueue(track.uri)
            return generation == sourceGeneration
        } catch {
            guard generation == sourceGeneration else { return false }
            SyncLog.shared.add("control", "add to queue failed: \(error.localizedDescription)")
            transientError = error.localizedDescription
            return false
        }
    }

    func upcomingTracks() async throws -> [TrackSummary] {
        guard supportsSpotifyFeatures else { return [] }
        return try await api.queue()
    }

    func recentTracks() async throws -> [TrackSummary] {
        guard supportsSpotifyFeatures else { return [] }
        return try await api.recentlyPlayed()
    }
    func searchTracks(_ query: String, offset: Int) async throws -> [TrackSummary] {
        guard supportsSpotifyFeatures else { return [] }
        return try await api.search(query, offset: offset)
    }

    /// Only albums and playlists accept a starting track (`offset`).
    private static func supportsOffset(_ uri: String) -> Bool {
        uri.hasPrefix("spotify:album:") || uri.hasPrefix("spotify:playlist:")
    }

    private func control(_ name: String, _ action: @escaping () async throws -> Void, optimistic: (() -> Void)? = nil) {
        guard supportsSpotifyFeatures else { return }
        let generation = sourceGeneration
        optimistic?()
        // Ignore stale polls for a moment so the optimistic state isn't undone.
        holdUntil = MediaClock.now() + 1.5
        Task {
            do {
                try await action()
                try? await Task.sleep(for: .milliseconds(400))
            } catch {
                guard generation == sourceGeneration else { return }
                // Spotify not running anywhere: shown to the user, but not a bug to report.
                var expectedMissingDevice = false
                if case .noActiveDevice = error as? SpotifyAPIError { expectedMissingDevice = true }
                SyncLog.shared.add(expectedMissingDevice ? "control-expected" : "control",
                                   "\(name) failed: \(error.localizedDescription)")
                transientError = error.localizedDescription
            }
            guard generation == sourceGeneration else { return }
            holdUntil = 0
            _ = await pollOnce()
        }
    }

    // MARK: Auto-skip

    /// What a song's lyrics turned out to be: enough to judge it before it plays.
    @MainActor
    private struct KnownLyrics {
        /// From Spicy Lyrics or the user's own TTML.
        var spicy: Bool
        /// nil when there are none.
        var kind: LyricsKind?

        init(_ document: LyricsDocument?) {
            let source = document?.sourceName ?? ""
            spicy = source.hasPrefix("Spicy Lyrics") || source.hasPrefix(LocalLyricsStore.sourceName)
            kind = document?.kind
        }

        init(_ lyrics: PreparedLyrics) {
            let source = lyrics.sourceName
            spicy = source.hasPrefix("Spicy Lyrics") || source.hasPrefix(LocalLyricsStore.sourceName)
            kind = lyrics.kind
        }

        /// A Spicy Lyrics sync: timed by line, or by word when only word-by-word sync is wanted.
        func qualifies(_ mode: AutoSkipMode) -> Bool {
            guard spicy, let kind else { return false }
            return mode == .wordByWord ? kind == .syllable : kind != .static
        }
    }

    /// Skips the playing song when it has no Spicy Lyrics sync (and the setting asks for that).
    /// Songs from the queue were looked up ahead of time (`lookAhead`), so those go the moment
    /// they start, together with any known-unsynced songs queued right after them; others once
    /// their lyrics are in. Runs on every song change and from the watchdog.
    private func checkAutoSkip() {
        guard supportsSpotifyFeatures, outgoingLyrics == nil else { return }
        guard let mode = AutoSkipMode(rawValue: settings.autoSkipMode), mode != .off,
              isPlaying, let track else { return }
        if skipCheckedMode != settings.autoSkipMode {
            skipCheckedMode = settings.autoSkipMode
            skipCheckedURI = nil
        }
        guard skipCheckedURI != track.uri else { return }
        let qualifies: Bool
        switch lyricsState {
        case .loaded(let lyrics): qualifies = KnownLyrics(lyrics).qualifies(mode)
        case .notFound: qualifies = false
        default:
            // Still loading, or offline: only a lookup made ahead of time can tell.
            guard let known = lookahead[track.id] else { return }
            qualifies = known.qualifies(mode)
        }
        skipCheckedURI = track.uri
        if qualifies {
            autoSkipped = 0
            return
        }
        guard track.uri != skipExemptURI else { return }
        guard autoSkipped < Self.autoSkipLimit else {
            if autoSkipped == Self.autoSkipLimit {
                autoSkipped += 1
                showNotice(String(localized: "\(Self.autoSkipLimit) песен подряд без синхронизации — пропуск на паузе"))
            }
            return
        }
        // Songs queued right after this one that are known to be unsynced go too, in one go:
        // none of them gets to play for a moment.
        var count = 1
        if let index = upcomingIDs.firstIndex(of: track.id) {
            for id in upcomingIDs[(index + 1)...] {
                guard let known = lookahead[id], !known.qualifies(mode),
                      autoSkipped + count < Self.autoSkipLimit else { break }
                count += 1
            }
        }
        autoSkipped += count
        SyncLog.shared.add("skip", "\"\(track.title.prefix(30))\": no Spicy Lyrics sync, skipping \(count) (\(autoSkipped))")
        showNotice(count > 1 ? String(localized: "Пропущено песен без синхронизации: \(count)")
                             : String(localized: "Пропущено: \(track.title)"))
        skipAhead(count)
    }

    // MARK: Looking ahead

    /// Looks up the lyrics of the next songs in the queue while this one plays: they are
    /// cached, so they show at once when the song comes, and auto-skip knows in advance which
    /// songs to jump over.
    private func lookAhead() {
        lookaheadTask?.cancel()
        guard supportsSpotifyFeatures else { return }
        #if DEBUG
        if DemoTrack.current != nil { return }
        #endif
        guard let current = track, pollTask != nil else { return }
        let skipping = AutoSkipMode(rawValue: settings.autoSkipMode).map { $0 != .off } ?? false
        let config = RemoteConfig.shared.values
        let depth = skipping ? config.lookaheadDepthSkipping : config.lookaheadDepth
        guard depth > 0 else { return }
        lookaheadTask = Task { [weak self] in
            // The playing song's own requests go first.
            try? await Task.sleep(for: .seconds(config.lookaheadDelay))
            guard let self, !Task.isCancelled, self.track?.uri == current.uri,
                  let queue = try? await self.api.queue() else { return }
            let upcoming = queue.prefix(depth).compactMap(Self.trackInfo)
            self.upcomingIDs = upcoming.map(\.id)
            for info in upcoming where self.lookahead[info.id] == nil {
                guard !Task.isCancelled else { return }
                switch await self.lyrics.lyrics(for: info) {
                case .found(let document): self.lookahead[info.id] = KnownLyrics(document)
                case .notFound: self.lookahead[info.id] = KnownLyrics(nil)
                case .failed, .cancelled: break
                }
            }
            if self.lookahead.count > 300 { self.lookahead.removeAll() }
            SyncLog.shared.add("queue", "looked ahead at \(upcoming.count) songs")
        }
    }

    /// A queued song, as far as lyrics need it.
    private static func trackInfo(_ summary: TrackSummary) -> TrackInfo? {
        guard summary.uri.hasPrefix("spotify:track:"), let id = summary.uri.split(separator: ":").last else { return nil }
        return TrackInfo(id: String(id), uri: summary.uri, title: summary.title, artists: summary.artists,
                         album: "", duration: summary.duration, artworkURL: nil, isLocal: false)
    }

    private func showNotice(_ text: String) {
        autoSkipNotice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.autoSkipNotice = nil
        }
    }

    // MARK: Lyrics & artwork

    private func onContentChanged(playing: Bool? = nil) {
        transitionRun.begin(trackID: track?.id, playing: playing ?? isPlaying, at: MediaClock.now())
        if MediaClock.now() < exemptNextSongUntil, let uri = track?.uri {
            skipExemptURI = uri
            exemptNextSongUntil = 0
        }
        translations = [:]
        lyricsTask?.cancel()
        lyricsTask = nil
        rawLyrics = nil
        switch content {
        case .track:
            loadLyrics(force: false)
            lookAhead()
        case .episode:
            lyricsState = .unavailable(.episode)
        case .ad:
            lyricsState = .unavailable(.ad)
        case .unknown:
            lyricsState = .unavailable(.unknownTrack)
        case .none:
            lyricsState = .idle
        }
        loadArtwork()
        loadBackgroundVisuals()
    }

    /// The artist's photo or the Canvas when the background style asks for one. Each is looked up
    /// once per track (and remembered), in the background; until then the cover shows.
    func loadBackgroundVisuals() {
        let style = settings.background
        guard settings.dynamicBackground, supportsSpotifyFeatures,
              style == .artist || (style == .canvas && RemoteConfig.shared.values.canvas),
              case .track(let info) = content, !info.isLocal, !info.id.hasPrefix("am:")
        else {
            visualsTask?.cancel()
            visualsKey = ""
            if artistImage != nil { artistImage = nil }
            if canvasURL != nil { canvasURL = nil }
            return
        }
        let key = style.rawValue + "|" + info.id
        guard key != visualsKey else { return }
        visualsKey = key
        visualsTask?.cancel()
        let trackID = info.id, uri = info.uri
        switch style {
        case .artist:
            if canvasURL != nil { canvasURL = nil }
            if let cached = artistImages[trackID] {
                artistImage = cached
                return
            }
            artistImage = nil
            visualsTask = Task { [weak self] in
                guard let self else { return }
                guard let url = try? await self.api.artistImageURL(trackID: trackID),
                      let data = try? await URLSession.shared.data(from: url).0,
                      let image = UIImage(data: data)?.downscaled(to: 720),
                      !Task.isCancelled, self.visualsKey == key
                else { return }
                if self.artistImages.count > 40 { self.artistImages.removeAll() }
                self.artistImages[trackID] = image
                self.artistImage = image
            }
        case .canvas:
            if artistImage != nil { artistImage = nil }
            if let cached = canvasURLs[trackID] {
                canvasURL = cached
                return
            }
            canvasURL = nil
            visualsTask = Task { [weak self] in
                guard let self else { return }
                let url: URL?
                do {
                    url = try await self.api.canvasURL(trackURI: uri)
                } catch {
                    SyncLog.log("canvas", "failed: \(error.localizedDescription)")
                    return
                }
                guard !Task.isCancelled, self.visualsKey == key else { return }
                if self.canvasURLs.count > 100 { self.canvasURLs.removeAll() }
                self.canvasURLs[trackID] = url
                self.canvasURL = url
                SyncLog.log("canvas", url == nil ? "none for this song" : "found")
            }
        case .dynamic, .cover:
            break
        }
    }

    func loadLyrics(force: Bool) {
        guard let track else { return }
        if let temporary = temporaryLyrics[track.id] {
            show(temporary)
            return
        }
        lyricsTask?.cancel()
        lyricsState = .loading
        SyncLog.shared.add("lyrics", "loading \"\(track.title.prefix(30))\" \(track.id)\(force ? " (no cache)" : "")")
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.lyrics.lyrics(for: track, ignoreCache: force)
            guard !Task.isCancelled, self.track?.id == track.id else { return }
            self.lyricsTask = nil
            switch result {
            case .found(let document):
                SyncLog.shared.add("lyrics", "found: \(document.sourceName), \(document.kind.rawValue), \(document.lines.count) lines")
                self.show(document)
                self.checkAutoSkip()
            case .notFound:
                SyncLog.shared.add("lyrics", "not found")
                self.lyricsState = .notFound
                self.checkAutoSkip()
            case .failed(let failure):
                SyncLog.shared.add("lyrics", "failed: \(failure.detail)")
                self.lyricsState = .failed(failure)
            case .cancelled:
                break
            }
        }
    }

    func setTranslations(_ result: [String: String], revision: Int) {
        guard outgoingLyrics == nil, revision == currentDocumentRevision, result != currentTranslations else { return }
        translations = result
        settingsChanged()
    }

    /// What replaces the original lines right now (translation in replace mode).
    private var replacements: [String: String] {
        settings.translateLyrics && settings.translationReplaces ? currentTranslations : [:]
    }

    func clearLyricsCache() {
        lyrics.clearCache()
    }

    // MARK: Own TTML

    enum TTMLMode: String, CaseIterable {
        /// Saved in the library: used for this track from now on.
        case library
        /// Only until the app quits (the extension's "Just once").
        case temporary
    }

    enum TTMLError: LocalizedError {
        case noTrack
        var errorDescription: String? { String(localized: "Сейчас не играет трек, к которому можно привязать текст.") }
    }

    var hasTemporaryLyrics: Bool { track.map { temporaryLyrics[$0.id] != nil } ?? false }

    /// Parses a TTML and shows it for the current track, saving it to the library if asked.
    func applyTTML(_ text: String, mode: TTMLMode) throws {
        guard let track else { throw TTMLError.noTrack }
        let document: LyricsDocument
        switch mode {
        case .library:
            document = try localLyrics.save(text, for: track)
            temporaryLyrics[track.id] = nil
        case .temporary:
            document = try TTMLParser.parse(text, sourceName: "Local TTML (temporary)")
            temporaryLyrics[track.id] = document
        }
        show(document)
    }

    /// Removes a track's own lyrics (saved and temporary) and reloads if it is playing.
    func removeOwnLyrics(trackID: String) {
        localLyrics.remove(trackID)
        temporaryLyrics[trackID] = nil
        if track?.id == trackID { loadLyrics(force: false) }
    }

    private func show(_ document: LyricsDocument) {
        lyricsTask?.cancel()
        lyricsTask = nil
        rawLyrics = document
        translations = [:]
        currentDocumentRevision += 1
        prepare(document)
    }

    private func prepare(_ document: LyricsDocument) {
        preparedRomanized = settings.showRomanization
        preparedSimple = settings.simpleLyricsMode
        preparedShape = currentShape
        preparedReplacements = replacements
        lyricsRevision += 1
        lyricsState = .loaded(PreparedLyrics(document: document, romanized: preparedRomanized,
                                             simple: preparedSimple, joinSplit: preparedShape.joinSplit,
                                             minimal: preparedShape.minimal, refreshed: preparedShape.refreshed,
                                             replacements: preparedReplacements))
    }

    /// Re-prepares the current lyrics after a display setting (or a replacing translation) changed.
    func settingsChanged() {
        guard let rawLyrics,
              preparedRomanized != settings.showRomanization || preparedSimple != settings.simpleLyricsMode
                || preparedShape != currentShape || preparedReplacements != replacements
        else { return }
        prepare(rawLyrics)
    }

    private func loadArtwork() {
        let url: URL?
        switch content {
        case .track(let track): url = track.artworkURL
        case .episode(_, _, let artworkURL): url = artworkURL
        default: url = nil
        }
        guard url != lastArtworkURL else { return }
        lastArtworkURL = url
        artworkTask?.cancel()
        guard let url else {
            // A song App Remote announced has no cover URL yet (its own cover or the Web API's
            // comes in a moment): keep the last one until then, so the background flows from
            // cover to cover instead of dipping to black.
            if case .track = content, artwork != nil { return }
            artwork = nil
            backgroundArtwork = nil
            artworkID = ""
            return
        }
        artworkTask = Task { [weak self] in
            // A failed download used to leave the background black for the whole song.
            var image: UIImage?
            for delay in [0.0, 1, 3, 8] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                for source in Self.artworkMirrors(url) {
                    if let data = try? await URLSession.shared.data(from: source).0, let decoded = UIImage(data: data) {
                        image = decoded
                        break
                    }
                }
                if image != nil { break }
            }
            guard let self, !Task.isCancelled else { return }
            guard let image else {
                // Try again on the next change; App Remote's cover may fill in meanwhile.
                if self.lastArtworkURL == url { self.lastArtworkURL = nil }
                return
            }
            self.artwork = image
            self.backgroundArtwork = image.downscaled(to: 160)
            self.artworkID = url.absoluteString
        }
    }

    /// `i.scdn.co` is unreachable on some networks (TLS fails); Spotify serves the same covers
    /// from its other CDN hosts.
    private static func artworkMirrors(_ url: URL) -> [URL] {
        guard url.host == "i.scdn.co", var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return [url] }
        return [url] + ["image-cdn-ak.spotifycdn.com", "image-cdn-fa.spotifycdn.com"].compactMap { host in
            components.host = host
            return components.url
        }
    }
}
