import SwiftUI

/// One line of text that slowly scrolls sideways when it does not fit, like Apple Music's
/// title and artist: a pause, one lap, a pause. Text that fits just sits still.
struct MarqueeText: View {
    let text: String
    let font: Font
    /// Scroll only while the text can be seen (no animating an invisible header).
    var active = true
    /// Text that fits sits in the middle instead of on the left (the external screen's title).
    var centered = false

    private static let gap: CGFloat = 36
    private static let speed: CGFloat = 32 // points per second
    private static let pause: Double = 2.5
    private static let fade: CGFloat = 12

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var scrolled = false

    private var overflows: Bool { boxWidth > 0 && textWidth > boxWidth + 1 }

    var body: some View {
        // The hidden copy gives the line its height and takes the width it is offered. It must not
        // be fixed-size: a frame with only a max width grows to its child, so a long title made
        // the header (and with it the whole screen) wider than the display.
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .overlay(alignment: centered && !overflows ? .center : .leading) {
                HStack(spacing: Self.gap) {
                    label
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    // A second copy follows the first, so the lap ends where it started.
                    if overflows { label }
                }
                .offset(x: scrolled ? -(textWidth + Self.gap) : 0)
            }
            .clipped()
            .mask(edgeMask)
            .task(id: "\(text)|\(overflows)|\(active)|\(Int(textWidth))") { await run() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
    }

    /// Soft edges while scrolling; none for text that fits.
    private var edgeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: overflows && scrolled ? Self.fade : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: overflows ? Self.fade : 0)
        }
    }

    private func run() async {
        reset()
        guard overflows, active else { return }
        let lap = Double((textWidth + Self.gap) / Self.speed)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.pause))
            guard !Task.isCancelled else { break }
            withAnimation(.linear(duration: lap)) { scrolled = true }
            try? await Task.sleep(for: .seconds(lap))
            guard !Task.isCancelled else { break }
            // The second copy now sits exactly where the first began: jump back unseen.
            reset()
        }
        reset()
    }

    private func reset() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scrolled = false }
    }
}
