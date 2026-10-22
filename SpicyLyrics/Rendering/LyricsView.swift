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
    /// Seconds added to the clock (the TV shows its picture later than the sound plays).
    var clockOffset: Double = 0
    /// At most 30 fps (the phone is warm).
    var lowFrameRate = false

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
    /// The line held down: its actions show in a menu over the lyrics, outside the per-frame
    /// timeline. A context menu on the line itself was rebuilt every frame, and its buttons did nothing.
    @State private var held: HeldLine?
    /// The line under a finger that may become a long press: it gives a little.
    @State private var pressedLine: Int?
    @State private var menuTick = 0
    /// "Что это значит?" from the line's menu.
    @State private var explainRequest: ExplainRequest?

    init(lyrics: PreparedLyrics, player: PlayerModel, settings: AppSettings,
         topInset: CGFloat = 0, bottomInset: CGFloat = 0, horizontalPadding: CGFloat = 24,
         reduced: Bool = false, fontScale: CGFloat = 1,
         onInteraction: @escaping () -> Void = {}, onBackgroundTap: @escaping () -> Void = {},
         tapSeeks: Bool = true, clockOffset: Double = 0, lowFrameRate: Bool = false) {
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
        self.lowFrameRate = lowFrameRate
        _animator = State(initialValue: LyricsAnimator(lyrics: lyrics, simple: settings.simpleLyricsMode,
                                                       minimal: settings.minimalLyricsMode,
                                                       refreshed: settings.refreshedSimpleLyrics))
    }

    private var animatorOptions: LyricsAnimator.Options {
        LyricsAnimator.Options(keepOverlapping: settings.keepOverlappingLines,
                               // Only in the refreshed layout (6.4.70); it animates the same with
                               // reduced motion on.
                               popOut: settings.backgroundLinePop && settings.simpleLyricsMode
                                   && settings.refreshedSimpleLyrics)
    }

    /// Always the animator's copy, so line indices and visuals can never disagree.
    private var shown: PreparedLyrics { animator.lyrics }

    private func typography(width: CGFloat) -> LyricsTypography {
        LyricsTypography(
            fontSize: clamp(CGFloat(settings.fontSize) * pinchScale, AppSettings.fontRange.lowerBound,
                            AppSettings.fontRange.upperBound) * fontScale,
            cqw: max(width, 1) / 100,
            hasDuets: settings.duetLinePadding && shown.lines.contains(where: \.oppositeAligned),
            simple: settings.simpleLyricsMode,
            centered: settings.centerLyrics,
            font: LyricsFontChoice(stored: settings.lyricsFont),
            blurScale: CGFloat(settings.blurStrength),
            glowScale: settings.glowStrength,
            inactiveBrightness: settings.inactiveBrightness,
            lineSpacingScale: CGFloat(settings.lineSpacingScale),
            translationScale: CGFloat(settings.translationScale),
            translationBrightness: settings.translationBrightness,
            weight: (LyricsWeight(rawValue: settings.lyricsWeight) ?? .bold).fontWeight,
            refreshed: animator.refreshed
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
        // Unsynced lyrics never move by themselves: a few frames a second notice a seek.
        if shown.kind == .static { return 1.0 / 4 }
        if !player.isPlaying { return 1.0 / 15 }
        var target = max(15, settings.lyricsFrameRate)
        // Line by line, only a slow sweep moves between lines (the scroll is Core Animation's
        // own, at the screen's rate): 30 fps looks the same and costs half.
        if reduced || lowFrameRate || shown.kind == .line { target = min(30, target) }
        return 1 / target
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
                                              frameInterval: frameInterval, options: animatorOptions)
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
                        // No spacing of its own: each row brings the gap above it (see `ownsGap`).
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(shown.lines) { line in
                                row(line, visual: visuals[line.id], typography: typography, focus: focus,
                                    viewport: geometry.size.height)
                                    .id(line.id)
                            }
                            // Spicy Lyrics always credits the writers and whoever synced the lyrics.
                            LyricsCreditsView(lyrics: shown, lyricSize: typography.fontSize,
                                              refined: settings.refinedCredits,
                                              followLastLine: settings.creditsFollowLastLine && !settings.centerLyrics,
                                              allSung: shown.kind == .static
                                                  || player.position(at: now) + clockOffset >= (shown.lines.last?.end ?? 0))
                                .padding(.top, typography.lineSpacing)
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
                            // Smooth Scrolling off: the lyrics jump to the line, like the extension's default.
                            if animator.snapped || !settings.smoothScrolling {
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
                                          blurEnabled: settings.blurInactiveLines && !userScrolling && !reduced,
                                          options: animatorOptions)
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
                // The held line's menu: everything behind it goes soft.
                .blur(radius: held == nil ? 0 : 12)
                .scaleEffect(held == nil ? 1 : 0.985)
                .animation(.spring(response: 0.42, dampingFraction: 0.85), value: held == nil)
                .overlay {
                    if let held {
                        LineActionMenu(held: held, font: typography.leadFont, centered: settings.centerLyrics,
                                       canSeek: shown.kind != .static,
                                       canExplain: player.track.flatMap { ExplainRequest(track: $0, lyrics: shown, line: held.line) } != nil,
                                       topInset: topInset, bottomInset: bottomInset,
                                       onAction: { perform($0, on: held.line) },
                                       onDismiss: { self.held = nil })
                    }
                }
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
                        FPSBadge(counter: frameCounter, target: 1 / frameInterval)
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
        .sensoryFeedback(.impact(weight: .medium), trigger: menuTick)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: pressedLine) { _, new in new != nil }
        #if DEBUG
        // `-demoHoldLine <n>`: the n-th line with words in it, held, for screenshots.
        .task {
            guard let n = UserDefaults.standard.object(forKey: "demoHoldLine") as? Int ?? Int(UserDefaults.standard.string(forKey: "demoHoldLine") ?? "") else { return }
            try? await Task.sleep(for: .seconds(4))
            let words = shown.lines.filter { !$0.isInterlude }
            guard words.indices.contains(n), let frame = culling.frame(of: words[n].id) else { return }
            menuTick += 1
            held = HeldLine(line: words[n], frame: frame)
        }
        #endif
        .sheet(item: $explainRequest) { request in
            LineExplanationView(request: request)
                .environment(player)
                .environment(settings)
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
                .glassCapsule(.pressable)
        }
        .buttonStyle(.plain)
    }
}

