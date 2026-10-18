import Foundation
import QuartzCore

enum ElementState: Equatable {
    case notSung, active, sung

    init(_ time: Double, _ start: Double, _ end: Double) {
        if time < start { self = .notSung } else if time >= end { self = .sung } else { self = .active }
    }
}

@inline(__always) private func progress(_ time: Double, _ start: Double, _ end: Double) -> Double {
    if time <= start { return 0 }
    if time >= end { return 1 }
    return (time - start) / (end - start)
}

// MARK: - Visual output (what the views draw)

/// Transform + paint of one glyph run (a syllable, a letter or a dot).
struct GlyphVisual: Equatable {
    var scale: Double = 1
    /// Vertical offset as a fraction of the font size.
    var yOffset: Double = 0
    /// 0…1+ glow strength, mapped to a shadow per element kind.
    var glow: Double = 0
    /// Left edge of the fill gradient as a fraction of the glyph width (-0.2 = unlit, 1 = lit).
    var gradient: Double = -0.2
    var opacity: Double = 1
}

struct SyllableVisual: Equatable {
    var glyph = GlyphVisual()
    /// Per-letter visuals for emphasized syllables, empty otherwise.
    var letters: [GlyphVisual] = []
}

struct LineVisual: Equatable {
    var state: ElementState = .notSung
    var opacity: Double = 0.51
    var blur: Double = 0
    /// Whole-line scale (line-synced lines grow to 1.05 while active).
    var scale: Double = 1
    /// Syllable-synced lines: `[word][syllable]`.
    var lead: [[SyllableVisual]] = []
    var background: [[SyllableVisual]] = []
    /// Line-synced lines.
    var line = GlyphVisual()
    /// Interlude dots. An interlude row only takes up space while active (`presence` 0/1);
    /// its dot group pops in and out with `dotGroupScale`.
    var dots: [GlyphVisual] = []
    var presence: Double = 1
    var dotGroupScale: Double = 0
}

// MARK: - Animation curves (values from Spicy Lyrics' LyricsAnimator.ts)

private enum Curves {
    static let scale = CubicSpline([(0, 0.95), (0.7, 1.0505), (1, 1)])
    static let yOffset = CubicSpline([(0, 1.0 / 100), (0.9, -(1.0 / 60)), (1, 0)])
    static let glow = CubicSpline([(0, 0), (0.15, 1), (0.6, 1), (1, 0)])
    static let letterScale = CubicSpline([(0, 0.95), (0.7, 1.175), (1, 1)])
    static let letterYOffset = CubicSpline([(0, 1.0 / 100), (0.9, -(1.0 / 56)), (1, 0)])
    static let lineGlow = CubicSpline([(0, 0), (0.5, 1), (1, 0)])

    static let dotScale = CubicSpline([(0, 0.75), (0.7, 1.05), (1, 1)])
    static let dotYOffset = CubicSpline([(0, 0), (0.9, -0.12), (1, 0)])
    static let dotGlow = CubicSpline([(0, 0), (0.6, 1), (1, 1)])
    static let dotOpacity = CubicSpline([(0, 0.35), (0.6, 1), (1, 1)])

    static let sungLetterGlow = glow.at(0.2)

    // Simple Lyrics Mode (`$simpleLyricsMode`): words only drift up, letters get milder curves
    // scaled by `SimpleLyricsMode_LetterEffectsStrengthConfig`, dots only fade.
    static let simpleYOffset = CubicSpline([(0, 1.0 / 100), (1, -0.033)])
    static let simpleLetterScale = CubicSpline([(0, 0.95), (0.7, 1.07), (1, 1)])
    static let simpleLetterYOffset = CubicSpline([(0, 1.0 / 100), (0.9, -(1.0 / 62)), (1, 0)])
    static let simpleDotOpacity = CubicSpline([(0, 0.27), (0.6, 1), (1, 1)])
    /// `Animate()` runs Simple Lyrics Mode 33.5 ms behind.
    static let simplePositionOffset = -0.0335
    static let simpleLongerThan = 1.5
    static let simpleLonger = (glow: 0.4, yOffset: 0.45, scale: 1.103)
    static let simpleShorter = (glow: 0.285, yOffset: 0.1, scale: 1.09)

