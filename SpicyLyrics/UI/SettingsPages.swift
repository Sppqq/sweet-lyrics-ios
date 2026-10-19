import SwiftUI

/// The groups of the main settings list.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case lyrics, player, connection, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lyrics: return String(localized: "Текст")
        case .player: return String(localized: "Плеер")
        case .connection: return String(localized: "Подключение")
        case .other: return String(localized: "Прочее")
        }
    }

    var pages: [SettingsPage] { SettingsPage.allCases.filter { $0.group == self } }
}

/// One page of settings: its row in the main list, and where search sends you.
enum SettingsPage: String, CaseIterable, Identifiable {
    case fontAndLines, animation, scrolling, translation, credits
    case themeAndBackground, playerScreen, noLyrics, landscape, gestures, pictureInPicture
    case musicSource, sync, lyricsSources
    case performance, experiments, reports
    case about

    var id: String { rawValue }

    /// Nil for "About", which sits on its own at the bottom.
    var group: SettingsGroup? {
        switch self {
        case .fontAndLines, .animation, .scrolling, .translation, .credits: return .lyrics
        case .themeAndBackground, .playerScreen, .noLyrics, .landscape, .gestures, .pictureInPicture: return .player
        case .musicSource, .sync, .lyricsSources: return .connection
        case .performance, .experiments, .reports: return .other
        case .about: return nil
        }
    }

    var title: String {
        switch self {
        case .fontAndLines: return String(localized: "Шрифт и строки")
        case .animation: return String(localized: "Анимация")
        case .scrolling: return String(localized: "Прокрутка")
        case .translation: return String(localized: "Перевод и романизация")
        case .credits: return String(localized: "Титры")
        case .themeAndBackground: return String(localized: "Тема и фон")
        case .playerScreen: return String(localized: "Экран плеера")
        case .noLyrics: return String(localized: "Когда нет текста")
        case .landscape: return String(localized: "Горизонтальный режим")
        case .gestures: return String(localized: "Жесты")
        case .pictureInPicture: return String(localized: "Картинка в картинке")
        case .musicSource: return String(localized: "Источник музыки")
        case .sync: return String(localized: "Синхронизация")
        case .lyricsSources: return String(localized: "Источники текстов")
        case .performance: return String(localized: "Батарея и нагрев")
        case .experiments: return String(localized: "Эксперименты")
        case .reports: return String(localized: "Отчёты об ошибках")
        case .about: return String(localized: "О приложении")
        }
    }

    var icon: String {
        switch self {
        case .fontAndLines: return "textformat.size"
        case .animation: return "sparkles"
        case .scrolling: return "arrow.up.and.down.text.horizontal"
        case .translation: return "character.bubble.fill"
        case .credits: return "person.text.rectangle"
        case .themeAndBackground: return "paintpalette.fill"
        case .playerScreen: return "rectangle.bottomhalf.inset.filled"
        case .noLyrics: return "text.badge.xmark"
        case .landscape: return "rectangle.landscape.rotate"
        case .gestures: return "hand.draw.fill"
        case .pictureInPicture: return "pip.fill"
        case .musicSource: return "music.note"
        case .sync: return "timer"
        case .lyricsSources: return "doc.text.fill"
        case .performance: return "bolt.fill"
        case .experiments: return "flask.fill"
        case .reports: return "paperplane.fill"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .fontAndLines: return .purple
        case .animation: return .pink
        case .scrolling: return .indigo
        case .translation: return .blue
        case .credits: return .brown
        case .themeAndBackground: return .indigo
        case .playerScreen: return .orange
        case .noLyrics: return .gray
        case .landscape: return .teal
        case .gestures: return .red
        case .pictureInPicture: return .green
        case .musicSource: return .pink
        case .sync: return .cyan
        case .lyricsSources: return .brown
        case .performance: return .yellow
        case .experiments: return .purple
        case .reports: return .mint
        case .about: return .gray
        }
    }
}

/// What search looks through: every setting's name as it reads on its page.
enum SettingsIndex {
    struct Hit: Identifiable {
        let title: String
        let page: SettingsPage
        var id: String { page.rawValue + "|" + title }
    }

