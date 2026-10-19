import SwiftUI
import UniformTypeIdentifiers

/// A line of lyrics in the font, size and weight chosen now, so a change is seen where it is made.
struct LyricPreview: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let choice = LyricsFontChoice(stored: settings.lyricsFont)
        let weight = (LyricsWeight(rawValue: settings.lyricsWeight) ?? .bold).fontWeight
        Text(String(localized: "Слова идут за голосом"))
            .font(choice.font(size: min(settings.fontSize, 40), weight: weight))
            .multilineTextAlignment(settings.centerLyrics ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: settings.centerLyrics ? .center : .leading)
            .padding(.vertical, 10)
            .animation(.easeOut(duration: 0.2), value: settings.lyricsFont)
    }
}

/// Fonts for the lyrics: the system's designs, ones built into iOS, and the user's own.
struct FontSettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var custom = CustomFonts.shared
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        Form {
            Section { LyricPreview() }

            Section(String(localized: "Системные")) {
                ForEach(LyricsFont.allCases) { font in
                    row(title: font.title, stored: font.rawValue, family: nil, design: font)
                }
            }

            Section(String(localized: "Встроенные в iOS")) {
                ForEach(BuiltInFonts.available, id: \.self) { name in
                    row(title: name, stored: LyricsFontChoice.stored(family: name), family: name, design: nil)
                }
            }

            Section {
                ForEach(custom.imported) { font in
                    ForEach(font.faces) { face in
                        row(title: face.displayName, stored: LyricsFontChoice.stored(face: face.postScriptName),
                            family: face.family, design: nil)
                    }
                    .onDelete { _ in remove(font) }
                }
                Button {
                    importing = true
                } label: {
                    Label(String(localized: "Импортировать шрифт…"), systemImage: "square.and.arrow.down")
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text(String(localized: "Мои шрифты"))
            } footer: {
                Text(String(localized: "Файлы .ttf, .otf и .ttc из «Файлов». Шрифт остаётся в приложении и работает и в тексте, и в окне «картинка в картинке». Смахните влево, чтобы удалить."))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.fontTypes) { result in
            switch result {
            case .success(let url):
                do {
                    let faces = try custom.importFont(from: url)
                    message = nil
                    if let first = faces.first { settings.lyricsFont = LyricsFontChoice.stored(face: first.postScriptName) }
                } catch {
                    message = error.localizedDescription
                }
            case .failure(let error):
                message = error.localizedDescription
            }
        }
        .sensoryFeedback(.selection, trigger: settings.lyricsFont)
    }

    private static let fontTypes: [UTType] = [.font] + ["ttf", "otf", "ttc"].compactMap { UTType(filenameExtension: $0) }

    private func row(title: String, stored: String, family: String?, design: LyricsFont?) -> some View {
        let choice = LyricsFontChoice(stored: stored)
        return Button {
            settings.lyricsFont = stored
        } label: {
            HStack {
                Text(title)
                    .font(choice.font(size: 19, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if settings.lyricsFont == stored {
                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
    }

    private func remove(_ font: CustomFonts.ImportedFont) {
        let current = LyricsFontChoice(stored: settings.lyricsFont)
        if font.faces.contains(where: { $0.postScriptName == current.postScriptName || $0.family == current.family }) {
            settings.lyricsFont = LyricsFont.standard.rawValue
        }
        custom.remove(font)
    }
}

/// The app's look: what is behind everything and the accent of its controls.
struct ThemeSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(AppTheme.allCases) { theme in
                        swatch(theme)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text(String(localized: "«Обложка» берёт фон и цвета из песни. Остальные темы не зависят от песни, их фон не движется, а телефон греется меньше. Тема действует и в окне «картинка в картинке»."))
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .sensoryFeedback(.selection, trigger: settings.theme)
    }

    private func swatch(_ theme: AppTheme) -> some View {
        let selected = settings.appTheme == theme
        return Button {
            withAnimation(.easeInOut(duration: 0.3)) { settings.theme = theme.rawValue }
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let gradient = theme.gradient {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(gradient)
                } else {
                    coverFill
                }
                HStack {
                    Text(theme.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Circle().fill(theme.isCover ? Color.white : theme.accent).frame(width: 14, height: 14)
                }
                .foregroundStyle(.white)
                .padding(12)
            }
            .frame(height: 92)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? Color.white : Color.white.opacity(0.14), lineWidth: selected ? 2 : 0.5)
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .white)
                        .padding(8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(SquishButtonStyle())
    }

    /// The song's own cover, blurred, for the "Cover" swatch.
    private var coverFill: some View {
        ZStack {
            Color(white: 0.14)
            if let image = player.backgroundArtwork {
                Image(uiImage: image).resizable().scaledToFill().blur(radius: 18)
            }
            Color.black.opacity(0.25)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
