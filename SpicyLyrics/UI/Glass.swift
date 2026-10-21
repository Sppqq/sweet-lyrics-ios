import SwiftUI

/// The current cover, blurred and dimmed, behind sheets: settings and the queue take their colour
/// from the song, like the player itself. Static, so it costs nothing while scrolling.
struct ArtworkBackdrop: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let gradient = settings.appTheme.gradient {
            Rectangle().fill(gradient)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        } else {
            coverBackdrop
        }
    }

    private var coverBackdrop: some View {
        // The black base decides the size; the cover is only painted over it and clipped.
        Color.black
            .overlay {
                AsyncImage(url: player.track?.artworkURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .saturation(1.35)
                            .blur(radius: 70, opaque: true)
                            .scaleEffect(1.4)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.6), value: player.track?.artworkURL)
            }
            .overlay {
                LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

extension View {
    /// A sheet's own background: the system's glass on iOS 26 (the player shows through it,
    /// blurred), the cover backdrop before.
    @ViewBuilder
    func glassSheetBackground() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            background { ArtworkBackdrop() }
        }
    }

    /// A bar's material before iOS 26; on 26 what is in it floats on its own glass.
    @ViewBuilder
    func legacyBarMaterial() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            background(.ultraThinMaterial)
        }
    }

    /// A settings page on the cover backdrop instead of flat grey.
    func settingsPage() -> some View {
        scrollContentBackground(.hidden)
            .background { ArtworkBackdrop() }
    }
}

// MARK: - Liquid Glass

/// How a glass surface looks: plain, or tinted with a colour (a primary button, a lit toggle).
struct GlassLook {
    var tint: Color?
    /// Reacts to touch: it brightens and swells under the finger (iOS 26).
    var interactive = false
    /// See-through, for small things over busy pictures (the cover, the lyrics).
    var clear = false

    static let regular = GlassLook()
    static let pressable = GlassLook(interactive: true)
    static func tinted(_ color: Color, interactive: Bool = true) -> GlassLook {
        GlassLook(tint: color, interactive: interactive)
    }

    @available(iOS 26.0, *)
    var glass: Glass {
        var glass: Glass = clear ? .clear : .regular
        if let tint { glass = glass.tint(tint) }
        return glass.interactive(interactive)
    }
}

extension View {
    /// Liquid Glass behind the view (iOS 26), a dark material with a hairline edge before it.
    @ViewBuilder
    func glass<S: Shape>(_ look: GlassLook = .regular, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(look.glass, in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint = look.tint { shape.fill(tint.opacity(0.55)) }
                    shape.stroke(.white.opacity(0.14), lineWidth: 0.6)
                }
                .environment(\.colorScheme, .dark)
            }
        }
    }

    func glassCapsule(_ look: GlassLook = .regular) -> some View { glass(look, in: Capsule()) }
    func glassCircle(_ look: GlassLook = .regular) -> some View { glass(look, in: Circle()) }
    func glassCard(_ look: GlassLook = .regular, radius: CGFloat = 22) -> some View {
        glass(look, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// The system's glass button (iOS 26); a material capsule that squeezes when pressed before it.
    /// `prominent` fills it with `tint` (or the accent colour): the one main action on a screen.
    @ViewBuilder
    func glassButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent).tint(tint ?? .accentColor)
            } else {
                buttonStyle(.glass).tint(tint)
            }
        } else {
            buttonStyle(FallbackGlassButtonStyle(tint: prominent ? (tint ?? .accentColor) : tint, prominent: prominent))
        }
    }
}

/// Glass shapes close together melt into each other and morph when one appears (iOS 26).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// What `glassButton` is before iOS 26.
private struct FallbackGlassButtonStyle: ButtonStyle {
    var tint: Color?
    var prominent: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(prominent ? .black : .white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background {
                ZStack {
                    if prominent, let tint {
                        Capsule().fill(tint)
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                        if let tint { Capsule().fill(tint.opacity(0.4)) }
                    }
                    Capsule().strokeBorder(.white.opacity(configuration.isPressed ? 0.3 : 0.14), lineWidth: 0.6)
                }
                .environment(\.colorScheme, .dark)
            }
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.62),
                       value: configuration.isPressed)
    }
}

/// A round glass button with a symbol in it ("•••", close, the queue's little buttons).
struct GlassIconLabel: View {
    let systemName: String
    var size: CGFloat = 36
    var weight: Font.Weight = .semibold
    var look: GlassLook = .pressable

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: weight))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .glassCircle(look)
            .contentShape(Circle())
    }
}

/// Light sweeping across placeholder shapes while something loads.
struct Shimmer: ViewModifier {
    var active = true
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if active && !reduceMotion {
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.6)
                            .offset(x: phase * geometry.size.width * 1.3)
                            .blendMode(.plusLighter)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmer(_ active: Bool = true) -> some View { modifier(Shimmer(active: active)) }

    /// Comes in from a blur, a little lower, `index` steps after the first: content that
    /// arrives in pieces (an answer, a list) settles one piece after another.
    func staggeredReveal(_ shown: Bool, index: Int = 0) -> some View {
        modifier(StaggeredReveal(shown: shown, index: index))
    }
}

private struct StaggeredReveal: ViewModifier {
    var shown: Bool
    var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduceMotion ? 0 : 10)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .animation(.spring(response: 0.55, dampingFraction: 0.86).delay(shown ? Double(index) * 0.07 : 0), value: shown)
    }
}

/// Press feedback shared by the custom buttons: a quick squeeze, then a spring back.
struct SquishButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.62),
                       value: configuration.isPressed)
    }
}

/// Four bars bouncing out of phase: "this one is playing". Still when paused or with Reduce Motion.
struct EqualizerBars: View {
    var playing: Bool
    var color: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !playing || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 4 + 12 * level(time, index))
                }
            }
            .frame(height: 16, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }

    private func level(_ time: Double, _ index: Int) -> Double {
        guard playing, !reduceMotion else { return 0.3 }
        let i = Double(index)
        return 0.5 + 0.5 * sin(time * (3.2 + i * 1.3) + i * 1.7)
    }
}