    // Spring tuning.
    static let yOffsetFrequency = 1.45, yOffsetDamping = 0.4
    static let scaleFrequency = 0.88, scaleDamping = 0.64
    static let glowFrequency = 1.18, glowDamping = 0.56

    // Line states (Mixed.css).
    static let notSungOpacity = 0.51
    static let activeOpacity = 1.0
    static let sungOpacity = 0.497
    /// `.line.Active + .line.Sung` (a line overlapped by the active one) when line blur is on.
    static let sungAfterActiveOpacity = 0.45
    static let blurMultiplier = 1.25
    static var maxBlur: Double { blurMultiplier * 5 + blurMultiplier * 0.465 }

    // CSS transitions (Mixed.css).
    /// `.line { transition: opacity 0.2s cubic-bezier(0.61, 1, 0.88, 1) }`
    static let lineOpacity = (duration: 0.2, easing: Easing.cubicBezier(0.61, 1, 0.88, 1))
    /// Line-synced `.line { transition: scale/opacity 0.2s cubic-bezier(0.37, 0, 0.63, 1) }`
    static let lineSynced = (duration: 0.2, easing: Easing.cubicBezier(0.37, 0, 0.63, 1))
    static let activeLineSyncedScale = 1.05
    /// `.musical-line { transition: opacity 0.14s }`
    static let interludeOpacity = (duration: 0.14, easing: Easing.ease)
    /// `.dotGroup { transition: scale 0.3s }`
    static let dotsIn = (duration: 0.3, easing: Easing.ease)
    /// `.musical-line:is(.pre-hidden, :not(.Active)) .dotGroup`: a small wind-up, then gone.
    static let dotsOut = (duration: 0.4, easing: Easing.linearPoints([
        (0, 0), (0.094, -0.006), (0.18, -0.029), (0.433, -0.157), (0.514, -0.185), (0.559, -0.189),
        (0.60, -0.182), (0.639, -0.163), (0.676, -0.133), (0.723, -0.074), (0.767, 0.006),
        (0.85, 0.238), (0.927, 0.566), (1, 1),
    ]))
    /// The dots start hiding this long before the interlude ends (`preHiddenDotLineMs`).
    static let preHiddenDots = 0.5
}

// MARK: - Spring bundles

private struct GlyphSprings {
    var scale: Spring
    var yOffset: Spring
    var glow: Spring

    init(scale: Double, yOffset: Double, glow: Double,
         scaleFrequency: Double = Curves.scaleFrequency, scaleDamping: Double = Curves.scaleDamping,
         yFrequency: Double = Curves.yOffsetFrequency, yDamping: Double = Curves.yOffsetDamping,
         glowFrequency: Double = Curves.glowFrequency, glowDamping: Double = Curves.glowDamping) {
        self.scale = Spring(scale, frequency: scaleFrequency, damping: scaleDamping)
        self.yOffset = Spring(yOffset, frequency: yFrequency, damping: yDamping)
        self.glow = Spring(glow, frequency: glowFrequency, damping: glowDamping)
    }

    mutating func step(scale s: Double, yOffset y: Double, glow g: Double, dt: Double) -> (Double, Double, Double) {
        scale.setGoal(s)
        yOffset.setGoal(y)
        glow.setGoal(g)
        return (scale.step(dt), yOffset.step(dt), glow.step(dt))
    }

    var isSettled: Bool { scale.canSleep && yOffset.canSleep && glow.canSleep }
}

private struct SyllableSprings {
    var glyph: GlyphSprings
    var letters: [GlyphSprings]
}

private struct DotSprings {
    var glyph: GlyphSprings
    var opacity: Spring
}

/// Scale that eases in with one curve and out with another (the interlude's dot group).
private struct InOutTween {
    private var tween = Tween(0, duration: Curves.dotsOut.duration, easing: Curves.dotsOut.easing)
    private var showing = false

    mutating func update(show: Bool, now: Double, snap: Bool) -> Double {
        if show != showing {
            showing = show
            let spec = show ? Curves.dotsIn : Curves.dotsOut
            tween = Tween(tween.value, duration: spec.duration, easing: spec.easing)
        }
        return tween.update(to: show ? 1 : 0, now: now, snap: snap)
    }