extension LyricsView {
    /// Lines this far (in screens) beyond the visible area are still drawn: a quick flick must not
    /// outrun them.
    private static let cullMargin: CGFloat = 0.8
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
                                  ? player.translations[line.sourceText] : nil,
                              ownsGap: true)
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
                    // Held: it gives a little under the finger, then lifts out into its menu.
                    .scaleEffect(pressedLine == line.id ? 0.955 : 1, anchor: pressAnchor(line))
                    .brightness(pressedLine == line.id ? 0.08 : 0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.62), value: pressedLine == line.id)
                    .onLongPressGesture(minimumDuration: 0.4) {
                        guard !line.isInterlude, let frame = culling.frame(of: line.id) else { return }
                        onInteraction()
                        menuTick += 1
                        pressedLine = nil
                        held = HeldLine(line: line, frame: frame)
                    } onPressingChanged: { pressing in
                        guard !line.isInterlude else { return }
                        if pressing {
                            pressedLine = line.id
                        } else if pressedLine == line.id {
                            pressedLine = nil
                        }
                    }
                    // Entirely under the header or the controls: nobody sees it, so it is not
                    // there for taps and long presses either (a scroll still passes through).
                    .allowsHitTesting(culling.isTouchable(line.id))
            }
        }
        .onGeometryChange(for: LineSpot.self) { proxy in
            let frame = proxy.frame(in: .scrollView)
            culling.note(line.id, frame: frame)
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
    /// The player fades audio in for about this long after a seek, so landing exactly on a
    /// line's start swallows its first syllable on faster songs (Spicy Lyrics' `SeekToLineStart`).
    private static let seekFadeCompensation: Double = 0.3

    private func seekTarget(_ line: PreparedLine) -> Double {
        let lead = settings.seekFadeCompensation ? Self.seekFadeCompensation : 0
        return max(0, line.start - lead - settings.timingOffsetMs / 1000 + player.appliedOutputLatency)
    }

    /// The held line shrinks towards its own side.
    private func pressAnchor(_ line: PreparedLine) -> UnitPoint {
        if settings.centerLyrics { return .center }
        return line.oppositeAligned ? .trailing : .leading
    }

    /// One of the held line's menu actions.
    private func perform(_ action: LineAction, on line: PreparedLine) {
        switch action {
        case .explain:
            explainRequest = player.track.flatMap { ExplainRequest(track: $0, lyrics: shown, line: line) }
        case .seek:
            resumeAutoScrollAt = .distantPast
            player.seekLyrics(to: seekTarget(line))
        case .copy:
            UIPasteboard.general.string = line.plainText
        case .copyAll:
            UIPasteboard.general.string = shown.lines.filter { !$0.isInterlude }.map(\.plainText).joined(separator: "\n")
        case .share:
            ShareSheet.present(line.plainText)
        }
    }
}

