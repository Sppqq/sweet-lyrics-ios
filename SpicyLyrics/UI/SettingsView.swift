import SwiftUI
import MediaPlayer

/// Settings laid out like iOS Settings: a short list of clearly named categories, each opening
/// its own page.
struct SettingsView: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player
    @Environment(PerformanceMonitor.self) private var performance
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            QuickTile(title: String(localized: "Экономия"), icon: "bolt.fill", tint: .yellow,
                                      isOn: Binding(get: { settings.powerSaving }, set: { settings.powerSaving = $0 }))
                            QuickTile(title: String(localized: "Фон"), icon: "photo.fill", tint: .indigo,
                                      isOn: Binding(get: { settings.dynamicBackground }, set: { settings.dynamicBackground = $0 }))
                            QuickTile(title: String(localized: "Перевод"), icon: "character.bubble.fill", tint: .blue,
                                      isOn: Binding(get: { settings.translateLyrics }, set: { settings.translateLyrics = $0 }))
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }

                    ForEach(SettingsGroup.allCases) { group in
                        Section(group.title) {
                            ForEach(group.pages) { page in
                                category(page, value: summary(page))
                            }
                        }
                    }

                    Section {
                        category(.about, value: summary(.about))
                        if settings.showStarRow { starRow }
                    }
                } else {
                    searchResults
                }
            }
            .settingsPage()
            .navigationTitle(String(localized: "Настройки"))
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: String(localized: "Поиск в настройках"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Готово")) { dismiss() }
                }
            }
        }
    }

    /// How many experiments are switched on.
    private var experimentsSummary: String? {
        let changed = [settings.backgroundLinePop, settings.refreshedSimpleLyrics].filter { $0 }.count
        return changed == 0 ? nil : String(localized: "Изменено: \(changed)")
    }

    /// The short value on the right of a page's row.
    private func summary(_ page: SettingsPage) -> String? {
        switch page {
        case .fontAndLines: return LyricsFontChoice(stored: settings.lyricsFont).title
        case .animation: return settings.simpleLyricsMode ? "Simple" : nil
        case .scrolling: return settings.smoothScrolling ? nil : String(localized: "Без плавности")
        case .translation: return translationSummary
        case .credits: return nil
        case .themeAndBackground:
            return settings.dynamicBackground ? settings.appTheme.title : String(localized: "Выкл.")
        case .playerScreen: return nil
        case .noLyrics:
            return AutoSkipMode(rawValue: settings.autoSkipMode).flatMap { $0 == .off ? nil : $0.title }
        case .landscape: return settings.landscapeLyricsOnly ? String(localized: "Только текст") : nil
        case .gestures: return settings.gesturesEnabled ? String(localized: "Вкл.") : String(localized: "Выкл.")
        case .pictureInPicture: return settings.autoPictureInPicture ? String(localized: "Авто") : nil
        case .musicSource: return settings.playbackSource.title
        case .sync: return settings.timingOffsetMs == 0 ? nil : String(localized: "\(Int(settings.timingOffsetMs)) мс")
        case .lyricsSources: return nil
        case .performance:
            return settings.powerSaving ? String(localized: "Экономия")
                : (performance.constrained ? String(localized: "Авто-экономия") : nil)
        case .experiments: return experimentsSummary
        case .reports:
            return ReportService.shared.unreadCount > 0 ? String(localized: "Новый ответ")
                : (settings.sendsReports ? String(localized: "Вкл.") : nil)
        case .about: return updates.latest.map { String(localized: "Есть \($0.version)") } ?? AppVersion.display
        }
    }

    /// Every setting whose name, section or page has the query in it, under the page it is on.
    private var searchResults: some View {
        let hits = SettingsIndex.search(query)
        return Section {
            if hits.isEmpty {
                Text(String(localized: "Ничего не нашлось"))
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.white.opacity(0.09))
            }
            ForEach(hits) { hit in
                NavigationLink {
                    SettingsDestination(page: hit.page)
                } label: {
                    HStack(spacing: 12) {
                        categoryIcon(hit.page.icon, hit.page.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.title)
                            Text(hit.page.group.map { "\($0.title) → \(hit.page.title)" } ?? hit.page.title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.white.opacity(0.09))
            }
        }
    }

    private var translationSummary: String? {
        switch (settings.translateLyrics, settings.showRomanization) {
        case (true, true): return String(localized: "Оба")
        case (true, false): return String(localized: "Перевод")
        case (false, true): return String(localized: "Романизация")
        case (false, false): return nil
        }
    }

    private func category(_ page: SettingsPage, value: String? = nil) -> some View {
        NavigationLink {
            SettingsDestination(page: page)
        } label: {
            HStack(spacing: 12) {
                categoryIcon(page.icon, page.color)
                Text(page.title)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .listRowBackground(Color.white.opacity(0.09))
    }

    private func categoryIcon(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
                    }
            }
    }

    /// Opens the repository: free app, a star is the thanks.
    private var starRow: some View {
        Link(destination: AppLinks.repository) {
            HStack(spacing: 12) {
                categoryIcon("star.fill", .yellow)
                Text(String(localized: "Поставить звезду на GitHub"))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .listRowBackground(Color.white.opacity(0.09))
        // Swipe to hide; Settings → About brings it back.
        .swipeActions {
            Button(String(localized: "Скрыть")) {
                withAnimation { settings.showStarRow = false }
            }
            .tint(.gray)
        }
    }
}

// MARK: - Building blocks

/// A big on/off tile for the three switches people reach for most.
private struct QuickTile: View {
    let title: String
    let icon: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.74)) { isOn.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(isOn ? .white : .secondary)
                    .symbolEffect(.bounce, value: isOn)
                Spacer(minLength: 0)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isOn ? .white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .glassCard(isOn ? .tinted(tint.opacity(0.85)) : .pressable, radius: 18)
            .animation(.spring(response: 0.38, dampingFraction: 0.74), value: isOn)
        }
        .buttonStyle(SquishButtonStyle())
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityValue(isOn ? String(localized: "Вкл.") : String(localized: "Выкл."))
    }
}