    var isSettled: Bool { tween.isSettled }
}

private struct LineSprings {
    var opacity: Tween
    var scale: Tween
    var glow: Spring
    var dotGroup = InOutTween()
    var lead: [[SyllableSprings]]
    var background: [[SyllableSprings]]
    var dots: [DotSprings]
    /// False once a line is off-stage and every spring has come to rest: it is skipped until
    /// its state changes again. Most of a song is asleep at any moment.
    var awake = true
    var lastState: ElementState?
}

// MARK: - Animator

/// Per-frame state machine for the lyrics. Not observable on purpose: the lyrics view's
/// `TimelineView` drives it once per frame and reads the resulting `visuals`.
final class LyricsAnimator {
    let lyrics: PreparedLyrics
    /// Simple Lyrics Mode.
    let simple: Bool
    private(set) var visuals: [LineVisual]
    /// The line the view should keep in focus (scroll target and blur origin).
    private(set) var focusIndex: Int = 0

    private var springs: [LineSprings]
    private var lastFrame: CFTimeInterval?
    private var lastPosition: Double?
    /// The last step jumped to the clock instead of animating (a seek, a resume, `snapNext()`).
    private(set) var snapped = true
    /// Smoothed time between frames actually drawn.
    private var frameTime: Double?
    private var expectedFrameTime: Double?
    /// Seconds the lyrics run ahead of the clock while frames come slower than asked for.
    private(set) var presentationLead: Double = 0

    /// A frame computed at `now` reaches the screen about one frame time later and stays there
    /// for another frame time. At the requested rate that delay is what the sync was set up with;
    /// when frames drop (a hot phone, a busy main thread) it grows, and the words fall behind
    /// the sound. Run ahead by the extra so they stay on time.
    private func updateLead(dt: Double, expected: Double?) {
        guard let expected, dt > 0.006, dt < 0.4 else { return }
        // A new rate (paused at 15 fps, playing again at 60): start from it, not from the old one.
        if expected != expectedFrameTime {
            expectedFrameTime = expected
            frameTime = expected
            presentationLead = 0
            return
        }
        let smoothed = frameTime.map { $0 + (dt - $0) * (dt > $0 ? 0.3 : 0.08) } ?? dt
        frameTime = smoothed
        presentationLead = clamp(1.5 * (smoothed - expected * 1.1), 0, 0.15)
    }

    /// The next step jumps straight to the clock (it was just checked and may have moved).
    func snapNext() { lastPosition = nil }

    init(lyrics: PreparedLyrics, simple: Bool = false) {
        self.lyrics = lyrics
        self.simple = simple
        springs = lyrics.lines.map(Self.makeSprings)
        visuals = lyrics.lines.map(Self.makeVisual)
    }

