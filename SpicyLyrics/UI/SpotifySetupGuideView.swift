import SwiftUI

/// Step-by-step guide to creating one's own Spotify developer app and signing in with its
/// Client ID. Required for everyone: the app has no Client ID of its own.
struct SpotifySetupGuideView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var draft = ""
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false
    @State private var bundleCopied = false

    private static let dashboard = URL(string: "https://developer.spotify.com/dashboard")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Свой доступ к Spotify"))
                        .font(.largeTitle.bold())
                    Text(String(localized: "Приложению нужен ваш собственный Client ID: так Spotify разрешает ему видеть, что у вас играет. Это бесплатно и занимает около 5 минут."))
                        .foregroundStyle(.white.opacity(0.75))
                }

                requirementCard

                step(1, String(localized: "Откройте Spotify for Developers")) {
                    Text(String(localized: "Войдите тем же аккаунтом, что и в приложении Spotify. При первом входе примите условия (Accept the terms) и подтвердите e-mail, если попросят."))
                    actionButton(String(localized: "Открыть developer.spotify.com"), systemImage: "safari") {
                        openURL(Self.dashboard)
                    }
                    Text(String(localized: "Удобнее делать с компьютера, но и с телефона получится."))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                }

                step(2, String(localized: "Создайте приложение")) {
                    Text("Нажмите **Create app** и заполните форму:")
                    bullet("**App name** — любое, например «Sweet Lyrics».")
                    bullet("**App description** — любое, например «Тексты песен».")
                    bullet("**Website** — можно оставить пустым.")
                    bullet("**Redirect URIs** — вставьте адрес ниже и нажмите **Add**:")
                    redirectURIBox
                    bullet("В **Which API/SDKs are you planning to use?** отметьте **Web API** и **iOS**.")
                    bullet("Для **iOS** вставьте в **iOS app bundles** этот Bundle ID (так текст идёт точно в такт прямо из приложения Spotify):")
                    copyBox(Bundle.main.bundleIdentifier ?? "", copied: $bundleCopied)
                    bullet("Поставьте галочку согласия с условиями и нажмите **Save**.")
                }

                step(3, String(localized: "Добавьте себя в пользователи")) {
                    Text("В приложении откройте **Settings** → вкладка **User Management** → **Add new user**. Имя любое, e-mail — тот, к которому привязан ваш аккаунт Spotify, затем **Add user**.")
                    Text(String(localized: "Так же можно добавить ещё до четырёх друзей, и они войдут с вашим Client ID."))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                }

                step(4, String(localized: "Скопируйте Client ID")) {
                    Text("Вкладка **Basic Information** → поле **Client ID** (32 символа, буквы и цифры) → скопируйте.")
                    Label(String(localized: "Client secret не нужен. Никому его не отправляйте."), systemImage: "exclamationmark.shield")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                step(5, String(localized: "Вставьте Client ID и войдите")) {
                    clientIDField
                    if let error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    Button {
                        Task { await saveAndLogIn() }
                    } label: {
                        HStack {
                            if busy { ProgressView().tint(.black) }
                            Text(String(localized: "Сохранить и войти"))
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .foregroundStyle(.black)
                    }
                    .glassButton(prominent: true, tint: Color(red: 0.12, green: 0.84, blue: 0.38))
                    .controlSize(.large)
                    .disabled(busy || !AppSettings.isValidClientID(draft))
                }

                troubleshooting
            }
            .padding(22)
        }
        .background(
            LinearGradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.14), .black],
                           startPoint: .topLeading, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .foregroundStyle(.white)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if draft.isEmpty { draft = settings.spotifyClientID }
        }
    }

    // MARK: Pieces

    private var requirementCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(localized: "Что понадобится"), systemImage: "checklist")
                .font(.headline)
            Text("• Аккаунт **Spotify Premium**: с 2026 года Spotify запускает приложения разработчиков только у владельцев с Premium.")
            Text(String(localized: "• 5 минут и браузер."))
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 18)
    }

    private var redirectURIBox: some View {
        copyBox(SpotifyAuth.redirectURI, copied: $copied)
    }

    private func copyBox(_ value: String, copied: Binding<Bool>) -> some View {
        HStack {
            Text(value)
                .font(.callout.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .textSelection(.enabled)
            Spacer()
            Button {
                UIPasteboard.general.string = value
                copied.wrappedValue = true
            } label: {
                Label(copied.wrappedValue ? String(localized: "Скопировано") : String(localized: "Скопировать"),
                      systemImage: copied.wrappedValue ? "checkmark" : "doc.on.doc")
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(12)
        .glassCard(radius: 14)
    }

    private var clientIDField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Client ID", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button {
                    if let text = UIPasteboard.general.string {
                        draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Label(String(localized: "Вставить"), systemImage: "doc.on.clipboard")
                        .font(.footnote.weight(.semibold))
                }
            }
            .padding(12)
            .glassCard(radius: 14)

            if !draft.isEmpty && !AppSettings.isValidClientID(draft) {
                Text(String(localized: "Client ID — это 32 символа из цифр и букв a–f. Проверьте, что скопирован именно Client ID, а не Client secret."))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Если не получается"))
                .font(.headline)
            problem("«INVALID_CLIENT: Invalid redirect URI»",
                    String(localized: "Redirect URI в приложении Spotify должен быть ровно spicylyrics-ios://callback — без пробелов и без слэша в конце. После правки нажмите Save."))
            problem("«INVALID_CLIENT: Invalid client»",
                    String(localized: "Client ID скопирован не полностью или с ошибкой. Скопируйте его ещё раз со вкладки Basic Information."))
            problem(String(localized: "Вход прошёл, но Spotify отвечает ошибкой 403"),
                    String(localized: "Добавьте свой e-mail в User Management (шаг 3) и проверьте, что у владельца приложения есть Premium."))
            problem(String(localized: "«Закончился лимит запросов»"),
                    String(localized: "Spotify ограничивает число запросов на аккаунт разработчика. Подождите несколько минут."))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 18)
    }

    private func problem(_ title: String, _ fix: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.semibold))
            Text(fix).font(.callout).foregroundStyle(.white.opacity(0.7))
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 32, height: 32)
                .glassCircle(.tinted(Color(red: 0.12, green: 0.84, blue: 0.38).opacity(0.85), interactive: false))
                .foregroundStyle(.black)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.weight(.semibold))
                content()
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
        }
        .glassButton()
    }

    // MARK: Sign in

    private func saveAndLogIn() async {
        let clientID = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppSettings.isValidClientID(clientID) else { return }
        busy = true
        error = nil
        defer { busy = false }
        // Switches over only if sign-in works: a cancelled attempt keeps the current session.
        do {
            try await auth.logIn(clientID: clientID)
            dismiss()
        } catch {
            if case SpotifyAuthError.cancelled = error { return }
            self.error = error.localizedDescription
        }
    }
}