/// A slider with its title and current value on one line above it.
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05
    /// How the value is shown; percent of 1 by default.
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

/// A "back to defaults" button at the bottom of a page.
private struct ResetSection: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Section {
            Button(title, role: .destructive) {
                withAnimation { action() }
            }
        }
    }
}

// MARK: - Pages

private struct FontLinesSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section { LyricPreview() }

            Section {
                NavigationLink {
                    FontSettings()
                        .settingsPage()
                        .navigationTitle(String(localized: "Шрифт"))
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    LabeledContent(String(localized: "Шрифт"), value: LyricsFontChoice(stored: settings.lyricsFont).title)
                }
                Picker(String(localized: "Насыщенность шрифта"), selection: $settings.lyricsWeight) {
                    ForEach(LyricsWeight.allCases) { weight in
                        Text(weight.title).tag(weight.rawValue)
                    }
                }
                SliderRow(title: String(localized: "Размер"), value: $settings.fontSize,
                          range: Double(AppSettings.fontRange.lowerBound)...Double(AppSettings.fontRange.upperBound),
                          step: 1, format: { "\(Int($0)) pt" })
                Toggle(String(localized: "По центру"), isOn: $settings.centerLyrics)
            } footer: {
                Text(String(localized: "Размер можно менять и щипком двумя пальцами прямо по тексту. После этого на пару секунд появится кнопка «Сбросить размер»."))
            }

            Section(String(localized: "Расстояния")) {
                SliderRow(title: String(localized: "Между строками"), value: $settings.lineSpacingScale, range: 0...4, step: 0.25)
            }

            Section {
                Toggle(String(localized: "Склеивать слова из слогов"), isOn: $settings.joinSplitWords)
                Toggle(String(localized: "Отступ дуэтов"), isOn: $settings.duetLinePadding)
            } header: {
                Text(String(localized: "Строки"))
            } footer: {
                Text(String(localized: "Слово, спетое по слогам, показывается одним словом, если слоги идут ровно. В дуэтах строки каждого исполнителя отступают к своей стороне, как две колонки."))
            }

            ResetSection(title: String(localized: "Вернуть как было")) { settings.resetLyricsLook() }
        }
    }
}

private struct ScrollSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                SliderRow(title: String(localized: "Положение активной строки"), value: $settings.activeLinePosition,
                          range: 0.2...0.8, step: 0.05, format: Self.positionLabel)
                Toggle(String(localized: "Плавная прокрутка"), isOn: $settings.smoothScrolling)
                if settings.smoothScrolling {
                    SliderRow(title: String(localized: "Скорость прокрутки"), value: $settings.scrollSpeed, range: 0.5...3, step: 0.25)
                }
                Toggle(String(localized: "Раннее пролистывание"), isOn: $settings.earlyScroll)
                if settings.earlyScroll {
                    SliderRow(title: String(localized: "Время раннего пролистывания"), value: $settings.earlyScrollMs,
                              range: 0...1000, step: 50, format: { "\(Int($0)) ms" })
                }
                Toggle(String(localized: "Перемотка чуть раньше строки"), isOn: $settings.seekFadeCompensation)
            } header: {
                Text(String(localized: "Прокрутка"))
            } footer: {
                Text(String(localized: "Где держится строка, которую поют, и как быстро текст доезжает до следующей. Тап по строке может перематывать на 300 мс раньше, чтобы плавное нарастание звука после перемотки не съедало первое слово: полезно для рэпа и быстрых песен."))
            }
        }
    }

    private static func positionLabel(_ value: Double) -> String {
        if abs(value - 0.5) < 0.01 { return String(localized: "По центру") }
        return value < 0.5 ? String(localized: "Выше на \(Int(((0.5 - value) * 100).rounded()))%")
                           : String(localized: "Ниже на \(Int(((value - 0.5) * 100).rounded()))%")
    }
}

private struct CreditsSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Новый вид титров"), isOn: $settings.refinedCredits)
            } footer: {
                Text(String(localized: "Авторы и источник текста под последней строкой: тихим шрифтом, без рамки, приглушены, пока последняя строка не спета. Для текстов от сообщества — кто сделал и кто загрузил. Выключите, чтобы вернуть прежние строки."))
            }

            Section {
                Toggle(String(localized: "Титры за последним исполнителем"), isOn: $settings.creditsFollowLastLine)
            } footer: {
                Text(String(localized: "Если песня кончается дуэтной строкой справа, авторы и источник текста встают под неё."))
            }
        }
    }
}

private struct EffectsSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Simple Lyrics Mode", isOn: $settings.simpleLyricsMode)
            } footer: {
                Text(String(localized: "Спокойная анимация из оригинального расширения: слова не подпрыгивают и не светятся, заливка мягче."))
            }

            Section {
                Toggle(String(localized: "Скрывать спетые строки"), isOn: $settings.minimalLyricsMode)
                if settings.minimalLyricsMode {
                    Toggle(String(localized: "Оставлять перекрывающиеся строки"), isOn: $settings.keepOverlappingLines)
                }
            } footer: {
                Text(String(localized: "Спетые строки плавно исчезают, следующие ждут чуть меньше и тусклее (Minimal Lyrics Mode). Строка, которая кончилась, пока выше ещё поют (бэк-вокал, наложения), может остаться приглушённой."))
            }

            Section {
                Toggle(String(localized: "Размывать неактивные строки"), isOn: $settings.blurInactiveLines)
                if settings.blurInactiveLines {
                    SliderRow(title: String(localized: "Сила размытия"), value: $settings.blurStrength, range: 0.25...2.5)
                }
            } header: {
                Text(String(localized: "Размытие"))
            } footer: {
                Text(String(localized: "Строки размываются тем сильнее, чем дальше они от текущей."))
            }

            Section {
                SliderRow(title: String(localized: "Свечение слов"), value: $settings.glowStrength, range: 0...2)
                    .disabled(settings.simpleLyricsMode)
                SliderRow(title: String(localized: "Яркость остальных строк"), value: $settings.inactiveBrightness, range: 0.5...1.5)
            } header: {
                Text(String(localized: "Свет"))
            } footer: {
                Text(settings.simpleLyricsMode
                     ? String(localized: "В Simple Lyrics Mode слова не светятся.")
                     : String(localized: "Свечение — мягкий ореол вокруг спетых слов."))
            }

            ResetSection(title: String(localized: "Вернуть эффекты по умолчанию")) { settings.resetEffects() }
        }
    }
}

