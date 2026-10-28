import AVFoundation
import SwiftUI
import UIKit
import Combine

/// A TV or monitor on AirPlay screen mirroring or a cable. Instead of a copy of the phone, that
/// screen gets the desktop extension's full-screen view (`Fullscreen.ts`): cover and title on
/// the left, lyrics on the right, over the flowing background. The phone stays the remote.
@MainActor
final class ExternalDisplay: ObservableObject {
    static let shared = ExternalDisplay()

    /// Some screen is showing the lyrics: the phone must not lock (that ends the mirroring).
    var isConnected: Bool { connections > 0 || accessoryShown }
    @Published private var connections = 0
    /// iOS 27: the scene accessory's content is on a screen.
    @Published private var accessoryShown = false

    fileprivate func setAccessoryShown(_ shown: Bool) {
        let wasConnected = isConnected
        accessoryShown = shown
        if !wasConnected && isConnected { settings?.tvPhoneLyrics = false }
        if !isConnected { settings?.tvPhoneLyrics = false }
        SyncLog.log("display", shown ? "external screen: lyrics shown (scene accessory)" : "external screen: lyrics gone (scene accessory)")
    }

    @Published private(set) var settings: AppSettings?
    @Published private(set) var player: PlayerModel?
    @Published private(set) var performance: PerformanceMonitor?

    /// Called once at launch, before iOS hands over a screen that is already connected.
    func attach(settings: AppSettings, player: PlayerModel, performance: PerformanceMonitor) {
        self.settings = settings
        self.player = player
        self.performance = performance
    }

    @Published private(set) var screenPixels: CGSize?

    fileprivate func connected(_ screen: UIScreen) {
        if !isConnected { settings?.tvPhoneLyrics = false }
        connections += 1
        screenPixels = screen.nativeBounds.size
    }
    fileprivate func disconnected() {
        connections = max(0, connections - 1)
        if connections == 0 { screenPixels = nil }
        if !isConnected { settings?.tvPhoneLyrics = false }
    }
}

/// Only to give the external screen its own scene; the app's window stays SwiftUI's. The same
/// scene is also declared in Info.plist (`UIApplicationSceneManifest`): without a manifest iOS
/// never offered the app a scene for the TV and just mirrored the phone.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        ExternalDisplay.startDiagnostics()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        guard session.role == .windowExternalDisplayNonInteractive else {
            return UISceneConfiguration(name: nil, sessionRole: session.role)
        }
        SyncLog.log("display", "iOS asks for the external screen's scene")
        let configuration = UISceneConfiguration(name: ExternalDisplaySceneDelegate.configurationName,
                                                 sessionRole: session.role)
        configuration.delegateClass = ExternalDisplaySceneDelegate.self
        return configuration
    }
}

extension ExternalDisplay {
    /// For the log: which screens and scenes iOS reports, so a TV that shows a copy of the phone
    /// instead of the lyrics can be told apart from one the app never heard of.
    private static func logState(_ reason: String) {
        let roles = UIApplication.shared.connectedScenes.map { $0.session.role.rawValue.replacingOccurrences(of: "UIWindowSceneSessionRole", with: "") }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }
        SyncLog.log("display", "\(reason): \(UIScreen.screens.count) screen(s), scenes [\(roles.joined(separator: ", "))], audio \(outputs.joined(separator: ", "))")
    }

    static func startDiagnostics() {
        let center = NotificationCenter.default
        SyncLog.log("display", "screens at launch: \(UIScreen.screens.count)")
        center.addObserver(forName: UIScreen.didConnectNotification, object: nil, queue: .main) { note in
            let screen = note.object as? UIScreen
            SyncLog.log("display", "screen connected \(screen.map { "\($0.bounds.size)" } ?? "?"), mirrored: \(screen?.mirrored != nil)")
        }
        center.addObserver(forName: UIScreen.didDisconnectNotification, object: nil, queue: .main) { _ in
            SyncLog.log("display", "screen disconnected")
        }
        // Screen mirroring switches the audio to AirPlay too: what does iOS show the app then?
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            logState("audio route changed")
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            logState("app active")
        }
        center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { note in
            guard let scene = note.object as? UIScene else { return }
            SyncLog.log("display", "scene disconnected: \(scene.session.role.rawValue)")
        }
        center.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { note in
            guard let scene = note.object as? UIScene else { return }
            SyncLog.log("display", "scene connecting: \(scene.session.role.rawValue), delegate \(scene.delegate.map { "\(type(of: $0))" } ?? "none")")
        }
    }
}

@objc(SLExternalDisplaySceneDelegate)
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// Matches `UISceneConfigurationName` in project.yml.
    static let configurationName = "External Display"

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let host = UIHostingController(rootView: ExternalDisplayRoot())
        host.view.backgroundColor = .black
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        // Not key: the phone's window keeps the keyboard and the menus.
        window.isHidden = false
        self.window = window
        ExternalDisplay.shared.connected(scene.screen)
        SyncLog.log("display", "external screen \(scene.screen.bounds.size) connected")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        ExternalDisplay.shared.disconnected()
        SyncLog.log("display", "external screen disconnected")
    }
}

