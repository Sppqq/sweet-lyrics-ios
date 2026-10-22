import AVFoundation
import AVKit
import CoreMedia
import Observation
import QuartzCore
import SwiftUI
import UIKit

/// Floating lyrics over other apps: the lyrics are drawn into video frames and shown in the
/// system's Picture in Picture window, which keeps the app running in the background (the
/// Android port's `PictureInPicture.kt` does the same with Android's PiP).
///
/// Not main-actor isolated because AVKit's delegate protocols aren't; every entry point runs on
/// the main thread and reaches the main-actor player through `MainActor.assumeIsolated`.
@Observable
final class LyricsPictureInPicture: NSObject {
    private(set) var isActive = false
    /// The window is opening or closing: the app must keep following Spotify meanwhile.
    private(set) var isTransitioning = false
    private(set) var isPossible = false
    private(set) var lastError: String?

    /// The error alert was dismissed.
    func clearError() { lastError = nil }

    /// The window is up, or about to be, or on its way out.
    var keepsAppRunning: Bool { isActive || isTransitioning }

    @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var player: PlayerModel?
    @ObservationIgnored private var settings: AppSettings?
    @ObservationIgnored private var renderer = PiPFrameRenderer(format: .wide)
    /// Until then frames come at the full rate (the app is being left, the window may open).
    @ObservationIgnored private var warmUntil: CFTimeInterval = 0
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastPlaying: Bool?
    /// The window was asked for (the menu button, or the setting that opens it on leaving). iOS
    /// sometimes opens it on its own after a manual start, even with the setting off.
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var lyricsAnimator: LyricsAnimator?
    /// What the animator was built for: comparing whole lyrics every frame was the costliest
    /// thing PiP did, the player's revision number says the same for free.
    @ObservationIgnored private var animatorKey: (revision: Int, simple: Bool)?
    @ObservationIgnored private weak var performance: PerformanceMonitor?
    @ObservationIgnored private var framesPerSecond: Double = 0
    @ObservationIgnored private let frameCounter = FrameRateCounter()

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
    }

    /// Connects the player. While the window may open on its own there is a controller from the
    /// start; otherwise it only exists from the moment the window is asked for until it closes:
    /// without one, iOS has nothing to open when the app is left.
    func configure(player: PlayerModel, settings: AppSettings, performance: PerformanceMonitor? = nil) {
        self.player = player
        self.settings = settings
        self.performance = performance
        guard Self.isSupported else { return }
        if settings.autoPictureInPicture { _ = ensureController() }
        // Leaving the app: the window may open on its own any moment now, and it opens on
        // whatever frame is on the layer. Make that one current and keep them coming.
        if lifecycleObservers.isEmpty {
            lifecycleObservers.append(NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                let auto = MainActor.assumeIsolated { self.settings?.autoPictureInPicture ?? false }
                // Said again every time the app is left: whatever happened to it since, it follows the setting.
                self.controller?.canStartPictureInPictureAutomaticallyFromInline = auto
                guard auto else { return }
                self.warmUp(for: 3)
            })
        }
        renderFrame()
        scheduleFrames(fps: idleFramesPerSecond)
    }

    private func ensureController() -> Bool {
        if controller != nil { return true }
        guard Self.isSupported else { return false }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = false
        controller.canStartPictureInPictureAutomaticallyFromInline = mayOpenItself
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            DispatchQueue.main.async { self?.isPossible = controller.isPictureInPicturePossible }
        }
        self.controller = controller
        return true
    }

    /// Lets go of the controller once the window is closed and may not open by itself.
    private func releaseControllerIfIdle() {
        guard controller != nil, !mayOpenItself, !keepsAppRunning else { return }
        possibleObservation = nil
        controller?.delegate = nil
        controller = nil
        isPossible = false
        SyncLog.log("pip", "controller released")
    }

    /// While the window is closed: nothing, unless it may open on its own when leaving the app;
    /// then a trickle keeps a fairly current frame on the layer (PiP cannot start without one).
    private var idleFramesPerSecond: Double {
        MainActor.assumeIsolated { settings?.autoPictureInPicture ?? false } ? 2 : 0
    }

    /// Full-rate frames for a moment, starting with one right now.
    private func warmUp(for seconds: Double) {
        guard controller != nil, !isActive else { return }
        warmUntil = MediaClock.now() + seconds
        renderFrame()
        scheduleFrames(fps: fullFramesPerSecond)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.1) { [weak self] in
            guard let self, !self.keepsAppRunning, !self.previewing else { return }
            self.scheduleFrames(fps: self.idleFramesPerSecond)
        }
    }

    private var fullFramesPerSecond: Double {
        MainActor.assumeIsolated { settings?.pipFrameRate ?? 30 }
    }

    func setAutomaticStart(_ enabled: Bool) {
        if enabled { _ = ensureController() }
        controller?.canStartPictureInPictureAutomaticallyFromInline = enabled
        if !isActive { scheduleFrames(fps: idleFramesPerSecond) }
        if !enabled { releaseControllerIfIdle() }
    }

    /// Closes the window if it is up (the app is in front again).
    func stopIfIdle() {
        guard isActive, !isTransitioning else { return }
        stop()
    }

    /// Whether iOS may open the window by itself right now.
    private var mayOpenItself: Bool {
        MainActor.assumeIsolated { settings?.autoPictureInPicture ?? false }
    }

    func start() {
        wanted = true
        lastError = nil
        guard ensureController(), let controller else {
            wanted = false
            lastError = String(localized: "Картинка в картинке не поддерживается на этом устройстве.")
            return
        }
        warmUp(for: 2)
        // A fresh controller needs a moment (and a frame on the layer) before it says yes.
        attemptStart(controller, triesLeft: 8)
    }

    private func attemptStart(_ controller: AVPictureInPictureController, triesLeft: Int) {
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
            return
        }
        guard triesLeft > 0 else {
            SyncLog.log("pip", "not possible right now")
            wanted = false
            lastError = String(localized: "Окно «картинка в картинке» сейчас недоступно. Попробуйте ещё раз.")
            releaseControllerIfIdle()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.controller === controller else { return }
            self.renderFrame()
            self.attemptStart(controller, triesLeft: triesLeft - 1)
        }
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    /// A setting that changes the frame (its shape) changed: draw one now.
    func refreshFrame() {
        renderFrame()
    }

    /// Frames at the window's rate without a PiP window, shown in the app instead (Debug only:
    /// the README's recording, made in the Simulator, which has no Picture in Picture).
    private(set) var previewing = false

    #if DEBUG
    func startPreview() {
        previewing = true
        renderFrame()
        scheduleFrames(fps: MainActor.assumeIsolated { settings?.pipFrameRate ?? 30 })
    }
    #endif

    // MARK: Frames

    private func scheduleFrames(fps: Double) {
        guard fps != framesPerSecond else { return }
        framesPerSecond = fps
        timer?.invalidate()
        timer = nil
        guard fps > 0 else { return }
        let timer = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.renderFrame() }
        // The idle trickle (and a paused window) need no precision: let iOS bundle the wake-ups.
        if fps <= 5 { timer.tolerance = 0.2 / fps }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func renderFrame() {
        guard let player else { return }
        let output = displayLayer.sampleBufferRenderer
        if output.status == .failed { output.flush() }
        // A new window shape: frames of the new size from here on.
        let format = MainActor.assumeIsolated { settings?.format ?? .wide }
        if renderer.shape != format {
            SyncLog.log("pip", "format \(format.rawValue)")
            renderer = PiPFrameRenderer(format: format)
            output.flush()
        }
        guard output.isReadyForMoreMediaData else { return }
        let reduced = MainActor.assumeIsolated { (settings?.powerSaving ?? false) || (performance?.constrained ?? false) }
        let snapshot = MainActor.assumeIsolated {
            if case .loaded(let lyrics) = player.lyricsState {
                let simple = settings?.simpleLyricsMode ?? false
                if animatorKey?.revision != player.lyricsRevision || animatorKey?.simple != simple {
                    lyricsAnimator = LyricsAnimator(lyrics: lyrics, simple: simple)
                    animatorKey = (player.lyricsRevision, simple)
                }
                lyricsAnimator?.step(position: player.position(), now: MediaClock.now(),
                                     blurEnabled: (settings?.blurInactiveLines ?? false) && !reduced,
                                     frameInterval: framesPerSecond > 0 ? 1 / framesPerSecond : nil)
            } else {
                lyricsAnimator = nil
                animatorKey = nil
            }
            let fpsText = settings?.pipShowFPS == true
                ? "\(Int(frameCounter.fps().rounded())) / \(Int(framesPerSecond.rounded())) fps" : nil
            return PiPSnapshot(player: player, settings: settings, animator: lyricsAnimator, reduced: reduced,
                               fpsText: fpsText)
        }
        guard let sample = renderer.sampleBuffer(for: snapshot) else { return }
        output.enqueue(sample)
        frameCounter.tick()

        // Full rate only while something moves: playing, or a line still sliding into place.
        if isActive || previewing {
            let moving = snapshot.isPlaying || renderer.isAnimating
            let fps = fullFramesPerSecond
            scheduleFrames(fps: moving ? (reduced ? min(20, fps) : fps) : 5)
        } else if isTransitioning || MediaClock.now() < warmUntil {
            scheduleFrames(fps: fullFramesPerSecond)
        }

        // Keep the PiP play/pause button in step with Spotify.
        if lastPlaying != snapshot.isPlaying {
            lastPlaying = snapshot.isPlaying
            controller?.invalidatePlaybackState()
        }
    }
}

