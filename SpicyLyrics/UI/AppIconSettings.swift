import SwiftUI
import UIKit

/// The names match the alternate app icon sets compiled by Xcode.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case original, dark, colorful

    var id: String { rawValue }

    var alternateName: String? {
        switch self {
        case .original: return nil
        case .dark: return "AppIconDark"
        case .colorful: return "AppIconColorful"
        }
    }

    var title: String {
        switch self {
        case .original: return String(localized: "Оригинальная")
        case .dark: return String(localized: "Тёмная")
        case .colorful: return String(localized: "Разноцветная")
        }
    }

    var previewName: String { (alternateName ?? "AppIcon") + "Preview" }
}

struct AppIconSettings: View {
    @Environment(\.scenePhase) private var scenePhase
    // iOS persists the icon itself. Read its actual value instead of storing a second copy.
    @State private var selectedName = UIApplication.shared.alternateIconName
    @State private var changing = false
    @State private var changeFailed = false

    var body: some View {
        Form {
            Section {
                ForEach(AppIconChoice.allCases) { icon in
                    Button {
                        change(to: icon)
                    } label: {
                        HStack(spacing: 16) {
                            if let preview = UIImage(named: icon.previewName, in: Self.resourceBundle, compatibleWith: nil) {
                                Image(uiImage: preview)
                                    .resizable()
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .accessibilityHidden(true)
                            }
                            Text(icon.title).foregroundStyle(.primary)
                            Spacer()
                            if selectedName == icon.alternateName {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .disabled(changing || !UIApplication.shared.supportsAlternateIcons)
                    .accessibilityAddTraits(selectedName == icon.alternateName ? .isSelected : [])
                }
                if changing {
                    ProgressView(String(localized: "Меняем иконку…"))
                }
            } footer: {
                Text(UIApplication.shared.supportsAlternateIcons
                     ? String(localized: "Иконка на экране «Домой» меняется независимо от темы приложения.")
                     : String(localized: "В этой сборке смена иконки недоступна."))
            }
        }
        .onAppear { refreshSelection() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshSelection() }
        }
        .alert(String(localized: "Не удалось сменить иконку"), isPresented: $changeFailed) {
            Button(String(localized: "Понятно"), role: .cancel) {}
        } message: {
            Text(String(localized: "Попробуйте ещё раз. Текущая иконка сохранена."))
        }
    }

    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    private func refreshSelection() {
        selectedName = UIApplication.shared.alternateIconName
    }

    private func change(to icon: AppIconChoice) {
        guard !changing, UIApplication.shared.supportsAlternateIcons,
              UIApplication.shared.alternateIconName != icon.alternateName else { return }
        changing = true
        UIApplication.shared.setAlternateIconName(icon.alternateName) { error in
            DispatchQueue.main.async {
                refreshSelection()
                changing = false
                changeFailed = error != nil
            }
        }
    }
}