/// iOS 27 offers the external screen only to an app that registered a scene accessory for it
/// ("Presenting content on a connected display"); before that the scene from Info.plist and
/// `AppDelegate` is enough. Put on the app's root view. The SDK check keeps older Xcodes (CI)
/// building.
struct ExternalDisplayAccessory: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            content.sceneAccessory {
                ExternalNonInteractiveAccessory {
                    ExternalDisplayRoot()
                }
                .onAvailabilityChange { available in
                    ExternalDisplay.shared.setAccessoryShown(available)
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct ExternalDisplayRoot: View {
    @ObservedObject private var display = ExternalDisplay.shared

    var body: some View {
        if let settings = display.settings, let player = display.player, let performance = display.performance {
            ExternalLyricsView()
                .environment(settings)
                .environment(player)
                .environment(performance)
                .preferredColorScheme(.dark)
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}

/// The desktop extension's full-screen page, sized from its CSS (ContentBox.css): the NowBar is
/// `min(30cqw, 52cqh) × 1.1` wide, ends a quarter of its width before the middle and is
/// centred vertically; the lyrics fill the right half. Nothing on it can be touched.
struct ExternalLyricsView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(PerformanceMonitor.self) private var performance

    var body: some View {
        GeometryReader { geometry in
            let layout = DesktopLayout(size: geometry.size)
            ZStack(alignment: .topLeading) {
                background
                    .frame(width: geometry.size.width, height: geometry.size.height)

                if let lyrics = shownLyrics {
                    lyricsColumn(lyrics, layout: layout)
                        .transition(.opacity)
                }

                if showsNowBar {
                    nowBar(layout: layout)
                        .frame(width: layout.nowBarWidth)
                        .offset(x: shownLyrics == nil ? layout.centeredX : layout.nowBarX, y: layout.nowBarTop)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.6), value: shownLyrics == nil)
            .animation(.easeInOut(duration: 0.5), value: showsNowBar)
            .animation(.easeInOut(duration: 0.5), value: settings.tvBackground)
            .animation(.easeInOut(duration: 0.4), value: player.lyricsRevision)
        }
        .ignoresSafeArea()
    }

    private var reduced: Bool { settings.powerSaving || performance.constrained }

    /// Cover and title on the left; with nothing to sing they stay, in the middle.
    private var showsNowBar: Bool { settings.tvShowNowBar || shownLyrics == nil }

    @ViewBuilder
    private var background: some View {
        switch TVBackground(rawValue: settings.tvBackground) ?? .cover {
        case .cover:
            DynamicBackground(
                image: settings.dynamicBackground ? player.backgroundArtwork : nil,
                imageID: player.artworkID,
                artistImage: player.artistImage,
                canvasURL: player.canvasURL,
                animated: settings.dynamicBackground && !reduced,
                playing: player.isPlaying && !reduced,
                dim: settings.tvBackgroundDim,
                speed: settings.backgroundSpeed,
                blur: settings.backgroundBlur,
                saturation: settings.backgroundSaturation
            )
            .transition(.opacity)
        case .nebula:
            if CoverVisualizer.isSupported {
                CoverVisualizerView(player: player, reduced: reduced, dim: settings.tvBackgroundDim * 0.6,
                                    randomColors: settings.nebulaColors == NebulaColors.random.rawValue,
                                    maxFrameRate: 30)
                    .transition(.opacity)
            } else {
                Color.black
            }
        case .black:
            Color.black.transition(.opacity)
        }
    }

    /// Lyrics to show; otherwise the NowBar moves to the middle, like the extension's
    /// `LyricsHidden` page for songs without lyrics.
    private var shownLyrics: PreparedLyrics? {
        guard case .loaded(let lyrics) = player.lyricsState, !lyrics.lines.isEmpty else { return nil }
        if settings.hideStaticLyrics && lyrics.kind == .static { return nil }
        return lyrics
    }

    // MARK: Lyrics

    private func lyricsColumn(_ lyrics: PreparedLyrics, layout: DesktopLayout) -> some View {
        // Room on both sides for the glow of the lines at the column's edges.
        let padding = layout.size.width * 0.02
        // `--DefaultLyricsSize: clamp(3rem, 7cqw, 4rem)`, relative to the screen's height here so
        // it reads from the sofa; the size setting still scales it.
        let size = clamp(layout.lyricsWidth * 0.07, layout.size.height * 0.045, layout.size.height * 0.062)
            * CGFloat(clamp(settings.tvLyricsScale, 0.6, 1.6))
        // Without the cover the lyrics take the middle of the screen.
        let x = settings.tvShowNowBar ? layout.lyricsX : layout.size.width * 0.14
        let width = settings.tvShowNowBar ? layout.lyricsWidth : layout.size.width * 0.72
        return LyricsView(
            lyrics: lyrics, player: player, settings: settings,
            horizontalPadding: padding, reduced: reduced,
            fontScale: size / CGFloat(AppSettings.defaultFontSize),
            tapSeeks: false,
            clockOffset: settings.tvOffsetMs / 1000
        )
        .id(player.lyricsRevision)
        .frame(width: width + padding * 2, height: layout.size.height)
        .offset(x: x - padding)
        .animation(.easeInOut(duration: 0.5), value: settings.tvShowNowBar)
        .opacity(player.isResyncing ? 0.3 : 1)
        .animation(.easeInOut(duration: 0.25), value: player.isResyncing)
        .allowsHitTesting(false)
    }

    // MARK: NowBar

    private func nowBar(layout: DesktopLayout) -> some View {
        let height = layout.size.height
        return VStack(spacing: 0) {
            artwork(side: layout.nowBarWidth, cornerRadius: height * 0.02)

            // `.Metadata`: 10cqh tall, centred; the title at 2.25× the base font, the artists at 1.5×.
            VStack(spacing: height * 0.004) {
                MarqueeText(text: title, font: .system(size: height * 0.034, weight: .heavy), centered: true)
                    .opacity(0.95)
                MarqueeText(text: subtitle, font: .system(size: height * 0.023), centered: true)
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .frame(width: layout.nowBarWidth * 0.85)
            .frame(height: height * 0.1)
            .padding(.top, height * 0.012)

            if settings.tvShowTimeline, let duration = player.track?.duration, duration > 0 {
                Timeline(duration: duration, height: height)
                    .padding(.top, height * 0.006)
                    .padding(.horizontal, layout.nowBarWidth * 0.01)
            }
        }
    }

    private func artwork(side: CGFloat, cornerRadius: CGFloat) -> some View {
        ZStack {
            if let artwork = player.artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.3))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.1))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .id(player.artworkID)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.6), value: player.artworkID)
        .opacity(0.95)
        .shadow(color: .black.opacity(0.27), radius: 20, y: 9)
    }

    private var title: String {
        switch player.content {
        case .track(let track): return track.title
        case .episode(let title, _, _): return title
        case .ad: return String(localized: "Реклама")
        case .unknown: return String(localized: "Неизвестный трек")
        case .none: return "Sweet Lyrics"
        }
    }

    private var subtitle: String {
        switch player.content {
        case .track(let track): return track.artistLine
        case .episode(_, let show, _): return show
        default:
            return player.statusMessage ?? (player.supportsSpotifyFeatures
                ? String(localized: "Включите музыку в Spotify")
                : String(localized: "Включите музыку в Apple Music"))
        }
    }
}

