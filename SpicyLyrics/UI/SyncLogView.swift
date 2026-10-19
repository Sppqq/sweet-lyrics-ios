import SwiftUI

/// Settings → Log: every poll, App Remote event and clock correction, and every error, to share
/// when something goes wrong.
struct SyncLogView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player
    @Environment(SpotifyAppRemote.self) private var appRemote
    @State private var exported: URL?
    @State private var copied = false

    private let log = SyncLog.shared

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Toggle(String(localized: "Вести журнал"), isOn: $settings.syncLogEnabled)
                if let exported {
                    ShareLink(item: exported) {
                        Label(String(localized: "Отправить файл журнала"), systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    UIPasteboard.general.string = ReportService.sanitize((header() + [""] + lines()).joined(separator: "\n"))
                    copied = true
                } label: {
                    Label(copied ? String(localized: "Скопировано") : String(localized: "Скопировать журнал"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                NavigationLink {
                    ReportComposeView().settingsPage()
                        .navigationTitle(String(localized: "Сообщить о проблеме"))
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label(String(localized: "Сообщить разработчику"), systemImage: "paperplane")
                }
                Button(role: .destructive) {
                    log.clear()
                    refreshFile()
                } label: {
                    Label(String(localized: "Очистить"), systemImage: "trash")
                }
            } footer: {
                Text(String(localized: "Когда что-то пошло не так (текст отстаёт, пауза не совпадает, ошибка): отправьте файл журнала. В нём тайминги, ошибки, названия треков и настройки, без ключей и токенов."))
            }

            Section(String(localized: "Последние записи")) {
                if log.entries.isEmpty {
                    Text(String(localized: "Пока пусто")).foregroundStyle(.secondary)
                }
                ForEach(log.entries.suffix(300).reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(SyncLog.time(entry.date))  \(entry.source)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .onAppear(perform: refreshFile)
        .onChange(of: log.entries.last?.id) { _, _ in copied = false }
        // The file to send keeps up with new entries (written once they pause for a moment).
        .task(id: log.entries.last?.id) {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            refreshFile()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Обновить"), systemImage: "arrow.clockwise", action: refreshFile)
            }
        }
    }

    private func refreshFile() {
        exported = log.export(header: header())
    }

    private func lines() -> [String] {
        log.entries.map { "\(SyncLog.time($0.date)) [\($0.source)] \($0.message)" }
    }

    private func header() -> [String] {
        log.header(settings: settings, player: player, appRemote: appRemote)
    }
}

extension SyncLog {
    /// The device and settings lines on top of every exported or reported log.
    func header(settings: AppSettings, player: PlayerModel, appRemote: SpotifyAppRemote) -> [String] {
        let device = UIDevice.current
        return [
            "Sweet Lyrics \(AppVersion.display)",
            "\(device.model), \(device.systemName) \(device.systemVersion)",
            "Exported \(SyncLog.time(Date()))",
            "offset \(Int(settings.timingOffsetMs)) ms, headphone latency \(settings.compensateOutputLatency ? "on" : "off") "
                + "(route \(Int(AudioRoute.outputLatency * 1000)) ms)",
            "start lead \(Int(player.startLead * 1000)) ms (learned, kept between launches)",
            "App Remote \(settings.useAppRemote ? "on" : "off"): \(appRemote.status), keeps clock \(player.remoteConnected)",
            "web poll \(settings.webPollInterval)s, remote query \(settings.remoteQueryInterval)s, auto wake \(settings.autoWakeSpotify ? "on" : "off")",
            "PiP: opens itself \(settings.autoPictureInPicture ? "on" : "off"), closes on return \(settings.closePiPOnReturn ? "on" : "off"), "
                + "format \(settings.pipFormat)",
            "now: \(player.isPlaying ? "playing" : "paused") at \(player.playbackPosition().s3)s, "
                + "track \"\(player.track?.title ?? "-")\" \(player.track?.uri ?? "")",
        ]
    }
}

/// A small badge over the lyrics: where the time last came from, how far off the clock was and,
/// while the Spotify app (App Remote) is not keeping time, why. Tap it for its state and a fix.
struct SyncIndicator: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(SpotifyAppRemote.self) private var appRemote
    @EnvironmentObject private var auth: SpotifyAuth

    var body: some View {
        Menu {
            if player.playbackSource == .appleMusic {
                Text("Apple Music")
                Button(String(localized: "Проверить время")) { player.refreshNow() }
            } else {
                Section {
                    if let ping = player.spotifyPing {
                        Text(String(localized: "Пинг до Spotify: \(Int((ping * 1000).rounded())) мс"))
                    }
                    Text(String(localized: "Связь с приложением Spotify: \(settings.useAppRemote ? appRemote.statusText : String(localized: "Выключено"))"))
                    if let error = appRemote.lastError, appRemote.status != .connected, !appRemote.otherDeviceActive {
                        Text(error)
                    }
                }
                if settings.useAppRemote {
                    switch appRemote.status {
                    case .needsLogin:
                        Button(String(localized: "Войти заново"), systemImage: "person.crop.circle.badge.checkmark") {
                            Task {
                                try? await auth.logIn()
                                appRemote.refresh()
                            }
                        }
                    case .unavailable, .connecting:
                        Button(String(localized: "Открыть Spotify и подключиться"), systemImage: "arrow.up.forward.app") {
                            appRemote.wakeSpotify()
                        }
                    case .off, .connected:
                        EmptyView()
                    }
                } else {
                    Button(String(localized: "Включить связь с приложением Spotify"), systemImage: "bolt.horizontal") { settings.useAppRemote = true }
                }
            }
        } label: {
            badge
        }
    }

    private var sdkNote: String? {
        guard player.supportsSpotifyFeatures else { return nil }
        guard settings.useAppRemote else { return String(localized: "без приложения Spotify") }
        switch appRemote.status {
        case .connected: return nil
        case .needsLogin: return String(localized: "войдите заново")
        case .connecting: return String(localized: "подключаюсь к Spotify")
        case .unavailable: return String(localized: "нет связи со Spotify")
        case .off: return String(localized: "без приложения Spotify")
        }
    }

    /// "App Remote" / "Web API" in words people know.
    private static func sourceName(_ source: String) -> String {
        if source == "Apple Music" { return source }
        return source == "App Remote" ? String(localized: "приложение") : String(localized: "интернет")
    }

    private var badge: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let sync = SyncLog.shared.lastSync
            HStack(spacing: 6) {
                Circle()
                    .fill(player.remoteConnected || player.playbackSource == .appleMusic ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                if let sync {
                    Text("\(Self.sourceName(sync.source)) \(sync.drift.signedMs) · \(String(format: "%.1f", context.date.timeIntervalSince(sync.at)))s")
                } else {
                    Text(Self.sourceName(player.playbackSource == .appleMusic ? "Apple Music" : (player.remoteConnected ? "App Remote" : "Web API")))
                }
                if let sdkNote {
                    Text("· " + sdkNote).foregroundStyle(.orange)
                }
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.35), in: Capsule())
        }
    }
}
