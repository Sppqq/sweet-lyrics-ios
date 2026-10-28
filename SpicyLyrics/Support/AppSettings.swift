import Foundation
import Observation
import SwiftUI

enum PlaybackSource: String, CaseIterable, Identifiable, Hashable {
    case spotify, appleMusic
    var id: String { rawValue }
    var title: String { self == .spotify ? "Spotify" : "Apple Music" }
}

/// Which player the lyrics follow: whichever of the two is playing (the default), or always one.
enum PlayerChoice: String, CaseIterable, Identifiable, Hashable {
    case automatic = "auto", spotify, appleMusic
    var id: String { rawValue }
    var title: String { source?.title ?? String(localized: "Авто") }
    /// The fixed player, nil for automatic.
    var source: PlaybackSource? {
        switch self {
        case .automatic: return nil
        case .spotify: return .spotify
        case .appleMusic: return .appleMusic
        }
    }
}

/// User preferences, persisted in UserDefaults. The Spicy Lyrics key lives here too: it is a
/// public client key (`sl_pk_…`), not a secret.
@Observable
final class AppSettings {
    private let defaults: UserDefaults
    /// The player being followed right now. Fixed by `playerChoice`, or switched by
    /// `AutoSourceSwitcher` when the choice is automatic (then it is the last one that played).
    var playbackSource: PlaybackSource { didSet { defaults.set(playbackSource.rawValue, forKey: Keys.playbackSource) } }
    var playerChoice: PlayerChoice {
        didSet {
            defaults.set(playerChoice.rawValue, forKey: Keys.playerChoice)
            if let source = playerChoice.source, playbackSource != source { playbackSource = source }
        }
    }
    var appleMusicOnboarded: Bool { didSet { defaults.set(appleMusicOnboarded, forKey: Keys.appleMusicOnboarded) } }
    var crossfadeSeconds: Double { didSet { defaults.set(crossfadeSeconds, forKey: Keys.crossfadeSeconds) } }
    var appleMusicAutoMix: Bool { didSet { defaults.set(appleMusicAutoMix, forKey: Keys.appleMusicAutoMix) } }
    var transitionMode: TransitionMode { didSet { defaults.set(transitionMode.rawValue, forKey: Keys.transitionMode) } }
    private(set) var transitionDetector: TransitionDetector {
        didSet {
            if let data = try? JSONEncoder().encode(transitionDetector) { defaults.set(data, forKey: Keys.transitionDetection) }
        }
    }

    var effectiveAutoMix: Bool {
        playbackSource == .appleMusic && (transitionMode == .manual ? appleMusicAutoMix : transitionEstimate.autoMix)
    }

    var effectiveTransitionWindow: Double {
        if effectiveAutoMix { return 10 }
        return transitionMode == .manual ? min(12, max(0, crossfadeSeconds)) : (transitionEstimate.crossfadeSeconds ?? 0)
    }

    var transitionEstimate: TransitionDetector.Estimate { transitionDetector.estimate(for: playbackSource) }

    func recordTransition(remaining: Double, startOffset: Double) {
        transitionDetector.record(remaining: remaining, startOffset: startOffset, source: playbackSource)
    }

    func resetTransitionDetection() { transitionDetector.reset(for: playbackSource) }

