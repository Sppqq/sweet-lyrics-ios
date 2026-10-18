import QuartzCore
import SwiftUI

/// The scrolling, animated lyrics. One `TimelineView` drives the animator once per frame.
struct LyricsView: View {
    let lyrics: PreparedLyrics
    let player: PlayerModel
    let settings: AppSettings
    /// Height (points) hidden under the header / controls; lyrics fade out before reaching them.
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var horizontalPadding: CGFloat = 24
    /// Go easy on the GPU (Low Power Mode, a hot phone or the user's choice): 30 fps, no line blur.
    var reduced = false
    /// Bigger lyrics on wide screens (iPad), like the extension's `7cqw` font size.
    var fontScale: CGFloat = 1
    /// Any touch or scroll on the lyrics (shows the controls again).
    var onInteraction: () -> Void = {}
    /// A tap on empty space between lines (toggles the controls).
    var onBackgroundTap: () -> Void = {}
    /// Tapping a line seeks to it. Off while the controls are hidden: the first tap only brings
    /// them back, so reaching the buttons from full-screen lyrics never rewinds the song.
    var tapSeeks = true
    /// Seconds added to the TV lyric clock to compensate for picture delay.
    var clockOffset: Double = 0

    @State private var animator: LyricsAnimator
    @State private var userScrolling = false
    @State private var resumeAutoScrollAt: Date = .distantPast
    /// Live two-finger pinch, applied to the font size until the fingers lift.
    @State private var pinchScale: CGFloat = 1
    /// "Reset size" pill after a pinch; each pinch restarts its countdown.
    @State private var showResetSize = false
    @State private var resetSizeTick = 0
    @State private var frameCounter = FrameRateCounter()
    /// Which lines are far enough off screen to skip drawing.
    @State private var culling = LineCulling()

    init(lyrics: PreparedLyrics, player: PlayerModel, settings: AppSettings,
         topInset: CGFloat = 0, bottomInset: CGFloat = 0, horizontalPadding: CGFloat = 24,
         reduced: Bool = false, fontScale: CGFloat = 1,
         onInteraction: @escaping () -> Void = {}, onBackgroundTap: @escaping () -> Void = {},
         tapSeeks: Bool = true, clockOffset: Double = 0) {
        self.lyrics = lyrics
        self.player = player
        self.settings = settings
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.horizontalPadding = horizontalPadding
        self.reduced = reduced
        self.fontScale = fontScale
        self.onInteraction = onInteraction
        self.onBackgroundTap = onBackgroundTap
        self.tapSeeks = tapSeeks
        self.clockOffset = clockOffset
        _animator = State(initialValue: LyricsAnimator(lyrics: lyrics, simple: settings.simpleLyricsMode))
    }

    /// Always the animator's copy, so line indices and visuals can never disagree.
    private var shown: PreparedLyrics { animator.lyrics }

    private func typography(width: CGFloat) -> LyricsTypography {
        LyricsTypography(
            fontSize: clamp(CGFloat(settings.fontSize) * pinchScale, AppSettings.fontRange.lowerBound,
                            AppSettings.fontRange.upperBound) * fontScale,
            cqw: max(width, 1) / 100,
            hasDuets: shown.lines.contains(where: \.oppositeAligned),
            simple: settings.simpleLyricsMode,
            centered: settings.centerLyrics,
            font: LyricsFontChoice(stored: settings.lyricsFont),
            blurScale: CGFloat(settings.blurStrength),
            glowScale: settings.glowStrength,
            inactiveBrightness: settings.inactiveBrightness,
            lineSpacingScale: CGFloat(settings.lineSpacingScale),
            translationScale: CGFloat(settings.translationScale),
            translationBrightness: settings.translationBrightness,
            weight: (LyricsWeight(rawValue: settings.lyricsWeight) ?? .bold).fontWeight
        )
    }