    /// Advances every spring to `position` (seconds). Safe to call more than once per frame.
    /// `frameInterval` is the frame time the caller asked for: frames coming slower than that
    /// move the lyrics ahead by the extra delay before they are seen (nil: no compensation).
    func step(position: Double, now: CFTimeInterval, blurEnabled: Bool, frameInterval: Double? = nil) {
        var dt = lastFrame.map { now - $0 } ?? (1.0 / 60)
        if dt <= 0 { return }
        updateLead(dt: dt, expected: frameInterval)
        let position = position + presentationLead + (simple ? Curves.simplePositionOffset : 0)
        // No frames for a while (the app or the floating window was hidden, the phone stalled):
        // whatever the springs were doing is stale, so snap like after a seek.
        let resumed = dt > 0.4
        // The springs are solved exactly for any step, so a slow frame takes its whole length:
        // capping it (it used to stop at 1/15 s) made them lag further behind the lower the fps.
        dt = min(dt, 0.25)
        // A seek: snap everything instead of animating across the whole song.
        let jumped = resumed || lastPosition.map { abs(position - $0) > 1.5 } ?? true
        lastFrame = now
        lastPosition = position
        snapped = jumped

        if lyrics.kind == .static {
            guard jumped else { return }
            for index in visuals.indices {
                visuals[index].state = .active
                visuals[index].opacity = 1
                visuals[index].blur = 0
                visuals[index].line.gradient = 1
            }
            return
        }

        focusIndex = Self.focus(in: lyrics.lines, at: position)
        var previousActive = false

        for index in lyrics.lines.indices {
            let line = lyrics.lines[index]
            var lineSprings = springs[index]
            let state = ElementState(position, line.start, line.end)
            if lineSprings.lastState != state || jumped { lineSprings.awake = true }
            lineSprings.lastState = state

            // Line level: opacity (a CSS transition) and the distance blur (set directly).
            var targetOpacity: Double
            switch state {
            case .notSung: targetOpacity = Curves.notSungOpacity
            case .active: targetOpacity = Curves.activeOpacity
            case .sung: targetOpacity = Curves.sungOpacity
            }
            if state == .sung, previousActive, blurEnabled, !line.isInterlude {
                targetOpacity = Curves.sungAfterActiveOpacity
            }
            if !line.isInterlude { previousActive = state == .active }

            let distance = abs(index - focusIndex)
            let blur = (!blurEnabled || state == .active || distance == 0)
                ? 0 : min(Curves.blurMultiplier * Double(distance), Curves.maxBlur)

            var visual = visuals[index]
            visual.state = state
            visual.blur = blur

            switch line.kind {
            case .syllable(let lead, let background):
                visual.opacity = lineSprings.opacity.update(to: targetOpacity, now: now, snap: jumped)
                if lineSprings.awake {
                    let settledLead = stepWords(lead, springs: &lineSprings.lead, into: &visual.lead,
                                                time: position, dt: dt, snap: jumped)
                    let settledBackground = stepWords(background, springs: &lineSprings.background,
                                                      into: &visual.background, time: position, dt: dt, snap: jumped)
                    if state != .active, settledLead, settledBackground { lineSprings.awake = false }
                }

            case .line:
                visual.opacity = lineSprings.opacity.update(to: targetOpacity, now: now, snap: jumped)
                visual.scale = lineSprings.scale.update(
                    to: state == .active ? Curves.activeLineSyncedScale : 1, now: now, snap: jumped)
                if lineSprings.awake {
                    let p = progress(position, line.start, line.end)
                    let targetGlow: Double
                    switch state {
                    case .active:
                        targetGlow = Curves.lineGlow.at(p)
                        visual.line.gradient = p
                    case .notSung:
                        targetGlow = Curves.lineGlow.at(0)
                        visual.line.gradient = -0.2
                    case .sung:
                        targetGlow = Curves.lineGlow.at(1)
                        visual.line.gradient = 1
                    }
                    lineSprings.glow.setGoal(simple ? 0 : targetGlow, replacePosition: jumped)
                    visual.line.glow = lineSprings.glow.step(dt)
                    if state != .active, lineSprings.glow.canSleep { lineSprings.awake = false }
                }

            case .interlude(let dots):
                // Only takes up space while active; fades in and out over 0.14s.
                visual.presence = state == .active ? 1 : 0
                visual.opacity = lineSprings.opacity.update(to: state == .active ? 1 : 0, now: now, snap: jumped)
                let preHidden = position > line.end - Curves.preHiddenDots
                visual.dotGroupScale = lineSprings.dotGroup.update(
                    show: state == .active && !preHidden, now: now, snap: jumped)
                if lineSprings.awake {
                    var settled = lineSprings.dotGroup.isSettled
                    for (k, dot) in dots.enumerated() {
                        let p: Double
                        switch ElementState(position, dot.start, dot.end) {
                        case .notSung: p = 0
                        case .active: p = progress(position, dot.start, dot.end)
                        case .sung: p = 1
                        }
                        var s = lineSprings.dots[k]
                        if simple {
                            // Simple mode: the dots only fade in.
                            let opacityTarget = Curves.simpleDotOpacity.at(p)
                            s.opacity.setGoal(opacityTarget, replacePosition: jumped)
                            let opacity = s.opacity.step(dt)
                            settled = settled && s.opacity.canSleep
                            lineSprings.dots[k] = s
                            visual.dots[k] = GlyphVisual(scale: 1, yOffset: 0, glow: 0, gradient: 1, opacity: opacity)
                            continue
                        }
                        if jumped {
                            s.glyph.scale.setGoal(Curves.dotScale.at(p), replacePosition: true)
                            s.glyph.yOffset.setGoal(Curves.dotYOffset.at(p), replacePosition: true)
                            s.glyph.glow.setGoal(Curves.dotGlow.at(p), replacePosition: true)
                            s.opacity.setGoal(Curves.dotOpacity.at(p), replacePosition: true)
                        }
                        let (scale, y, glow) = s.glyph.step(
                            scale: Curves.dotScale.at(p), yOffset: Curves.dotYOffset.at(p), glow: Curves.dotGlow.at(p), dt: dt)
                        s.opacity.setGoal(Curves.dotOpacity.at(p))
                        let opacity = s.opacity.step(dt)
                        settled = settled && s.glyph.isSettled && s.opacity.canSleep
                        lineSprings.dots[k] = s
                        visual.dots[k] = GlyphVisual(scale: scale, yOffset: y, glow: glow, gradient: 1, opacity: opacity)
                    }
                    if state != .active, settled { lineSprings.awake = false }
                }

            case .static:
                break
            }

            springs[index] = lineSprings
            if visuals[index] != visual { visuals[index] = visual }
        }
    }