    /// The user's own Client ID (from their own Spotify developer app). Required: none is built in.
    var spotifyClientID: String { didSet { defaults.set(spotifyClientID, forKey: Keys.clientID) } }
    var spicyLyricsKey: String { didSet { defaults.set(spicyLyricsKey, forKey: Keys.spicyKey) } }
    /// Shifts lyrics against the playback clock, in milliseconds. Positive = lyrics earlier.
    var timingOffsetMs: Double { didSet { defaults.set(timingOffsetMs, forKey: Keys.offset) } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: Keys.fontSize) } }
    var blurInactiveLines: Bool { didSet { defaults.set(blurInactiveLines, forKey: Keys.blur) } }
    var dynamicBackground: Bool { didSet { defaults.set(dynamicBackground, forKey: Keys.background) } }
    var showRomanization: Bool { didSet { defaults.set(showRomanization, forKey: Keys.romanization) } }
    var useLRCLibFallback: Bool { didSet { defaults.set(useLRCLibFallback, forKey: Keys.lrclib) } }
    var keepScreenOn: Bool { didSet { defaults.set(keepScreenOn, forKey: Keys.keepScreenOn) } }
    /// Fade the header and controls out while lyrics play, like Apple Music.
    var autoHideControls: Bool { didSet { defaults.set(autoHideControls, forKey: Keys.autoHide) } }
    /// Subtract the audio output delay (Bluetooth) when Spotify plays on this iPhone.
    var compensateOutputLatency: Bool { didSet { defaults.set(compensateOutputLatency, forKey: Keys.outputLatency) } }
    /// Read the position from the Spotify app on this phone (App Remote) when it is reachable.
    var useAppRemote: Bool { didSet { defaults.set(useAppRemote, forKey: Keys.appRemote) } }
    /// Seconds between Web API polls while playing (when App Remote is not keeping time).
    var webPollInterval: Double { didSet { defaults.set(webPollInterval, forKey: Keys.webPollInterval) } }
    /// Seconds between App Remote position queries.
    var remoteQueryInterval: Double { didSet { defaults.set(remoteQueryInterval, forKey: Keys.remoteQueryInterval) } }
    /// Keep the sync log (Settings → Sync log).
    var syncLogEnabled: Bool { didSet { defaults.set(syncLogEnabled, forKey: Keys.syncLog) } }
    /// Small badge over the lyrics: where the time came from and how far off it was.
    var showSyncIndicator: Bool { didSet { defaults.set(showSyncIndicator, forKey: Keys.syncIndicator) } }
    // Picture in Picture look.
    var pipTextScale: Double { didSet { defaults.set(pipTextScale, forKey: Keys.pipTextScale) } }
    var pipBackgroundDim: Double { didSet { defaults.set(pipBackgroundDim, forKey: Keys.pipBackgroundDim) } }
    var pipFrameRate: Double { didSet { defaults.set(pipFrameRate, forKey: Keys.pipFrameRate) } }
    var pipShowTranslation: Bool { didSet { defaults.set(pipShowTranslation, forKey: Keys.pipShowTranslation) } }
    var pipBlurLines: Bool { didSet { defaults.set(pipBlurLines, forKey: Keys.pipBlurLines) } }
    /// Translate the lyrics on the device and show the translation under each line.
    var translateLyrics: Bool { didSet { defaults.set(translateLyrics, forKey: Keys.translate) } }
    var translationLanguage: String { didSet { defaults.set(translationLanguage, forKey: Keys.translationLanguage) } }
    /// `TranslationProvider.rawValue`: where translations come from.
    var translationProvider: String { didSet { defaults.set(translationProvider, forKey: Keys.translationProvider) } }
    /// The user's own DeepL API key (kept in the Keychain).
    var deeplKey: String {
        didSet {
            // Saved once typing pauses, not on every keystroke.
            deeplSave?.cancel()
            let key = deeplKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let save = DispatchWorkItem {
                if key.isEmpty { Keychain.delete(Self.deeplKeychainKey) } else { Keychain.write(Self.deeplKeychainKey, data: Data(key.utf8)) }
            }
            deeplSave = save
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: save)
        }
    }
    @ObservationIgnored private var deeplSave: DispatchWorkItem?
    /// Interface language: "system", "en" or "ru". Applied through `AppleLanguages` on the next launch.
    var appLanguage: String {
        didSet {
            defaults.set(appLanguage, forKey: Keys.appLanguage)
            Self.applyLanguage(appLanguage)
        }
    }
    /// Show the translation instead of the original line (re-timed), not under it.
    var translationReplaces: Bool { didSet { defaults.set(translationReplaces, forKey: Keys.translationReplaces) } }
    /// Open the floating lyrics window when leaving the app.
    var autoPictureInPicture: Bool { didSet { defaults.set(autoPictureInPicture, forKey: Keys.autoPiP) } }
    /// Opening the app closes the floating window.
    var closePiPOnReturn: Bool { didSet { defaults.set(closePiPOnReturn, forKey: Keys.closePiPOnReturn) } }
    /// PiP: drifting cover background like the app (off = still cover, for weaker phones).
    var pipAnimatedBackground: Bool { didSet { defaults.set(pipAnimatedBackground, forKey: Keys.pipAnimatedBackground) } }
    /// PiP: track and artist under the lyrics.
    var pipShowTitle: Bool { didSet { defaults.set(pipShowTitle, forKey: Keys.pipShowTitle) } }
    /// `PiPFormat.rawValue`: the window's shape.
    var pipFormat: String { didSet { defaults.set(pipFormat, forKey: Keys.pipFormat) } }
    /// Spicy Lyrics' Simple Lyrics Mode: calmer word animation, softer fill.
    var simpleLyricsMode: Bool { didSet { defaults.set(simpleLyricsMode, forKey: Keys.simpleMode) } }
    /// Centre the lyrics instead of aligning them left (duets then stay centred too).
    var centerLyrics: Bool { didSet { defaults.set(centerLyrics, forKey: Keys.centerLyrics) } }
    /// `LyricsFont.rawValue`.
    var lyricsFont: String { didSet { defaults.set(lyricsFont, forKey: Keys.lyricsFont) } }
    /// `AppTheme.rawValue`.
    var theme: String { didSet { defaults.set(theme, forKey: Keys.theme) } }
    var appTheme: AppTheme { AppTheme(rawValue: theme) ?? .cover }
    /// Swipes to change tracks and pinch to resize the lyrics.
    var gesturesEnabled: Bool { didSet { defaults.set(gesturesEnabled, forKey: Keys.gestures) } }
    /// The system volume slider under the playback buttons.
    var showVolumeSlider: Bool { didSet { defaults.set(showVolumeSlider, forKey: Keys.volumeSlider) } }
    /// Battery saver: 30 fps lyrics, no line blur, still background.
    var powerSaving: Bool { didSet { defaults.set(powerSaving, forKey: Keys.powerSaving) } }
    /// Landscape: show the big artwork / the title and artist next to the lyrics.
    var landscapeArtwork: Bool { didSet { defaults.set(landscapeArtwork, forKey: Keys.landscapeArtwork) } }
    var landscapeTitle: Bool { didSet { defaults.set(landscapeTitle, forKey: Keys.landscapeTitle) } }
    /// Landscape: nothing but the lyrics; a tap brings the controls back for a few seconds.
    var landscapeLyricsOnly: Bool { didSet { defaults.set(landscapeLyricsOnly, forKey: Keys.landscapeLyricsOnly) } }
    /// Show just the background instead of the "lyrics not found" notice.
    var hideNotFoundNotice: Bool { didSet { defaults.set(hideNotFoundNotice, forKey: Keys.hideNotFound) } }
    /// Show just the background instead of unsynced (static) lyrics.
    var hideStaticLyrics: Bool { didSet { defaults.set(hideStaticLyrics, forKey: Keys.hideStatic) } }
    /// `HiddenLyricsView.rawValue`: what fills the screen where lyrics were hidden.
    var hiddenLyricsView: String { didSet { defaults.set(hiddenLyricsView, forKey: Keys.hiddenLyricsView) } }
    /// `NebulaColors.rawValue`: where the nebula takes its colours from.
    var nebulaColors: String { didSet { defaults.set(nebulaColors, forKey: Keys.nebulaColors) } }
    /// Visible nebula brightness, from black to its original brightness.
    var nebulaBrightness: Double { didSet { defaults.set(nebulaBrightness, forKey: Keys.nebulaBrightness) } }
    /// Twinkling stars in the dark parts of the nebula.
    var nebulaStars: Bool { didSet { defaults.set(nebulaStars, forKey: Keys.nebulaStars) } }
    // The TV (AirPlay screen mirroring or a cable): set up from the phone while it is connected.
    /// × the lyrics' size on the TV.
    var tvLyricsScale: Double { didSet { defaults.set(tvLyricsScale, forKey: Keys.tvLyricsScale) } }
    /// Milliseconds the TV's lyrics run ahead (a TV shows the picture later than the sound plays).
    var tvOffsetMs: Double { didSet { defaults.set(tvOffsetMs, forKey: Keys.tvOffsetMs) } }
    /// Cover and title on the left of the TV's lyrics.
    var tvShowNowBar: Bool { didSet { defaults.set(tvShowNowBar, forKey: Keys.tvShowNowBar) } }
    /// The timeline under the TV's title.
    var tvShowTimeline: Bool { didSet { defaults.set(tvShowTimeline, forKey: Keys.tvShowTimeline) } }
    /// `TVBackground.rawValue`.
    var tvBackground: String { didSet { defaults.set(tvBackground, forKey: Keys.tvBackground) } }
    /// Black layer over the TV's background.
    var tvBackgroundDim: Double { didSet { defaults.set(tvBackgroundDim, forKey: Keys.tvBackgroundDim) } }
    /// The phone keeps showing the lyrics too, instead of the TV's settings.
    var tvPhoneLyrics: Bool { didSet { defaults.set(tvPhoneLyrics, forKey: Keys.tvPhoneLyrics) } }
    /// `ArtworkBackground.rawValue`: what flows behind the big cover.
    var artworkBackground: String { didSet { defaults.set(artworkBackground, forKey: Keys.artworkBackground) } }
    /// Full-screen Canvas with the big cover hidden, when the track has a video.
    var artworkCanvas: Bool { didSet { defaults.set(artworkCanvas, forKey: Keys.artworkCanvas) } }
    /// One synced line under the big cover.
    var artworkLyricLine: Bool { didSet { defaults.set(artworkLyricLine, forKey: Keys.artworkLyricLine) } }
    /// `AutoSkipMode.rawValue`: skip songs without a Spicy Lyrics sync.
    var autoSkipMode: String { didSet { defaults.set(autoSkipMode, forKey: Keys.autoSkip) } }

    // Look & feel (multipliers are 1 at the original's values).
    /// Strength of the blur on lines away from the active one.
    var blurStrength: Double { didSet { defaults.set(blurStrength, forKey: Keys.blurStrength) } }
    /// Strength of the glow around sung words.
    var glowStrength: Double { didSet { defaults.set(glowStrength, forKey: Keys.glowStrength) } }
    /// Brightness of lines that are not being sung.
    var inactiveBrightness: Double { didSet { defaults.set(inactiveBrightness, forKey: Keys.inactiveBrightness) } }
    /// Gap between lines.
    var lineSpacingScale: Double { didSet { defaults.set(lineSpacingScale, forKey: Keys.lineSpacingScale) } }
    /// Size of the translation under a line, × its default.
    var translationScale: Double { didSet { defaults.set(translationScale, forKey: Keys.translationScale) } }
    /// Black layer over the background, 0…0.7.
    var backgroundDim: Double { didSet { defaults.set(backgroundDim, forKey: Keys.backgroundDim) } }
    /// Speed of the background drift.
    var backgroundSpeed: Double { didSet { defaults.set(backgroundSpeed, forKey: Keys.backgroundSpeed) } }
    /// Blur of the background cover.
    var backgroundBlur: Double { didSet { defaults.set(backgroundBlur, forKey: Keys.backgroundBlur) } }
    /// Seconds before the controls hide while a song plays.
    var autoHideDelay: Double { didSet { defaults.set(autoHideDelay, forKey: Keys.autoHideDelay) } }
    /// `LyricsWeight.rawValue`.
    var lyricsWeight: String { didSet { defaults.set(lyricsWeight, forKey: Keys.lyricsWeight) } }
    /// Where the line being sung sits in the visible lyrics: 0.5 is the middle (the original).
    var activeLinePosition: Double { didSet { defaults.set(activeLinePosition, forKey: Keys.activeLinePosition) } }
    /// × the speed of the glide to the next line.
    var scrollSpeed: Double { didSet { defaults.set(scrollSpeed, forKey: Keys.scrollSpeed) } }
    /// Start scrolling to the next line a bit before it is sung.
    var earlyScroll: Bool { didSet { defaults.set(earlyScroll, forKey: Keys.earlyScroll) } }
    var earlyScrollMs: Double { didSet { defaults.set(earlyScrollMs, forKey: Keys.earlyScrollMs) } }
    /// A tap on a line lands 300 ms before it, so the player's fade-in after a seek
    /// doesn't swallow the first word (the extension's Seek Fade-in Compensation).
    var seekFadeCompensation: Bool { didSet { defaults.set(seekFadeCompensation, forKey: Keys.seekFadeCompensation) } }
    /// Days synced lyrics stay in the cache (1…30): kept longer, a song played again is there at once.
    var syncedLyricsCacheDays: Double {
        didSet { defaults.set(syncedLyricsCacheDays, forKey: Keys.syncedLyricsCacheDays) }
    }
    static let syncedLyricsCacheRange: ClosedRange<Double> = 1...30
    /// The same, read off the main thread by the lyrics cache.
    nonisolated static var syncedLyricsCacheDaysStored: Double {
        let stored = UserDefaults.standard.object(forKey: Keys.syncedLyricsCacheDays) as? Double ?? 7
        return min(max(stored, syncedLyricsCacheRange.lowerBound), syncedLyricsCacheRange.upperBound)
    }
    /// Smooth Scrolling: glide from line to line; off, the lyrics jump to the next line.
    var smoothScrolling: Bool { didSet { defaults.set(smoothScrolling, forKey: Keys.smoothScrolling) } }
    /// Duet Line Padding: each singer's lines lean toward their side, so duets read as two columns.
    var duetLinePadding: Bool { didSet { defaults.set(duetLinePadding, forKey: Keys.duetLinePadding) } }
    /// Join Split Words: a word sung in evenly paced parts is shown and filled as one word.
    var joinSplitWords: Bool { didSet { defaults.set(joinSplitWords, forKey: Keys.joinSplitWords) } }
    /// Minimal Lyrics Mode: lines fade out once sung, lines to come wait a little smaller.
    var minimalLyricsMode: Bool { didSet { defaults.set(minimalLyricsMode, forKey: Keys.minimalLyricsMode) } }
    /// In Minimal Lyrics Mode a line that ends while one above it is still sung stays, dimmed.
    var keepOverlappingLines: Bool { didSet { defaults.set(keepOverlappingLines, forKey: Keys.keepOverlappingLines) } }
    /// Experiment: background vocals stay tucked under their line until it's sung.
    var backgroundLinePop: Bool { didSet { defaults.set(backgroundLinePop, forKey: Keys.backgroundLinePop) } }
    /// Experiment: the refreshed Simple Lyrics Mode (one sweep along the line, floating words).
    var refreshedSimpleLyrics: Bool { didSet { defaults.set(refreshedSimpleLyrics, forKey: Keys.refreshedSimpleLyrics) } }
    /// What the cover background shows: the flowing cover, the still cover, the artist, the Canvas.
    var backgroundStyle: String { didSet { defaults.set(backgroundStyle, forKey: Keys.backgroundStyle) } }
    /// Visible video brightness: 0 is black, 1 is the original video.
    var canvasBrightness: Double { didSet { defaults.set(canvasBrightness, forKey: Keys.canvasBrightness) } }
    var showCanvas: Bool { didSet { defaults.set(showCanvas, forKey: Keys.showCanvas) } }
    var background: BackgroundStyle {
        let style = BackgroundStyle(rawValue: backgroundStyle) ?? .dynamic
        return showCanvas ? .canvas : (BackgroundStyle.offered.contains(style) ? style : .dynamic)
    }
    /// Spicy Lyrics' "Refined Credits": quiet type under the last line instead of the old credit lines.
    var refinedCredits: Bool { didSet { defaults.set(refinedCredits, forKey: Keys.refinedCredits) } }
    /// A song ending on a duet line sung from the right keeps its credits on that side.
    var creditsFollowLastLine: Bool { didSet { defaults.set(creditsFollowLastLine, forKey: Keys.creditsFollowLastLine) } }
    /// × the brightness of the translation under a line.
    var translationBrightness: Double { didSet { defaults.set(translationBrightness, forKey: Keys.translationBrightness) } }
    /// × the saturation of the cover behind the lyrics (app and PiP).
    var backgroundSaturation: Double { didSet { defaults.set(backgroundSaturation, forKey: Keys.backgroundSaturation) } }
    /// Lyrics frame rate while a song plays (battery saver caps it at 30).
    var lyricsFrameRate: Double { didSet { defaults.set(lyricsFrameRate, forKey: Keys.lyricsFrameRate) } }
    /// Frame counter over the lyrics / in the PiP window.
    var showLyricsFPS: Bool { didSet { defaults.set(showLyricsFPS, forKey: Keys.showLyricsFPS) } }
    var pipShowFPS: Bool { didSet { defaults.set(pipShowFPS, forKey: Keys.pipShowFPS) } }
    /// Open Spotify once by itself when it keeps refusing the SDK connection.
    var autoWakeSpotify: Bool { didSet { defaults.set(autoWakeSpotify, forKey: Keys.autoWakeSpotify) } }
    /// May errors be sent to the developer by themselves (anonymously)? 0 = not asked yet, 1 = yes, 2 = no.
    var reportConsent: Int { didSet { defaults.set(reportConsent, forKey: Keys.reportConsent) } }
    /// The app version that last ran, to ask about reports once after an update.
    var lastSeenVersion: String { didSet { defaults.set(lastSeenVersion, forKey: Keys.lastSeenVersion) } }
    /// Tell about a newer stable release (Settings → About).
    var notifyUpdates: Bool { didSet { defaults.set(notifyUpdates, forKey: Keys.notifyUpdates) } }
    /// A release the user chose to skip: no notice for it, only for a newer one.
    var skippedUpdateVersion: String { didSet { defaults.set(skippedUpdateVersion, forKey: Keys.skippedUpdateVersion) } }
    /// The "star on GitHub" row on the main settings page.
    var showStarRow: Bool { didSet { defaults.set(showStarRow, forKey: Keys.showStarRow) } }
    /// Random, made once per install: tells reports from one phone apart, and nothing else.
    let installID: String

    var sendsReports: Bool {
        get { reportConsent == 1 }
        set { reportConsent = newValue ? 1 : 2 }
    }

    /// Keys baked in at build time from `Config/Secrets.xcconfig` or CI secrets (may be empty).
    /// When present they are fixed: the app ignores anything typed in settings.
    let bundledSpicyLyricsKey = BundledKeys.spicyLyricsKey.flatMap(AppSettings.clientKey)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let choice = PlayerChoice(rawValue: defaults.string(forKey: Keys.playerChoice) ?? "") ?? .automatic
        playerChoice = choice
        playbackSource = choice.source
            ?? PlaybackSource(rawValue: defaults.string(forKey: Keys.playbackSource) ?? "") ?? .spotify
        appleMusicOnboarded = defaults.bool(forKey: Keys.appleMusicOnboarded)
        crossfadeSeconds = min(12, max(0, defaults.double(forKey: Keys.crossfadeSeconds)))
        appleMusicAutoMix = defaults.bool(forKey: Keys.appleMusicAutoMix)
        let mode: TransitionMode = defaults.string(forKey: Keys.transitionMode).flatMap { TransitionMode(rawValue: $0) }
            ?? (defaults.double(forKey: Keys.crossfadeSeconds) > 0 ? .manual : .automatic)
        transitionMode = mode
        defaults.set(mode.rawValue, forKey: Keys.transitionMode)
        transitionDetector = defaults.data(forKey: Keys.transitionDetection)
            .flatMap { try? JSONDecoder().decode(TransitionDetector.self, from: $0) } ?? TransitionDetector()
        defaults.register(defaults: [
            Keys.pipAnimatedBackground: true,
            Keys.pipShowTitle: true,
            Keys.offset: 0.0,
            Keys.fontSize: Self.defaultFontSize,
            Keys.blur: true,
            Keys.background: true,
            Keys.romanization: false,
            Keys.lrclib: true,
            Keys.keepScreenOn: true,
            Keys.autoHide: true,
            Keys.landscapeArtwork: true,
            Keys.powerSaving: false,
            Keys.volumeSlider: true,
            Keys.gestures: true,
            Keys.outputLatency: true,
            Keys.simpleMode: false,
            Keys.autoPiP: false,
            Keys.translate: false,
            Keys.appLanguage: "system",
            Keys.translationReplaces: false,
            Keys.translationLanguage: Self.defaultTranslationLanguage,
            Keys.translationProvider: TranslationProvider.defaultProvider.rawValue,
            Keys.pipFormat: PiPFormat.wide.rawValue,
            Keys.centerLyrics: false,
            Keys.lyricsFont: LyricsFont.standard.rawValue,
            Keys.theme: AppTheme.cover.rawValue,
            Keys.landscapeTitle: true,
            Keys.landscapeLyricsOnly: false,
            Keys.hideNotFound: false,
            Keys.hideStatic: false,
            Keys.hiddenLyricsView: HiddenLyricsView.background.rawValue,
            Keys.artworkLyricLine: true,
            Keys.artworkCanvas: false,
            Keys.nebulaColors: NebulaColors.cover.rawValue,
            Keys.nebulaStars: true,
            Keys.nebulaBrightness: 1.0,
            Keys.tvLyricsScale: 1.0,
            Keys.tvOffsetMs: 0.0,
            Keys.tvShowNowBar: true,
            Keys.tvShowTimeline: true,
            Keys.tvBackground: TVBackground.cover.rawValue,
            Keys.tvBackgroundDim: Self.defaultBackgroundDim,
            Keys.tvPhoneLyrics: false,
            Keys.artworkBackground: ArtworkBackground.nebula.rawValue,
            Keys.autoSkip: AutoSkipMode.off.rawValue,
            Keys.blurStrength: 1.0,
            Keys.glowStrength: 1.0,
            Keys.inactiveBrightness: 1.0,
            Keys.lineSpacingScale: 1.0,
            Keys.translationScale: 1.0,
            Keys.backgroundDim: Self.defaultBackgroundDim,
            Keys.backgroundSpeed: 1.0,
            Keys.backgroundBlur: 1.0,
            Keys.autoHideDelay: 4.0,
            Keys.lyricsWeight: LyricsWeight.bold.rawValue,
            Keys.activeLinePosition: 0.5,
            Keys.scrollSpeed: 1.0,
            Keys.earlyScroll: false,
            Keys.earlyScrollMs: 250.0,
            Keys.refinedCredits: true,
            Keys.joinSplitWords: false,
            Keys.smoothScrolling: true,
            Keys.syncedLyricsCacheDays: 7.0,
            Keys.duetLinePadding: true,
            Keys.minimalLyricsMode: false,
            Keys.keepOverlappingLines: true,
            Keys.backgroundLinePop: false,
            Keys.refreshedSimpleLyrics: false,
            Keys.backgroundStyle: BackgroundStyle.dynamic.rawValue,
            Keys.seekFadeCompensation: true,
            Keys.creditsFollowLastLine: false,
            Keys.translationBrightness: 1.0,
            Keys.backgroundSaturation: 1.0,
            Keys.canvasBrightness: 1 - Self.defaultBackgroundDim - 0.15,
            Keys.lyricsFrameRate: 60.0,
            Keys.showLyricsFPS: false,
            Keys.pipShowFPS: false,
            Keys.autoWakeSpotify: false,
            Keys.reportConsent: 0,
            Keys.lastSeenVersion: "",
            Keys.notifyUpdates: true,
            Keys.showStarRow: true,
            Keys.closePiPOnReturn: true,
        ])
        spotifyClientID = defaults.string(forKey: Keys.clientID) ?? ""
        spicyLyricsKey = defaults.string(forKey: Keys.spicyKey) ?? ""
        timingOffsetMs = defaults.double(forKey: Keys.offset)
        fontSize = defaults.double(forKey: Keys.fontSize)
        blurInactiveLines = defaults.bool(forKey: Keys.blur)
        dynamicBackground = defaults.bool(forKey: Keys.background)
        showRomanization = defaults.bool(forKey: Keys.romanization)
        useLRCLibFallback = defaults.bool(forKey: Keys.lrclib)
        keepScreenOn = defaults.bool(forKey: Keys.keepScreenOn)
        autoHideControls = defaults.bool(forKey: Keys.autoHide)
        powerSaving = defaults.bool(forKey: Keys.powerSaving)
        showVolumeSlider = defaults.bool(forKey: Keys.volumeSlider)
        gesturesEnabled = defaults.bool(forKey: Keys.gestures)
        compensateOutputLatency = defaults.bool(forKey: Keys.outputLatency)
        useAppRemote = defaults.object(forKey: Keys.appRemote) as? Bool ?? true
        webPollInterval = defaults.object(forKey: Keys.webPollInterval) as? Double ?? 2
        remoteQueryInterval = defaults.object(forKey: Keys.remoteQueryInterval) as? Double ?? 1.5
        syncLogEnabled = defaults.object(forKey: Keys.syncLog) as? Bool ?? true
        showSyncIndicator = defaults.object(forKey: Keys.syncIndicator) as? Bool ?? false
        pipTextScale = defaults.object(forKey: Keys.pipTextScale) as? Double ?? 1
        pipBackgroundDim = defaults.object(forKey: Keys.pipBackgroundDim) as? Double ?? 0.42
        pipFrameRate = defaults.object(forKey: Keys.pipFrameRate) as? Double ?? 30
        pipShowTranslation = defaults.object(forKey: Keys.pipShowTranslation) as? Bool ?? true
        pipBlurLines = defaults.object(forKey: Keys.pipBlurLines) as? Bool ?? true
        simpleLyricsMode = defaults.bool(forKey: Keys.simpleMode)
        autoPictureInPicture = defaults.bool(forKey: Keys.autoPiP)
        closePiPOnReturn = defaults.bool(forKey: Keys.closePiPOnReturn)
        pipAnimatedBackground = defaults.bool(forKey: Keys.pipAnimatedBackground)
        pipShowTitle = defaults.bool(forKey: Keys.pipShowTitle)
        translateLyrics = defaults.bool(forKey: Keys.translate)
        let language = defaults.string(forKey: Keys.translationLanguage) ?? ""
        translationLanguage = Self.translationLanguages.contains(language) ? language : Self.defaultTranslationLanguage
        translationReplaces = defaults.bool(forKey: Keys.translationReplaces)
        translationProvider = defaults.string(forKey: Keys.translationProvider) ?? TranslationProvider.defaultProvider.rawValue
        deeplKey = Keychain.read(Self.deeplKeychainKey).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        pipFormat = defaults.string(forKey: Keys.pipFormat) ?? PiPFormat.wide.rawValue
        appLanguage = defaults.string(forKey: Keys.appLanguage) ?? "system"
        centerLyrics = defaults.bool(forKey: Keys.centerLyrics)
        lyricsFont = defaults.string(forKey: Keys.lyricsFont) ?? LyricsFont.standard.rawValue
        theme = defaults.string(forKey: Keys.theme) ?? AppTheme.cover.rawValue
        landscapeArtwork = defaults.bool(forKey: Keys.landscapeArtwork)
        landscapeTitle = defaults.bool(forKey: Keys.landscapeTitle)
        landscapeLyricsOnly = defaults.bool(forKey: Keys.landscapeLyricsOnly)
        hideNotFoundNotice = defaults.bool(forKey: Keys.hideNotFound)
        hideStaticLyrics = defaults.bool(forKey: Keys.hideStatic)
        hiddenLyricsView = defaults.string(forKey: Keys.hiddenLyricsView) ?? HiddenLyricsView.background.rawValue
        artworkLyricLine = defaults.bool(forKey: Keys.artworkLyricLine)
        artworkCanvas = defaults.bool(forKey: Keys.artworkCanvas)
        nebulaColors = defaults.string(forKey: Keys.nebulaColors) ?? NebulaColors.cover.rawValue
        nebulaStars = defaults.bool(forKey: Keys.nebulaStars)
        nebulaBrightness = defaults.double(forKey: Keys.nebulaBrightness)
        tvLyricsScale = defaults.double(forKey: Keys.tvLyricsScale)
        tvOffsetMs = defaults.double(forKey: Keys.tvOffsetMs)
        tvShowNowBar = defaults.bool(forKey: Keys.tvShowNowBar)
        tvShowTimeline = defaults.bool(forKey: Keys.tvShowTimeline)
        tvBackground = defaults.string(forKey: Keys.tvBackground) ?? TVBackground.cover.rawValue
        tvBackgroundDim = defaults.double(forKey: Keys.tvBackgroundDim)
        tvPhoneLyrics = defaults.bool(forKey: Keys.tvPhoneLyrics)
        artworkBackground = defaults.string(forKey: Keys.artworkBackground) ?? ArtworkBackground.nebula.rawValue
        autoSkipMode = defaults.string(forKey: Keys.autoSkip) ?? AutoSkipMode.off.rawValue
        blurStrength = defaults.double(forKey: Keys.blurStrength)
        glowStrength = defaults.double(forKey: Keys.glowStrength)
        inactiveBrightness = defaults.double(forKey: Keys.inactiveBrightness)
        lineSpacingScale = defaults.double(forKey: Keys.lineSpacingScale)
        translationScale = defaults.double(forKey: Keys.translationScale)
        backgroundDim = defaults.double(forKey: Keys.backgroundDim)
        backgroundSpeed = defaults.double(forKey: Keys.backgroundSpeed)
        backgroundBlur = defaults.double(forKey: Keys.backgroundBlur)
        autoHideDelay = defaults.double(forKey: Keys.autoHideDelay)
        lyricsWeight = defaults.string(forKey: Keys.lyricsWeight) ?? LyricsWeight.bold.rawValue
        activeLinePosition = defaults.double(forKey: Keys.activeLinePosition)
        scrollSpeed = defaults.double(forKey: Keys.scrollSpeed)
        earlyScroll = defaults.bool(forKey: Keys.earlyScroll)
        earlyScrollMs = defaults.double(forKey: Keys.earlyScrollMs)
        refinedCredits = defaults.bool(forKey: Keys.refinedCredits)
        joinSplitWords = defaults.bool(forKey: Keys.joinSplitWords)
        smoothScrolling = defaults.bool(forKey: Keys.smoothScrolling)
        syncedLyricsCacheDays = Self.syncedLyricsCacheDaysStored
        duetLinePadding = defaults.bool(forKey: Keys.duetLinePadding)
        minimalLyricsMode = defaults.bool(forKey: Keys.minimalLyricsMode)
        keepOverlappingLines = defaults.bool(forKey: Keys.keepOverlappingLines)
        backgroundLinePop = defaults.bool(forKey: Keys.backgroundLinePop)
        refreshedSimpleLyrics = defaults.bool(forKey: Keys.refreshedSimpleLyrics)
        canvasBrightness = defaults.double(forKey: Keys.canvasBrightness)
        showCanvas = defaults.bool(forKey: Keys.showCanvas)
        let storedStyle = BackgroundStyle(rawValue: defaults.string(forKey: Keys.backgroundStyle) ?? "") ?? .dynamic
        // A style no longer offered (Canvas) goes back to the default, so Settings shows a choice.
        backgroundStyle = (BackgroundStyle.offered.contains(storedStyle) ? storedStyle : .dynamic).rawValue
        seekFadeCompensation = defaults.bool(forKey: Keys.seekFadeCompensation)
        creditsFollowLastLine = defaults.bool(forKey: Keys.creditsFollowLastLine)
        translationBrightness = defaults.double(forKey: Keys.translationBrightness)
        backgroundSaturation = defaults.double(forKey: Keys.backgroundSaturation)
        lyricsFrameRate = defaults.double(forKey: Keys.lyricsFrameRate)
        showLyricsFPS = defaults.bool(forKey: Keys.showLyricsFPS)
        pipShowFPS = defaults.bool(forKey: Keys.pipShowFPS)
        autoWakeSpotify = defaults.bool(forKey: Keys.autoWakeSpotify)
        reportConsent = defaults.integer(forKey: Keys.reportConsent)
        lastSeenVersion = defaults.string(forKey: Keys.lastSeenVersion) ?? ""
        notifyUpdates = defaults.bool(forKey: Keys.notifyUpdates)
        skippedUpdateVersion = defaults.string(forKey: Keys.skippedUpdateVersion) ?? ""
        showStarRow = defaults.bool(forKey: Keys.showStarRow)
        let install = defaults.string(forKey: Keys.installID) ?? UUID().uuidString
        defaults.set(install, forKey: Keys.installID)
        installID = install
    }

    /// The Client ID to sign in with: always the user's own.
    var effectiveSpotifyClientID: String {
        spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasValidClientID: Bool { Self.isValidClientID(spotifyClientID) }

    /// A Spotify Client ID is 32 hex characters.
    static func isValidClientID(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count == 32 && value.allSatisfy(\.isHexDigit)
    }

    /// The Spicy Lyrics client key built into the app, else the one typed in settings.
    var validSpicyKey: String? {
        bundledSpicyLyricsKey ?? Self.clientKey(spicyLyricsKey)
    }

    var hasBundledSpicyKey: Bool { bundledSpicyLyricsKey != nil }

    private static func clientKey(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sl_pk_"), key.count >= 14 else { return nil }
        return key
    }

    /// The app follows the phone's language (English unless it is Russian) or a fixed choice.
    /// iOS reads `AppleLanguages` at launch, so a change shows after the app restarts.
    static func applyLanguage(_ language: String) {
        if language == "en" || language == "ru" {
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// The ids of `LyricsTranslation.languages`.
    static let translationLanguages: Set<String> = ["ru", "en", "uk", "de", "fr", "es", "it", "pt", "pl", "tr", "ja", "ko", "zh-Hans"]

    /// The phone's language if the translators offer it, else English.
    private static var defaultTranslationLanguage: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        let id = code == "zh" ? "zh-Hans" : code
        return translationLanguages.contains(id) ? id : "en"
    }

    /// Lyric font size limits (settings slider and pinch).
    static let fontRange: ClosedRange<CGFloat> = 22...56
    static let defaultFontSize = 32.0
    static let defaultBackgroundDim = 0.28
    private static let deeplKeychainKey = "deeplKey"

    var provider: TranslationProvider {
        let chosen = TranslationProvider(rawValue: translationProvider) ?? .defaultProvider
        // Apple's on-device translation needs iOS 18: fall back to the server before that.
        return chosen.isAvailable ? chosen : .server
    }

    var format: PiPFormat { PiPFormat(rawValue: pipFormat) ?? .wide }

    /// Back to the original look: text size, alignment, font and every effect slider.
    func resetLyricsLook() {
        fontSize = Self.defaultFontSize
        lyricsFont = LyricsFont.standard.rawValue
        centerLyrics = false
        lineSpacingScale = 1
        lyricsWeight = LyricsWeight.bold.rawValue
        activeLinePosition = 0.5
        scrollSpeed = 1
        earlyScroll = false
        earlyScrollMs = 250
        refinedCredits = true
        joinSplitWords = false
        smoothScrolling = true
        duetLinePadding = true
        minimalLyricsMode = false
        keepOverlappingLines = true
        seekFadeCompensation = true
        creditsFollowLastLine = false
    }

    /// The translation's own look (its page in settings).
    func resetTranslationLook() {
        translationReplaces = false
        translationScale = 1
        translationBrightness = 1
    }

    /// The floating window's look (its page in settings).
    func resetPictureInPicture() {
        pipFormat = PiPFormat.wide.rawValue
        pipAnimatedBackground = true
        pipShowTitle = true
        pipTextScale = 1
        pipBackgroundDim = 0.42
        pipFrameRate = 30
        pipBlurLines = true
        pipShowTranslation = true
        pipShowFPS = false
    }

    func resetEffects() {
        simpleLyricsMode = false
        refreshedSimpleLyrics = false
        blurInactiveLines = true
        blurStrength = 1
        glowStrength = 1
        inactiveBrightness = 1
    }

    func resetBackground() {
        nebulaBrightness = 1
        dynamicBackground = true
        showCanvas = false
        canvasBrightness = 1 - Self.defaultBackgroundDim - 0.15
        backgroundStyle = BackgroundStyle.dynamic.rawValue
        backgroundDim = Self.defaultBackgroundDim
        backgroundSpeed = 1
        backgroundBlur = 1
        backgroundSaturation = 1
    }

    func resetTV() {
        tvLyricsScale = 1
        tvOffsetMs = 0
        tvShowNowBar = true
        tvShowTimeline = true
        tvBackground = TVBackground.cover.rawValue
        tvBackgroundDim = Self.defaultBackgroundDim
    }

    func resetPlaybackTransitions() {
        crossfadeSeconds = 0
        appleMusicAutoMix = false
        transitionMode = .automatic
    }

    private enum Keys {
        static let playbackSource = "playbackSource"
        static let playerChoice = "playerChoice"
        static let appleMusicOnboarded = "appleMusicOnboarded"
        static let crossfadeSeconds = "crossfadeSeconds"
        static let appleMusicAutoMix = "appleMusicAutoMix"
        static let transitionMode = "transitionMode"
        /// v2: v1 learned crossfades that were only the start lead (`holdPreviousLyrics`).
        static let transitionDetection = "transitionDetection.v2"
        static let clientID = "spotifyClientID"
        static let spicyKey = "spicyLyricsKey"
        static let offset = "timingOffsetMs"
        static let fontSize = "fontSize"
        static let blur = "blurInactiveLines"
        static let background = "dynamicBackground"
        static let romanization = "showRomanization"
        static let lrclib = "useLRCLibFallback"
        static let keepScreenOn = "keepScreenOn"
        static let autoHide = "autoHideControls"
        static let powerSaving = "powerSaving"
        static let volumeSlider = "showVolumeSlider"
        static let gestures = "gesturesEnabled"
        static let outputLatency = "compensateOutputLatency"
        static let appRemote = "useAppRemote"
        static let webPollInterval = "webPollInterval"
        static let remoteQueryInterval = "remoteQueryInterval"
        static let syncLog = "syncLogEnabled"
        static let syncIndicator = "showSyncIndicator"
        static let pipTextScale = "pipTextScale"
        static let pipBackgroundDim = "pipBackgroundDim"
        static let pipFrameRate = "pipFrameRate"
        static let pipShowTranslation = "pipShowTranslation"
        static let pipBlurLines = "pipBlurLines"
        static let simpleMode = "simpleLyricsMode"
        static let autoPiP = "autoPictureInPicture"
        static let closePiPOnReturn = "closePiPOnReturn"
        static let pipAnimatedBackground = "pipAnimatedBackground"
        static let pipShowTitle = "pipShowTitle"
        static let translate = "translateLyrics"
        static let translationLanguage = "translationLanguage"
        static let translationReplaces = "translationReplaces"
        static let appLanguage = "appLanguage"
        static let centerLyrics = "centerLyrics"
        static let lyricsFont = "lyricsFont"
        static let theme = "appTheme"
        static let landscapeArtwork = "landscapeArtwork"
        static let landscapeTitle = "landscapeTitle"
        static let landscapeLyricsOnly = "landscapeLyricsOnly"
        static let hideNotFound = "hideNotFoundNotice"
        static let hideStatic = "hideStaticLyrics"
        static let hiddenLyricsView = "hiddenLyricsView"
        static let artworkLyricLine = "artworkLyricLine"
        static let artworkCanvas = "artworkCanvas"
        static let nebulaColors = "nebulaColors"
        static let nebulaStars = "nebulaStars"
        static let nebulaBrightness = "nebulaBrightness"
        static let tvLyricsScale = "tvLyricsScale"
        static let tvOffsetMs = "tvOffsetMs"
        static let tvShowNowBar = "tvShowNowBar"
        static let tvShowTimeline = "tvShowTimeline"
        static let tvBackground = "tvBackground"
        static let tvBackgroundDim = "tvBackgroundDim"
        static let tvPhoneLyrics = "tvPhoneLyrics"
        static let artworkBackground = "artworkBackground"
        static let autoSkip = "autoSkipMode"
        static let blurStrength = "blurStrength"
        static let glowStrength = "glowStrength"
        static let inactiveBrightness = "inactiveBrightness"
        static let lineSpacingScale = "lineSpacingScale"
        static let translationScale = "translationScale"
        static let backgroundDim = "backgroundDim"
        static let backgroundSpeed = "backgroundSpeed"
        static let backgroundBlur = "backgroundBlur"
        static let autoHideDelay = "autoHideDelay"
        static let lyricsWeight = "lyricsWeight"
        static let translationProvider = "translationProvider"
        static let pipFormat = "pipFormat"
        static let activeLinePosition = "activeLinePosition"
        static let scrollSpeed = "scrollSpeed"
        static let earlyScroll = "earlyScroll"
        static let earlyScrollMs = "earlyScrollMs"
        static let refinedCredits = "refinedCredits"
        static let joinSplitWords = "joinSplitWords"
        static let smoothScrolling = "smoothScrolling"
        static let syncedLyricsCacheDays = "syncedLyricsCacheDays"
        static let duetLinePadding = "duetLinePadding"
        static let minimalLyricsMode = "minimalLyricsMode"
        static let keepOverlappingLines = "keepOverlappingLines"
        static let backgroundLinePop = "backgroundLinePop"
        static let refreshedSimpleLyrics = "refreshedSimpleLyrics"
        static let canvasBrightness = "canvasBrightness"
        static let showCanvas = "showCanvas"
        static let backgroundStyle = "backgroundStyle"
        static let seekFadeCompensation = "seekFadeCompensation"
        static let creditsFollowLastLine = "creditsFollowLastLine"
        static let translationBrightness = "translationBrightness"
        static let backgroundSaturation = "backgroundSaturation"
        static let lyricsFrameRate = "lyricsFrameRate"
        static let showLyricsFPS = "showLyricsFPS"
        static let pipShowFPS = "pipShowFPS"
        static let autoWakeSpotify = "autoWakeSpotify"
        static let reportConsent = "reportConsent"
        static let lastSeenVersion = "lastSeenVersion"
        static let notifyUpdates = "notifyUpdates"
        static let skippedUpdateVersion = "skippedUpdateVersion"
        static let showStarRow = "showStarRow"
        static let installID = "installID"
    }
}

/// What fills the screen where lyrics were hidden ("not found" notice or unsynced lyrics).
enum HiddenLyricsView: String, CaseIterable, Identifiable {
    /// Just the moving background.
    case background
    /// The cover, as big as fits, over the nebula.
    case artwork
    /// The nebula alone.
    case visualizer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .background: return String(localized: "Фон")
        case .artwork: return String(localized: "Большая обложка")
        case .visualizer: return String(localized: "Туманность")
        }
    }
}