private struct BackgroundSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PerformanceMonitor.self) private var performance

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                NavigationLink {
                    ThemeSettings()
                        .settingsPage()
                        .navigationTitle(String(localized: "Тема"))
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    LabeledContent(String(localized: "Тема"), value: settings.appTheme.title)
                }
            }

            Section {
                Toggle(String(localized: "Обложка на фоне"), isOn: $settings.dynamicBackground)
            } footer: {
                if settings.powerSaving || performance.constrained {
                    Text(String(localized: "Сейчас включена экономия батареи, поэтому фон не двигается."))
                } else {
                    Text(String(localized: "Размытая обложка трека, которая медленно плавает за текстом."))
                }
            }

            if settings.dynamicBackground {
                Section {
                    Picker(String(localized: "Что на фоне"), selection: $settings.backgroundStyle) {
                        ForEach(BackgroundStyle.offered) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }
                } footer: {
                    Text(backgroundStyleNote)
                }

                Section(String(localized: "Обложка")) {
                    if settings.background != .cover {
                        SliderRow(title: String(localized: "Скорость движения"), value: $settings.backgroundSpeed, range: 0.25...3)
                    }
                    SliderRow(title: String(localized: "Размытие"), value: $settings.backgroundBlur, range: 0.3...3)
                    SliderRow(title: String(localized: "Насыщенность цвета"), value: $settings.backgroundSaturation, range: 0...2)
                }
            }

            Section {
                SliderRow(title: String(localized: "Затемнение"), value: $settings.backgroundDim, range: 0...0.7, step: 0.02)
            } footer: {
                Text(String(localized: "Чем темнее фон, тем лучше читается белый текст на светлых обложках."))
            }

            ResetSection(title: String(localized: "Вернуть фон по умолчанию")) { settings.resetBackground() }
        }
    }
}

extension BackgroundSettings {
    fileprivate var backgroundStyleNote: String {
        switch settings.background {
        case .dynamic: return String(localized: "Размытая обложка медленно плавает за текстом.")
        case .cover: return String(localized: "Размытая обложка стоит на месте. Меньше тратит батарею.")
        case .artist: return String(localized: "Фото артиста из Spotify, размытое. Если фото нет, видна обложка.")
        case .canvas: return String(localized: "Короткое видео песни из Spotify (Canvas), если оно есть, иначе живая обложка. Расходует больше трафика и батареи.")
        }
    }
}

/// Experiments, as the extension keeps them: new looks that can be switched back to the old one.
private struct ExperimentsSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Выезжающий бэк-вокал"), isOn: $settings.backgroundLinePop)
            } footer: {
                Text(String(localized: "Строки бэк-вокала спрятаны под своей строкой, пока её не начнут петь, потом выезжают из-под неё, а строки ниже расступаются. Когда обе спеты, бэк-вокал прячется обратно. Работает только в Simple Lyrics Mode с обновлённым Simple Lyrics."))
            }

            Section {
                Toggle(String(localized: "Обновлённый Simple Lyrics"), isOn: $settings.refreshedSimpleLyrics)
                    .disabled(!settings.simpleLyricsMode)
            } footer: {
                Text(settings.simpleLyricsMode
                     ? String(localized: "Заливка идёт по строке одним мягким краем, слова всплывают одно за другим, буквы коротких протяжных слов чуть раздуваются, расходятся и светятся. Строки стоят дальше друг от друга, точки в проигрышах заполняются по одной и медленно «дышат».")
                     : String(localized: "Работает только с Simple Lyrics Mode (Текст → Анимация)."))
            }
        }
    }
}

