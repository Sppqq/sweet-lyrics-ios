import SwiftUI

/// Typography and spacing shared by all lines, from Spicy Lyrics' Mixed.css. `cqw` is 1% of the
/// lyrics container's width, the unit the stylesheet sizes spacing in.
struct LyricsTypography: Equatable {
    var fontSize: CGFloat
    var cqw: CGFloat = 3.9
    /// The song has duet (opposite-aligned) lines.
    var hasDuets = false
    /// Simple Lyrics Mode: softer, wider fill (`--gradient-offset: 30%`, alpha 1 → 0.3).
    var simple = false
    var centered = false
    var font = LyricsFontChoice(stored: LyricsFont.standard.rawValue)
    /// User multipliers (1 = the original look).
    var blurScale: CGFloat = 1
    var glowScale: Double = 1
    /// 0.5 darker … 1.5 brighter lines that are not being sung.
    var inactiveBrightness: Double = 1
    var lineSpacingScale: CGFloat = 1
    var translationScale: CGFloat = 1
    var translationBrightness: Double = 1
    var weight: Font.Weight = .bold
    /// Refreshed Simple Lyrics: lines further apart, the part still to come a little brighter.
    var refreshed = false

    var leadFont: Font { font.font(size: fontSize, weight: weight) }
    /// Width of the lit → unlit fade, as a fraction of a glyph.
    var fillFade: Double { simple ? 0.5 : 0.2 }
    var leadAlpha: GradientAlpha { simple ? GradientAlpha(lit: 1, unlit: refreshed ? 0.4 : 0.3) : .lead }
    /// `.line.bg-line { --font-size: calc(var(--DefaultLyricsSize) * 0.75) }`
    var backgroundFontSize: CGFloat { fontSize * 0.75 }
    var backgroundFont: Font { font.font(size: backgroundFontSize, weight: weight) }
    /// `.word::after { margin-right: 0.32ch }` (a "0" in the bold face is ~0.6em wide).
    func wordGap(_ size: CGFloat) -> CGFloat { size * 0.6 * 0.32 }
    /// `.line { margin: 1cqw 0 }`, collapsing between neighbours. Refreshed Simple Lyrics sets the
    /// rows apart by a share of the type instead (`REFRESHED_GAP_EM`).
    var lineSpacing: CGFloat { (refreshed ? fontSize * 0.62 : cqw) * lineSpacingScale }
    /// Static lyrics: `--DefaultLyricsSize: 5cqw` against the synced 7cqw, weight 500.
    var staticFont: Font { font.font(size: fontSize * 5 / 7, weight: .medium) }
    /// `.line { padding-right: 5cqw }`, or the 15cqw duet inset on the side a line leans away from.
    func insets(opposite: Bool) -> EdgeInsets {
        if centered { return EdgeInsets(top: 0, leading: cqw * 5, bottom: 0, trailing: cqw * 5) }
        if hasDuets {
            return opposite ? EdgeInsets(top: 0, leading: cqw * 15, bottom: 0, trailing: 0)
                            : EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: cqw * 15)
        }
        return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: cqw * 5)
    }

    static func == (lhs: LyricsTypography, rhs: LyricsTypography) -> Bool {
        lhs.fontSize == rhs.fontSize && lhs.cqw == rhs.cqw && lhs.hasDuets == rhs.hasDuets
            && lhs.simple == rhs.simple && lhs.centered == rhs.centered && lhs.font == rhs.font
            && lhs.blurScale == rhs.blurScale && lhs.glowScale == rhs.glowScale
            && lhs.inactiveBrightness == rhs.inactiveBrightness && lhs.lineSpacingScale == rhs.lineSpacingScale
            && lhs.translationScale == rhs.translationScale
            && lhs.translationBrightness == rhs.translationBrightness && lhs.weight == rhs.weight
            && lhs.refreshed == rhs.refreshed
    }

    /// Scales how far a line's opacity sits below fully lit, so the active line stays at 1
    /// and the change animates as smoothly as the opacity itself.
    func opacity(_ value: Double) -> Double {
        // Minimal Lyrics Mode fades sung lines out completely.
        if value <= 0.001 { return 0 }
        return clamp(1 - (1 - value) * (2 - inactiveBrightness), 0.05, 1)
    }
}

/// How bright the lit / unlit parts of the fill gradient are (Mixed.css `--gradient-alpha*`).
struct GradientAlpha: Equatable {
    var lit: Double
    var unlit: Double