/// The system share sheet over whatever is on screen.
enum ShareSheet {
    @MainActor
    static func present(_ text: String) {
        let scene = UIApplication.shared.connectedScenes
            .filter { $0.session.role == .windowApplication }
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        // iPad: from the middle of the screen.
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY,
                                                                width: 0, height: 0)
        sheet.popoverPresentationController?.permittedArrowDirections = []
        top.present(sheet, animated: true)
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

    /// Where each drawn line is in the scroll view's visible space; read when one is held.
    private var frames: [Int: CGRect] = [:]

    func note(_ id: Int, frame: CGRect) { frames[id] = frame }
    func frame(of id: Int) -> CGRect? { frames[id] }

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
    /// The extension's "Refined Credits" experiment (on by default since 6.4).
    var refined = true
    /// "Credits Follow the Last Singer": a song ending on a duet line sung from the right.
    var followLastLine = false
    /// The refined credits stay dim, like a line still to come, until the last line is sung.
    var allSung = true

    private var credits: LyricsCredits { lyrics.credits }
    /// A little larger than on desktop, for a phone screen (as the Android port does).
    private var small: CGFloat { max(12, lyricSize * 0.34 * 1.2) }
    private var trailing: Bool {
        followLastLine && (lyrics.lines.last { !$0.isInterlude && !$0.isBackground }?.oppositeAligned ?? false)
    }

    var body: some View {
        if refined {
            let size = max(14, lyricSize * 0.34 * 1.2)
            RefinedCreditsView(lyrics: lyrics, size: size, trailing: trailing)
                .opacity(allSung ? 1 : 0.55)
                .animation(.easeOut(duration: 0.4), value: allSung)
                // Closer to the last line than the old lines: the song's footnote.
                .padding(.top, size * 0.75)
        } else {
            legacy.padding(.top, lyricSize * 0.45)
        }
    }