// MARK: - AVKit delegates

extension LyricsPictureInPicture: AVPictureInPictureControllerDelegate {
    /// The window opening or closing is when the clock most often goes wrong (the app changes
    /// state, the main thread is busy animating): check it against Spotify each time.
    private func checkClock(_ reason: String) {
        guard let player else { return }
        MainActor.assumeIsolated { player.resync(reason) }
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        SyncLog.log("pip", "starting")
        if !wanted && !mayOpenItself {
            // iOS opened it on its own although the setting is off: close it again.
            SyncLog.log("pip", "opened by iOS against the setting, closing")
            controller.canStartPictureInPictureAutomaticallyFromInline = false
            DispatchQueue.main.async { controller.stopPictureInPicture() }
        }
        isTransitioning = true
        MainActor.assumeIsolated { SilentAudio.shared.start() }
        renderFrame()
        scheduleFrames(fps: fullFramesPerSecond)
        checkClock("pip opening")
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        SyncLog.log("pip", "started")
        if !wanted && !mayOpenItself { controller.stopPictureInPicture() }
        isActive = true
        isTransitioning = false
        scheduleFrames(fps: fullFramesPerSecond)
        renderFrame()
        checkClock("pip opened")
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        SyncLog.log("pip", "stopping")
        isTransitioning = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        SyncLog.log("pip", "stopped")
        wanted = false
        controller.canStartPictureInPictureAutomaticallyFromInline = mayOpenItself
        isActive = false
        DispatchQueue.main.async { [weak self] in self?.releaseControllerIfIdle() }
        MainActor.assumeIsolated { SilentAudio.shared.stop() }
        isTransitioning = false
        scheduleFrames(fps: idleFramesPerSecond)
        checkClock("pip closed")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        wanted = false
        isActive = false
        isTransitioning = false
        MainActor.assumeIsolated { SilentAudio.shared.stop() }
        scheduleFrames(fps: idleFramesPerSecond)
        DispatchQueue.main.async { [weak self] in self?.releaseControllerIfIdle() }
        SyncLog.log("pip", "failed to start: \(error.localizedDescription)")
        lastError = String(localized: "Не удалось открыть окно: \(error.localizedDescription)")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // Back to the app: let it catch up with the song and lay itself out first, so the window
        // shrinks back onto lyrics that are already where they should be.
        checkClock("back from pip")
        DispatchQueue.main.async { completionHandler(true) }
    }
}

extension LyricsPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        guard let player else { return }
        MainActor.assumeIsolated {
            if player.isPlaying != playing { player.togglePlay() }
        }
    }

    /// A live stream as far as AVKit is concerned: no scrubber in the window.
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        guard let player else { return true }
        return MainActor.assumeIsolated { !player.isPlaying }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        if let player {
            MainActor.assumeIsolated {
                player.seek(to: max(0, player.playbackPosition() + skipInterval.seconds))
            }
        }
        completionHandler()
    }
}

// MARK: - What a frame shows

/// Shape of the floating window: iOS sizes the window to the video's frame.
enum PiPFormat: String, CaseIterable, Identifiable {
    case wide, square, portrait, tall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wide: return String(localized: "Широкое 2:1")
        case .square: return String(localized: "Квадрат 1:1")
        case .portrait: return String(localized: "Вертикальное 3:4")
        case .tall: return String(localized: "Высокое 9:16")
        }
    }

    /// Frame size in pixels: about the same pixel count each, so every shape costs the same.
    var frameSize: CGSize {
        switch self {
        case .wide: return CGSize(width: 800, height: 400)
        case .square: return CGSize(width: 560, height: 560)
        case .portrait: return CGSize(width: 480, height: 640)
        case .tall: return CGSize(width: 432, height: 768)
        }
    }

    /// Width ÷ height.
    var aspect: CGFloat { frameSize.width / frameSize.height }
}

/// How the app draws its lyrics, from the settings.
struct PiPStyle: Equatable {
    var design: UIFontDescriptor.SystemDesign = .default
    /// A font family (built into iOS) instead of a system design.
    var family: String?
    /// One imported face, by PostScript name.
    var postScriptName: String?
    var simple = false
    var centered = false
    var glow: Double = 1
    var inactiveBrightness: Double = 1
    /// Distance blur multiplier, 0 when line blur is off.
    var blur: Double = 0
    var lineSpacing: CGFloat = 1
    var translationScale: CGFloat = 1
    /// Lyric size multiplier for the window.
    var textScale: CGFloat = 1
    var weight: UIFont.Weight = .bold
    /// Spicy Lyrics' refined credits (see `RefinedCreditsView`).
    var refinedCredits = true
    /// Duet Line Padding.
    var duetPadding = true

    /// Same as the app's `LyricsTypography.opacity`.
    func opacity(_ value: Double) -> CGFloat {
        CGFloat(clamp(1 - (1 - value) * (2 - inactiveBrightness), 0.05, 1))
    }
}