    static let lead = GradientAlpha(lit: 0.85, unlit: 0.5)
    static let background = GradientAlpha(lit: 0.6, unlit: 0.3)
}

/// The glow shadows of Spicy Lyrics, per element kind (`--text-shadow-*` in LyricsAnimator.ts).
enum GlowKind {
    case syllable, letter, dot, line

    /// CSS blur radius is ~2σ; SwiftUI's shadow radius is closer to σ.
    func radius(_ glow: Double) -> CGFloat {
        switch self {
        case .syllable: return (4 + 2 * glow) / 2
        case .letter: return (4 + 12 * glow) / 2
        case .dot: return (4 + 6 * glow) / 2
        case .line: return (4 + 8 * glow) / 2
        }
    }

    func opacity(_ glow: Double) -> Double {
        let value: Double
        switch self {
        case .syllable: value = glow * 0.35
        case .letter: value = glow * 1.85
        case .dot: value = glow * 0.9
        case .line: value = glow * 0.5
        }
        return clamp(value, 0, 1)
    }
}

extension View {
    /// Left-to-right fill: fully lit before `position`, unlit from `position + fade` on.
    func lyricFill(_ position: Double, alpha: GradientAlpha, fade: Double = 0.2) -> some View {
        foregroundStyle(
            LinearGradient(
                colors: [.white.opacity(alpha.lit), .white.opacity(alpha.unlit)],
                startPoint: UnitPoint(x: position, y: 0.5),
                endPoint: UnitPoint(x: position + fade, y: 0.5)
            )
        )
    }

    @ViewBuilder
    func lyricGlow(_ glow: Double, kind: GlowKind) -> some View {
        let opacity = kind.opacity(glow)
        if opacity > 0.004 {
            shadow(color: .white.opacity(opacity), radius: kind.radius(glow))
        } else {
            self
        }
    }
}

// MARK: - Line

struct LyricLineView: View, Equatable {
    let line: PreparedLine
    let visual: LineVisual
    let typography: LyricsTypography
    /// On-device translation shown under the line.
    var translation: String? = nil
    /// In a list: the row brings the gap above it itself (a background row none, so one tucked
    /// away by Pop-Out takes no room at all). Off, a background row pulls itself up by the gap.
    var ownsGap = false

    static func == (lhs: LyricLineView, rhs: LyricLineView) -> Bool {
        lhs.line.id == rhs.line.id && lhs.visual == rhs.visual && lhs.typography == rhs.typography
            && lhs.translation == rhs.translation && lhs.ownsGap == rhs.ownsGap
    }

    private var rowAnchor: UnitPoint {
        typography.centered ? .center : (line.oppositeAligned ? .trailing : .leading)
    }

    private var topGap: CGFloat {
        if ownsGap { return line.isBackground ? 0 : typography.lineSpacing }
        // `.bg-line { margin: -1cqw 0 1cqw }`: tucked right under the line above.
        return line.isBackground ? -typography.lineSpacing : 0
    }

    private var horizontalAlignment: HorizontalAlignment {
        typography.centered ? .center : (line.oppositeAligned ? .trailing : .leading)
    }
    private var frameAlignment: Alignment { typography.centered ? .center : (line.oppositeAligned ? .trailing : .leading) }
    private var textAlignment: TextAlignment { typography.centered ? .center : (line.oppositeAligned ? .trailing : .leading) }