private struct LanguageSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player

    private var providerNote: String {
        switch settings.provider {
        case .apple:
            return String(localized: "Apple переводит прямо на телефоне (iOS 18 и новее), без интернета. Строки, которые уже на выбранном языке, не переводятся. При первом использовании iOS предложит скачать языковую модель.")
        case .server:
            return String(localized: "Строки текста отправляются на сервер Sweet Lyrics, он переводит их через Google. Переводы общие для всех: песню, которую уже кто-то слушал, сервер отдаёт сразу. Ничего о вас не отправляется; переводы запоминаются и на телефоне.")
        case .google, .yandex:
            return String(localized: "Строки текста отправляются в онлайн-переводчик. Нужен интернет; переводы запоминаются на телефоне, повторно песня не переводится. Строки, которые уже на выбранном языке, не переводятся.")
        case .deepl:
            return String(localized: "DeepL переводит лучше всех, но нужен свой ключ API: бесплатного тарифа (500 000 символов в месяц) хватает с запасом. Ключ хранится в связке ключей iOS.")
        }
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Романизация"), isOn: $settings.showRomanization)
            } footer: {
                Text(String(localized: "Латиница вместо японского, китайского, корейского, кириллицы и греческого. Делается прямо на телефоне."))
            }

            Section {
                Toggle(String(localized: "Переводить текст"), isOn: $settings.translateLyrics)
                if settings.translateLyrics {
                    Picker(String(localized: "Переводчик"), selection: $settings.translationProvider) {
                        ForEach(TranslationProvider.allCases.filter(\.isAvailable)) { provider in
                            Text(provider.title).tag(provider.rawValue)
                        }
                    }
                    if settings.provider == .deepl {
                        SecureField(String(localized: "Ключ DeepL API"), text: $settings.deeplKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        Link(String(localized: "Получить бесплатный ключ DeepL"),
                             destination: URL(string: "https://www.deepl.com/your-account/keys")!)
                    }
                    Picker(String(localized: "Язык перевода"), selection: $settings.translationLanguage) {
                        ForEach(LyricsTranslation.languages, id: \.id) { language in
                            Text(language.name).tag(language.id)
                        }
                    }
                    Picker(String(localized: "Показывать"), selection: $settings.translationReplaces) {
                        Text(String(localized: "Под строкой")).tag(false)
                        Text(String(localized: "Вместо строки")).tag(true)
                    }
                    if !settings.translationReplaces {
                        SliderRow(title: String(localized: "Размер перевода"), value: $settings.translationScale, range: 0.6...1.6)
                        SliderRow(title: String(localized: "Яркость перевода"), value: $settings.translationBrightness, range: 0.5...1.6)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = player.translationError, settings.translateLyrics {
                        Text(String(localized: "Последняя ошибка: \(error)"))
                            .foregroundStyle(.orange)
                    }
                    if settings.translateLyrics && settings.translationReplaces {
                        Text(String(localized: "Перевод заменяет оригинал, а слова подсвечиваются по ритму исходной строки: время каждой строки делится между новыми словами по их длине."))
                    }
                    Text(providerNote)
                }
            }

            if settings.translateLyrics {
                ResetSection(title: String(localized: "Вернуть вид перевода")) { settings.resetTranslationLook() }
            }
        }
    }
}

private struct InterfaceSettings: View {
    @Environment(AppSettings.self) private var settings
    /// The language the app runs in now, to tell when a restart is needed.
    @State private var launchLanguage = Bundle.main.preferredLocalizations.first ?? "en"

    private var pendingRestart: Bool {
        switch settings.appLanguage {
        case "en", "ru": return settings.appLanguage != launchLanguage
        default:
            let system = Bundle.preferredLocalizations(from: Bundle.main.localizations,
                                                       forPreferences: Locale.preferredLanguages).first ?? "en"
            return system != launchLanguage
        }
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(String(localized: "Язык"), selection: $settings.appLanguage) {
                    Text(String(localized: "Как на телефоне")).tag("system")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Русский").tag("ru")
                }
            } header: {
                Text(String(localized: "Язык приложения"))
            } footer: {
                if pendingRestart {
                    Text(String(localized: "Язык сменится после перезапуска приложения: закройте его в переключателе приложений и откройте снова."))
                }
            }

            Section {
                Toggle(String(localized: "Прятать кнопки во время песни"), isOn: $settings.autoHideControls)
                if settings.autoHideControls {
                    SliderRow(title: String(localized: "Через"), value: $settings.autoHideDelay, range: 2...12, step: 1,
                              format: { String(localized: "\(Int($0)) с") })
                }
            } footer: {
                Text(String(localized: "Как в Apple Music: кнопки исчезают, пока играет песня. Касание внизу экрана возвращает их."))
            }

            Section {
                Toggle(String(localized: "Строка текста под обложкой"), isOn: $settings.artworkLyricLine)
                Picker(String(localized: "Фон за обложкой"), selection: $settings.artworkBackground) {
                    ForEach(ArtworkBackground.allCases) { background in
                        Text(background.title).tag(background.rawValue)
                    }
                }
                if settings.artworkBackground == ArtworkBackground.nebula.rawValue {
                    Picker(String(localized: "Цвета туманности"), selection: $settings.nebulaColors) {
                        ForEach(NebulaColors.allCases) { colors in
                            Text(colors.title).tag(colors.rawValue)
                        }
                    }
                    Toggle(String(localized: "Звёзды в туманности"), isOn: $settings.nebulaStars)
                }
            } header: {
                Text(String(localized: "Большая обложка"))
            } footer: {
                Text(String(localized: "Кнопка с цитатой внизу слева переключает текст и большую обложку. Под обложкой — строка, которую поют, с бэк-вокалом и теми же анимациями, что и в тексте. За обложкой течёт туманность (в цветах обложки или в случайных, своих для каждой песни) или тот же фон, что и за текстом."))
            }

            Section {
                Toggle(String(localized: "Полоска громкости"), isOn: $settings.showVolumeSlider)
                Toggle(String(localized: "Не гасить экран"), isOn: $settings.keepScreenOn)
            } footer: {
                Text(String(localized: "Текст на телевизоре: включите «Повтор экрана» в Пункте управления (AirPlay) или подключите экран кабелем. Там откроется полноэкранный текст, как в десктопной версии, а телефон останется пультом и не будет гаснуть."))
            }
        }
    }
}

private struct LandscapeSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Только текст"), isOn: $settings.landscapeLyricsOnly)
            } footer: {
                Text(String(localized: "Прячет весь интерфейс: текст занимает весь экран, а кнопки появляются по касанию на несколько секунд."))
            }

            Section {
                Toggle(String(localized: "Обложка"), isOn: $settings.landscapeArtwork)
                Toggle(String(localized: "Название и исполнитель"), isOn: $settings.landscapeTitle)
            } header: {
                Text(String(localized: "Слева от текста"))
            } footer: {
                Text(String(localized: "Если выключить и то и другое, текст сдвинется к центру, когда кнопки спрячутся."))
            }
            .disabled(settings.landscapeLyricsOnly)
        }
    }
}