/// What flows behind the big cover.
/// The extension's background styles that make sense on a phone (`BackgroundStyle` in stores.ts).
enum BackgroundStyle: String, CaseIterable, Identifiable {
    /// The cover flowing like liquid (Kawarp).
    case dynamic
    /// The cover, blurred and still.
    case cover
    /// The artist's photo, or the cover when there's none.
    case artist
    /// The song's Spotify Canvas video, or the flowing cover when it has none.
    case canvas

    var id: String { rawValue }

    /// What Settings offers. Canvas is held back for now: Spotify's canvaz-cache doesn't take
    /// this app's sign-in, so it would only ever show the flowing cover.
    static let offered: [BackgroundStyle] = [.dynamic, .cover, .artist]

    var title: String {
        switch self {
        case .dynamic: return String(localized: "Живая обложка")
        case .cover: return String(localized: "Обложка")
        case .artist: return String(localized: "Фото артиста")
        case .canvas: return "Canvas"
        }
    }
}

enum ArtworkBackground: String, CaseIterable, Identifiable {
    /// The nebula.
    case nebula
    /// The same moving background as behind the lyrics.
    case background

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nebula: return String(localized: "Туманность")
        case .background: return String(localized: "Как у текста")
        }
    }
}

/// What flows behind the lyrics on the TV.
enum TVBackground: String, CaseIterable, Identifiable {
    /// The cover, like behind the lyrics on the phone.
    case cover
    case nebula
    /// Plain black: nothing moving.
    case black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cover: return String(localized: "Обложка")
        case .nebula: return String(localized: "Туманность")
        case .black: return String(localized: "Чёрный")
        }
    }
}

