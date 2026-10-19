import QuartzCore
import SwiftUI

/// One line of lyrics under the big cover, like Spotify's: the line being sung with its backing
/// vocals, word by word with the same fill, lift and glow as the full lyrics. The sung line
/// leaves upwards as the next one rises in; after the last line it fades away.
///
/// Everything here moves frame by frame from the clock, not with SwiftUI animations: the words
/// being sung update every frame, which cuts any animation of theirs short. An animated swap made
/// the last lit word jump; an animated move (the controls showing or hiding) left the animating
/// words behind while the rest of the line moved. So the line glides to `frame` itself, on the
/// same curve and time as the cover above it.
struct ArtworkLyricLine: View {
    let player: PlayerModel
    let settings: AppSettings
    var fontSize: CGFloat = 24
    /// Where the line sits, in the coordinates of the area this view fills.
    var frame: CGRect

    @State private var animator: LyricsAnimator
    @State private var switcher = LineSwitcher()
    @State private var glide = FrameGlide()

    init(lyrics: PreparedLyrics, player: PlayerModel, settings: AppSettings, fontSize: CGFloat = 24, frame: CGRect) {
        self.player = player
        self.settings = settings
        self.fontSize = fontSize
        self.frame = frame
        _animator = State(initialValue: LyricsAnimator(lyrics: lyrics, simple: settings.simpleLyricsMode))
    }

    var body: some View {
        let frameInterval = player.isPlaying ? 1.0 / 30 : 1.0 / 10
        TimelineView(.animation(minimumInterval: frameInterval)) { _ in
            let box = glide.value(toward: frame, now: CACurrentMediaTime())
            let now = MediaClock.now()
            let position = player.position(at: now)
            let _ = animator.step(position: position, now: now, blurEnabled: false, frameInterval: frameInterval)
            let _ = switcher.show(Self.shownLine(animator.lyrics.lines, focus: animator.focusIndex,
                                                 at: position + animator.presentationLead),
                                  now: now, instantly: animator.snapped)
            let progress = switcher.progress(at: now)
            let rise = box.height * 0.35
            let typography = typography(width: box.width)
            ZStack(alignment: .topLeading) {
                if let previous = switcher.previous, progress < 1 {
                    block(previous, typography)
                        .offset(y: -rise * progress)
                        .opacity(1 - progress)
                }
                if let current = switcher.current {
                    block(current, typography)
                        .offset(y: rise * (1 - progress))
                        .opacity(progress)
                }
            }
            .frame(width: box.width, height: box.height, alignment: .topLeading)
            // Lines leaving upwards must not run over the cover, but the words' glow and the
            // interlude dots' pulse spill past the edges a little: room around them.
            .mask {
                Rectangle()
                    .padding(.horizontal, -32)
                    .padding(.top, -12)
                    .padding(.bottom, -32)
            }
            .offset(x: box.minX, y: box.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    /// A lead line with its backing vocals under it; in a duet, the other singer's line that
    /// comes in over it as well, on its own side like in the full lyrics.
    private func block(_ index: Int, _ typography: LyricsTypography) -> some View {
        let lines = animator.lyrics.lines
        let visuals = animator.visuals
        let rows = lines.indices.contains(index) ? Self.rows(of: index, in: lines) : []
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.self) { row in
                LyricLineView(line: lines[row], visual: visuals[row], typography: typography,
                              translation: translation(lines[row]))
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }

    /// The line to show: the one in focus, or nothing once the last line (and its backing
    /// vocals) has been sung.
    private static func shownLine(_ lines: [PreparedLine], focus: Int, at position: Double) -> Int? {
        guard lines.indices.contains(focus) else { return nil }
        let isLast = !lines[(focus + 1)...].contains { !$0.isBackground }
        guard isLast else { return focus }
        let end = backing(of: focus, in: lines).map { lines[$0].end }.reduce(lines[focus].end, max)
        return position > end + 1 ? nil : focus
    }

    /// Backing-vocal rows that belong to a lead line.
    private static func backing(of lead: Int, in lines: [PreparedLine]) -> [Int] {
        var rows: [Int] = []
        var index = lead + 1
        while index < lines.count, lines[index].isBackground {
            if lines[index].leadID == lead { rows.append(index) }
            index += 1
        }
        return rows
    }

    /// The lead line and its backing vocals, then the other singer's line if it starts before
    /// this one ends (with its own backing vocals).
    private static func rows(of lead: Int, in lines: [PreparedLine]) -> [Int] {
        var rows = [lead] + backing(of: lead, in: lines)
        let line = lines[lead]
        guard !line.isInterlude,
              let partner = lines.indices.dropFirst(lead + 1).first(where: { !lines[$0].isBackground }),
              !lines[partner].isInterlude,
              lines[partner].oppositeAligned != line.oppositeAligned,
              lines[partner].start < line.end else { return rows }
        rows += [partner] + backing(of: partner, in: lines)
        return rows
    }

    private func typography(width: CGFloat) -> LyricsTypography {
        LyricsTypography(
            fontSize: fontSize,
            cqw: max(width, 1) / 100,
            hasDuets: settings.duetLinePadding && animator.lyrics.lines.contains(where: \.oppositeAligned),
            simple: settings.simpleLyricsMode,
            centered: false,
            font: LyricsFontChoice(stored: settings.lyricsFont),
            blurScale: 0,
            glowScale: settings.glowStrength,
            inactiveBrightness: settings.inactiveBrightness,
            lineSpacingScale: 1,
            translationScale: CGFloat(settings.translationScale),
            translationBrightness: settings.translationBrightness,
            weight: (LyricsWeight(rawValue: settings.lyricsWeight) ?? .bold).fontWeight
        )
    }

    private func translation(_ line: PreparedLine) -> String? {
        guard settings.translateLyrics, !settings.translationReplaces else { return nil }
        return player.translations[line.sourceText]
    }
}

/// Glides a frame to its new place like the controls' `easeInOut(duration: 0.45)`.
private final class FrameGlide {
    private var from = CGRect.null
    private var to = CGRect.null
    private var start: CFTimeInterval = 0
    private static let duration: Double = 0.45
    private static let curve = Easing.cubicBezier(0.42, 0, 0.58, 1)

    func value(toward target: CGRect, now: CFTimeInterval) -> CGRect {
        if to.isNull {
            from = target
            to = target
        } else if target != to {
            from = value(at: now)
            to = target
            start = now
        }
        return value(at: now)
    }

    private func value(at now: CFTimeInterval) -> CGRect {
        let t = CGFloat(Self.curve.value(at: (now - start) / Self.duration))
        return CGRect(x: from.minX + (to.minX - from.minX) * t,
                      y: from.minY + (to.minY - from.minY) * t,
                      width: from.width + (to.width - from.width) * t,
                      height: from.height + (to.height - from.height) * t)
    }
}

/// Which line is on screen and which one is leaving, and how far the swap has got.
private final class LineSwitcher {
    private(set) var current: Int?
    private(set) var previous: Int?
    private var changedAt: CFTimeInterval = -.infinity
    private static let duration: Double = 0.4

    func show(_ index: Int?, now: CFTimeInterval, instantly: Bool) {
        guard index != current else { return }
        previous = current
        current = index
        // After a seek or a gap the new line just appears.
        changedAt = instantly ? -.infinity : now
    }

    /// 0 when the swap begins … 1 when it is done (eased).
    func progress(at now: CFTimeInterval) -> Double {
        let t = min(1, max(0, (now - changedAt) / Self.duration))
        return t * t * (3 - 2 * t)
    }
}
