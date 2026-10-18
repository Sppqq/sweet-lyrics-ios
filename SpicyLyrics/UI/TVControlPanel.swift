import SwiftUI

/// While a TV shows the lyrics, the phone shows how they look there instead of a second copy of
/// them: size, delay, layout and background, saved for the next time. It comes in with the
/// AirPlay rings spreading out and the cards rising one after another.
struct TVControlPanel: View {
    @ObservedObject private var externalDisplay = ExternalDisplay.shared
    @Environment(AppSettings.self) private var settings
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    /// Show the lyrics on the phone again.
    var onShowLyrics: () -> Void = {}

    @State private var appeared = false

    var body: some View {
        @Bindable var settings = settings
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                hero
                    .padding(.bottom, 2)
                    .staged(0, appeared)

                card {
                    ValueSlider(title: String(localized: "Размер текста"), value: $settings.tvLyricsScale,
                                range: 0.6...1.6, step: 0.05, minIcon: "textformat.size.smaller",
                                maxIcon: "textformat.size.larger") { "\(Int(($0 * 100).rounded()))%" }
                    Divider().overlay(.white.opacity(0.15))
                    offsetRow
                }
                .staged(1, appeared)

                card {
                    Toggle(String(localized: "Обложка и название"), isOn: $settings.tvShowNowBar)
                    Divider().overlay(.white.opacity(0.15))
                    Toggle(String(localized: "Полоса времени"), isOn: $settings.tvShowTimeline)
                        .disabled(!settings.tvShowNowBar)
                }
                .staged(2, appeared)

                card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "Фон"))
                        Picker(String(localized: "Фон"), selection: $settings.tvBackground) {
                            ForEach(TVBackground.allCases) { background in
                                Text(background.title).tag(background.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if settings.tvBackground != TVBackground.black.rawValue {
                        Divider().overlay(.white.opacity(0.15))
                        ValueSlider(title: String(localized: "Затемнение"), value: $settings.tvBackgroundDim,
                                    range: 0...0.7, step: 0.02, minIcon: "sun.max", maxIcon: "moon") {
                            "\(Int(($0 * 100).rounded()))%"
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: settings.tvBackground)
                .staged(3, appeared)

                HStack(spacing: 10) {
                    Button(action: onShowLyrics) {
                        Label(String(localized: "На телефон"), systemImage: "iphone")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) { settings.resetTV() }
                    } label: {
                        Label(String(localized: "Сбросить"), systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .buttonStyle(PanelButtonStyle())
                .staged(4, appeared)

                Text(String(localized: "Всё сохраняется и применится, когда телевизор подключится в следующий раз."))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .staged(5, appeared)
            }
            .foregroundStyle(.white)
            .tint(.white)
            .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.2, green: 0.78, blue: 0.35)))
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Between the header and the controls, fading out at both ends: nothing scrolls under
        // the buttons.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
            }
        }
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .environment(\.colorScheme, .dark)
        .onAppear { appeared = true }
    }

    // MARK: Hero

    /// The AirPlay screen icon popping in, with rings spreading out from it like a signal.
    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    Circle()
                        .stroke(.white.opacity(0.55), lineWidth: 1.5)
                        .frame(width: 64, height: 64)
                        .scaleEffect(appeared ? 2.3 : 0.9)
                        .opacity(appeared ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.7).delay(0.2 + Double(ring) * 0.35), value: appeared)
                }
                Circle()
                    .fill(.white.opacity(0.14))
                    .frame(width: 64, height: 64)
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .white.opacity(0.25), radius: 18)
                Image(systemName: "airplay.video")
                    .font(.system(size: 27, weight: .semibold))
                    .symbolEffect(.bounce, value: appeared)
            }
            .frame(height: 84)
            .scaleEffect(appeared ? 1 : 0.3)
            .animation(.spring(response: 0.6, dampingFraction: 0.62), value: appeared)

            VStack(spacing: 4) {
                Text(String(localized: "Текст на телевизоре"))
                    .font(.title3.weight(.bold))
                Text(screenLine)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var screenLine: String {
        guard let size = externalDisplay.screenPixels, size.width > 0 else {
            return String(localized: "Телефон теперь пульт")
        }
        let width = Int(max(size.width, size.height)), height = Int(min(size.width, size.height))
        return String(localized: "Телефон теперь пульт") + " · \(width) × \(height)"
    }

    // MARK: Delay

    /// A TV shows the picture a little after the sound: the lyrics there can run ahead to match.
    private var offsetRow: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "Сдвиг текста"))
                Spacer()
                Text(Self.formatOffset(settings.tvOffsetMs))
                    .foregroundStyle(.white.opacity(0.65))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: settings.tvOffsetMs))
            }
            HStack(spacing: 12) {
                stepButton("minus", by: -50)
                Slider(value: $settings.tvOffsetMs, in: -1000...1500, step: 10)
                stepButton("plus", by: 50)
            }
            Text(String(localized: "Если текст на телевизоре отстаёт от музыки, сдвиньте вправо; если спешит — влево."))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func stepButton(_ symbol: String, by step: Double) -> some View {
        Button {
            withAnimation(.snappy) {
                settings.tvOffsetMs = clamp(settings.tvOffsetMs + step, -1000, 1500)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.15), in: Circle())
        }
        .buttonStyle(SquishButtonStyle(scale: 0.85))
        .buttonRepeatBehavior(.enabled)
    }

    static func formatOffset(_ ms: Double) -> String {
        let value = Int(ms.rounded())
        if value == 0 { return String(localized: "0 мс") }
        return (value > 0 ? "+" : "−") + "\(abs(value)) " + String(localized: "мс")
    }

    // MARK: Cards

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
    }
}

/// A titled slider with its value and a small icon at each end.
private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double
    var minIcon: String
    var maxIcon: String
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .foregroundStyle(.white.opacity(0.65))
                    .monospacedDigit()
            }
            HStack(spacing: 12) {
                Image(systemName: minIcon).font(.footnote).foregroundStyle(.white.opacity(0.6))
                Slider(value: $value, in: range, step: step)
                Image(systemName: maxIcon).font(.body).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

private struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 13)
            .padding(.horizontal, 10)
            .background(.white.opacity(configuration.isPressed ? 0.24 : 0.15),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

private extension View {
    /// Rises into place after the ones before it.
    func staged(_ index: Int, _ shown: Bool) -> some View {
        self
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 28)
            .blur(radius: shown ? 0 : 6)
            .animation(.spring(response: 0.6, dampingFraction: 0.82).delay(0.12 + Double(index) * 0.07), value: shown)
    }
}

/// Blurs, shrinks a little and fades: the lyrics making way for the TV panel and back.
struct BlurFade: ViewModifier {
    let amount: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: 18 * amount)
            .scaleEffect(1 - 0.07 * amount)
            .opacity(1 - Double(amount))
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0))
    }
}