    /// Spicy Lyrics centres the active line in the visible lyrics, 30 px above the middle
    /// (`ScrollTo(..., "Center")` with a 30 px padding). The setting moves it up or down.
    private func anchor(height: CGFloat) -> UnitPoint {
        let visible = max(height - topInset - bottomInset, 1)
        let spot = topInset + visible * CGFloat(clamp(settings.activeLinePosition, 0.2, 0.8))
        return UnitPoint(x: 0.5, y: clamp((spot - 30) / max(height, 1), 0.1, 0.9))
    }

    /// The virtualizer's glide: a critically damped 1 Hz spring (`SMOOTH_SCROLL_FREQUENCY/DAMPING`),
    /// quicker or slower with the setting.
    private var scrollAnimation: Animation {
        .spring(response: 1 / clamp(settings.scrollSpeed, 0.25, 4) * MediaClock.durationScale, dampingFraction: 1)
    }
    /// `USER_SCROLL_COOLDOWN` in ScrollToActiveLine.ts.
    private static let userScrollCooldown: TimeInterval = 0.75

    private var frameInterval: Double {
        if !player.isPlaying { return 1.0 / 15 }
        let target = max(15, settings.lyricsFrameRate)
        return 1 / (reduced ? min(30, target) : target)
    }

    var body: some View {
        GeometryReader { geometry in
            let typography = typography(width: geometry.size.width - horizontalPadding * 2)
            let anchor = anchor(height: geometry.size.height)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    TimelineView(.animation(minimumInterval: frameInterval)) { _ in
                        let now = MediaClock.now()
                        let _ = settings.showLyricsFPS ? frameCounter.tick(now) : ()
                        let _ = animator.step(position: player.position(at: now) + clockOffset, now: now,
                                              blurEnabled: settings.blurInactiveLines && !userScrolling && !reduced,
                                              frameInterval: frameInterval)
                        let focus = animator.focusIndex
                        // Early scroll: the line the scroll follows is the one that starts shortly.
                        let scrollFocus = settings.earlyScroll && shown.kind != .static && !animator.lyrics.lines.isEmpty
                            ? LyricsAnimator.focus(in: animator.lyrics.lines,
                                                   at: player.position(at: now) + clockOffset + settings.earlyScrollMs / 1000)
                            : focus
                        let visuals = animator.visuals

                        let _ = culling.sync(CullingKey(typography: typography, topInset: topInset, bottomInset: bottomInset,
                                                        translated: settings.translateLyrics && !settings.translationReplaces
                                                            ? player.translations.count : -1))
                        LazyVStack(alignment: .leading, spacing: typography.lineSpacing) {
                            ForEach(shown.lines) { line in
                                row(line, visual: visuals[line.id], typography: typography, focus: focus,
                                    viewport: geometry.size.height)
                                    .id(line.id)
                            }
                            // Spicy Lyrics always credits the writers and whoever synced the lyrics.
                            LyricsCreditsView(lyrics: shown, lyricSize: typography.fontSize)
                                .padding(.top, typography.fontSize * 0.45)
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, geometry.size.height * 0.6)
                        // iOS 17 has no scroll phases: a view inside the scroll view watches its pan.
                        .background {
                            if #unavailable(iOS 18.0) { ScrollPanWatcher(onChange: scrollInteraction) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .scrollView) { point in
                            guard inVisibleArea(point.y, viewport: geometry.size.height) else { return }
                            onBackgroundTap()
                        }
                        .onChange(of: scrollFocus) { _, newFocus in
                            guard shown.kind != .static, !userScrolling, Date() >= resumeAutoScrollAt else { return }
                            // After a seek or a gap (back from the background or PiP) jump to the
                            // line: gliding across half the song would show it was ever behind.
                            if animator.snapped {
                                proxy.scrollTo(newFocus, anchor: anchor)
                            } else {
                                withAnimation(scrollAnimation) {
                                    proxy.scrollTo(newFocus, anchor: anchor)
                                }
                            }
                        }
                        // The clock was just checked (app or PiP opened or closed, a stall).
                        .onChange(of: player.snapToken) { _, _ in
                            animator.snapNext()
                            let now = MediaClock.now()
                            animator.step(position: player.position(at: now) + clockOffset, now: now,
                                          blurEnabled: settings.blurInactiveLines && !userScrolling && !reduced)
                            guard shown.kind != .static, !userScrolling else { return }
                            proxy.scrollTo(animator.focusIndex, anchor: anchor)
                        }
                        // The visible area changes when the controls show or hide: re-centre.
                        .onChange(of: anchor.y) { _, _ in
                            guard shown.kind != .static, !userScrolling else { return }
                            withAnimation(scrollAnimation) {
                                proxy.scrollTo(animator.focusIndex, anchor: anchor)
                            }
                        }
                        .task {
                            guard shown.kind != .static else { return }
                            try? await Task.sleep(for: .milliseconds(80))
                            proxy.scrollTo(animator.focusIndex, anchor: anchor)
                        }
                    }
                }
                .modifier(ScrollInteractionObserver(onChange: scrollInteraction))
                .mask(EdgeFade(top: topInset, bottom: bottomInset))
                // Pinch to resize the lyrics; saved when the fingers lift.
                .pinch(enabled: settings.gesturesEnabled) { scale in
                    pinchScale = scale
                } onEnd: { scale in
                    let size = clamp(settings.fontSize * Double(scale), Double(AppSettings.fontRange.lowerBound),
                                     Double(AppSettings.fontRange.upperBound))
                    settings.fontSize = size.rounded()
                    pinchScale = 1
                    if settings.fontSize != AppSettings.defaultFontSize {
                        resetSizeTick += 1
                        withAnimation(.easeOut(duration: 0.2)) { showResetSize = true }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if settings.showLyricsFPS {
                        FPSBadge(counter: frameCounter, target: player.isPlaying ? 1 / frameInterval : 15)
                            .padding(.top, topInset + 6)
                            .padding(.leading, horizontalPadding)
                    }
                }
                .overlay(alignment: .bottom) {
                    if showResetSize {
                        resetSizeButton
                            .padding(.bottom, bottomInset + 16)
                            .transition(.opacity)
                    }
                }
                .task(id: resetSizeTick) {
                    guard showResetSize else { return }
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                    // Fades away slowly, so there is time to notice and tap it.
                    withAnimation(.easeIn(duration: 1.5)) { showResetSize = false }
                }
            }
        }
    }

    /// The user started or stopped dragging the lyrics.
    private func scrollInteraction(_ interacting: Bool) {
        userScrolling = interacting
        if interacting {
            onInteraction()
        } else {
            resumeAutoScrollAt = Date().addingTimeInterval(Self.userScrollCooldown)
        }
    }

    /// Undo an accidental pinch.
    private var resetSizeButton: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                settings.fontSize = AppSettings.defaultFontSize
            }
            withAnimation(.easeOut(duration: 0.25)) { showResetSize = false }
        } label: {
            Label(String(localized: "Сбросить размер"), systemImage: "arrow.uturn.backward")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
    }
}

