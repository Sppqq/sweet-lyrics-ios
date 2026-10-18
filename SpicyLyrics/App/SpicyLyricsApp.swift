import SwiftUI

@main
@MainActor
struct SpicyLyricsApp: App {
    /// Gives a TV on AirPlay screen mirroring (or a cable) its own full-screen lyrics.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: AppSettings
    @StateObject private var auth: SpotifyAuth
    @State private var player: PlayerModel
    @State private var performance: PerformanceMonitor
    @State private var pip = LyricsPictureInPicture()
    @State private var appRemote: SpotifyAppRemote
    @State private var updates: UpdateChecker
    @State private var sourceSwitcher: AutoSourceSwitcher

    init() {
        AudioRoute.prepare()
        CustomFonts.shared.registerAll()
        let settings = AppSettings()
        SyncLog.shared.enabled = settings.syncLogEnabled
        let auth = SpotifyAuth(settings: settings)
        let api = SpotifyAPI(auth: auth)
        let localLyrics = LocalLyricsStore()
        let lyrics = LyricsService(settings: settings, auth: auth, local: localLyrics)
        _settings = State(initialValue: settings)
        _auth = StateObject(wrappedValue: auth)
        let appRemote = SpotifyAppRemote(auth: auth, settings: settings)
        let player = PlayerModel(api: api, lyrics: lyrics, settings: settings, localLyrics: localLyrics)
        let performance = PerformanceMonitor()
        ExternalDisplay.shared.attach(settings: settings, player: player, performance: performance)
        _performance = State(initialValue: performance)
        ReportService.shared.attach(settings: settings, player: player, appRemote: appRemote)
        _appRemote = State(initialValue: appRemote)
        _updates = State(initialValue: UpdateChecker(settings: settings))
        _sourceSwitcher = State(initialValue: AutoSourceSwitcher(settings: settings, auth: auth, api: api))
        _player = State(initialValue: player)
    }

    var body: some Scene {
        WindowGroup {
            RootView(sourceSwitcher: sourceSwitcher)
                .environment(settings)
                .environment(player)
                .environment(performance)
                .environment(pip)
                .environment(appRemote)
                .environment(updates)
                .environmentObject(auth)
                .preferredColorScheme(.dark)
                .tint(settings.appTheme.accent)
        }
    }
}

