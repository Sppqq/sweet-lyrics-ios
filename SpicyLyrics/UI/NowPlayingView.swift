import SwiftUI

/// The main screen, laid out like Apple Music's lyrics view: header and controls float over
/// full-height lyrics and fade away while a song plays. Landscape puts artwork and controls on
/// the left, lyrics on the right.
struct NowPlayingView: View {
    @ObservedObject private var externalDisplay = ExternalDisplay.shared
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(PerformanceMonitor.self) private var performance
    @Environment(LyricsPictureInPicture.self) private var pip
    @State private var showSettings = false
    @State private var showPicker = false
    @State private var pickerDetent: PresentationDetent = .medium
    @State private var showSetupGuide = false
    @State private var showOwnLyrics = false
    /// Big ⏭/⏮ flash after a swipe changes the track.
    @State private var skipFeedback: SkipDirection?
    @State private var skipCount = 0
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @State private var chromeVisible = !UserDefaults.standard.bool(forKey: "demoHideChrome")
    #else
    @State private var chromeVisible = true
    #endif
    /// Bumped on every touch; restarts the auto-hide countdown.
    @State private var interactionTick = 0
    @State private var headerSwipe: CGFloat = 0
    @State private var headerHeight: CGFloat = 76
    /// Frames of the nebula, for the FPS badge where the lyrics would be.
    @State private var nebulaFrames = FrameRateCounter()
    @State private var controlsHeight: CGFloat = 250
    @State private var landscapeControlsHeight: CGFloat = 150
    @State private var isLandscape = false
    /// The bottom-left button put the big cover in place of the lyrics.
    #if DEBUG
    @State private var artworkMode = UserDefaults.standard.bool(forKey: "demoArtworkMode")
    #else
    @State private var artworkMode = false
    #endif
    /// The small cover in the header grows into the big one and shrinks back into it.
    @Namespace private var coverSpace

    private static let chromeAnimation = Animation.easeInOut(duration: 0.45)
    /// The badges at the top of the lyrics each take a row of their own (a long sync badge ran
    /// into the FPS one): FPS, then the sync badge, then any notice.
    private static let badgeRow: CGFloat = 30
    private var syncBadgeOffset: CGFloat { settings.showLyricsFPS ? Self.badgeRow : 0 }
    private var fpsBadgeClearance: CGFloat {
        syncBadgeOffset + (settings.showSyncIndicator ? Self.badgeRow : 0)
    }
    /// The small cover in the header.
    private static let miniArtworkSide: CGFloat = 54