extension LyricsView {
    /// Lines this far (in screens) beyond the visible area are still drawn: a quick flick must not
    /// outrun them.
    private static let cullMargin: CGFloat = 1.25
    /// The lines around the one being sung are always drawn.
    private static let alwaysDrawn = 3

    /// A touch at this height (in the scroll view's own space) lands in the lyrics you can see,
    /// not under the header or the controls.
    private func inVisibleArea(_ y: CGFloat, viewport: CGFloat) -> Bool {
        y >= topInset && y <= viewport - bottomInset
    }

    /// One line. Far off screen it is an empty box of the same height (so nothing moves), and is
    /// drawn again before it scrolls into view.
    @ViewBuilder
    private func row(_ line: PreparedLine, visual: LineVisual, typography: LyricsTypography,
                     focus: Int, viewport: CGFloat) -> some View {
        Group {
            if abs(line.id - focus) > Self.alwaysDrawn, let height = culling.hiddenHeight(of: line.id) {
                Color.clear.frame(height: height)
            } else {
                LyricLineView(line: line, visual: visual, typography: typography,
                              translation: settings.translateLyrics && !settings.translationReplaces
                                  ? player.translations[line.sourceText] : nil)
                    .equatable()
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .scrollView) { point in
                        guard inVisibleArea(point.y, viewport: viewport) else { return }
                        guard tapSeeks else { return onBackgroundTap() }
                        onInteraction()
                        guard shown.kind != .static else { return }
                        resumeAutoScrollAt = .distantPast
                        player.seekLyrics(to: seekTarget(line))
                    }
                    .contextMenu { lineMenu(line) }
                    // Entirely under the header or the controls: nobody sees it, so it is not
                    // there for taps and long presses either (a scroll still passes through).
                    .allowsHitTesting(culling.isTouchable(line.id))
            }
        }
        .onGeometryChange(for: LineSpot.self) { proxy in
            let frame = proxy.frame(in: .scrollView)
            let margin = viewport * Self.cullMargin
            return LineSpot(height: proxy.size.height,
                            near: frame.maxY > -margin && frame.minY < viewport + margin,
                            touchable: frame.maxY > topInset && frame.minY < viewport - bottomInset)
        } action: { spot in
            culling.record(line.id, spot)
        }
    }

    /// Where to seek so `line` lights up right away: its start, less the user's offset, plus the
    /// headphone delay the clock subtracts (else the line before stayed lit ~200 ms on AirPods).
    private func seekTarget(_ line: PreparedLine) -> Double {
        max(0, line.start - settings.timingOffsetMs / 1000 + player.appliedOutputLatency)
    }

    /// Long press on a line.
    @ViewBuilder
    func lineMenu(_ line: PreparedLine) -> some View {
        if !line.isInterlude {
            if shown.kind != .static {
                Button {
                    player.seekLyrics(to: seekTarget(line))
                } label: {
                    Label(String(localized: "Перемотать сюда"), systemImage: "play.circle")
                }
            }
            Button {
                UIPasteboard.general.string = line.plainText
            } label: {
                Label(String(localized: "Скопировать строку"), systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = shown.lines.filter { !$0.isInterlude }.map(\.plainText).joined(separator: "\n")
            } label: {
                Label(String(localized: "Скопировать весь текст"), systemImage: "doc.on.doc.fill")
            }
            ShareLink(item: line.plainText) {
                Label(String(localized: "Поделиться строкой"), systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// Where a line is relative to the scroll view.
private struct LineSpot: Equatable {
    var height: CGFloat
    /// Within (or close to) the visible area.
    var near: Bool
    /// At least partly in the part of the screen the header and controls leave free.
    var touchable: Bool
}

/// What the lines' heights depend on besides the text: when it changes, the remembered heights
/// are stale and every line is drawn (and measured) again.
private struct CullingKey: Equatable {
    var typography: LyricsTypography
    /// Which lines are under the header and controls follows them.
    var topInset: CGFloat
    var bottomInset: CGFloat
    var translated: Int
}

/// Remembers each line's height and whether it is near the screen, so far-away lines can be
/// swapped for an empty box. Read once per frame by the lyrics view; not observable on purpose.
private final class LineCulling {
    private var heights: [Int: CGFloat] = [:]
    private var far: Set<Int> = []
    private var hidden: Set<Int> = []
    private var key: CullingKey?

    func sync(_ key: CullingKey) {
        guard key != self.key else { return }
        self.key = key
        heights.removeAll()
        far.removeAll()
        hidden.removeAll()
    }

    func record(_ id: Int, _ spot: LineSpot) {
        heights[id] = spot.height
        if spot.near { far.remove(id) } else { far.insert(id) }
        if spot.touchable { hidden.remove(id) } else { hidden.insert(id) }
    }

    func isTouchable(_ id: Int) -> Bool { !hidden.contains(id) }

    /// The height to keep free for a line that is far away and measured; nil when it must be drawn.
    func hiddenHeight(of id: Int) -> CGFloat? {
        far.contains(id) ? heights[id] : nil
    }
}

/// Pauses auto-scroll while the user drags the lyrics. iOS 18 reports the scroll phase; on iOS 17
/// the scroll view's own pan gesture is watched (without it, the next line yanked the lyrics back
/// mid-drag).
private struct ScrollInteractionObserver: ViewModifier {
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { oldPhase, newPhase in
                switch newPhase {
                case .interacting, .tracking:
                    onChange(true)
                case .idle:
                    // Only a user scroll coming to rest counts, not our own scrollTo animation.
                    switch oldPhase {
                    case .interacting, .tracking, .decelerating:
                        onChange(false)
                    default:
                        break
                    }
                default:
                    break
                }
            }
        } else {
            content
        }
    }
}

/// iOS 17: finds the enclosing UIScrollView and follows its pan gesture and deceleration.
private struct ScrollPanWatcher: UIViewRepresentable {
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WatcherView, context: Context) {
        view.onChange = onChange
    }

    final class WatcherView: UIView {
        var onChange: (Bool) -> Void = { _ in }
        private weak var scrollView: UIScrollView?
        private var settleTimer: Timer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, scrollView == nil else { return }
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            guard let found = view as? UIScrollView else { return }
            scrollView = found
            found.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                settleTimer?.invalidate()
                onChange(true)
            case .ended, .cancelled, .failed:
                waitForRest()
            default:
                break
            }
        }

        /// The flick coasts on after the finger lifts: done once it stops.
        private func waitForRest() {
            settleTimer?.invalidate()
            settleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                if self.scrollView?.isDecelerating != true {
                    timer.invalidate()
                    self.onChange(false)
                }
            }
        }
    }
}