/// Everything a frame needs, read from the player on the main thread.
struct PiPSnapshot: @unchecked Sendable {
    var title: String
    var artist: String
    var isPlaying: Bool
    var artworkID: String
    var artwork: UIImage?
    /// Drifting cover like the app's background, or a still one (setting / battery saver).
    var animatedBackground = true
    /// The track and artist at the bottom of the window.
    var showTitle = true
    var message: String?
    var theme: AppTheme = .cover
    /// No lyrics, and the setting asks for the big cover: it is drawn in the middle of the window.
    var cover: UIImage?
    /// The animator's copy of the lyrics, so line indices and visuals always agree.
    var lyrics: PreparedLyrics?
    var revision = 0
    var visuals: [LineVisual] = []
    var focus = 0
    var position: Double = 0
    var duration: Double = 0
    /// Translations shown under the lines ("Под строкой" mode).
    var translations: [String: String] = [:]
    var style = PiPStyle()
    /// How much the cover behind the lyrics is darkened.
    var backgroundDim: CGFloat = 0.42
    var backgroundSaturation: Double = 1
    /// "30 fps" in the corner, when the counter is on.
    var fpsText: String?

    @MainActor
    init(player: PlayerModel, settings: AppSettings?, animator: LyricsAnimator?, reduced: Bool = false, fpsText: String? = nil) {
        self.fpsText = fpsText
        animatedBackground = (settings?.pipAnimatedBackground ?? true) && !reduced
        showTitle = settings?.pipShowTitle ?? true
        title = player.track?.title ?? "Sweet Lyrics"
        artist = player.track?.artistLine ?? ""
        isPlaying = player.isPlaying
        artworkID = player.artworkID
        theme = settings?.appTheme ?? .cover
        // A fixed theme paints its own background; the cover only matters for "Cover".
        artwork = theme.isCover ? player.backgroundArtwork : nil
        if let settings {
            let choice = LyricsFontChoice(stored: settings.lyricsFont)
            style.design = choice.uiDesign
            style.family = choice.family
            style.postScriptName = choice.postScriptName
            style.simple = settings.simpleLyricsMode
            style.centered = settings.centerLyrics
            style.glow = settings.glowStrength
            style.inactiveBrightness = settings.inactiveBrightness
            style.blur = settings.blurInactiveLines && settings.pipBlurLines && !reduced ? settings.blurStrength : 0
            style.textScale = CGFloat(settings.pipTextScale)
            backgroundDim = CGFloat(settings.pipBackgroundDim)
            style.lineSpacing = CGFloat(settings.lineSpacingScale)
            style.translationScale = CGFloat(settings.translationScale)
            style.weight = (LyricsWeight(rawValue: settings.lyricsWeight) ?? .bold).uiWeight
            style.refinedCredits = settings.refinedCredits
            style.duetPadding = settings.duetLinePadding
            backgroundSaturation = settings.backgroundSaturation
        }

        switch player.lyricsState {
        case .loaded(let document):
            guard let animator, !animator.lyrics.lines.isEmpty,
                  !(settings?.hideStaticLyrics == true && document.kind == .static)
            else {
                showWithoutLyrics(player, settings)
                return
            }
            lyrics = animator.lyrics
            revision = player.lyricsRevision
            visuals = animator.visuals
            focus = animator.focusIndex
            position = player.position()
            duration = player.track?.duration ?? 0
            if settings?.translateLyrics == true, settings?.translationReplaces != true,
               settings?.pipShowTranslation != false {
                translations = player.translations
            }
        case .loading:
            message = String(localized: "Загрузка текста…")
        case .notFound:
            showWithoutLyrics(player, settings)
        case .failed(let failure):
            message = failure.notice.title
        case .unavailable(let notice):
            message = notice.title
        case .idle:
            message = player.statusMessage ?? (player.supportsSpotifyFeatures ? String(localized: "Включите музыку в Spotify") : String(localized: "Включите музыку в Apple Music"))
        }
    }

    /// A song without (shown) lyrics: what the "instead of the text" setting says, like in the app: the
    /// big cover, or just the moving background. No "not found" message.
    @MainActor
    private mutating func showWithoutLyrics(_ player: PlayerModel, _ settings: AppSettings?) {
        message = nil
        if settings?.hiddenLyricsView == HiddenLyricsView.artwork.rawValue { cover = player.artwork }
    }
}

// MARK: - Drawing frames

/// Draws snapshots into pixel buffers and wraps them as sample buffers for the PiP layer.
///
/// The window shows the app's own lyrics column: same rows, wrapping, fill, glow, line opacity,
/// distance blur and spring scroll, with the credits after the last line. Every row is laid
/// out and rasterized once, so a frame is a copy of the cached background plus a few mask fills.
final class PiPFrameRenderer {
    let shape: PiPFormat
    private let size: CGSize
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    private var fonts: [String: UIFont] = [:]
    private var gradients: [String: CGGradient] = [:]

    // Layout of the frame (pixels). Every shape keeps the same lyric size: iOS gives a tall
    // window about the same area as a wide one, so the words come out as big on screen.
    private static let inset: CGFloat = 36
    /// Lyric size in frame pixels (the app's 32 pt on a phone, scaled to the window), times the
    /// window's text size setting.
    private static let baseLeadSize: CGFloat = 56
    private var leadSize: CGFloat = 56
    private static let clipTop: CGFloat = 12

    /// Where the line in focus sits, from the top of the lyrics: near the top in a wide window
    /// (one or two lines show), about a third of the way down in a tall one.
    private static func anchor(viewport: CGFloat) -> CGFloat {
        max(28, (viewport - 300) * 0.4)
    }

    private static func clipBottom(height: CGFloat, showTitle: Bool) -> CGFloat {
        height - (showTitle ? 62 : 10)
    }

    /// Where the middle of the line in focus sits, as a fraction of the frame's height: the app
    /// puts the window's source there, so it opens from and closes onto the app's own lyrics.
    static func focusFraction(format: PiPFormat, showTitle: Bool, textScale: Double) -> CGFloat {
        let height = format.frameSize.height
        let viewport = clipBottom(height: height, showTitle: showTitle) - clipTop
        let lead = (baseLeadSize * CGFloat(textScale)).rounded()
        return (clipTop + anchor(viewport: viewport) + lead * 0.6) / height
    }
    /// Radius the soft masks are blurred with (frame pixels).
    private static let softRadius: CGFloat = 6

    private enum RunRef {
        case space
        case syllable(Int, Int)
        case letter(Int, Int, Int)
        case line
    }
    private struct Row {
        var layout: PiPTextLayout
        /// Offset of the text box in the column (duet and centred insets).
        var x: CGFloat
        var runs: [RunRef]
        var fontSize: CGFloat
        /// Where a growing line-synced line is anchored, 0 leading … 1 trailing.
        var anchor: CGFloat
        var isBackground: Bool
    }
    private struct LayoutKey: Equatable {
        var revision: Int
        var style: PiPStyle
        var translations: [String: String]
    }
    /// One entry per lyric line; nil for interludes (drawn as dots).
    private var rows: [Row?] = []
    private var credits: PiPTextLayout?
    private var layoutKey: LayoutKey?
    private var lastLyricEnd: Double = 0
    private var footer: (text: String, layout: PiPTextLayout)?
    private var messageLayout: (text: String, layout: PiPTextLayout)?