    private static var entries: [(String, SettingsPage)] {
        func on(_ page: SettingsPage, _ titles: [String]) -> [(String, SettingsPage)] { titles.map { ($0, page) } }
        return on(.fontAndLines, [
            String(localized: "Шрифт"), String(localized: "Насыщенность шрифта"), String(localized: "Размер"),
            String(localized: "По центру"), String(localized: "Между строками"),
            String(localized: "Склеивать слова из слогов"), String(localized: "Отступ дуэтов"),
        ]) + on(.animation, [
            "Simple Lyrics Mode", String(localized: "Размывать неактивные строки"), String(localized: "Сила размытия"),
            String(localized: "Свечение слов"), String(localized: "Яркость остальных строк"),
            String(localized: "Скрывать спетые строки"), String(localized: "Оставлять перекрывающиеся строки"),
        ]) + on(.scrolling, [
            String(localized: "Положение активной строки"), String(localized: "Плавная прокрутка"),
            String(localized: "Скорость прокрутки"), String(localized: "Раннее пролистывание"),
            String(localized: "Время раннего пролистывания"), String(localized: "Перемотка чуть раньше строки"),
        ]) + on(.translation, [
            String(localized: "Романизация"), String(localized: "Переводить текст"), String(localized: "Переводчик"),
            String(localized: "Язык перевода"), String(localized: "Размер перевода"), String(localized: "Яркость перевода"),
        ]) + on(.credits, [
            String(localized: "Новый вид титров"), String(localized: "Титры за последним исполнителем"),
        ]) + on(.themeAndBackground, [
            String(localized: "Тема"), String(localized: "Обложка на фоне"), String(localized: "Что на фоне"),
            String(localized: "Скорость движения"), String(localized: "Размытие"),
            String(localized: "Насыщенность цвета"), String(localized: "Затемнение"),
        ]) + on(.playerScreen, [
            String(localized: "Язык приложения"), String(localized: "Прятать кнопки во время песни"),
            String(localized: "Большая обложка"), String(localized: "Строка текста под обложкой"),
            String(localized: "Фон за обложкой"), String(localized: "Цвета туманности"),
            String(localized: "Звёзды в туманности"), String(localized: "Полоска громкости"),
            String(localized: "Не гасить экран"),
        ]) + on(.noLyrics, [
            String(localized: "Пропускать песни"), String(localized: "Скрывать «Текст не найден»"),
            String(localized: "Скрывать несинхронный текст"), String(localized: "Вместо текста"),
        ]) + on(.landscape, [
            String(localized: "Только текст"), String(localized: "Название и исполнитель"),
        ]) + on(.gestures, [
            String(localized: "Жесты"),
        ]) + on(.pictureInPicture, [
            String(localized: "Открывать при сворачивании"), String(localized: "Закрывать при возврате в приложение"),
            String(localized: "Форма окна"), String(localized: "Анимированный фон"), String(localized: "Название песни"),
            String(localized: "Размер текста"), String(localized: "Затемнение фона"), String(localized: "Частота кадров"),
            String(localized: "Размытие соседних строк"), String(localized: "Перевод в окне"), String(localized: "Показывать FPS"),
        ]) + on(.musicSource, [
            String(localized: "Источник музыки"), "Spotify", "Apple Music", "Client ID",
            String(localized: "Режим перехода"), "AutoMix",
        ]) + on(.sync, [
            String(localized: "Связь с приложением Spotify"), String(localized: "Открывать Spotify, если молчит"),
            String(localized: "Текст спешит или опаздывает"), String(localized: "Как часто сверять время"),
            String(localized: "Значок сверки над текстом"), String(localized: "Учитывать задержку наушников"),
            String(localized: "Журнал"),
        ]) + on(.lyricsSources, [
            "Spicy Lyrics", String(localized: "Запасной источник LRCLIB"), String(localized: "Свои тексты (TTML)"),
            String(localized: "Хранить синхронизированные тексты"),
            String(localized: "Перезагрузить текст"), String(localized: "Очистить кэш текстов"),
        ]) + on(.performance, [
            String(localized: "Экономия батареи"), String(localized: "Частота кадров текста"),
            String(localized: "Показывать FPS в плеере"),
        ]) + on(.experiments, [
            String(localized: "Выезжающий бэк-вокал"), String(localized: "Обновлённый Simple Lyrics"),
        ]) + on(.reports, [
            String(localized: "Отправлять отчёты об ошибках"), String(localized: "Сообщить о проблеме"),
        ]) + on(.about, [
            String(localized: "Сообщать о новых версиях"), String(localized: "«Звезда на GitHub» в настройках"),
        ])
    }

    /// Settings whose own name matches come first, then those on a page whose name matches.
    static func search(_ query: String) -> [Hit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        func matches(_ text: String) -> Bool {
            text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let all = entries
        var hits = all.filter { matches($0.0) }.map { Hit(title: $0.0, page: $0.1) }
        let pages = SettingsPage.allCases.filter { matches($0.title) }
        for page in pages where !hits.contains(where: { $0.page == page && $0.title == page.title }) {
            hits.append(Hit(title: page.title, page: page))
        }
        // One row per setting and page.
        var seen = Set<String>()
        return hits.filter { seen.insert($0.id).inserted }
    }
}