struct RootView: View {
    @ObservedObject private var externalDisplay = ExternalDisplay.shared
    /// Follows whichever player is playing when the player choice is "Auto".
    let sourceSwitcher: AutoSourceSwitcher
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LyricsPictureInPicture.self) private var pip
    @Environment(SpotifyAppRemote.self) private var appRemote
    @Environment(UpdateChecker.self) private var updates
    /// Letting go of Spotify after the app went to the background, unless the floating window
    /// turns up meanwhile.
    @State private var stopTask: Task<Void, Never>?
    /// The one-time question about sending error reports, after an update.
    @State private var askAboutReports = false

    var body: some View {
        Group {
            if isExternalDisplayDemo {
                #if DEBUG
                // A 16:9 TV picture in the middle of the sideways phone.
                ZStack {
                    Color.black
                    ExternalLyricsView()
                        .aspectRatio(16 / 9, contentMode: .fit)
                }
                .ignoresSafeArea()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                #endif
            } else if sourceReady || isDemo {
                NowPlayingView()
            } else {
                OnboardingView()
            }
        }
        // The TV on screen mirroring (iOS 27 needs this to offer the screen at all).
        .modifier(ExternalDisplayAccessory())
        .onChange(of: scenePhase, initial: true) { old, phase in
            updateActivity(phase)
            // Back in the app: the lyrics on screen were last drawn a while ago.
            if phase == .active, old != .active {
                player.resync("app active")
                Task {
                    await updates.check()
                    await ReportService.shared.refreshThreads()
                }
            }
        }
        .onChange(of: auth.isLoggedIn) { _, _ in updateActivity(scenePhase) }
        .onChange(of: settings.playbackSource) { _, _ in
            appRemote.stop()
            player.sourceChanged()
            updateActivity(scenePhase)
        }
        .onChange(of: settings.playerChoice) { _, _ in updateActivity(scenePhase) }
        .onChange(of: settings.appleMusicOnboarded) { _, _ in updateActivity(scenePhase) }
        .onChange(of: settings.keepScreenOn) { _, _ in updateActivity(scenePhase) }
        .onChange(of: externalDisplay.isConnected) { _, _ in updateActivity(scenePhase) }
        .onChange(of: pip.keepsAppRunning) { _, _ in updateActivity(scenePhase) }
        .onChange(of: settings.useAppRemote) { _, _ in appRemote.refresh() }
        .onChange(of: settings.syncLogEnabled) { _, enabled in SyncLog.shared.enabled = enabled }
        .onOpenURL { url in appRemote.handle(url) }
        .task {
            askAboutReportsAfterUpdate()
            await updates.check()
            await ReportService.shared.refreshThreads()
        }
        .alert(String(localized: "Помочь улучшить приложение?"), isPresented: $askAboutReports) {
            Button(String(localized: "Разрешить")) { settings.reportConsent = 1 }
            Button(String(localized: "Не сейчас"), role: .cancel) { settings.reportConsent = 2 }
        } message: {
            Text(String(localized: "Когда что-то ломается, приложение может анонимно отправлять разработчику журнал: версия приложения, модель телефона и iOS, названия треков и тайминги. Без аккаунта Spotify, ключей и токенов. Отчёты разбирает разработчик вместе с ИИ-ассистентом (Claude, Anthropic). Изменить это можно в Настройках → Отчёты об ошибках."))
        }
        .alert(String(localized: "Вышла новая версия"), isPresented: updateNoticeShown, presenting: updates.pendingNotice) { release in
            Button(String(localized: "Обновить")) {
                remindLater = release.version
                updates.openUpdate(release)
            }
            Button(String(localized: "Пропустить эту версию")) { updates.skip(release) }
            Button(String(localized: "Позже"), role: .cancel) { remindLater = release.version }
        } message: { release in
            Text(String(localized: "Sweet Lyrics \(release.version) уже доступна (у вас \(AppVersion.marketing)). Обновить можно в AltStore или SideStore → My Apps. Отключить эти уведомления: Настройки → О приложении."))
        }
        .alert(String(localized: "Разработчик ответил на ваш отчёт"), isPresented: answerNoticeShown,
               presenting: ReportService.shared.unreadAnswer) { thread in
            Button(String(localized: "Открыть")) { openThread = thread.id }
            Button(String(localized: "Позже"), role: .cancel) { answerLater = thread.lastDeveloperMessage?.id }
        } message: { thread in
            Text(thread.lastDeveloperMessage?.text.prefix(300).description ?? "")
        }
        .sheet(item: Binding(get: { openThread.map(OpenThread.init) }, set: { openThread = $0?.id })) { open in
            NavigationStack {
                ReportThreadView(threadID: open.id)
                    .navigationTitle(String(localized: "Отчёт"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Готово")) { openThread = nil }
                        }
                    }
            }
        }
        #if DEBUG
        .task {
            if let demo = DemoTrack.current { player.startDemo(demo) }
            if isExternalDisplayDemo,
               let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
        }
        #endif
    }

    /// The report thread opened from the answer notice.
    @State private var openThread: String?
    /// "Later" on the answer notice: not again for this answer until the next launch.
    @State private var answerLater: Int?

    private struct OpenThread: Identifiable { let id: String }

    /// A new answer to the user's report: after the other questions, never two alerts at once.
    private var answerNoticeShown: Binding<Bool> {
        Binding(get: {
            guard openThread == nil, !askAboutReports, !updateNoticeShown.wrappedValue,
                  let thread = ReportService.shared.unreadAnswer else { return false }
            return thread.lastDeveloperMessage?.id != answerLater
        }, set: { shown in
            if !shown, openThread == nil { answerLater = ReportService.shared.unreadAnswer?.lastDeveloperMessage?.id }
        })
    }

    /// "Later" hides the notice until the next launch.
    @State private var remindLater: String?

    /// The update notice waits for the reports question (one alert at a time) and the login.
    private var updateNoticeShown: Binding<Bool> {
        Binding(get: {
            guard sourceReady || isDemo, !askAboutReports, let notice = updates.pendingNotice else { return false }
            return notice.version != remindLater
        }, set: { shown in
            if !shown, let notice = updates.pendingNotice, settings.skippedUpdateVersion != notice.version {
                remindLater = notice.version
            }
        })
    }

    /// Once, the first time the app runs after an update (not on a fresh install), while nothing
    /// has been decided yet.
    private func askAboutReportsAfterUpdate() {
        let current = "\(AppVersion.marketing)/\(AppVersion.build)"
        let seen = settings.lastSeenVersion
        guard seen != current else { return }
        // An install from before this question existed has no version stored but is signed in.
        if settings.reportConsent == 0, !seen.isEmpty || auth.isLoggedIn { askAboutReports = true }
        settings.lastSeenVersion = current
    }

    /// Debug: `-demoExternalDisplay YES` puts the external screen's view on the phone itself
    /// (the Simulator's external display can't be attached from the command line).
    private var isExternalDisplayDemo: Bool {
        #if DEBUG
        return isDemo && UserDefaults.standard.bool(forKey: "demoExternalDisplay")
        #else
        return false
        #endif
    }

    private var isDemo: Bool {
        #if DEBUG
        return DemoTrack.current != nil
        #else
        return false
        #endif
    }

    /// Following Spotify is wanted: the app is on screen (Control Center or the app switcher
    /// over it count), or the floating window is up or on its way.
    private func wantsToFollow(_ phase: ScenePhase) -> Bool {
        sourceReady && (phase != .background || pip.keepsAppRunning)
    }

    private var sourceReady: Bool {
        // Read here so SwiftUI notices sign-in changes; the switcher knows which player counts.
        _ = auth.isLoggedIn
        return sourceSwitcher.anySourceReady
    }

    private func updateActivity(_ phase: ScenePhase) {
        // A locked phone stops screen mirroring: keep it awake while the TV shows the lyrics.
        UIApplication.shared.isIdleTimerDisabled = phase == .active && sourceReady
            && (settings.keepScreenOn || externalDisplay.isConnected)
        if wantsToFollow(phase) {
            stopTask?.cancel()
            stopTask = nil
            sourceSwitcher.preferReadySource()
            player.startPolling()
            if settings.playbackSource == .spotify, settings.useAppRemote { appRemote.start(player: player) }
            sourceSwitcher.start(player: player)
            return
        }
        guard sourceReady else {
            stopFollowing()
            return
        }
        // Leaving the app: the floating window may still be opening (iOS only says so after its
        // animation). Dropping App Remote right then and reconnecting a moment later was what
        // threw the timing off: wait a little and look again.
        guard stopTask == nil else { return }
        stopTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            stopTask = nil
            let phase: ScenePhase = UIApplication.shared.applicationState == .background ? .background : .active
            if !wantsToFollow(phase) { stopFollowing() }
        }
    }

    private func stopFollowing() {
        stopTask?.cancel()
        stopTask = nil
        player.stopPolling()
        appRemote.stop()
        sourceSwitcher.stop()
    }
}