    var body: some View {
        VStack(alignment: horizontalAlignment, spacing: typography.fontSize * 0.1) {
            content
            if let translation, !translation.isEmpty {
                Text(translation)
                    // A backing vocal's translation is as much smaller as the vocal itself.
                    .font(.system(size: (line.isBackground ? typography.backgroundFontSize : typography.fontSize)
                                  * 0.55 * typography.translationScale, weight: .semibold))
                    .foregroundStyle(.white.opacity(min(1, (line.isBackground ? 0.45 : 0.6) * typography.translationBrightness)))
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
            .padding(typography.insets(opposite: line.oppositeAligned))
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            // Minimal Lyrics Mode: rows not being sung shrink a little toward their edge.
            .scaleEffect(visual.rowScale, anchor: rowAnchor)
            .modifier(PopOut(reveal: visual.reveal, fontSize: typography.backgroundFontSize,
                             anchor: line.oppositeAligned && !typography.centered ? .topTrailing : .topLeading))
            .padding(.top, topGap)
            .opacity(typography.opacity(visual.opacity))
            .blur(radius: visual.blur * typography.blurScale > 0.05 ? visual.blur * typography.blurScale / 2 : 0)
    }

    @ViewBuilder
    private var content: some View {
        switch line.kind {
        case .syllable(let lead, let background):
            // `.bg-line { margin: -1cqw 0 1cqw }` cancels the gap under the lead line.
            VStack(alignment: horizontalAlignment, spacing: 0) {
                if !lead.isEmpty {
                    WordFlowView(words: lead, visuals: visual.lead,
                                 fontSize: line.isBackground ? typography.backgroundFontSize : typography.fontSize,
                                 font: line.isBackground ? typography.backgroundFont : typography.leadFont,
                                 alpha: line.isBackground && !visual.soloBackground ? .background : typography.leadAlpha, typography: typography,
                                 alignment: horizontalAlignment)
                }
                if !background.isEmpty {
                    WordFlowView(words: background, visuals: visual.background, fontSize: typography.backgroundFontSize,
                                 font: typography.backgroundFont, alpha: .background, typography: typography,
                                 alignment: horizontalAlignment)
                }
            }
            // VoiceOver reads the line, not syllable by syllable.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.plainText)

        case .line(let text):
            Text(text)
                .font(typography.leadFont)
                .multilineTextAlignment(textAlignment)
                .lyricFill(visual.line.gradient, alpha: typography.leadAlpha, fade: typography.fillFade)
                .lyricGlow(visual.state == .active ? visual.line.glow * typography.glowScale : 0, kind: .line)
                // Active line-synced lines grow to 1.05 from their aligned edge.
                .scaleEffect(visual.scale, anchor: typography.centered ? .center : (line.oppositeAligned ? .trailing : .leading))

        case .static(let text):
            Text(text)
                .font(typography.staticFont)
                .multilineTextAlignment(textAlignment)
                .foregroundStyle(.white)

        case .interlude:
            InterludeDotsView(dots: visual.dots, presence: visual.presence,
                              groupScale: visual.dotGroupScale * visual.dotBreath, typography: typography)
        }
    }
}

// MARK: - Words

/// Lays the words of a syllable-synced line out like text, never breaking inside a word.
private struct WordFlowView: View {
    let words: [PreparedWord]
    let visuals: [[SyllableVisual]]
    let fontSize: CGFloat
    let font: Font
    let alpha: GradientAlpha
    let typography: LyricsTypography
    let alignment: HorizontalAlignment

    /// Syllables in reading order, each knowing whether it is glued to the next (same word).
    /// Letter-animated syllables are laid out letter by letter (still glued), so a very long
    /// word can break between letters instead of running off the screen.
    private var items: [FlowItem] {
        words.indices.flatMap { w -> [FlowItem] in
            let syllables = words[w].syllables
            return syllables.indices.flatMap { s -> [FlowItem] in
                let lastSyllable = s == syllables.count - 1
                guard let letters = syllables[s].letters, !letters.isEmpty else {
                    return [FlowItem(id: w * 1_000_000 + s * 1_000, w: w, s: s, letter: nil, gluedToNext: !lastSyllable)]
                }
                return letters.indices.map { l in
                    FlowItem(id: w * 1_000_000 + s * 1_000 + l + 1, w: w, s: s, letter: l,
                             gluedToNext: !(lastSyllable && l == letters.count - 1))
                }
            }
        }
    }

    private struct FlowItem: Identifiable {
        let id: Int
        let w: Int
        let s: Int
        /// Index of the letter in an emphasized syllable, nil for a whole syllable.
        let letter: Int?
        let gluedToNext: Bool
    }

    private func visual(_ item: FlowItem) -> SyllableVisual {
        visuals.indices.contains(item.w) && visuals[item.w].indices.contains(item.s)
            ? visuals[item.w][item.s] : SyllableVisual()
    }

    /// A letter rides its word (the letter group's container in the extension), which has its
    /// own scale and lift.
    private func letterVisual(_ item: FlowItem, _ l: Int) -> GlyphVisual {
        let syllable = visual(item)
        var letter = syllable.letters.indices.contains(l) ? syllable.letters[l] : GlyphVisual()
        letter.scale *= syllable.glyph.scale
        letter.yOffset += syllable.glyph.yOffset
        return letter
    }

    var body: some View {
        FlowLayout(alignment: alignment, spacing: typography.wordGap(fontSize), rowSpacing: 0) {
            ForEach(items) { item in
                Group {
                    if let l = item.letter, let letters = words[item.w].syllables[item.s].letters {
                        GlyphView(text: letters[l].text, visual: letterVisual(item, l),
                                  fontSize: fontSize, font: font, alpha: alpha, fade: typography.fillFade,
                                  glowKind: .letter, glowScale: typography.glowScale)
                    } else {
                        GlyphView(text: words[item.w].syllables[item.s].text, visual: visual(item).glyph,
                                  fontSize: fontSize, font: font, alpha: alpha, fade: typography.fillFade,
                                  glowKind: .syllable, glowScale: typography.glowScale)
                    }
                }
                .layoutValue(key: GluedToNext.self, value: item.gluedToNext)
                // A letter grows with its syllable; its own pop on top may overlap, as in the extension.
                .layoutValue(key: GlyphGrowth.self, value: CGFloat(visual(item).glyph.scale))
            }
        }
    }
}

private struct GlyphView: View {
    let text: String
    let visual: GlyphVisual
    let fontSize: CGFloat
    let font: Font
    let alpha: GradientAlpha
    let fade: Double
    let glowKind: GlowKind
    let glowScale: Double

    var body: some View {
        Text(text)
            .font(font)
            .fixedSize()
            .lyricFill(visual.gradient, alpha: alpha, fade: visual.fade ?? fade)
            .lyricGlow(visual.glow * glowScale, kind: glowKind)
            .scaleEffect(visual.scale)
            .offset(x: visual.xOffset * fontSize, y: visual.yOffset * fontSize)
    }
}

// MARK: - Pop-Out

/// Background Vocal Pop-Out: a row tucked under its lead line takes no height; coming out it
/// grows to its own height while sliding down from under the line and fading in (Mixed.css
/// `.Exp_BackgroundLinePop .bg-line`). Fully out it is left alone.
private struct PopOut: ViewModifier {
    let reveal: Double
    let fontSize: CGFloat
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        if reveal >= 0.999 {
            content
        } else {
            RevealLayout(fraction: CGFloat(max(0, reveal))) {
                content
                    .scaleEffect(0.8 + 0.2 * reveal, anchor: anchor)
                    .offset(y: -0.6 * fontSize * (1 - reveal))
                    // The text is gone before the rows below glide in over it.
                    .opacity(reveal * reveal)
            }
        }
    }
}

/// Lays out its one child at full size but reports only `fraction` of its height.
private struct RevealLayout: Layout {
    var fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: size.height * fraction)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

// MARK: - Interlude

/// The "•••" row of an instrumental gap (`.musical-line .dotGroup`): three dots at 1.3× the lyric
/// size, packed tight, each with its own springs; the whole group pops in and out.
///
/// The extension draws "•" in its own font, whose bullet is 0.348 em across on a 0.485 em advance
/// (SF Pro's is only 0.246 em), so the dots are drawn as circles of exactly that size.
private struct InterludeDotsView: View {
    let dots: [GlyphVisual]
    let presence: Double
    let groupScale: Double
    let typography: LyricsTypography