private struct PictureInPictureSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Открывать при сворачивании"), isOn: $settings.autoPictureInPicture)
                Toggle(String(localized: "Закрывать при возврате в приложение"), isOn: $settings.closePiPOnReturn)
            } footer: {
                Text(String(localized: "Текст поверх других приложений. Вручную окно открывается из меню «•••» в плеере. Если открыть приложение, окно закроется само: текст уже на экране."))
            }

            Section {
                Picker(String(localized: "Форма окна"), selection: $settings.pipFormat) {
                    ForEach(PiPFormat.allCases) { format in
                        Text(format.title).tag(format.rawValue)
                    }
                }
                Toggle(String(localized: "Анимированный фон"), isOn: $settings.pipAnimatedBackground)
                Toggle(String(localized: "Название песни"), isOn: $settings.pipShowTitle)
            } header: {
                Text(String(localized: "Окно"))
            } footer: {
                Text(String(localized: "Широкое окно показывает одну-две строки, вертикальное — больше строк, как в плеере. Анимированный фон — плавающая обложка, как в приложении. На слабых устройствах выключите его; в режиме экономии он и так неподвижен."))
            }

            Section {
                SliderRow(title: String(localized: "Размер текста"), value: $settings.pipTextScale, range: 0.7...1.4)
                SliderRow(title: String(localized: "Затемнение фона"), value: $settings.pipBackgroundDim, range: 0.1...0.8)
                Picker(String(localized: "Частота кадров"), selection: $settings.pipFrameRate) {
                    Text("15").tag(15.0)
                    Text("24").tag(24.0)
                    Text("30").tag(30.0)
                    Text("60").tag(60.0)
                }
                Toggle(String(localized: "Размытие соседних строк"), isOn: $settings.pipBlurLines)
                Toggle(String(localized: "Перевод в окне"), isOn: $settings.pipShowTranslation)
                Toggle(String(localized: "Показывать FPS"), isOn: $settings.pipShowFPS)
            } header: {
                Text(String(localized: "Текст в окне"))
            } footer: {
                Text(String(localized: "Меньше кадров — меньше нагрузка и нагрев. Размытие строк работает, только если оно включено и в «Эффектах»."))
            }

            ResetSection(title: String(localized: "Сбросить вид окна")) { settings.resetPictureInPicture() }
        }
    }
}

private struct GestureSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Жесты"), isOn: $settings.gesturesEnabled)
            } footer: {
                Text(String(localized: "Свайпы и щипок работают на iOS 18 и новее."))
            }

            Section {
                row("hand.draw", String(localized: "Свайп влево / вправо по тексту"), String(localized: "следующий / предыдущий трек"))
                row("arrow.up.left.and.arrow.down.right", String(localized: "Щипок двумя пальцами"), String(localized: "размер текста"))
                row("hand.tap", String(localized: "Долгое нажатие на строку"), String(localized: "перемотать, скопировать, поделиться"))
                row("hand.point.up.left", String(localized: "Касание строки"), String(localized: "перемотать к ней"))
                row("chevron.up", String(localized: "Свайп вверх внизу экрана"), String(localized: "показать кнопки"))
                row("chevron.down", String(localized: "Свайп вниз по заголовку"), String(localized: "спрятать кнопки"))
            } header: {
                Text(String(localized: "Что умеют"))
            } footer: {
                Text(String(localized: "На iPad с клавиатурой: пробел — пауза, ⌘← / ⌘→ — треки."))
            }
        }
    }

    private func row(_ icon: String, _ gesture: String, _ effect: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(gesture)
                Text(effect).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
    }
}

private struct MusicSourceSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(String(localized: "Плеер"), selection: Binding(get: { settings.playerChoice }, set: {
                    if $0 == .appleMusic { settings.appleMusicOnboarded = true }
                    settings.playerChoice = $0
                })) {
                    ForEach(PlayerChoice.allCases) { Text($0.title).tag($0) }
                }
                if settings.playerChoice == .automatic {
                    LabeledContent(String(localized: "Сейчас"), value: settings.playbackSource.title)
                }
            } header: {
                Text(String(localized: "Источник музыки"))
            } footer: {
                if settings.playerChoice == .automatic {
                    Text(String(localized: "Текст идёт за тем плеером, который сейчас играет. Если играют оба, побеждает тот, что на этом телефоне. Для Apple Music нужен доступ к медиатеке, для Spotify — вход."))
                }
            }
            // With Apple Music in the picture its section below has the Spotify link too.
            if settings.playerChoice == .spotify {
                Section {
                    NavigationLink {
                        SpotifySettings()
                            .settingsPage()
                            .navigationTitle("Spotify")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        LabeledContent(String(localized: "Аккаунт Spotify"), value: settings.hasValidClientID
                                       ? "…" + String(settings.spotifyClientID.suffix(4)) : String(localized: "Не настроен"))
                    }
                }
            }
            if settings.playerChoice != .spotify {
                Section {
                    LabeledContent(String(localized: "Доступ к медиатеке"), value: authorizationText)
                    if player.appleMusic.authorization == .notDetermined {
                        Button(String(localized: "Разрешить доступ к Музыке")) {
                            Task { await player.appleMusic.requestAuthorization() }
                        }
                    } else if player.appleMusic.authorization != .authorized {
                        Button(String(localized: "Открыть настройки iOS")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    Button(String(localized: "Открыть Музыку")) {
                        if let url = URL(string: "music:") { UIApplication.shared.open(url) }
                    }
                } footer: {
                    Text(String(localized: "Доступен только системный плеер «Музыки». iOS не разрешает читать воспроизведение других приложений."))
                }
                Section {
                    NavigationLink("Spotify") { SpotifySettings() }
                } footer: {
                    Text(String(localized: "LRCLIB для Apple Music включён всегда. Вход в Spotify необязателен: он позволяет найти соответствие трека для Spicy Lyrics."))
                }
            }
            Section {
                Picker(String(localized: "Режим перехода"), selection: $settings.transitionMode) {
                    Text(String(localized: "Авто (по умолчанию)")).tag(TransitionMode.automatic)
                    Text(String(localized: "Вручную")).tag(TransitionMode.manual)
                }
                if settings.transitionMode == .automatic {
                    if settings.transitionEstimate.autoMix {
                        Text(String(localized: "Определено: AutoMix"))
                    } else if let seconds = settings.transitionEstimate.crossfadeSeconds {
                        Text(String(localized: "Определено: \(Int(seconds)) с"))
                    } else {
                        Text(String(localized: "Пока не определено — дослушайте пару песен до конца"))
                    }
                    Button(String(localized: "Сбросить определение")) { settings.resetTransitionDetection() }
                } else {
                    Picker(String(localized: "Плавный переход в музыкальном приложении"), selection: $settings.crossfadeSeconds) {
                        Text(String(localized: "Выкл.")).tag(0.0)
                        ForEach(1...12, id: \.self) { seconds in
                            Text("\(seconds) " + String(localized: "с")).tag(Double(seconds))
                        }
                    }
                    if settings.playerChoice != .spotify {
                        Toggle("AutoMix", isOn: $settings.appleMusicAutoMix)
                    }
                }
            } footer: {
                Text(String(localized: "Авто оценивает переход по естественным сменам треков отдельно для Spotify и Apple Music. Вручную можно указать настройку музыкального приложения. Это не меняет звук."))
            }
            ResetSection(title: String(localized: "Сбросить настройки перехода")) { settings.resetPlaybackTransitions() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active, settings.playerChoice != .spotify { player.appleMusic.read() }
        }
    }

    private var authorizationText: String {
        switch player.appleMusic.authorization {
        case .authorized: return String(localized: "Разрешён")
        case .notDetermined: return String(localized: "Не запрошен")
        case .denied: return String(localized: "Отклонён")
        case .restricted: return String(localized: "Ограничен")
        @unknown default: return String(localized: "Неизвестно")
        }
    }
}