    /// Lines starting this close together are sung together (a duet); the first one keeps focus.
    private static let duetWindow: Double = 0.6

    /// The last line that has started (so the view stays on a line through short gaps).
    static func focus(in lines: [PreparedLine], at time: Double) -> Int {
        var low = 0, high = lines.count - 1, found = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        // Background rows never hold focus: they belong to their lead line (`ResolveToLeadIndex`).
        if lines[found].isBackground, let lead = lines[found].leadID { found = lead }
        // Prefer the first of several lines that start together (duets). Only lines that start
        // together count: a long earlier line that merely overlaps (a trailing backing vocal, a
        // word timed a bit early) must not hold focus while the next line is being sung.
        var index = found
        while index > 0 {
            let previous = lines[index - 1]
            guard !previous.isInterlude, !previous.isBackground,
                  lines[index].start - previous.start <= duetWindow,
                  ElementState(time, previous.start, previous.end) == .active
            else { break }
            index -= 1
        }
        return index
    }

    /// Steps every syllable of a word list; returns whether all of their springs are at rest.
    private func stepWords(_ words: [PreparedWord], springs: inout [[SyllableSprings]], into visuals: inout [[SyllableVisual]],
                           time: Double, dt: Double, snap: Bool) -> Bool {
        var settled = true
        for w in words.indices {
            for s in words[w].syllables.indices {
                let syllable = words[w].syllables[s]
                var store = springs[w][s]
                var visual = visuals[w][s]
                if let letters = syllable.letters, let first = letters.first, let last = letters.last {
                    // A letter group lives on the emphasized range (`Emphasize` ends it 250 ms early),
                    // and the whole word rides the word springs while its letters ripple on top.
                    var group = syllable
                    group.start = first.start
                    group.end = last.end
                    stepSyllable(group, &store, &visual, time: time, dt: dt, snap: snap)
                    stepLetters(group, letters, &store, &visual, time: time, dt: dt, snap: snap)
                } else {
                    stepSyllable(syllable, &store, &visual, time: time, dt: dt, snap: snap)
                }
                settled = settled && store.glyph.isSettled && store.letters.allSatisfy(\.isSettled)
                springs[w][s] = store
                visuals[w][s] = visual
            }
        }
        return settled
    }