/// Soft fade at the top and bottom like the extension's `--ImageMask`. The clear bands follow the
/// header and controls, so lyrics never run underneath them (and animate with them).
private struct EdgeFade: View {
    var top: CGFloat
    var bottom: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(0, top))
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 56)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 72)
            Color.clear.frame(height: max(0, bottom))
        }
    }
}

/// The block after the last line, in Spicy Lyrics' order and wording (`ApplyLyricsCredits.ts`,
/// `ApplyProvider.ts`, `ApplyIsByCommunity.tsx`): writers, provider, then the community sync's
/// maker and uploader. Sizes follow Mixed.css relative to the lyric size.
private struct LyricsCreditsView: View {
    let lyrics: PreparedLyrics
    let lyricSize: CGFloat

    private var credits: LyricsCredits { lyrics.credits }
    /// A little larger than on desktop, for a phone screen (as the Android port does).
    private var small: CGFloat { max(12, lyricSize * 0.34 * 1.2) }

    var body: some View {
        VStack(alignment: .leading, spacing: lyricSize * 0.25) {
            if !lyrics.songwriters.isEmpty {
                Text("Written by: " + lyrics.songwriters.joined(separator: ", "))
                    .font(.system(size: max(14, lyricSize * 0.47), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let provider = credits.providedBy {
                Text("Provided by: " + provider)
                    .font(.system(size: small, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            if credits.isCommunity == true, credits.maker != nil || credits.uploader != nil {
                Text("These lyrics have been provided by our community")
                    .font(.system(size: small, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            if let maker = credits.maker {
                ContributorRow(role: "Made by", contributor: maker, size: small)
            }
            if let uploader = credits.uploader {
                ContributorRow(
                    role: credits.maker != nil ? "Uploaded by" : (credits.isCommunity == true ? "Made by" : "Submitted by"),
                    contributor: uploader,
                    size: small
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Made by @name" with the avatar after it; tapping opens the Spicy Lyrics profile.
private struct ContributorRow: View {
    let role: String
    let contributor: LyricsContributor
    let size: CGFloat
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 4) {
            (Text(role + " ").foregroundStyle(.white.opacity(0.6))
                + Text("@" + contributor.name).bold().underline().foregroundStyle(.white.opacity(0.75)))
                .font(.system(size: size, weight: .semibold))
            if let avatar = contributor.avatarURL {
                AsyncImage(url: avatar) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.1)
                }
                .frame(width: size * 1.4, height: size * 1.4)
                .clipShape(Circle())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = contributor.profileURL { openURL(url) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(contributor.profileURL != nil ? .isLink : [])
    }
}