/// `.Timeline`: elapsed time, the bar, the time left.
private struct Timeline: View {
    @Environment(PlayerModel.self) private var player
    let duration: Double
    let height: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5)) { _ in
            let position = clamp(player.playbackPosition(at: MediaClock.now()), 0, duration)
            HStack(spacing: height * 0.014) {
                Text(PlaybackBar.format(position))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white.opacity(0.85))
                            .frame(width: geometry.size.width * CGFloat(position / duration))
                    }
                }
                .frame(height: height * 0.008)
                Text(PlaybackBar.format(duration))
            }
            .font(.system(size: height * 0.017, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// ContentBox.css's fullscreen geometry, in points of the external screen.
private struct DesktopLayout {
    let size: CGSize

    /// `--NowBarWidth: calc(min(30cqw, 52cqh) * 1.1)`
    var nowBarWidth: CGFloat { min(size.width * 0.3, size.height * 0.52) * 1.1 }
    /// `--NowBarRightSpacing: NowBarWidth / 4`
    private var rightSpacing: CGFloat { nowBarWidth / 4 }
    /// `--NowBarLeftSpacing: 50cqw - NowBarWidth - NowBarRightSpacing` (kept on screen when the
    /// display is taller than wide).
    private var leftSpacing: CGFloat { max(size.width / 2 - nowBarWidth - rightSpacing, size.width * 0.04) }

    var nowBarX: CGFloat { leftSpacing }
    var centeredX: CGFloat { (size.width - nowBarWidth) / 2 }
    /// `padding-top: calc(50cqh - NowBarWidth * 0.625)`
    var nowBarTop: CGFloat { max(0, size.height / 2 - nowBarWidth * 0.625) }

    /// The lyrics' side paddings in fullscreen: `50cqw - RightSpacing × 0.3` and `LeftSpacing × 0.35`.
    var lyricsX: CGFloat { max(size.width / 2 - rightSpacing * 0.3, leftSpacing + nowBarWidth + size.width * 0.02) }
    var lyricsWidth: CGFloat { max(1, size.width - leftSpacing * 0.35 - lyricsX) }
}