    // The column's scroll: the app's critically damped 1 Hz spring.
    private var scroll: CGFloat = 0
    private var velocity: CGFloat = 0
    private var scrollTarget: CGFloat = 0
    private var lastStep: CFTimeInterval?
    private var scrollRevision = -1
    private var purgeCountdown = 0

    /// The column is still gliding to its line.
    private(set) var isAnimating = false

    // The animated background is drawn small (a quarter of the frame, ten times a second),
    // stretched into a cached full-size backdrop, and that backdrop is copied into every frame.
    private var backgroundSize: CGSize { CGSize(width: (size.width / 4).rounded(), height: (size.height / 4).rounded()) }
    private static let backgroundInterval: CFTimeInterval = 0.1
    /// Same layers as the app's `CoverBlobsView`: size × diagonal, centre, rotation period (s),
    /// drift radii and period (s), whether the layer is a soft blob.
    private static let backgroundLayers: [(size: CGFloat, center: CGPoint, rotation: Double,
                                           drift: CGSize, driftPeriod: Double, blob: Bool)] = [
        (1.35, CGPoint(x: 0.5, y: 0.5), 60, .zero, 0, false),
        (0.95, CGPoint(x: 0.22, y: 0.24), -40, CGSize(width: 0.16, height: 0.12), 19, true),
        (0.85, CGPoint(x: 0.82, y: 0.68), 32, CGSize(width: 0.14, height: 0.15), 23, true),
        (0.75, CGPoint(x: 0.3, y: 0.86), -50, CGSize(width: 0.15, height: 0.1), 27, true),
    ]
    private var coverImages: (id: String, base: CGImage, blob: CGImage)?
    private var backdrop: CGContext?
    private var backdropKey: (artworkID: String, animated: Bool, hasArtwork: Bool, dim: CGFloat)?
    private var backdropTheme: AppTheme?
    private var backdropRenderedAt: CFTimeInterval = 0

    init(format: PiPFormat) {
        self.shape = format
        let size = format.frameSize
        self.size = size
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(size.width),
            kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }

    func sampleBuffer(for snapshot: PiPSnapshot) -> CMSampleBuffer? {
        guard let pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { return nil }
        let now = MediaClock.now()

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer),
           let context = CGContext(data: base, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: Self.sRGB,
                                   bitmapInfo: Self.bitmapInfo) {
            copyBackdrop(snapshot, now: now, into: base, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer))
            // Top-left origin from here on.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            draw(snapshot, in: CGRect(origin: .zero, size: size), now: now, context: context)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        if format == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private var clipBottom: CGFloat = 0
    private var fpsLayout: (text: String, layout: PiPTextLayout)?