    private func stepSyllable(_ syllable: PreparedSyllable, _ store: inout SyllableSprings, _ visual: inout SyllableVisual,
                              time: Double, dt: Double, snap: Bool) {
        let state = ElementState(time, syllable.start, syllable.end)
        if simple {
            // No scale or glow: the word drifts up while a wider, softer fill passes over it.
            let p: Double
            switch state {
            case .notSung: p = 0; visual.glyph.gradient = -0.5
            case .active: p = progress(time, syllable.start, syllable.end); visual.glyph.gradient = -0.5 + 1.2 * p
            case .sung: p = 1; visual.glyph.gradient = 1
            }
            store.glyph.yOffset.setGoal(Curves.simpleYOffset.at(p), replacePosition: snap)
            visual.glyph.yOffset = store.glyph.yOffset.step(dt)
            visual.glyph.scale = 1
            visual.glyph.glow = 0
            return
        }
        let p: Double
        switch state {
        case .notSung:
            p = 0
            visual.glyph.gradient = -0.2
        case .active:
            p = progress(time, syllable.start, syllable.end)
            visual.glyph.gradient = -0.2 + 1.2 * p
        case .sung:
            p = 1
            visual.glyph.gradient = 1
        }
        let targets = (Curves.scale.at(p), Curves.yOffset.at(p), Curves.glow.at(p))
        if snap {
            store.glyph.scale.setGoal(targets.0, replacePosition: true)
            store.glyph.yOffset.setGoal(targets.1, replacePosition: true)
            store.glyph.glow.setGoal(targets.2, replacePosition: true)
        }
        let (scale, y, glow) = store.glyph.step(scale: targets.0, yOffset: targets.1, glow: targets.2, dt: dt)
        visual.glyph.scale = scale
        visual.glyph.yOffset = y
        visual.glyph.glow = glow
    }

    private func stepLetters(_ syllable: PreparedSyllable, _ letters: [PreparedLetter], _ store: inout SyllableSprings,
                             _ visual: inout SyllableVisual, time: Double, dt: Double, snap: Bool) {
        let wordState = ElementState(time, syllable.start, syllable.end)

        var activeLetter = -1
        var activeProgress = 0.0
        if wordState == .active {
            for (i, letter) in letters.enumerated() where ElementState(time, letter.start, letter.end) == .active {
                activeLetter = i
                activeProgress = progress(time, letter.start, letter.end)
                break
            }
        }

        let scaleCurve = simple ? Curves.simpleLetterScale : Curves.letterScale
        let yCurve = simple ? Curves.simpleLetterYOffset : Curves.letterYOffset
        let strength = syllable.end - syllable.start > Curves.simpleLongerThan ? Curves.simpleLonger : Curves.simpleShorter
        // Simple mode scales the letter curves and drives them by the whole word's progress.
        let wordProgress = progress(time, syllable.start, syllable.end)
        let restScale = scaleCurve.at(0)
        let restY = yCurve.at(0)
        let restGlow = Curves.glow.at(0)
        let unlit = simple ? -0.5 : -0.2

        for k in letters.indices {
            let letter = letters[k]
            let letterState = ElementState(time, letter.start, letter.end)
            var targetScale = restScale, targetY = restY, targetGlow = restGlow
            let gradient: Double

            switch wordState {
            case .notSung:
                gradient = unlit
            case .sung:
                targetScale = scaleCurve.at(1)
                targetY = yCurve.at(1)
                targetGlow = Curves.glow.at(1)
                gradient = 1
            case .active:
                if activeLetter >= 0 {
                    // Proximity falloff around the letter being sung.
                    let count = simple ? wordProgress : activeProgress
                    let baseScale = scaleCurve.at(count) * (simple ? strength.scale : 1)
                    let baseY = yCurve.at(count) * (simple ? strength.yOffset : 1)
                    let baseGlow = Curves.glow.at(count) * (simple ? strength.glow : 1)
                    let d = Double(abs(k - activeLetter))
                    let falloff = max(0, 1 / (1 + pow(d, 2.8)))
                    let glowFalloff = max(0, 1 / (1 + d * 0.9))
                    targetScale = restScale + (baseScale - restScale) * falloff
                    targetY = restY + (baseY - restY) * falloff
                    targetGlow = restGlow + (baseGlow - restGlow) * glowFalloff
                }
                switch letterState {
                case .notSung:
                    if !simple {
                        targetScale = restScale
                        targetY = restY
                        targetGlow = restGlow
                    }
                    gradient = unlit
                case .sung:
                    if activeLetter == -1 { targetGlow = Curves.sungLetterGlow }
                    gradient = 1
                case .active:
                    gradient = k == activeLetter ? unlit + 1.2 * easeSinOut(activeProgress) : unlit
                }
            }

            var springs = store.letters[k]
            if snap {
                springs.scale.setGoal(targetScale, replacePosition: true)
                springs.yOffset.setGoal(targetY, replacePosition: true)
                springs.glow.setGoal(targetGlow, replacePosition: true)
            }
            let (scale, y, glow) = springs.step(scale: targetScale, yOffset: targetY, glow: targetGlow, dt: dt)
            store.letters[k] = springs
            visual.letters[k] = GlyphVisual(scale: scale, yOffset: y * 2, glow: glow, gradient: gradient, opacity: 1)
        }
    }