/// Where the nebula behind the big cover takes its colours from.
enum NebulaColors: String, CaseIterable, Identifiable {
    case cover, random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cover: return String(localized: "Из обложки")
        case .random: return String(localized: "Случайные")
        }
    }
}

/// Which songs get skipped for having no Spicy Lyrics sync.
enum AutoSkipMode: String, CaseIterable, Identifiable {
    case off
    /// No Spicy Lyrics sync at all (not found, LRCLIB, or unsynced).
    case synced
    /// Anything short of word-by-word sync.
    case wordByWord

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return String(localized: "Не пропускать")
        case .synced: return String(localized: "Без синхронизации")
        case .wordByWord: return String(localized: "Без пословной синхронизации")
        }
    }
}

/// Typeface for the lyrics.
enum LyricsFont: String, CaseIterable, Identifiable {
    case standard, rounded, serif, mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "SF Pro"
        case .rounded: return "SF Pro Rounded"
        case .serif: return "New York"
        case .mono: return "SF Mono"
        }
    }
}

/// Thickness of the lyrics (the original is bold).
enum LyricsWeight: String, CaseIterable, Identifiable {
    case semibold, bold, heavy, black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .semibold: return String(localized: "Полужирный")
        case .bold: return String(localized: "Жирный")
        case .heavy: return String(localized: "Плотный")
        case .black: return String(localized: "Сверхжирный")
        }
    }

    var uiWeight: UIFont.Weight {
        switch self {
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    var fontWeight: Font.Weight {
        switch self {
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

/// Where the nebula behind the big cover takes its colours from.