    private func draw(_ snapshot: PiPSnapshot, in rect: CGRect, now: CFTimeInterval, context: CGContext) {
        drawContent(snapshot, in: rect, now: now, context: context)
        guard let text = snapshot.fpsText else { return }
        if fpsLayout?.text != text {
            fpsLayout = (text, PiPTextLayout(blocks: [PiPTextBlock(runs: [text], font: ctFont(20, .semibold, .monospaced),
                                                                   singleLine: true)], width: 200))
        }
        if let layout = fpsLayout?.layout, let mask = layout.sharp.first {
            let box = CGRect(x: rect.width - layout.size.width - 26, y: 10,
                             width: layout.size.width + 16, height: layout.size.height + 8)
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.45)
            context.addPath(CGPath(roundedRect: box, cornerWidth: box.height / 2, cornerHeight: box.height / 2, transform: nil))
            context.fillPath()
            context.fill(mask: mask, in: layout.firstRect.offsetBy(dx: box.minX + 8, dy: box.minY + 4), white: 0.9)
        }
    }

    private func drawContent(_ snapshot: PiPSnapshot, in rect: CGRect, now: CFTimeInterval, context: CGContext) {
        let inset = Self.inset
        clipBottom = Self.clipBottom(height: rect.height, showTitle: snapshot.showTitle)

        // Footer: track and artist (can be switched off).
        if snapshot.showTitle {
            let text = snapshot.artist.isEmpty ? snapshot.title : "\(snapshot.title) — \(snapshot.artist)"
            if footer?.text != text {
                footer = (text, PiPTextLayout(blocks: [PiPTextBlock(runs: [text], font: ctFont(24, .semibold, .default),
                                                                    gray: 0.55, singleLine: true)],
                                              width: rect.width - inset * 2))
            }
            if let layout = footer?.layout, let mask = layout.sharp.first {
                context.fill(mask: mask, in: layout.firstRect.offsetBy(dx: inset, dy: rect.height - 50), white: 1)
            }
        }

        guard let lyrics = snapshot.lyrics else {
            isAnimating = false
            if snapshot.message == nil {
                if let cover = snapshot.cover?.cgImage { drawCover(cover, in: rect, context: context) }
                return
            }
            let text = snapshot.message ?? ""
            if messageLayout?.text != text {
                messageLayout = (text, PiPTextLayout(blocks: [PiPTextBlock(runs: [text],
                                                                           font: ctFont(46, .bold, snapshot.style.design, family: snapshot.style.family, face: snapshot.style.postScriptName))],
                                                     width: rect.width - inset * 2))
            }
            if let layout = messageLayout?.layout, let mask = layout.sharp.first {
                let top = ((Self.clipTop + clipBottom) / 2 - layout.size.height / 2).rounded()
                context.fill(mask: mask, in: layout.firstRect.offsetBy(dx: inset, dy: top), white: 0.85)
            }
            return
        }
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: Self.clipTop, width: rect.width, height: clipBottom - Self.clipTop))
        drawLyrics(lyrics, snapshot, width: rect.width - inset * 2, now: now, context: context)
        context.restoreGState()
    }

    /// The cover as big as fits between the top and the footer, centred, with a soft shadow.
    private func drawCover(_ image: CGImage, in rect: CGRect, context: CGContext) {
        let room = CGRect(x: Self.inset, y: Self.clipTop + 8, width: rect.width - Self.inset * 2,
                          height: clipBottom - Self.clipTop - 16)
        let side = max(0, min(room.width, room.height))
        let box = CGRect(x: rect.midX - side / 2, y: room.midY - side / 2, width: side, height: side)
        let path = CGPath(roundedRect: box, cornerWidth: side * 0.05, cornerHeight: side * 0.05, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: UIColor.black.withAlphaComponent(0.5).cgColor)
        context.addPath(path)
        context.setFillColor(gray: 0, alpha: 1)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        // The context is flipped (top-left origin); images are not.
        context.translateBy(x: box.minX, y: box.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        context.restoreGState()
    }

    // MARK: Lyrics column

    private func buildRows(_ lyrics: PreparedLyrics, _ snapshot: PiPSnapshot, width column: CGFloat) {
        let style = snapshot.style
        let cqw = column / 100
        let hasDuets = style.duetPadding && lyrics.lines.contains(where: \.oppositeAligned)
        let size = leadSize
        let lead = ctFont(size, style.weight, style.design, family: style.family, face: style.postScriptName)
        let background = ctFont(size * 0.75, style.weight, style.design, family: style.family, face: style.postScriptName)
        let still = ctFont(size * 5 / 7, .medium, style.design, family: style.family, face: style.postScriptName)

        rows = lyrics.lines.map { line -> Row? in
            // `.line { padding-right: 5cqw }`, or 15cqw on the side a duet line leans away from.
            var left: CGFloat = 0, right = cqw * 5
            if style.centered {
                left = cqw * 5
            } else if hasDuets {
                if line.oppositeAligned { left = cqw * 15; right = 0 } else { right = cqw * 15 }
            }
            let alignment: CGFloat = style.centered ? 0.5 : (line.oppositeAligned ? 1 : 0)
            var texts: [String] = []
            var runs: [RunRef] = []
            var font = lead
            var extra: [PreparedWord] = []
            switch line.kind {
            case .interlude:
                return nil
            case .syllable(let words, let backing):
                for (w, word) in words.enumerated() {
                    if w > 0 { texts.append(" "); runs.append(.space) }
                    for (s, syllable) in word.syllables.enumerated() {
                        if let letters = syllable.letters, !letters.isEmpty {
                            for (l, letter) in letters.enumerated() {
                                texts.append(letter.text)
                                runs.append(.letter(w, s, l))
                            }
                        } else {
                            texts.append(syllable.text)
                            runs.append(.syllable(w, s))
                        }
                    }
                }
                font = line.isBackground ? background : lead
                extra = backing
            case .line(let text):
                texts = [text]
                runs = [.line]
            case .static(let text):
                texts = [text]
                runs = [.line]
                font = still
            }
            // A word wider than the window's narrow column was broken mid-word ("замечательн / о"):
            // that row gets a smaller font instead, down to 70 %.
            let rowWidth = max(1, column - left - right)
            let longest = texts.joined().split(whereSeparator: \.isWhitespace).map { word in
                CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(
                    string: String(word), attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), nil, nil, nil))
            }.max() ?? 0
            if longest > rowWidth {
                font = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * max(0.7, rowWidth / longest * 0.98), nil, nil)
            }
            var blocks = [PiPTextBlock(runs: texts, font: font, alignment: alignment)]
            if !extra.isEmpty {
                let text = extra.map { $0.syllables.map(\.text).joined() }.joined(separator: " ")
                blocks.append(PiPTextBlock(runs: [text], font: background, gray: 0.5, alignment: alignment))
            }
            if let translation = snapshot.translations[line.sourceText], !translation.isEmpty {
                // A backing vocal's translation is as much smaller as the vocal itself.
                let translationSize = (line.isBackground ? size * 0.75 : size) * 0.55 * style.translationScale
                blocks.append(PiPTextBlock(runs: [translation], font: ctFont(translationSize, .semibold, style.design, family: style.family, face: style.postScriptName),
                                           gray: line.isBackground ? 0.45 : 0.6, alignment: alignment,
                                           spacing: size * 0.1))
            }
            return Row(layout: PiPTextLayout(blocks: blocks, width: rowWidth), x: left,
                       runs: runs, fontSize: CTFontGetSize(font), anchor: alignment, isBackground: line.isBackground)
        }
        lastLyricEnd = lyrics.kind == .static ? 0 : lyrics.lines.map(\.end).max() ?? 0
        // Spicy Lyrics always credits the writers and the people who synced the lyrics.
        credits = style.refinedCredits
            ? refinedCreditsLayout(lyrics, width: column - cqw * 5, design: style.design)
            : creditsLayout(lyrics, width: column - cqw * 5, design: style.design)
    }

    /// The block after the last line, as in the app (`LyricsCreditsView`).
    private func creditsLayout(_ lyrics: PreparedLyrics, width: CGFloat, design: UIFontDescriptor.SystemDesign) -> PiPTextLayout? {
        let size = leadSize
        let gap = size * 0.25
        let small = ctFont(size * 0.41, .semibold, design)
        var blocks: [PiPTextBlock] = []
        func add(_ text: String, _ font: CTFont, _ gray: CGFloat) {
            blocks.append(PiPTextBlock(runs: [text], font: font, gray: gray, spacing: blocks.isEmpty ? 0 : gap))
        }
        if !lyrics.songwriters.isEmpty {
            add("Written by: " + lyrics.songwriters.joined(separator: ", "), ctFont(size * 0.47, .semibold, design), 0.7)
        }
        let credits = lyrics.credits
        if let provider = credits.providedBy { add("Provided by: " + provider, small, 0.55) }
        if credits.isCommunity == true, credits.maker != nil || credits.uploader != nil {
            add("These lyrics have been provided by our community", ctFont(size * 0.41, .bold, design), 0.65)
        }
        if let maker = credits.maker { add("Made by @" + maker.name, small, 0.7) }
        if let uploader = credits.uploader {
            let role = credits.maker != nil ? "Uploaded by" : (credits.isCommunity == true ? "Made by" : "Submitted by")
            add(role + " @" + uploader.name, small, 0.7)
        }
        guard !blocks.isEmpty else { return nil }
        return PiPTextLayout(blocks: blocks, width: max(1, width))
    }

    /// The refined credits, as in the app (`RefinedCreditsView`): the songwriters, then the
    /// source or "Community lyrics · Made by @…" on a smaller, quieter line. One tone per line here.
    private func refinedCreditsLayout(_ lyrics: PreparedLyrics, width: CGFloat,
                                      design: UIFontDescriptor.SystemDesign) -> PiPTextLayout? {
        let size = leadSize * 0.41
        var blocks: [PiPTextBlock] = []
        if !lyrics.songwriters.isEmpty {
            blocks.append(PiPTextBlock(runs: ["Written by " + lyrics.songwriters.joined(separator: ", ")],
                                       font: ctFont(size, .semibold, design), gray: 0.65))
        }
        let credits = lyrics.credits
        var second: String?
        if credits.isCommunity == true, credits.maker != nil || credits.uploader != nil {
            var parts = ["Community lyrics"]
            if let maker = credits.maker { parts.append("Made by @" + maker.name) }
            if let uploader = credits.uploader {
                parts.append((credits.maker != nil ? "Uploaded by @" : "Made by @") + uploader.name)
            }
            second = parts.joined(separator: " · ")
        } else if let provider = credits.providedBy {
            second = "Provided by " + provider + (credits.via.map { " via " + $0 } ?? "")
        }
        if let second {
            blocks.append(PiPTextBlock(runs: [second], font: ctFont(size * 0.86, .medium, design), gray: 0.55,
                                       spacing: blocks.isEmpty ? 0 : size * 0.3))
        }
        guard !blocks.isEmpty else { return nil }
        return PiPTextLayout(blocks: blocks, width: max(1, width))
    }

    private func drawLyrics(_ lyrics: PreparedLyrics, _ snapshot: PiPSnapshot, width column: CGFloat,
                            now: CFTimeInterval, context: CGContext) {
        let style = snapshot.style
        let key = LayoutKey(revision: snapshot.revision, style: style, translations: snapshot.translations)
        if key != layoutKey || rows.count != lyrics.lines.count {
            leadSize = (Self.baseLeadSize * style.textScale).rounded()
            buildRows(lyrics, snapshot, width: column)
            layoutKey = key
        }
        let size = leadSize
        let cqw = column / 100
        // The app's `1cqw` gap, a little roomier at this size.
        let spacing = (cqw * 1.6 * style.lineSpacing).rounded()
        let dotsHeight = size * 1.18

        // Where every row sits in the column.
        var tops: [CGFloat] = []
        var heights: [CGFloat] = []
        tops.reserveCapacity(rows.count)
        heights.reserveCapacity(rows.count)
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let visual = snapshot.visuals.indices.contains(index) ? snapshot.visuals[index] : LineVisual()
            let height: CGFloat
            if let row {
                height = row.layout.size.height
                // `.bg-line { margin: -1cqw 0 1cqw }`: tucked right under the line above.
                if row.isBackground, index > 0 { y -= spacing }
            } else {
                // An interlude only takes up room while it is on (and eases in and out).
                height = (dotsHeight * CGFloat(clamp(visual.opacity, 0, 1))).rounded()
            }
            tops.append(y)
            heights.append(height)
            if height > 0 { y += height + spacing }
        }
        let creditsTop = y + size * 0.45 - spacing

        // Scroll target: the line in focus at the anchor, the credits once the song is sung.
        let viewport = clipBottom - Self.clipTop
        let anchor = Self.anchor(viewport: viewport)
        var target: CGFloat
        if lyrics.kind == .static {
            let progress = snapshot.duration > 0 ? CGFloat(clamp(snapshot.position / snapshot.duration, 0, 1)) : 0
            target = max(0, creditsTop - viewport * 0.5) * progress - anchor
        } else if snapshot.position > lastLyricEnd + 0.6, credits != nil {
            target = creditsTop - anchor
        } else {
            target = (tops.indices.contains(snapshot.focus) ? tops[snapshot.focus] : 0) - anchor
        }
        target = target.rounded()
        // No frames for a while (the window was closed, the phone stalled): the column jumps to
        // its line instead of gliding there from wherever it was left.
        let resumed = lastStep.map { now - $0 > 0.4 } ?? true
        let dt = min(1.0 / 15, max(0, now - (lastStep ?? now)))
        lastStep = now
        if scrollRevision != snapshot.revision || abs(target - scroll) > viewport * 2.5 || resumed
            || UIAccessibility.isReduceMotionEnabled {
            scroll = target
            velocity = 0
            scrollRevision = snapshot.revision
        } else if dt > 0 {
            // Critically damped, ω = 2π (the app's `spring(response: 1, dampingFraction: 1)`).
            let omega: CGFloat = 2 * .pi
            let steps = max(1, Int((dt / (1.0 / 120)).rounded(.up)))
            let h = CGFloat(dt) / CGFloat(steps)
            for _ in 0..<steps {
                velocity += (-omega * omega * (scroll - target) - 2 * omega * velocity) * h
                scroll += velocity * h
            }
        }
        scrollTarget = target
        isAnimating = abs(velocity) > 2 || abs(scroll - target) > 0.5

        // Draw what is on screen.
        var firstVisible = Int.max, lastVisible = -1
        for index in rows.indices {
            let top = tops[index] - scroll + Self.clipTop
            let height = heights[index]
            guard height > 0, top + height > Self.clipTop - 4, top < clipBottom + 4 else { continue }
            firstVisible = min(firstVisible, index)
            lastVisible = max(lastVisible, index)
            let visual = snapshot.visuals.indices.contains(index) ? snapshot.visuals[index] : LineVisual()
            let opacity = style.opacity(visual.opacity) * edgeFade(top: top, height: height)
            guard opacity > 0.01 else { continue }
            if let row = rows[index] {
                drawRow(row, index: index, line: lyrics.lines[index], visual: visual, focus: snapshot.focus,
                        origin: CGPoint(x: Self.inset + row.x, y: top), opacity: opacity, style: style, context: context)
            } else {
                drawDots(visual, top: top, height: height, column: column, centered: style.centered,
                         opposite: lyrics.lines[index].oppositeAligned,
                         opacity: CGFloat(visual.opacity) * edgeFade(top: top, height: height), style: style,
                         context: context)
            }
        }
        if let credits {
            let top = creditsTop - scroll + Self.clipTop
            if top < clipBottom, top + credits.size.height > Self.clipTop, let mask = credits.sharp.first {
                context.fill(mask: mask, in: credits.firstRect.offsetBy(dx: Self.inset, dy: top),
                             white: edgeFade(top: top, height: credits.size.height))
                if let restMask = credits.sharp.rest, let rest = credits.restRect {
                    context.fill(mask: restMask, in: rest.offsetBy(dx: Self.inset, dy: top),
                                 white: edgeFade(top: top, height: credits.size.height))
                }
            }
        }

        // Keep bitmaps only for rows near the window.
        purgeCountdown -= 1
        if purgeCountdown <= 0, lastVisible >= 0 {
            purgeCountdown = 30
            for index in rows.indices where index < firstVisible - 3 || index > lastVisible + 6 {
                if let row = rows[index], row.layout.isRasterized { row.layout.purge() }
            }
        }
    }

    /// Rows leaving the top or entering at the bottom fade with how much of them is inside.
    private func edgeFade(top: CGFloat, height: CGFloat) -> CGFloat {
        let h = max(height, 1)
        let inside = min((top + h - Self.clipTop) / h, (clipBottom - top) / h)
        let value = clamp(inside, 0, 1)
        return value * value * (3 - 2 * value)
    }

    private func drawRow(_ row: Row, index: Int, line: PreparedLine, visual: LineVisual, focus: Int,
                         origin: CGPoint, opacity: CGFloat, style: PiPStyle, context: CGContext) {
        let layout = row.layout
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        // The app's distance blur (`blur(radius: blur × strength / 2)` at 32 pt), at this size.
        let radius = CGFloat(visual.blur * style.blur / 2) * leadSize / 32
        let soft = style.blur > 0 ? min(1, radius / Self.softRadius) : 0
        let alpha: GradientAlpha = row.isBackground ? .background
            : (style.simple ? GradientAlpha(lit: 1, unlit: 0.3) : .lead)

        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        if case .line = line.kind, visual.scale != 1, !reduceMotion {
            // Active line-synced lines grow to 1.05 from their aligned edge.
            let anchor = CGPoint(x: layout.size.width * row.anchor, y: layout.size.height / 2)
            context.translateBy(x: anchor.x, y: anchor.y)
            context.scaleBy(x: CGFloat(visual.scale), y: CGFloat(visual.scale))
            context.translateBy(x: -anchor.x, y: -anchor.y)
        }

        let animated: Bool
        switch line.kind {
        case .syllable, .line: animated = visual.state == .active || abs(index - focus) <= 2
        default: animated = false
        }
        if animated, soft < 0.05 {
            drawPieces(row, visual: visual, alpha: alpha, opacity: opacity, style: style, context: context)
        } else {
            let lit: Bool
            switch line.kind {
            case .static: lit = true
            case .line: lit = visual.line.gradient >= 1
            default: lit = visual.state == .sung
            }
            let value: CGFloat = isStatic(line) ? 1 : CGFloat(lit ? alpha.lit : alpha.unlit)
            // A line that just ended is blurred at once, but its glow is still dying down (it peaks
            // on the last words, which a spring brings up late): keep drawing it, as the app does.
            if animated { drawGlows(row, visual: visual, opacity: opacity, style: style, context: context) }
            fillMixed(layout.sharp.first, layout.soft.first, soft: soft, rect: layout.firstRect,
                      alpha: value * opacity, context: context)
        }
        if let rest = layout.restRect {
            fillMixed(layout.sharp.rest, soft > 0.02 ? layout.soft.rest : nil, soft: soft, rect: rest,
                      alpha: opacity, context: context)
        }
        context.restoreGState()
    }

    private func isStatic(_ line: PreparedLine) -> Bool {
        if case .static = line.kind { return true }
        return false
    }

    /// A sharp mask, cross-faded into its soft copy as the distance blur grows.
    private func fillMixed(_ sharp: CGImage?, _ soft: CGImage?, soft amount: CGFloat, rect: CGRect,
                           alpha: CGFloat, context: CGContext) {
        if amount < 0.98, let sharp { context.fill(mask: sharp, in: rect, white: alpha * (1 - amount)) }
        if amount > 0.02, let soft { context.fill(mask: soft, in: rect, white: alpha * amount * 1.15) }
    }

    /// The line being sung: each syllable / letter with the animator's fill, lift, scale and glow.
    private func drawPieces(_ row: Row, visual: LineVisual, alpha: GradientAlpha, opacity: CGFloat,
                            style: PiPStyle, context: CGContext) {
        let layout = row.layout
        let masks = layout.sharp
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let fade = CGFloat(style.simple ? 0.5 : 0.2)
        let gradient = fillGradient(alpha)
        var glows: [CGImage?]?
        let shifts = reduceMotion ? nil : Self.growthShifts(row, visual)
        for (p, piece) in layout.pieces.enumerated() {
            guard masks.pieces.indices.contains(p), let mask = masks.pieces[p],
                  let drawn = Self.glyph(row.runs[piece.run], visual) else { continue }
            let (glyph, kind) = drawn
            let runWidth = layout.runWidths[piece.run]
            let scale = reduceMotion ? 1 : CGFloat(glyph.scale)
            let lift = reduceMotion ? 0 : CGFloat(glyph.yOffset) * row.fontSize
            let glyphRect = piece.glyphRect

            context.saveGState()
            context.setAlpha(opacity * CGFloat(glyph.opacity))
            context.translateBy(x: glyphRect.midX + (shifts?[p] ?? 0), y: glyphRect.midY + lift)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -glyphRect.midX, y: -glyphRect.midY)

            // Glow first, so it sits behind the letters like a shadow.
            let glow = reduceMotion ? 0 : kind.opacity(glyph.glow * style.glow)
            if glow > 0.004 {
                if glows == nil { glows = layout.glows }
                if let glows, glows.indices.contains(p), let soft = glows[p] {
                    context.fill(mask: soft, in: layout.glowRect(piece), white: CGFloat(glow) * 1.6)
                }
            }
            let edge = glyphRect.minX + CGFloat(glyph.gradient) * runWidth - piece.advance - piece.rect.minX
            let feather = max(1, runWidth * fade)
            context.fill(mask: mask, in: piece.rect) { context, _ in
                context.drawLinearGradient(gradient, start: CGPoint(x: edge, y: 0), end: CGPoint(x: edge + feather, y: 0),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            context.restoreGState()
        }
    }

    /// What a run draws with: its animator visual and glow kind (nil for spaces).
    private static func glyph(_ run: RunRef, _ visual: LineVisual) -> (GlyphVisual, GlowKind)? {
        switch run {
        case .space:
            return nil
        case .syllable(let w, let s):
            return (syllable(visual.lead, w, s)?.glyph ?? GlyphVisual(), .syllable)
        case .letter(let w, let s, let l):
            let syllable = syllable(visual.lead, w, s)
            if let syllable, syllable.letters.indices.contains(l) {
                // The letter rides its word's own scale and lift.
                var letter = syllable.letters[l]
                letter.scale *= syllable.glyph.scale
                letter.yOffset += syllable.glyph.yOffset
                return (letter, .letter)
            }
            return (syllable?.glyph ?? GlyphVisual(), .syllable)
        case .line:
            return (visual.line, .line)
        }
    }

    /// Only the glow of each piece, where `drawPieces` would put it.
    private func drawGlows(_ row: Row, visual: LineVisual, opacity: CGFloat, style: PiPStyle, context: CGContext) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let layout = row.layout
        var glows: [CGImage?]?
        let shifts = Self.growthShifts(row, visual)
        for (p, piece) in layout.pieces.enumerated() {
            guard let drawn = Self.glyph(row.runs[piece.run], visual) else { continue }
            let (glyph, kind) = drawn
            let glow = kind.opacity(glyph.glow * style.glow)
            guard glow > 0.004 else { continue }
            if glows == nil { glows = layout.glows }
            guard let glows, glows.indices.contains(p), let soft = glows[p] else { continue }
            let rect = piece.glyphRect
            context.saveGState()
            context.setAlpha(opacity * CGFloat(glyph.opacity))
            context.translateBy(x: rect.midX + shifts[p], y: rect.midY + CGFloat(glyph.yOffset) * row.fontSize)
            context.scaleBy(x: CGFloat(glyph.scale), y: CGFloat(glyph.scale))
            context.translateBy(x: -rect.midX, y: -rect.midY)
            context.fill(mask: soft, in: layout.glowRect(piece), white: CGFloat(glow) * 1.6)
            context.restoreGState()
        }
    }

    /// Per piece: the shift that keeps the pieces of a word touching while each is scaled about
    /// its own centre (`wordGrowthShifts`). A letter grows with its syllable.
    private static func growthShifts(_ row: Row, _ visual: LineVisual) -> [CGFloat] {
        let pieces = row.layout.pieces
        var shifts = [CGFloat](repeating: 0, count: pieces.count)
        var word: [Int] = []
        func flush() {
            defer { word = [] }
            guard word.count > 1 else { return }
            let growth = word.map { p -> CGFloat in
                switch row.runs[pieces[p].run] {
                case .syllable(let w, let s), .letter(let w, let s, _):
                    return CGFloat(syllable(visual.lead, w, s)?.glyph.scale ?? 1)
                default:
                    return 1
                }
            }
            let widths = word.map { pieces[$0].glyphRect.width }
            for (k, shift) in wordGrowthShifts(widths: widths, growth: growth).enumerated() { shifts[word[k]] = shift }
        }
        for p in pieces.indices {
            // Spaces have no pieces: neighbouring runs on one line are one word.
            if let last = word.last, pieces[p].run != pieces[last].run + 1
                || pieces[p].glyphRect.minY != pieces[last].glyphRect.minY { flush() }
            word.append(p)
        }
        flush()
        return shifts
    }

    private static func syllable(_ visuals: [[SyllableVisual]], _ w: Int, _ s: Int) -> SyllableVisual? {
        visuals.indices.contains(w) && visuals[w].indices.contains(s) ? visuals[w][s] : nil
    }

    private func fillGradient(_ alpha: GradientAlpha) -> CGGradient {
        let key = "\(alpha.lit)|\(alpha.unlit)"
        if let cached = gradients[key] { return cached }
        let gradient = CGGradient(colorSpace: Self.sRGB,
                                  colorComponents: [1, 1, 1, CGFloat(alpha.lit), 1, 1, 1, CGFloat(alpha.unlit)],
                                  locations: [0, 1], count: 2)!
        gradients[key] = gradient
        return gradient
    }

    /// Interlude dots, as the app's `InterludeDotsView`.
    private func drawDots(_ visual: LineVisual, top: CGFloat, height: CGFloat, column: CGFloat, centered: Bool, opposite: Bool,
                          opacity: CGFloat, style: PiPStyle, context: CGContext) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let groupScale = reduceMotion ? 1 : CGFloat(visual.dotGroupScale)
        guard groupScale > 0.001, !visual.dots.isEmpty, opacity > 0.01 else { return }
        let size = leadSize
        let dotFont = size * 1.3
        let diameter = dotFont * 0.348
        let advance = dotFont * 0.485 + 2.88
        let groupWidth = advance * CGFloat(visual.dots.count)
        // On the side of the singer who comes next, as in the app (a duet partner: the right).
        let left = Self.inset + (centered ? (column - groupWidth) / 2 : (opposite ? column - groupWidth : 0))
        context.saveGState()
        context.translateBy(x: left + groupWidth / 2, y: top + height / 2)
        context.scaleBy(x: groupScale, y: groupScale)
        for (index, dot) in visual.dots.enumerated() {
            let scale = reduceMotion ? 1 : CGFloat(dot.scale)
            let lift = reduceMotion ? 0 : CGFloat(dot.yOffset) * size
            let d = diameter * scale
            let x = -groupWidth / 2 + advance * (CGFloat(index) + 0.5)
            context.saveGState()
            context.setAlpha(opacity * CGFloat(dot.opacity))
            let glow = reduceMotion ? 0 : GlowKind.dot.opacity(dot.glow * style.glow)
            if glow > 0.004 {
                context.setShadow(offset: .zero, blur: GlowKind.dot.radius(dot.glow) * 2 * size / 32,
                                  color: UIColor.white.withAlphaComponent(CGFloat(glow)).cgColor)
            }
            context.setFillColor(UIColor.white.withAlphaComponent(CGFloat(GradientAlpha.lead.lit)).cgColor)
            context.fillEllipse(in: CGRect(x: x - d / 2, y: lift - d / 2, width: d, height: d))
            context.restoreGState()
        }
        context.restoreGState()
    }

    private func ctFont(_ size: CGFloat, _ weight: UIFont.Weight, _ design: UIFontDescriptor.SystemDesign,
                        family: String? = nil, face: String? = nil) -> CTFont {
        let key = "\(size)|\(weight.rawValue)|\(design.rawValue)|\(family ?? "")|\(face ?? "")"
        if let cached = fonts[key] { return cached as CTFont }
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        var font = base.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: size) } ?? base
        if let family {
            // The family may be gone (an imported font that was removed): then the system font stays.
            let descriptor = UIFontDescriptor(fontAttributes: [.family: family, .traits: [UIFontDescriptor.TraitKey.weight: weight]])
            let custom = UIFont(descriptor: descriptor, size: size)
            if custom.familyName == family { font = custom }
        }
        // An imported face exactly as picked; gone (removed) -> the system font stays.
        if let face, let custom = UIFont(name: face, size: size) { font = custom }
        fonts[key] = font
        return font as CTFont
    }

    // MARK: Background

    /// Copies the cached backdrop (cover, drifting, darkened) into the frame, redrawing it at
    /// most ten times a second.
    private func copyBackdrop(_ snapshot: PiPSnapshot, now: CFTimeInterval, into base: UnsafeMutableRawPointer,
                              bytesPerRow: Int) {
        let width = Int(size.width), height = Int(size.height)
        if backdrop == nil {
            backdrop = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                 space: Self.sRGB, bitmapInfo: Self.bitmapInfo)
        }
        guard let backdrop, let source = backdrop.data else { return }
        let coverID = "\(snapshot.artworkID)|\(snapshot.backgroundSaturation)"
        if let artwork = snapshot.artwork, coverImages?.id != coverID,
           let rendered = CoverBlobsView.render(artwork, saturation: snapshot.backgroundSaturation) {
            coverImages = (coverID, rendered.base, rendered.blob)
            backdropKey = nil
        }
        let themed = !snapshot.theme.isCover
        let hasArtwork = !themed && snapshot.artwork != nil && coverImages != nil
        let stale = backdropTheme != snapshot.theme || backdropKey?.artworkID != snapshot.artworkID || backdropKey?.animated != snapshot.animatedBackground
            || backdropKey?.hasArtwork != hasArtwork || backdropKey?.dim != snapshot.backgroundDim
        if stale || (snapshot.animatedBackground && hasArtwork && now - backdropRenderedAt >= Self.backgroundInterval) {
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            backdrop.setFillColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
            backdrop.fill(rect)
            if themed, let gradient = CGGradient(colorsSpace: Self.sRGB, colors: snapshot.theme.colors.map(\.cgColor) as CFArray,
                                                 locations: nil) {
                backdrop.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
            }
            if hasArtwork, let images = coverImages,
               let frame = renderBackground(images, time: snapshot.animatedBackground ? now : 0) {
                backdrop.interpolationQuality = .medium
                backdrop.draw(frame, in: rect)
            }
            // Darker than the app's background: the window is small and has to stay readable.
            if !themed {
                backdrop.setFillColor(red: 0, green: 0, blue: 0, alpha: snapshot.backgroundDim)
                backdrop.fill(rect)
            }
            backdropTheme = snapshot.theme
            backdropKey = (snapshot.artworkID, snapshot.animatedBackground, hasArtwork, snapshot.backgroundDim)
            backdropRenderedAt = now
        }
        let rowBytes = width * 4
        for row in 0..<height {
            memcpy(base + row * bytesPerRow, source + row * backdrop.bytesPerRow, rowBytes)
        }
    }

    /// One frame of the drifting cover, at low resolution.
    private func renderBackground(_ images: (id: String, base: CGImage, blob: CGImage), time t: CFTimeInterval) -> CGImage? {
        let size = backgroundSize
        guard let small = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: Self.sRGB, bitmapInfo: Self.bitmapInfo
        ) else { return nil }
        small.interpolationQuality = .low
        let diagonal = hypot(size.width, size.height)
        for layer in Self.backgroundLayers {
            let side = diagonal * layer.size
            let angle = 2 * Double.pi * t / layer.rotation
            let drift = layer.driftPeriod > 0 ? 2 * Double.pi * t / layer.driftPeriod : 0
            let center = CGPoint(
                x: size.width * layer.center.x + CGFloat(cos(drift)) * size.width * layer.drift.width,
                y: size.height * layer.center.y + CGFloat(sin(drift)) * size.height * layer.drift.height
            )
            small.saveGState()
            small.translateBy(x: center.x, y: center.y)
            small.rotate(by: CGFloat(angle))
            small.draw(layer.blob ? images.blob : images.base, in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
            small.restoreGState()
        }
        return small.makeImage()
    }
}

// MARK: - Hosting the layer

/// Puts the PiP layer into the window (AVKit needs it there); tucked behind the background.
struct PictureInPictureHost: UIViewRepresentable {
    let pip: LyricsPictureInPicture

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.isUserInteractionEnabled = false
        view.layer.addSublayer(pip.displayLayer)
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {}

    final class HostView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            // Follows the lyrics as the controls come and go; no implicit layer animation.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayers?.forEach { $0.frame = bounds }
            CATransaction.commit()
        }
    }
}