    private var legacy: some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: lyricSize * 0.25) {
            if !lyrics.songwriters.isEmpty {
                Text("Written by: " + lyrics.songwriters.joined(separator: ", "))
                    .font(.system(size: max(14, lyricSize * 0.47), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let provider = credits.providedBy {
                Text("Provided by: " + provider + (credits.via.map { " Via " + $0 } ?? ""))
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
        .multilineTextAlignment(trailing ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}

/// Spicy Lyrics' refined credits (Mixed.css, `.Exp_RefinedCredits .SongCredits`): no box, the
/// songwriters, then the source on a smaller second line, or for community lyrics "Community
/// lyrics · Made by @maker · Uploaded by @uploader". Labels at 55% of white, names at 70%.
private struct RefinedCreditsView: View {
    let lyrics: PreparedLyrics
    let size: CGFloat
    let trailing: Bool
    @Environment(\.openURL) private var openURL

    private static let text = Color.white.opacity(0.7)
    private static let muted = Color.white.opacity(0.55)

    private var credits: LyricsCredits { lyrics.credits }
    private var secondary: CGFloat { max(size * 0.86, 12) }
    private var alignment: HorizontalAlignment { trailing ? .trailing : .leading }
    /// Community lyrics name their source in the community line, so "Provided by" goes.
    private var community: Bool {
        credits.isCommunity == true && (credits.maker != nil || credits.uploader != nil)
    }

    var body: some View {
        VStack(alignment: alignment, spacing: size * 0.3) {
            if !lyrics.songwriters.isEmpty {
                (Text("Written by ").foregroundColor(Self.muted)
                    + Text(lyrics.songwriters.joined(separator: ", ")).foregroundColor(Self.text))
                    .font(.system(size: size, weight: .semibold))
            }
            if community {
                communityLine
            } else if let provider = credits.providedBy {
                Text(providerLine(provider))
                    .font(.system(size: secondary, weight: .medium))
            }
        }
        .lineSpacing(size * 0.1)
        .multilineTextAlignment(trailing ? .trailing : .leading)
        // A footnote's measure, so a long list of songwriters doesn't run the full lyrics width.
        .frame(maxWidth: size * 46, alignment: Alignment(horizontal: alignment, vertical: .center))
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }

    /// "Provided by Apple Music via lrc.red", only the source's link underlined.
    private func providerLine(_ provider: String) -> AttributedString {
        var line = AttributedString("Provided by " + provider)
        line.swiftUI.foregroundColor = Self.muted
        if let via = credits.via {
            var label = AttributedString(" via ")
            label.swiftUI.foregroundColor = Self.muted
            var link = AttributedString(via)
            link.swiftUI.foregroundColor = Self.text
            if let url = credits.viaURL {
                link.link = url
                link.swiftUI.underlineStyle = Text.LineStyle(pattern: .solid, color: .white.opacity(0.7 * 0.35))
            }
            line += label + link
        }
        return line
    }

    /// Each person stays whole on one line; the dot before them separates, outside the link.
    private var communityLine: some View {
        FlowLayout(alignment: alignment, spacing: 0, rowSpacing: size * 0.3) {
            Text("Community lyrics").foregroundColor(Self.muted)
            if let maker = credits.maker {
                person("Made by", maker)
            }
            if let uploader = credits.uploader {
                person(credits.maker != nil ? "Uploaded by" : "Made by", uploader)
            }
        }
        .font(.system(size: secondary, weight: .medium))
    }

    /// The dot, the role, the avatar, then the name; only the name reads as a link.
    private func person(_ role: String, _ contributor: LyricsContributor) -> some View {
        HStack(spacing: secondary * 0.3) {
            Text("\u{00B7}").foregroundColor(Self.muted)
                .padding(.horizontal, secondary * 0.15)
            Text(role).foregroundColor(Self.muted)
            if let avatar = contributor.avatarURL {
                AsyncImage(url: avatar) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.1)
                }
                .frame(width: secondary * 1.15, height: secondary * 1.15)
                .clipShape(Circle())
                .opacity(0.85)
            }
            Text("@" + contributor.name)
                .fontWeight(.semibold)
                .foregroundColor(Self.text)
                .underline(color: .white.opacity(0.7 * 0.35))
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = contributor.profileURL { openURL(url) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(contributor.profileURL != nil ? .isLink : [])
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