    // MARK: Construction

    private static func makeSprings(_ line: PreparedLine) -> LineSprings {
        func syllableSprings(_ words: [PreparedWord]) -> [[SyllableSprings]] {
            words.map { word in
                word.syllables.map { syllable in
                    SyllableSprings(
                        glyph: GlyphSprings(scale: Curves.scale.at(0), yOffset: Curves.yOffset.at(0), glow: Curves.glow.at(0)),
                        letters: (syllable.letters ?? []).map { _ in
                            GlyphSprings(scale: Curves.letterScale.at(0), yOffset: Curves.letterYOffset.at(0), glow: Curves.glow.at(0))
                        }
                    )
                }
            }
        }

        var lead: [[SyllableSprings]] = []
        var background: [[SyllableSprings]] = []
        var dots: [DotSprings] = []
        switch line.kind {
        case .syllable(let l, let b):
            lead = syllableSprings(l)
            background = syllableSprings(b)
        case .interlude(let d):
            dots = d.map { _ in
                DotSprings(
                    glyph: GlyphSprings(scale: Curves.dotScale.at(0), yOffset: Curves.dotYOffset.at(0), glow: Curves.dotGlow.at(0),
                                        scaleFrequency: 0.7, scaleDamping: 0.6, yFrequency: 1.25, yDamping: 0.4,
                                        glowFrequency: 1, glowDamping: 0.5),
                    opacity: Spring(Curves.dotOpacity.at(0), frequency: 1, damping: 0.5)
                )
            }
        default:
            break
        }
        let opacity: Tween
        switch line.kind {
        case .interlude:
            opacity = Tween(0, duration: Curves.interludeOpacity.duration, easing: Curves.interludeOpacity.easing)
        case .line:
            opacity = Tween(Curves.notSungOpacity, duration: Curves.lineSynced.duration, easing: Curves.lineSynced.easing)
        default:
            opacity = Tween(Curves.notSungOpacity, duration: Curves.lineOpacity.duration, easing: Curves.lineOpacity.easing)
        }
        return LineSprings(
            opacity: opacity,
            scale: Tween(1, duration: Curves.lineSynced.duration, easing: Curves.lineSynced.easing),
            glow: Spring(0, frequency: 1, damping: 0.5),
            lead: lead,
            background: background,
            dots: dots
        )
    }

    private static func makeVisual(_ line: PreparedLine) -> LineVisual {
        var visual = LineVisual()
        func syllableVisuals(_ words: [PreparedWord]) -> [[SyllableVisual]] {
            words.map { word in
                word.syllables.map { syllable in
                    let rest = GlyphVisual(scale: Curves.scale.at(0), yOffset: Curves.yOffset.at(0), glow: 0, gradient: -0.2)
                    let letterRest = GlyphVisual(scale: Curves.letterScale.at(0), yOffset: Curves.letterYOffset.at(0) * 2, glow: 0, gradient: -0.2)
                    return SyllableVisual(glyph: rest, letters: (syllable.letters ?? []).map { _ in letterRest })
                }
            }
        }
        switch line.kind {
        case .syllable(let lead, let background):
            visual.lead = syllableVisuals(lead)
            visual.background = syllableVisuals(background)
        case .interlude(let dots):
            visual.dots = dots.map { _ in GlyphVisual(scale: Curves.dotScale.at(0), yOffset: 0, glow: 0, gradient: 1, opacity: Curves.dotOpacity.at(0)) }
            visual.presence = 0
            visual.opacity = 0
        case .static:
            visual.opacity = 1
            visual.line.gradient = 1
        case .line:
            break
        }
        return visual
    }
}
