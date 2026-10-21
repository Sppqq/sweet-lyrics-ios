import SwiftUI

/// A held lyric line and where it was on screen when the finger came down.
struct HeldLine: Equatable {
    let line: PreparedLine
    /// In the lyrics view's own space.
    let frame: CGRect
}

/// What a long press on a line opens, like an iOS context menu: the line lifts out of the lyrics
/// in a glass card (the rest blurs and dims behind it) and a glass menu grows out under it.
/// The actions run after the card has settled back.
struct LineActionMenu: View {
    let held: HeldLine
    let font: Font
    var centered = false
    var canSeek = true
    var canExplain = true
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    let onAction: (LineAction) -> Void
    let onDismiss: () -> Void

    @State private var lifted = false
    @State private var contentHeight: CGFloat = 0
    @State private var chosen: LineAction?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let margin: CGFloat = 16
    private static let cardPadding: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width - Self.margin * 2, 460)
            let x = (geometry.size.width - width) / 2
            // Where the card starts: its text over the line as it was in the lyrics.
            let start = held.frame.minY - Self.cardPadding
            // Where it settles: as close to there as the menu under it allows.
            let lowest = geometry.size.height - bottomInset - contentHeight - 12
            let target = min(max(start, topInset + 12), max(topInset + 12, lowest))

            ZStack(alignment: .topLeading) {
                Color.black
                    .opacity(lifted ? 0.42 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close(nil) }
                    .accessibilityLabel(String(localized: "Закрыть"))
                    .accessibilityAddTraits(.isButton)

                VStack(alignment: .leading, spacing: 12) {
                    card
                    menu
                }
                .frame(width: width)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                .offset(x: x, y: lifted ? target : start)
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.74)) {
                lifted = true
            }
        }
        .sensoryFeedback(.selection, trigger: chosen)
    }

    // MARK: The lifted line

    private var frameAlignment: Alignment {
        if centered { return .center }
        return held.line.oppositeAligned ? .trailing : .leading
    }

    private var card: some View {
        Text(held.line.plainText)
            .font(font)
            .foregroundStyle(.white)
            .multilineTextAlignment(centered ? .center : (held.line.oppositeAligned ? .trailing : .leading))
            .shadow(color: .white.opacity(lifted ? 0.35 : 0), radius: 18)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .padding(Self.cardPadding)
            .background {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.clear)
                    .glassCard(radius: 28)
                    .opacity(lifted ? 1 : 0)
            }
            .scaleEffect(lifted ? 1.03 : 1, anchor: UnitPoint(x: frameAlignment == .trailing ? 1 : (frameAlignment == .center ? 0.5 : 0), y: 0.5))
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: The menu

    private var menu: some View {
        // A plain stack, not a glass container: the container draws the glass itself and the
        // buttons would skip their staggered entrance.
        VStack(spacing: 10) {
            if canExplain {
                explainButton
                    .reveal(lifted, index: 0)
            }
            HStack(spacing: 10) {
                if canSeek {
                    tile(.seek, String(localized: "Сюда"), "backward.end.alt.fill")
                        .reveal(lifted, index: 1)
                }
                tile(.copy, String(localized: "Копировать"), "doc.on.doc.fill")
                    .reveal(lifted, index: 2)
                tile(.share, String(localized: "Поделиться"), "square.and.arrow.up.fill")
                    .reveal(lifted, index: 3)
            }
            Button {
                close(.copyAll)
            } label: {
                Label(String(localized: "Скопировать весь текст"), systemImage: "text.quote")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .glassCapsule(.pressable)
                    .contentShape(Capsule())
            }
            .buttonStyle(SquishButtonStyle())
            .reveal(lifted, index: 4)
        }
        .scaleEffect(lifted ? 1 : 0.7, anchor: .top)
        .opacity(lifted ? 1 : 0)
    }

    private var explainButton: some View {
        Button {
            close(.explain)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .symbolEffect(.bounce, value: lifted)
                Text(String(localized: "Что это значит?"))
                    .font(.headline)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .opacity(0.6)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background { IntelligenceGlow(active: lifted, cornerRadius: 22) }
            .glassCard(.pressable, radius: 22)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(SquishButtonStyle())
    }

    private func tile(_ action: LineAction, _ title: String, _ symbol: String) -> some View {
        Button {
            close(action)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(height: 24)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .glassCard(.pressable, radius: 20)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(SquishButtonStyle(scale: 0.92))
    }

    /// The card sinks back into the lyrics, then the action runs.
    private func close(_ action: LineAction?) {
        chosen = action
        withAnimation(reduceMotion ? .easeIn(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.9)) {
            lifted = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            onDismiss()
            if let action { onAction(action) }
        }
    }
}

enum LineAction: Hashable {
    case explain, seek, copy, copyAll, share
}

/// Apple Intelligence's moving rainbow edge, softly, around the "explain" button.
struct IntelligenceGlow: View {
    var active = true
    var cornerRadius: CGFloat = 22
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let colors: [Color] = [
        Color(red: 0.98, green: 0.45, blue: 0.35), Color(red: 0.98, green: 0.35, blue: 0.75),
        Color(red: 0.62, green: 0.4, blue: 1.0), Color(red: 0.3, green: 0.62, blue: 1.0),
        Color(red: 0.98, green: 0.72, blue: 0.3), Color(red: 0.98, green: 0.45, blue: 0.35),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduceMotion)) { context in
            let angle = Angle.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) * 90)
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            ZStack {
                shape.fill(AngularGradient(colors: Self.colors, center: .center, angle: angle))
                    .opacity(0.22)
                shape.strokeBorder(AngularGradient(colors: Self.colors, center: .center, angle: angle), lineWidth: 1.5)
                    .blur(radius: 1)
                shape.strokeBorder(AngularGradient(colors: Self.colors, center: .center, angle: angle), lineWidth: 6)
                    .blur(radius: 10)
                    .opacity(0.7)
            }
        }
        .opacity(active ? 1 : 0)
        .allowsHitTesting(false)
    }
}

private extension View {
    /// Settles in a beat after the one before: the menu fills in from the top.
    func reveal(_ shown: Bool, index: Int) -> some View {
        self
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 6)
            .scaleEffect(shown ? 1 : 0.88)
            .animation(shown ? .spring(response: 0.42, dampingFraction: 0.78).delay(0.05 + Double(index) * 0.035)
                             : .easeIn(duration: 0.12), value: shown)
    }
}