private struct SyncSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player
    @Environment(SpotifyAppRemote.self) private var appRemote
    @EnvironmentObject private var auth: SpotifyAuth

    @State private var bundleCopied = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            if settings.playerChoice != .appleMusic {
                Section {
                    Toggle(String(localized: "Связь с приложением Spotify"), isOn: $settings.useAppRemote)
                    if settings.useAppRemote {
                        LabeledContent(String(localized: "Состояние"), value: appRemote.statusText)
                        Toggle(String(localized: "Открывать Spotify, если молчит"), isOn: $settings.autoWakeSpotify)
                        if let error = appRemote.lastError, appRemote.status != .connected, !appRemote.otherDeviceActive {
                            Text(error)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                        if appRemote.status == .needsLogin {
                            Button(String(localized: "Войти заново")) {
                                Task {
                                    try? await auth.logIn()
                                    appRemote.refresh()
                                }
                            }
                        } else if appRemote.status == .unavailable || appRemote.status == .connecting {
                            Button(String(localized: "Открыть Spotify и подключиться")) { appRemote.wakeSpotify() }
                        }
                    }
                } header: {
                    Text(String(localized: "Откуда брать время песни"))
                } footer: {
                    Text(String(localized: "Включено: когда Spotify играет на этом iPhone, время песни берётся прямо из приложения Spotify — точно в такт и даже без интернета. Выключено или Spotify играет на другом устройстве (компьютер, колонка): время узнаётся у Spotify через интернет, чуть менее точно."))
                }

                if settings.useAppRemote {
                    Section {
                        Button {
                            UIPasteboard.general.string = Bundle.main.bundleIdentifier
                            bundleCopied = true
                        } label: {
                            LabeledContent("Bundle ID") {
                                Text(bundleCopied ? String(localized: "Скопировано") : (Bundle.main.bundleIdentifier ?? "—"))
                                    .font(.footnote.monospaced())
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                        }
                        .foregroundStyle(.primary)
                        LabeledContent("Redirect URI") {
                            Text(SpotifyAuth.redirectURI).font(.footnote.monospaced())
                        }
                    } header: {
                        Text(String(localized: "Если не подключается"))
                    } footer: {
                        Text(String(localized: "1. Включите музыку в Spotify на этом iPhone. 2. На developer.spotify.com → ваше приложение → Settings отметьте «iOS» и добавьте Bundle ID и Redirect URI отсюда (нажатие копирует Bundle ID; AltStore меняет его при установке). 3. Нажмите «Открыть Spotify и подключиться». Если пишет «Нужно войти заново» — войдите заново: старый вход был без доступа к приложению Spotify."))
                    }
                }
            }

            Section {
                VStack(alignment: .leading) {
                    Text(String(localized: "Сдвиг текста: \(Int(settings.timingOffsetMs)) мс"))
                    Slider(value: $settings.timingOffsetMs, in: -1500...1500, step: 50)
                }
                Button(String(localized: "Сбросить сдвиг")) { settings.timingOffsetMs = 0 }
                    .disabled(settings.timingOffsetMs == 0)
            } header: {
                Text(String(localized: "Текст спешит или опаздывает"))
            } footer: {
                Text(String(localized: "Слова загораются позже, чем их поют, — двигайте вправо (плюс). Раньше — влево (минус)."))
            }

            Section {
                if settings.playerChoice != .appleMusic {
                    SliderRow(title: String(localized: "Через интернет: раз в"), value: $settings.webPollInterval, range: 1...5,
                              step: 0.5, format: { String(format: "%.1f", $0) + " " + String(localized: "с") })
                    SliderRow(title: String(localized: "С приложением Spotify: раз в"), value: $settings.remoteQueryInterval,
                              range: 0.5...5, step: 0.5, format: { String(format: "%.1f", $0) + " " + String(localized: "с") })
                }
                Toggle(String(localized: "Значок сверки над текстом"), isOn: $settings.showSyncIndicator)
            } header: {
                Text(String(localized: "Как часто сверять время"))
            } footer: {
                if settings.playerChoice != .appleMusic {
                    Text(String(localized: "Чаще — точнее, но частые запросы через интернет расходуют общий лимит вашего Client ID. Значок над текстом показывает, откуда пришло время («приложение» или «интернет»), на сколько часы разошлись и как давно была сверка. Нажмите на него, чтобы проверить связь с приложением Spotify."))
                }
            }

            Section {
                Toggle(String(localized: "Учитывать задержку наушников"), isOn: $settings.compensateOutputLatency)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent(AudioRoute.outputName,
                                   value: String(localized: "\(Int((player.appliedOutputLatency * 1000).rounded())) мс"))
                }
            } footer: {
                Text(String(localized: "При воспроизведении на этом iPhone можно вычитать задержку Bluetooth-наушников."))
            }

            Section {
                NavigationLink {
                    SyncLogView()
                        .settingsPage()
                        .navigationTitle(String(localized: "Журнал"))
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    LabeledContent(String(localized: "Журнал"), value: settings.syncLogEnabled ? "" : String(localized: "Выкл."))
                }
            } footer: {
                Text(String(localized: "Что приложение узнавало о песне и времени: пригодится, если текст отстаёт."))
            }
        }
    }
}

