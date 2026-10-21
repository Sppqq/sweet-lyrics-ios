import SwiftUI
import MediaPlayer

/// First run: set up one's own Spotify Client ID (step-by-step guide), then sign in with it.
struct OnboardingView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player
    @State private var selectedSource: PlaybackSource = .spotify
    @State private var error: String?
    @State private var busy = false

    private var canLogIn: Bool { settings.hasValidClientID }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sweet Lyrics")
                            .font(.system(size: 40, weight: .heavy))
                        Text(String(localized: "Пословные тексты для Spotify и Apple Music."))
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    if let error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }

                    Picker(String(localized: "Источник музыки"), selection: $selectedSource) {
                        ForEach(PlaybackSource.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if selectedSource == .spotify {
                        accessExplanation
                    } else {
                        Text(String(localized: "Apple Music работает без Spotify Client ID. Разрешите доступ к медиатеке и включите песню в приложении «Музыка»."))
                            .foregroundStyle(.secondary)
                    }

                    Text(String(localized: "Приложение не связано со Spotify AB и с авторами Spicy Lyrics. Это неофициальный порт расширения Spicy Lyrics под AGPL-3.0."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            // The actions sit at the bottom, under the thumb.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if selectedSource == .appleMusic {
                        Button {
                            Task {
                                busy = true
                                error = nil
                                defer { busy = false }
                                await player.appleMusic.requestAuthorization()
                                guard player.appleMusic.authorization == .authorized else {
                                    error = String(localized: "Доступ к Музыке не разрешён. Откройте Настройки → Sweet Lyrics и разрешите доступ к медиатеке.")
                                    return
                                }
                                settings.appleMusicOnboarded = true
                                settings.playbackSource = .appleMusic
                            }
                        } label: {
                            Text(String(localized: "Продолжить с Apple Music"))
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .foregroundStyle(.black)
                        }
                        .glassButton(prominent: true, tint: .white)
                        .controlSize(.large)
                        .disabled(busy)
                    } else {
                        if canLogIn {
                            loginButton
                        }
                        NavigationLink {
                            SpotifySetupGuideView()
                        } label: {
                            Label(canLogIn ? String(localized: "Сменить Client ID") : String(localized: "Настроить доступ к Spotify"),
                                  systemImage: "key.horizontal")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .foregroundStyle(canLogIn ? .white : .black)
                        }
                        .glassButton(prominent: !canLogIn, tint: canLogIn ? nil : .white)
                        .controlSize(.large)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .background(
                LinearGradient(colors: [Color(red: 0.25, green: 0.1, blue: 0.35), .black],
                               startPoint: .topLeading, endPoint: .bottom)
                    .ignoresSafeArea()
            )
        }
    }

    private var loginButton: some View {
        Button {
            Task { await logIn() }
        } label: {
            HStack {
                if busy { ProgressView().tint(.black) }
                Text(String(localized: "Войти через Spotify"))
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .foregroundStyle(.black)
        }
        .glassButton(prominent: true, tint: Color(red: 0.12, green: 0.84, blue: 0.38))
        .controlSize(.large)
        .disabled(busy)
    }

    @ViewBuilder
    private var accessExplanation: some View {
        if canLogIn {
            Text(String(localized: "Используется ваш Client ID …\(String(settings.spotifyClientID.suffix(4)))."))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
        } else {
            Text(String(localized: "Чтобы приложение видело, что играет в Spotify, нужно своё приложение в бесплатном кабинете разработчика Spotify и его Client ID. Это обязательно и занимает около 5 минут (нужен Spotify Premium). Пошаговая инструкция — по кнопке ниже."))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func logIn() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await auth.logIn()
            settings.playbackSource = .spotify
        } catch SpotifyAuthError.cancelled {
            // Nothing to report.
        } catch {
            self.error = error.localizedDescription
        }
    }
}