    private static let bulletDiameter: CGFloat = 0.348
    private static let bulletAdvance: CGFloat = 0.485

    var body: some View {
        let dotFont = typography.fontSize * 1.3
        let diameter = dotFont * Self.bulletDiameter
        // `--dot-gap: clamp(0.005rem, 1.7cqw, 0.18rem)`
        let gap = min(max(0.08, typography.cqw * 1.7), 2.88)
        if presence > 0 {
            HStack(spacing: gap) {
                ForEach(dots.indices, id: \.self) { i in
                    let dot = dots[i]
                    Circle()
                        .fill(.white.opacity(GradientAlpha.lead.lit))
                        .frame(width: diameter, height: diameter)
                        .frame(width: dotFont * Self.bulletAdvance)
                        .opacity(dot.opacity)
                        .lyricGlow(dot.glow * typography.glowScale, kind: .dot)
                        .scaleEffect(dot.scale)
                        .offset(y: dot.yOffset * typography.fontSize)
                }
            }
            .frame(height: typography.fontSize * 1.18)
            .scaleEffect(max(groupScale, 0.0001), anchor: .center)
        }
    }
}

// MARK: - Flow layout

/// Wrapping row layout: places subviews left to right and starts a new row when out of width.
/// The next item belongs to the same word: keep them on one row when the word fits.
struct GluedToNext: LayoutValueKey {
    static let defaultValue = false
}

/// How much a piece is scaled about its own centre. The pieces of one word move apart or
/// together by it, so the word grows as one: scaled each about its own centre, a growing
/// syllable ran into its neighbours and a shrinking one left a gap (worst with three or more).
struct GlyphGrowth: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

/// Horizontal shifts that keep the pieces of a word touching while each is scaled by its
/// growth about its own centre; the word as a whole stays centred where it was laid out.
func wordGrowthShifts(widths: [CGFloat], growth: [CGFloat]) -> [CGFloat] {
    let extra = zip(widths, growth).map { $0 * ($1 - 1) }
    let total = extra.reduce(0, +)
    var before: CGFloat = 0
    return extra.map { piece in
        defer { before += piece }
        return before + piece / 2 - total / 2
    }
}

/// Wrapping row layout for syllables. Words (runs of glued syllables) stay together and wrap as
/// a unit, like text; a word wider than the whole row (Japanese and Chinese lines are often one
/// long "word" with no spaces) breaks between its syllables instead of running off screen.
struct FlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat
    var rowSpacing: CGFloat