private struct PerformanceSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PerformanceMonitor.self) private var performance

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Экономия батареи"), isOn: $settings.powerSaving)
            } footer: {
                Text(String(localized: "30 кадров в секунду, без размытия строк, неподвижный фон в приложении и в PiP."))
            }

            Section {
                Picker(String(localized: "Частота кадров текста"), selection: $settings.lyricsFrameRate) {
                    Text("24").tag(24.0)
                    Text("30").tag(30.0)
                    Text("45").tag(45.0)
                    Text("60").tag(60.0)
                    if UIScreen.main.maximumFramesPerSecond > 60 {
                        Text("120").tag(120.0)
                    }
                }
                Toggle(String(localized: "Показывать FPS в плеере"), isOn: $settings.showLyricsFPS)
            } header: {
                Text(String(localized: "Кадры"))
            } footer: {
                Text(String(localized: "Меньше кадров — меньше нагрев. На паузе текст рисуется 15 раз в секунду, построчный текст и режим экономии — не больше 30 (прокрутка всё равно идёт с частотой экрана). Счётчик показывает реальные кадры / цель. Частота и счётчик PiP — в «Картинке в картинке»."))
            }

            Section {
                LabeledContent(String(localized: "Сейчас"), value: settings.powerSaving
                               ? String(localized: "Экономия включена")
                               : (performance.constrained ? String(localized: "Экономия (авто)") : String(localized: "Полная плавность")))
            } footer: {
                Text(String(localized: "Экономия включается сама в режиме энергосбережения iOS и когда телефон сильно нагревается."))
            }
        }
    }
}

private struct SourceSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var cacheCleared = false
    @State private var showOwnLyrics = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                if settings.hasBundledSpicyKey {
                    Label(String(localized: "Ключ Spicy Lyrics встроен в приложение"), systemImage: "checkmark.seal.fill")
                } else {
                    TextField("sl_pk_…", text: $settings.spicyLyricsKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    if !settings.spicyLyricsKey.isEmpty && settings.validSpicyKey == nil {
                        Text(settings.spicyLyricsKey.hasPrefix("sl_sk_")
                             ? String(localized: "Это секретный ключ. Нужен клиентский ключ sl_pk_…")
                             : String(localized: "Ключ должен начинаться с sl_pk_"))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Link(String(localized: "Получить ключ Spicy Lyrics"), destination: URL(string: "https://developers.spicylyrics.org")!)
                }
                if settings.playerChoice != .appleMusic {
                    Toggle(String(localized: "Запасной источник LRCLIB"), isOn: $settings.useLRCLibFallback)
                }
            } header: {
                Text("Spicy Lyrics")
            } footer: {
                Text(String(localized: "С клиентским ключом используется публичный API /v1/lyrics. Без ключа приложение пробует токен Spotify, как расширение для Spicetify."))
            }

            Section {
                Picker(String(localized: "Хранить синхронизированные тексты"), selection: $settings.syncedLyricsCacheDays) {
                    ForEach([1.0, 3, 7, 14, 30], id: \.self) { days in
                        Text(String(localized: "\(Int(days)) дн.")).tag(days)
                    }
                }
            } footer: {
                Text(String(localized: "Сколько дней текст с таймингами лежит на телефоне: пока он там, песня открывается сразу и без интернета. Дольше — меньше запросов, но правки синхронизации в Spicy Lyrics приходят позже."))
            }

            Section {
                Button(String(localized: "Свои тексты (TTML)")) { showOwnLyrics = true }
                Button(String(localized: "Перезагрузить текст")) { player.loadLyrics(force: true) }
                Button(cacheCleared ? String(localized: "Кэш очищен") : String(localized: "Очистить кэш текстов")) {
                    player.clearLyricsCache()
                    cacheCleared = true
                }
                .disabled(cacheCleared)
            }
        }
        .sheet(isPresented: $showOwnLyrics) {
            OwnLyricsView()
                .environment(player)
        }
    }
}