    var body: some View {
        GeometryReader { geometry in
            let size = Self.clampedToWindow(geometry.size)
            // Side by side in landscape. iPad upright gets the portrait layout: side by side, the
            // lyrics column was too narrow and every line wrapped.
            let landscape = size.width > size.height && size.width > 560
            ZStack {
                // The PiP layer has to be in the window; it sits behind everything, right under
                // the lyrics: the floating window opens out of it and closes back into it.
                if !pip.previewing {
                    let source = pipSource(in: size, landscape: landscape)
                    PictureInPictureHost(pip: pip)
                        .frame(width: source.width, height: source.height)
                        .position(x: source.midX, y: source.midY)
                        .allowsHitTesting(false)
                }

                DynamicBackground(
                    image: settings.dynamicBackground ? player.backgroundArtwork : nil,
                    imageID: player.artworkID,
                    artistImage: player.artistImage,
                    canvasURL: player.canvasURL,
                    animated: settings.dynamicBackground && !reduced && !tvMode,
                    playing: player.isPlaying,
                    dim: settings.backgroundDim,
                    speed: settings.backgroundSpeed,
                    blur: settings.backgroundBlur,
                    saturation: settings.backgroundSaturation
                )

                // Experimental: a visualizer where the lyrics were hidden.
                ZStack {
                    if showVisualizer {
                        // Less than half the background's darkening: the nebula should glow, the lines still read.
                        CoverVisualizerView(player: player, reduced: reduced, dim: settings.backgroundDim * 0.4,
                                            randomColors: settings.nebulaColors == NebulaColors.random.rawValue,
                                            stars: settings.nebulaStars,
                                            frameCounter: settings.showLyricsFPS ? nebulaFrames : nil,
                                            maxFrameRate: Int(settings.lyricsFrameRate))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.8), value: showVisualizer)

                if landscape {
                    landscapeLayout(size)
                } else {
                    portraitLayout(size)
                }

                if let notice = player.autoSkipNotice {
                    Label(notice, systemImage: "forward.end.fill")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                        .padding(.horizontal, 24)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, (chromeVisible && !landscape ? headerHeight : 0) + 8 + fpsBadgeClearance)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .allowsHitTesting(false)
                }

                Color.clear
                    .allowsHitTesting(false)
                    .onChange(of: landscape, initial: true) { _, value in isLandscape = value }

                if let skipFeedback {
                    Image(systemName: skipFeedback == .next ? "forward.fill" : "backward.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                        .padding(30)
                        .background(.ultraThinMaterial, in: Circle())
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                #if DEBUG
                if pip.previewing { DemoPiPScene(pip: pip) }
                #endif
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: skipCount)
        .background { keyboardShortcuts }
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
        .task(id: AutoHideKey(tick: interactionTick, eligible: canAutoHide)) { await autoHideAfterDelay() }
        .onChange(of: player.isPlaying) { _, playing in
            // Pausing brings the controls back, like Apple Music (not in lyrics-only mode).
            if !playing && !lyricsOnly { showChrome() }
        }
        .onChange(of: pip.isActive) { _, active in
            // Coming back from the floating window can leave the hosting view at the size it had
            // during the restore animation (wider than the screen): lay the window out again.
            if !active { Self.relayoutWindows() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Self.relayoutWindows()
            // The lyrics are on screen again: the floating window has nothing left to do.
            if settings.closePiPOnReturn { pip.stopIfIdle() }
        }
        .onChange(of: settings.pipFormat) { _, _ in pip.refreshFrame() }
        .animation(.easeInOut(duration: 0.3), value: player.autoSkipNotice)
        .onChange(of: lyricsOnly) { _, value in
            if value { hideChrome() }
        }
        .onChange(of: tvMode, initial: true) { _, value in
            if value { showChrome() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(settings)
                .environment(player)
                .environment(performance)
                .environmentObject(auth)
        }
        .sheet(isPresented: $showSetupGuide) {
            NavigationStack {
                SpotifySetupGuideView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "Закрыть")) { showSetupGuide = false }
                        }
                    }
            }
            .environment(settings)
            .environmentObject(auth)
        }
        .sheet(isPresented: $showOwnLyrics) {
            OwnLyricsView()
                .environment(player)
        }
        .sheet(isPresented: $showPicker) {
            TrackPickerView()
                .environment(settings)
                .environment(player)
                .environmentObject(auth)
                .presentationDetents([.medium, .large], selection: $pickerDetent)
                .presentationDragIndicator(.visible)
        }
        .onChange(of: settings.showRomanization) { _, _ in player.settingsChanged() }
        .onChange(of: settings.simpleLyricsMode) { _, _ in player.settingsChanged() }
        .onChange(of: settings.joinSplitWords) { _, _ in player.settingsChanged() }
        .onChange(of: settings.backgroundStyle) { _, _ in player.loadBackgroundVisuals() }
        .onChange(of: settings.dynamicBackground) { _, _ in player.loadBackgroundVisuals() }
        .onChange(of: settings.minimalLyricsMode) { _, _ in player.settingsChanged() }
        .onChange(of: settings.refreshedSimpleLyrics) { _, _ in player.settingsChanged() }
        .onChange(of: settings.translationReplaces) { _, _ in player.settingsChanged() }
        .onChange(of: settings.translateLyrics) { _, _ in player.settingsChanged() }
        .modifier(LyricsTranslation(player: player, settings: settings))
        .task { pip.configure(player: player, settings: settings, performance: performance) }
        #if DEBUG
        .task {
            guard DemoTrack.current != nil else { return }
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "demoLandscape"),
               let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
            if defaults.bool(forKey: "demoSettings") { showSettings = true }
            if defaults.bool(forKey: "demoQueue") {
                pickerDetent = .large
                showPicker = true
            }
            // Slow Core Animation (scrolling, the background) down with the lyrics clock.
            if MediaClock.scale != 1 {
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    scene.windows.forEach { $0.layer.speed = Float(MediaClock.scale) }
                }
            }
            if defaults.bool(forKey: "demoPiP") {
                // Once the lyrics are on screen, as the "•••" menu would.
                try? await Task.sleep(for: .seconds(3))
                if LyricsPictureInPicture.isSupported {
                    pip.start()
                } else {
                    pip.startPreview()
                }
            }
        }
        #endif
        .onChange(of: settings.autoPictureInPicture) { _, enabled in pip.setAutomaticStart(enabled) }
        .modifier(NowPlayingAlerts(pip: pip, player: player))
    }

    // MARK: Chrome visibility

    private struct AutoHideKey: Hashable {
        var tick: Int
        var eligible: Bool
    }

    /// The app's window, or nil before it exists (never the external screen's).
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .filter { $0.session.role == .windowApplication }
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
    }

    /// Never lay out wider or taller than the window itself: after Picture in Picture the
    /// proposed size could briefly be the restore animation's and the layout would stick to it.
    private static func clampedToWindow(_ size: CGSize) -> CGSize {
        guard let bounds = keyWindow?.bounds, bounds.width > 0, bounds.height > 0 else { return size }
        return CGSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
    }

    private static func relayoutWindows() {
        DispatchQueue.main.async {
            for scene in UIApplication.shared.connectedScenes {
                guard let scene = scene as? UIWindowScene else { continue }
                for window in scene.windows {
                    if let root = window.rootViewController?.view, root.frame != window.bounds {
                        SyncLog.log("pip", "root view \(root.frame.size) ≠ window \(window.bounds.size), fixing")
                        root.frame = window.bounds
                    }
                    window.setNeedsLayout()
                    window.layoutIfNeeded()
                }
            }
        }
    }

    /// Low Power Mode, a hot phone, or the battery saver setting.
    private var reduced: Bool { settings.powerSaving || performance.constrained }

    /// Where the floating window opens from and closes back onto: across the lyrics, with the
    /// window's line in focus on the app's active line, so the window seems to lift the lyrics
    /// off the screen and put them back.
    private func pipSource(in size: CGSize, landscape: Bool) -> CGRect {
        let format = settings.format
        let area: CGRect
        var top: CGFloat = 0, bottom: CGFloat = 0
        if landscape {
            let column = min(size.width * 0.4, 420) + 12
            area = CGRect(x: column, y: 0, width: max(1, size.width - column), height: size.height)
        } else {
            area = CGRect(origin: .zero, size: size)
            top = chromeVisible ? headerHeight : 0
            bottom = chromeVisible ? controlsHeight : 0
        }
        // `LyricsView.anchor`: the active line sits 30 pt above this spot in the visible lyrics.
        let visible = max(area.height - top - bottom, 1)
        let activeY = area.minY + top + visible * CGFloat(clamp(settings.activeLinePosition, 0.2, 0.8)) - 20
        var width = max(area.width, 1)
        var height = width / format.aspect
        // Kept on screen: AVKit animates from the part of the layer it can see.
        if height > size.height {
            height = size.height
            width = height * format.aspect
        }
        let fraction = PiPFrameRenderer.focusFraction(format: format, showTitle: settings.pipShowTitle,
                                                      textScale: settings.pipTextScale)
        let y = min(max(0, activeY - fraction * height), max(0, size.height - height))
        return CGRect(x: area.midX - width / 2, y: y, width: width, height: height)
    }

    private var lyricsLoaded: Bool {
        if case .loaded = player.lyricsState { return true }
        return false
    }

    /// Landscape with "Только текст": the controls only show up for a moment after a tap.
    private var lyricsOnly: Bool { isLandscape && settings.landscapeLyricsOnly }

    /// No lyrics to show by the user's choice (not found / unsynced): just the background.
    private var lyricsHidden: Bool {
        switch player.lyricsState {
        case .notFound: return settings.hideNotFoundNotice
        // Podcasts and ads only say there's nothing to show, like "not found"; errors keep their notice.
        case .unavailable(let notice): return settings.hideNotFoundNotice && notice.isNoLyrics
        case .loaded(let lyrics): return settings.hideStaticLyrics && lyrics.kind == .static
        default: return false
        }
    }

    /// The song has lyrics to switch to: the lyrics button is greyed out otherwise.
    private var lyricsAvailable: Bool {
        switch player.lyricsState {
        case .loaded, .loading: return !lyricsHidden
        default: return false
        }
    }

    /// A TV shows the lyrics: the phone shows the TV's settings in their place.
    private var tvMode: Bool { externalDisplay.isConnected && !settings.tvPhoneLyrics }

    /// The experimental visualizer fills in for lyrics hidden by the user's choice.
    private var showVisualizer: Bool {
        CoverVisualizer.isSupported && !tvMode
            && ((bigArtworkShown && settings.artworkBackground == ArtworkBackground.nebula.rawValue)
                || (lyricsHidden && settings.hiddenLyricsView == HiddenLyricsView.visualizer.rawValue))
    }

    /// The big cover instead of the lyrics: chosen with the bottom-left button, or the setting
    /// for songs whose lyrics are hidden.
    private var bigArtworkShown: Bool {
        !tvMode && (artworkMode || (lyricsHidden && settings.hiddenLyricsView == HiddenLyricsView.artwork.rawValue))
    }

    /// Synced lyrics for the line under the big cover.
    private var artworkLyrics: PreparedLyrics? {
        guard settings.artworkLyricLine, case .loaded(let lyrics) = player.lyricsState,
              lyrics.kind != .static, !lyrics.lines.isEmpty, !lyricsHidden else { return nil }
        return lyrics
    }

    /// Landscape with hidden lyrics: the controls fade away too, leaving the background alone.
    private var backgroundOnly: Bool { isLandscape && lyricsHidden }

    private var canAutoHide: Bool {
        guard chromeVisible, !tvMode, !showSettings, !showPicker, !showSetupGuide, !showOwnLyrics else { return false }
        return lyricsOnly || backgroundOnly || (settings.autoHideControls && player.isPlaying && lyricsLoaded)
    }

    /// Hides the controls after the set delay, unless something brought them back meanwhile.
    private func autoHideAfterDelay() async {
        guard canAutoHide else { return }
        try? await Task.sleep(for: .seconds(lyricsOnly ? 4 : settings.autoHideDelay))
        guard !Task.isCancelled, canAutoHide else { return }
        withAnimation(Self.chromeAnimation) { chromeVisible = false }
    }

    private func showChrome() {
        interactionTick += 1
        guard !chromeVisible else { return }
        withAnimation(Self.chromeAnimation) { chromeVisible = true }
    }

    private func toggleChrome() {
        interactionTick += 1
        withAnimation(Self.chromeAnimation) { chromeVisible.toggle() }
    }

    private func hideChrome() {
        withAnimation(Self.chromeAnimation) { chromeVisible = false }
    }

    /// The big cover in place of the lyrics, or back.
    private func toggleArtworkMode() {
        showChrome()
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { artworkMode.toggle() }
    }

    // MARK: Gestures & keyboard

    private enum SkipDirection { case next, previous }

    /// Swipe across the lyrics: next / previous track with a flash and a light tap.
    private func skip(_ direction: SkipDirection) {
        if direction == .next { player.next() } else { player.previous() }
        skipCount += 1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { skipFeedback = direction }
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard skipFeedback == direction else { return }
            withAnimation(.easeOut(duration: 0.25)) { skipFeedback = nil }
        }
    }

    /// Hardware keyboard (iPad): space plays/pauses, ⌘← / ⌘→ change tracks.
    private var keyboardShortcuts: some View {
        ZStack {
            Button(String(localized: "Пауза / воспроизведение")) { player.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
            Button(String(localized: "Следующий трек")) { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button(String(localized: "Предыдущий трек")) { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Portrait

    private func portraitLayout(_ size: CGSize) -> some View {
        ZStack {
            lyricsArea(
                topInset: chromeVisible ? headerHeight : 0,
                bottomInset: chromeVisible ? controlsHeight : 0,
                horizontalPadding: 28
            )

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    .opacity(chromeVisible ? 1 : 0)
                    .offset(y: chromeVisible ? 0 : -24)

                Spacer(minLength: 0)

                controls()
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                    .opacity(chromeVisible ? 1 : 0)
                    .offset(y: chromeVisible ? 0 : 40)
            }
            .allowsHitTesting(chromeVisible)

            // Like Apple Music: while the controls are hidden, where they live is not part of the
            // lyrics. A tap there brings them back instead of seeking to a line.
            if !chromeVisible {
                VStack(spacing: 0) {
                    wakeZone.frame(height: headerHeight + 24)
                    Spacer(minLength: 0)
                    wakeZone.frame(height: controlsHeight + 24)
                }
            }
        }
        // Nothing that overflows (a long title, say) may widen the screen and push the lyrics
        // and controls past its edge.
        .frame(width: size.width, height: size.height)
    }

    /// Invisible area that shows the controls on tap.
    private var wakeZone: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { showChrome() }
            .verticalSwipe(.up) { showChrome() }
            .accessibilityLabel(String(localized: "Показать элементы управления"))
            .accessibilityAddTraits(.isButton)
    }

    // MARK: Landscape

    private func landscapeLayout(_ size: CGSize) -> some View {
        let lyricsOnly = settings.landscapeLyricsOnly || lyricsHidden
        // The big cover sits where the lyrics were: the column keeps the title and controls,
        // just not the small cover.
        let showTitle = settings.landscapeTitle && !lyricsOnly
        let column = min(size.width * 0.4, 420)
        let blockWidth = column - 40
        // The artwork gets whatever height the title and controls leave free.
        let reserved = (chromeVisible ? landscapeControlsHeight + 18 : 0) + (showTitle ? 62 : 0) + 24
        let artworkSide = min(blockWidth, size.height * 0.62, size.height - reserved)
        let showArtwork = settings.landscapeArtwork && !lyricsOnly && !bigArtworkShown && artworkSide >= 72
        let infoWidth = showArtwork ? artworkSide : min(blockWidth, 320)
        // With artwork and title switched off the column is empty once the controls hide:
        // slide the lyrics to the middle instead of leaving a gap (no re-wrapping).
        let columnEmpty = !showArtwork && !showTitle && !chromeVisible

        return HStack(spacing: 0) {
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                if showArtwork {
                    artwork(side: artworkSide, cornerRadius: 12)
                        .scaleEffect(player.isPlaying ? 1 : 0.86)
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: player.isPlaying)
                        .onTapGesture { toggleChrome() }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                if showTitle {
                    titleBlock
                        .frame(width: infoWidth)
                }

                if chromeVisible {
                    controls(compact: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { landscapeControlsHeight = $0 }
                        .frame(width: max(infoWidth, 280))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                Spacer(minLength: 0)
            }
            .frame(width: column)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            // Empty space in the column toggles the controls (the buttons keep their own taps).
            .onTapGesture { toggleChrome() }
            // "•••" in the column's corner, out of the title's way.
            .overlay(alignment: .topTrailing) {
                // Whenever the controls are up: settings and the track list stay in reach.
                if chromeVisible {
                    moreMenu
                        .padding(.top, 4)
                        .transition(.opacity)
                }
            }
            .padding(.leading, 12)
            .opacity(columnEmpty ? 0 : 1)

            lyricsArea(topInset: 0, bottomInset: 0, horizontalPadding: 24)
                .frame(width: max(0, size.width - column - 12))
        }
        .frame(width: size.width, alignment: .leading)
        .offset(x: columnEmpty ? -(column + 12) / 2 : 0)
        .overlay(alignment: .bottom) {
            if !chromeVisible {
                wakeZone.frame(height: size.height * 0.2)
            }
        }
        .animation(Self.chromeAnimation, value: showArtwork)
        .animation(Self.chromeAnimation, value: showTitle)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            trackInfo
            moreMenu
        }
        .foregroundStyle(.white)
        // Swipe the header down to tuck the controls away.
        .verticalSwipe(.down) { hideChrome() }
    }

    /// Small artwork and title. Tap to pick a track, swipe sideways to skip.
    private var trackInfo: some View {
        HStack(spacing: 12) {
            // The big cover is on screen: no need for the small one. A tap on it opens the big
            // cover (the title next to it keeps opening the track list).
            if !bigArtworkShown {
                heroArtwork(side: Self.miniArtworkSide, cornerRadius: 6)
                    .transition(.opacity)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(String(localized: "Показать обложку"))
                    .accessibilityAction { toggleArtworkMode() }
            }
            titleBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .offset(x: headerSwipe)
        .opacity(1 - min(Double(abs(headerSwipe)) / 160, 0.6))
        // One tap for the whole row, sorted by where it lands: a tap of the cover's own lost to
        // this one, so the small cover opened the track list instead of the big cover.
        .onTapGesture(coordinateSpace: .local) { location in
            if !bigArtworkShown, location.x <= Self.miniArtworkSide + 6 {
                toggleArtworkMode()
            } else {
                showChrome()
                if player.supportsSpotifyFeatures { showPicker = true }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 28)
                .onChanged { value in
                    guard settings.gesturesEnabled,
                          abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    headerSwipe = value.translation.width * 0.5
                }
                .onEnded { value in
                    let width = value.translation.width
                    // A deliberate, mostly horizontal swipe: a sloppy tap near "•••" must not skip.
                    if settings.gesturesEnabled, player.track != nil,
                       abs(width) > 110, abs(width) > abs(value.translation.height) * 2 {
                        skip(width < 0 ? .next : .previous)
                    }
                    showChrome()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { headerSwipe = 0 }
                }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(settings.gesturesEnabled
                           ? String(localized: "Выбрать трек. Смахните влево или вправо, чтобы переключить трек.")
                           : String(localized: "Выбрать трек."))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Too long to fit: rides sideways, like in Apple Music.
            MarqueeText(text: title, font: .system(size: 17, weight: .semibold), active: chromeVisible || isLandscape)
            MarqueeText(text: subtitle, font: .system(size: 17), active: chromeVisible || isLandscape)
                .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func artwork(side: CGFloat, cornerRadius: CGFloat) -> some View {
        artworkFill(cornerRadius: cornerRadius)
            .frame(width: side, height: side)
    }

    /// The header's cover and the big one are the same view to SwiftUI: switching between them
    /// flies the cover from one place to the other, growing or shrinking on the way.
    private func heroArtwork(side: CGFloat, cornerRadius: CGFloat) -> some View {
        artworkFill(cornerRadius: cornerRadius)
            .matchedGeometryEffect(id: "cover", in: coverSpace)
            .frame(width: side, height: side)
    }

    /// The cover filling whatever size it is offered.
    private func artworkFill(cornerRadius: CGFloat) -> some View {
        Group {
            if let artwork = player.artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
            } else {
                GeometryReader { geometry in
                    Image(systemName: "music.note")
                        .font(.system(size: min(geometry.size.width, geometry.size.height) * 0.35))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .background(.white.opacity(0.1))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Apple Music's "•••" button.
    private var moreMenu: some View {
        Menu {
            // Three rows at most: with large system text a long menu barely fits and scrolls badly.
            // The everyday actions sit side by side in one row.
            ControlGroup {
                if player.supportsSpotifyFeatures {
                    Button {
                        showPicker = true
                    } label: {
                        Label(String(localized: "Трек"), systemImage: "music.note.list")
                    }
                }
                Button {
                    settings.translateLyrics.toggle()
                } label: {
                    Label(settings.translateLyrics ? String(localized: "Без перевода") : String(localized: "Перевод"),
                          systemImage: "character.bubble")
                }
                if LyricsPictureInPicture.isSupported {
                    Button {
                        pip.isActive ? pip.stop() : pip.start()
                    } label: {
                        Label(pip.isActive ? String(localized: "Закрыть окно") : String(localized: "Поверх"),
                              systemImage: pip.isActive ? "pip.exit" : "pip.enter")
                    }
                }
            }
            Menu {
                Button {
                    player.loadLyrics(force: true)
                } label: {
                    Label(String(localized: "Перезагрузить текст"), systemImage: "arrow.clockwise")
                }
                Button {
                    showOwnLyrics = true
                } label: {
                    Label(String(localized: "Свой текст (TTML)"), systemImage: "doc.text")
                }
                if let url = spotifyURL {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Label(player.supportsSpotifyFeatures ? String(localized: "Открыть в Spotify") : String(localized: "Открыть Музыку"), systemImage: "arrow.up.forward.app")
                    }
                }
            } label: {
                Label(String(localized: "Ещё"), systemImage: "ellipsis.circle")
            }
            Button {
                showSettings = true
            } label: {
                Label(String(localized: "Настройки"), systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.18), in: Circle())
                // 48 pt touch target around the 30 pt circle.
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
                .hoverEffect(.highlight)
        }
        .simultaneousGesture(TapGesture().onEnded { showChrome() })
    }

    private var spotifyURL: URL? {
        if !player.supportsSpotifyFeatures { return URL(string: "music:") }
        guard let track = player.track else { return URL(string: "spotify:") }
        return URL(string: track.uri) ?? URL(string: "spotify:")
    }

    private func controls(compact: Bool = false) -> some View {
        PlaybackBar(
            onInteraction: { showChrome() },
            onShowQueue: { if player.supportsSpotifyFeatures { showPicker = true } },
            onToggleLyrics: {
                withAnimation(.easeInOut(duration: 0.45)) { artworkMode.toggle() }
            },
            lyricsShown: !bigArtworkShown,
            lyricsAvailable: lyricsAvailable,
            isVisible: chromeVisible,
            compact: compact
        )
        .foregroundStyle(.white)
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
        default: return player.statusMessage ?? (player.supportsSpotifyFeatures ? String(localized: "Ожидание Spotify…") : String(localized: "Ожидание Apple Music…"))
        }
    }

    // MARK: Lyrics

    /// The lyrics (or what stands in for them), or the TV's settings while a TV shows them.
    private func lyricsArea(topInset: CGFloat, bottomInset: CGFloat, horizontalPadding: CGFloat) -> some View {
        ZStack {
            if tvMode {
                TVControlPanel(topInset: topInset, bottomInset: bottomInset) {
                    withAnimation(.spring(response: 0.7, dampingFraction: 0.88)) { settings.tvPhoneLyrics = true }
                }
                .transition(.blurFade)
            } else {
                phoneLyricsArea(topInset: topInset, bottomInset: bottomInset, horizontalPadding: horizontalPadding)
                    .transition(.blurFade)
            }
        }
        .animation(.spring(response: 0.7, dampingFraction: 0.88), value: tvMode)
        .overlay(alignment: .bottom) {
            // The lyrics are on the phone by choice: one tap back to the TV's settings.
            if externalDisplay.isConnected && settings.tvPhoneLyrics && chromeVisible {
                Button {
                    withAnimation(.spring(response: 0.7, dampingFraction: 0.88)) { settings.tvPhoneLyrics = false }
                } label: {
                    Label(String(localized: "Настройки телевизора"), systemImage: "airplay.video")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                }
                .buttonStyle(SquishButtonStyle())
                .padding(.bottom, bottomInset + 12)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    @ViewBuilder
    private func phoneLyricsArea(topInset: CGFloat, bottomInset: CGFloat, horizontalPadding: CGFloat) -> some View {
        if bigArtworkShown || lyricsHidden {
            ZStack {
                Color.clear
                if bigArtworkShown {
                    bigArtwork(topInset: topInset, bottomInset: bottomInset)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleChrome() }
            .trackSwipes(enabled: settings.gesturesEnabled && player.track != nil,
                         onNext: { skip(.next) }, onPrevious: { skip(.previous) })
            .overlay(alignment: .topLeading) {
                // The lyrics' FPS badge, here counting the nebula's frames.
                if settings.showLyricsFPS && showVisualizer {
                    FPSBadge(counter: nebulaFrames,
                             target: Double(VisualizerSurface.framesPerSecond(playing: player.isPlaying, reduced: reduced,
                                                                     maxFrameRate: Int(settings.lyricsFrameRate))))
                        .padding(.top, topInset + 6)
                        .padding(.leading, horizontalPadding)
                }
            }
        } else {
            visibleLyricsArea(topInset: topInset, bottomInset: bottomInset, horizontalPadding: horizontalPadding)
        }
    }

    /// The cover, as big as the free space allows, over the nebula; optionally one synced line
    /// under it. It grows when the controls hide and sinks back a little on pause, like Apple
    /// Music; a new song's cover fades in over the old one.
    private func bigArtwork(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        GeometryReader { geometry in
            let margin: CGFloat = isLandscape ? 24 : 28
            let freeHeight = geometry.size.height - topInset - bottomInset
            let lyrics = artworkLyrics
            let lineFont: CGFloat = isLandscape ? 20 : 24
            // Room for two lines and a backing vocal or a translation under the cover; with
            // translations under the lines, a little more for the backing vocal's own.
            let translated = settings.translateLyrics && !settings.translationReplaces
            let lineHeight: CGFloat = lyrics == nil ? 0 : lineFont * (translated ? 5.2 : 4.4)
            let gap: CGFloat = lyrics == nil ? 0 : 20
            let side = max(0, min(geometry.size.width - margin * 2, freeHeight - margin * 2 - lineHeight - gap, 720))
            let blockTop = topInset + freeHeight / 2 - (side + gap + lineHeight) / 2
            ZStack(alignment: .topLeading) {
                ZStack {
                    artworkFill(cornerRadius: max(10, side * 0.035))
                        .id(player.artworkID)
                        .transition(.opacity)
                }
                .matchedGeometryEffect(id: "cover", in: coverSpace)
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                .scaleEffect(player.isPlaying ? 1 : 0.88)
                .position(x: geometry.size.width / 2, y: blockTop + side / 2)
                .animation(.spring(response: 0.5, dampingFraction: 0.75), value: player.isPlaying)
                .animation(.easeInOut(duration: 0.6), value: player.artworkID)
                .animation(Self.chromeAnimation, value: topInset)
                .animation(Self.chromeAnimation, value: bottomInset)
                // Moves itself along with the cover (see `ArtworkLyricLine`).
                if let lyrics {
                    ArtworkLyricLine(lyrics: lyrics, player: player, settings: settings, fontSize: lineFont,
                                     frame: CGRect(x: (geometry.size.width - side) / 2, y: blockTop + side + gap,
                                                   width: side, height: lineHeight))
                        .id(player.lyricsRevision)
                        .transition(.opacity)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func visibleLyricsArea(topInset: CGFloat, bottomInset: CGFloat, horizontalPadding: CGFloat) -> some View {
        lyricsContent(topInset: topInset, bottomInset: bottomInset, horizontalPadding: horizontalPadding)
            // Until Spotify confirms what is playing, the lyrics on screen may be stale.
            .opacity(player.isResyncing ? 0.3 : 1)
            .overlay(alignment: .top) {
                if player.isResyncing {
                    Label(String(localized: "Синхронизация со Spotify…"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, topInset + 8 + fpsBadgeClearance)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: player.isResyncing)
            .trackSwipes(enabled: settings.gesturesEnabled && player.track != nil,
                         onNext: { skip(.next) }, onPrevious: { skip(.previous) })
    }

    /// iPad: the extension sizes lyrics at 7% of the container width, so wide screens get more.
    private var lyricFontScale: CGFloat { sizeClass == .regular ? 1.35 : 1 }

    @ViewBuilder
    private func lyricsContent(topInset: CGFloat, bottomInset: CGFloat, horizontalPadding: CGFloat) -> some View {
        switch player.lyricsState {
        case .loaded(let lyrics):
            LyricsView(
                lyrics: lyrics, player: player, settings: settings,
                topInset: topInset, bottomInset: bottomInset,
                horizontalPadding: horizontalPadding, reduced: reduced, fontScale: lyricFontScale,
                onInteraction: { showChrome() },
                onBackgroundTap: { toggleChrome() },
                tapSeeks: chromeVisible || lyricsOnly,
                lowFrameRate: performance.warm
            )
            .id(player.lyricsRevision)
            .overlay(alignment: .topTrailing) {
                if settings.showSyncIndicator {
                    SyncIndicator()
                        .padding(.top, topInset + 6 + syncBadgeOffset)
                        .padding(.trailing, horizontalPadding)
                }
            }
            .transition(.opacity)
        case .loading:
            LyricsSkeleton()
                .padding(.top, topInset)
                .frame(maxHeight: .infinity, alignment: .top)
        case .notFound:
            LyricsNoticeView(notice: player.track?.isLocal == true ? .localTrack : .notFound,
                             onOwnLyrics: { showOwnLyrics = true })
        case .failed(let failure):
            LyricsNoticeView(notice: failure.notice, failure: failure)
        case .unavailable(let notice):
            LyricsNoticeView(notice: notice)
        case .idle:
            idleState
        }
    }

    private var idleState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.quarternote.3")
                .font(.system(size: 44))
            Text(player.statusMessage ?? (player.supportsSpotifyFeatures ? String(localized: "Включите музыку в Spotify") : String(localized: "Включите музыку в Apple Music")))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if player.accessProblem != nil {
                Button {
                    showSetupGuide = true
                } label: {
                    Label(String(localized: "Подключить свой Client ID"), systemImage: "key.horizontal")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color(red: 0.12, green: 0.84, blue: 0.38), in: Capsule())
                        .foregroundStyle(.black)
                }
            } else {
                Button {
                    if let url = spotifyURL { UIApplication.shared.open(url) }
                } label: {
                    Label(player.supportsSpotifyFeatures ? String(localized: "Открыть Spotify") : String(localized: "Открыть Музыку"), systemImage: "arrow.up.forward.app")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The player's two alerts, kept out of its long modifier chain (older compilers took too long
/// to type-check them inline).
private struct NowPlayingAlerts: ViewModifier {
    let pip: LyricsPictureInPicture
    let player: PlayerModel

    private var pipErrorShown: Binding<Bool> {
        Binding(get: { pip.lastError != nil && !pip.isActive }, set: { shown in
            if !shown { pip.clearError() }
        })
    }

    private var transientErrorShown: Binding<Bool> {
        Binding(get: { player.transientError != nil }, set: { shown in
            if !shown { player.transientError = nil }
        })
    }

    func body(content: Content) -> some View {
        content
            .alert(String(localized: "Картинка в картинке"), isPresented: pipErrorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(pip.lastError ?? "")
            }
            .alert(player.playbackSource.title, isPresented: transientErrorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(player.transientError ?? "")
            }
    }
}

/// Placeholder bars while lyrics load (the extension's LyricsSkeleton).
private struct LyricsSkeleton: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(0..<6, id: \.self) { i in
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(pulse ? 0.16 : 0.08))
                    .frame(width: [260, 200, 300, 170, 240, 210][i], height: 30)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