    private struct Row {
        var items: [(index: Int, x: CGFloat)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func append(_ index: Int, size: CGSize, gap: CGFloat) {
            let x = items.isEmpty ? 0 : width + gap
            items.append((index, x))
            width = x + size.width
            height = max(height, size.height)
        }
    }

    /// Bounds arrive rounded to the pixel grid; without slack the widest row could stop fitting
    /// on placement and spill into an extra row over the next line.
    private static let slack: CGFloat = 1

    private func arrangeRows(for subviews: Subviews, maxWidth rawWidth: CGFloat) -> ([Row], [CGSize]) {
        let maxWidth = rawWidth + Self.slack
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }

        // Words: runs of glued subviews.
        var words: [[Int]] = []
        var current: [Int] = []
        for index in subviews.indices {
            current.append(index)
            if !subviews[index][GluedToNext.self] {
                words.append(current)
                current = []
            }
        }
        if !current.isEmpty { words.append(current) }

        var rows: [Row] = []
        var row = Row()
        func newRow() {
            if !row.items.isEmpty { rows.append(row) }
            row = Row()
        }

        for word in words {
            let wordWidth = word.reduce(0) { $0 + sizes[$1].width }
            if wordWidth <= maxWidth {
                if !row.items.isEmpty, row.width + spacing + wordWidth > maxWidth { newRow() }
                for (k, index) in word.enumerated() {
                    row.append(index, size: sizes[index], gap: k == 0 ? spacing : 0)
                }
            } else {
                // Too long for any row: break between its syllables.
                for (k, index) in word.enumerated() {
                    let gap: CGFloat = k == 0 ? spacing : 0
                    if !row.items.isEmpty, row.width + gap + sizes[index].width > maxWidth { newRow() }
                    row.append(index, size: sizes[index], gap: gap)
                }
            }
        }
        newRow()
        return (rows, sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let (rows, _) = arrangeRows(for: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(rows.count - 1, 0))
        // Take the whole offered width, so placement wraps against exactly what was measured.
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (rows, sizes) = arrangeRows(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            let start: CGFloat
            switch alignment {
            case .trailing: start = bounds.maxX - row.width
            case .center: start = bounds.minX + (bounds.width - row.width) / 2
            default: start = bounds.minX
            }
            let shifts = growthShifts(row, sizes: sizes, subviews: subviews)
            for (k, item) in row.items.enumerated() {
                let size = sizes[item.index]
                subviews[item.index].place(
                    at: CGPoint(x: start + item.x + shifts[k], y: y + (row.height - size.height)),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
            }
            y += row.height + rowSpacing
        }
    }

    /// Per item of `row`: the shift that keeps each word's pieces touching as they grow. A word
    /// broken over two rows is a word of its own on each.
    private func growthShifts(_ row: Row, sizes: [CGSize], subviews: Subviews) -> [CGFloat] {
        var shifts: [CGFloat] = []
        shifts.reserveCapacity(row.items.count)
        var run: [Int] = []
        func flush() {
            guard !run.isEmpty else { return }
            shifts += wordGrowthShifts(widths: run.map { sizes[$0].width },
                                       growth: run.map { subviews[$0][GlyphGrowth.self] })
            run = []
        }
        for item in row.items {
            run.append(item.index)
            if !subviews[item.index][GluedToNext.self] { flush() }
        }
        flush()
        return shifts
    }
}