private struct NoLyricsSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            if settings.playerChoice != .appleMusic {
                Section {
                    Picker(String(localized: "Пропускать песни"), selection: $settings.autoSkipMode) {
                        ForEach(AutoSkipMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                } footer: {
                    Text(String(localized: "Песня, у которой нет синхронизации в Spicy Lyrics (текст не найден, есть только в LRCLIB или без таймингов), пропускается сама. Свои TTML считаются. Не пропускаются песни, выбранные вручную или возвращённые кнопкой «назад»; после \(PlayerModel.autoSkipLimit) пропусков подряд пропуск встаёт на паузу."))
                }
            }

            Section {
                Toggle(String(localized: "Скрывать «Текст не найден»"), isOn: $settings.hideNotFoundNotice)
                Toggle(String(localized: "Скрывать несинхронный текст"), isOn: $settings.hideStaticLyrics)
            } footer: {
                Text(String(localized: "Вместо сообщения или статичного текста остаётся только фон. В горизонтальном режиме кнопки тоже прячутся; касание возвращает их."))
            }

            if settings.hideNotFoundNotice || settings.hideStaticLyrics {
                Section {
                    Picker(String(localized: "Вместо текста"), selection: $settings.hiddenLyricsView) {
                        ForEach(HiddenLyricsView.allCases) { view in
                            Text(view.title).tag(view.rawValue)
                        }
                    }
                } footer: {
                    Text(String(localized: "Большая обложка — во весь экран поверх туманности в цветах обложки, как в Apple Music: становится больше, когда кнопки прячутся, и чуть уменьшается на паузе. Туманность течёт, пока песня играет, и почти замирает на паузе."))
                }
            }
        }
    }
}

private struct SpotifySettings: View {
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
            Section {
                LabeledContent("Client ID", value: settings.hasValidClientID
                               ? "…\(String(settings.spotifyClientID.suffix(4)))"
                               : String(localized: "Не настроен"))
                NavigationLink {
                    SpotifySetupGuideView()
                } label: {
                    Label(String(localized: "Сменить Client ID"), systemImage: "key.horizontal")
                }
            } footer: {
                Text(String(localized: "Для входа в Spotify нужен собственный Client ID. Его также можно использовать для поиска текстов треков Apple Music."))
            }

            Section {
                if auth.isLoggedIn {
                    Button(String(localized: "Выйти из Spotify"), role: .destructive) { auth.logOut() }
                } else if settings.hasValidClientID {
                    Button(String(localized: "Войти через Spotify")) { Task { try? await auth.logIn() } }
                }
            }
        }
    }
}

private struct AboutSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(UpdateChecker.self) private var updates

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LabeledContent(String(localized: "Версия"), value: AppVersion.display)
            }
            if UpdateChecker.isSupported {
                Section {
                    Toggle(String(localized: "Сообщать о новых версиях"), isOn: $settings.notifyUpdates)
                    if let latest = updates.latest {
                        Button {
                            updates.openUpdate(latest)
                        } label: {
                            Label(String(localized: "Обновить до \(latest.version)"), systemImage: "arrow.down.app.fill")
                        }
                    }
                    Button {
                        Task { await updates.check(force: true) }
                    } label: {
                        HStack {
                            Text(String(localized: "Проверить сейчас"))
                            Spacer()
                            if updates.checking { ProgressView() }
                        }
                    }
                    .disabled(updates.checking)
                } header: {
                    Text(String(localized: "Обновления"))
                } footer: {
                    Text(updateStatus)
                }
            }
            Section(String(localized: "Авторы")) {
                creditLink(String(localized: "Автор"), name: "sppq", url: "https://spicylyrics.org/sppq")
                creditLink("GitHub", name: "Sppqq", url: "https://github.com/Sppqq")
                creditLink(String(localized: "Тестер"), name: "nie4ick", url: "https://spicylyrics.org/nie4ick")
            }
            Section {
                Link(String(localized: "Spicy Lyrics (оригинал)"), destination: URL(string: "https://github.com/Spikerko/spicy-lyrics")!)
                Link("Spicy Lyrics Mobile (Android)", destination: URL(string: "https://github.com/spicylyrics/mobile")!)
                Link(String(localized: "Этот проект на GitHub"), destination: AppLinks.repository)
                Link("LRCLIB", destination: URL(string: "https://lrclib.net")!)
            } footer: {
                Text(String(localized: "Неофициальный iOS-порт. Распространяется по лицензии AGPL-3.0, как и оригинал. Не связан со Spotify AB."))
            }
            Section {
                Toggle(String(localized: "«Звезда на GitHub» в настройках"), isOn: $settings.showStarRow)
            } footer: {
                Text(String(localized: "Строка внизу главной страницы настроек. Её можно скрыть и свайпом влево."))
            }
        }
    }

    private var updateStatus: String {
        let note = String(localized: "Когда выходит стабильная версия, приложение предложит обновиться (не чаще раза в 6 часов проверяет GitHub). Обновление ставится через AltStore или SideStore.")
        if updates.failed { return String(localized: "Не удалось проверить: нет связи с GitHub.") + " " + note }
        if let latest = updates.latest { return String(localized: "Доступна версия \(latest.version).") + " " + note }
        if let checked = updates.lastChecked {
            return String(localized: "Установлена последняя версия (проверено \(checked.formatted(.relative(presentation: .named)))).") + " " + note
        }
        return note
    }

    private func creditLink(_ role: String, name: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            LabeledContent(role) {
                HStack(spacing: 4) {
                    Text(name)
                    Image(systemName: "arrow.up.right").font(.caption)
                }
            }
        }
        .foregroundStyle(.primary)
    }
}

/// A settings page with its title, whether it is opened from the list or from search.
struct SettingsDestination: View {
    let page: SettingsPage

    var body: some View {
        content
            .settingsPage()
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .fontAndLines: FontLinesSettings()
        case .animation: EffectsSettings()
        case .scrolling: ScrollSettings()
        case .translation: LanguageSettings()
        case .credits: CreditsSettings()
        case .themeAndBackground: BackgroundSettings()
        case .playerScreen: InterfaceSettings()
        case .noLyrics: NoLyricsSettings()
        case .landscape: LandscapeSettings()
        case .gestures: GestureSettings()
        case .pictureInPicture: PictureInPictureSettings()
        case .musicSource: MusicSourceSettings()
        case .sync: SyncSettings()
        case .lyricsSources: SourceSettings()
        case .performance: PerformanceSettings()
        case .experiments: ExperimentsSettings()
        case .reports: ReportSettings()
        case .about: AboutSettings()
        }
    }
}
