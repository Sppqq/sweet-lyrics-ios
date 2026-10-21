import SwiftUI

/// Pick what plays next without leaving the app: the queue, recent history and search.
struct TrackPickerView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case queue, recent, search
        var id: Self { self }

        var title: String {
            switch self {
            case .queue: return String(localized: "Очередь")
            case .recent: return String(localized: "Недавние")
            case .search: return String(localized: "Поиск")
            }
        }
    }

    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings
    @EnvironmentObject private var auth: SpotifyAuth
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Tab = .queue
    @State private var queue: [TrackSummary] = []
    @State private var recent: [TrackSummary] = []
    @State private var results: [TrackSummary] = []
    @State private var query = ""
    @State private var canLoadMore = false
    @State private var loading = false
    /// The last failure, per tab: an error in history must not fill the empty queue.
    @State private var errors: [Tab: String] = [:]
    private var error: String? { errors[tab] }
    @State private var needsRelogin = false
    /// "Added to the queue" for a moment after a swipe or the menu.
    @State private var queuedTitle: String?
    @State private var queuedCount = 0
    @FocusState private var searchFocused: Bool

    private static let recentScope = "user-read-recently-played"

    @Namespace private var tabNamespace

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            if tab == .search {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .glassSheetBackground()
        .overlay(alignment: .bottom) {
            if let queuedTitle {
                Label(String(localized: "В очереди: \(queuedTitle)"), systemImage: "text.badge.checkmark")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassCapsule()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: queuedTitle)
        // The player's own alert can't show over this sheet: a failed "add to queue" shows here.
        .alert("Spotify", isPresented: Binding(get: { player.transientError != nil }, set: { shown in
            if !shown { player.transientError = nil }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.transientError ?? "")
        }
        .sensoryFeedback(.success, trigger: queuedCount)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: tab)
        .task(id: tab) {
            if tab == .search {
                searchFocused = results.isEmpty
            } else {
                await load(tab)
            }
        }
        .task(id: query) {
            // Debounce typing.
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard tab == .search else { return }
            guard !text.isEmpty else {
                results = []
                canLoadMore = false
                errors[.search] = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await runSearch(text, offset: 0)
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .contentTransition(.interpolate)
                Text(player.deviceName ?? "Spotify")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if tab != .search {
                roundButton("arrow.clockwise") { Task { await load(tab) } }
                    .disabled(loading)
                    .opacity(loading ? 0.5 : 1)
            }
            roundButton("xmark") { dismiss() }
                .accessibilityLabel(String(localized: "Готово"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    private func roundButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GlassIconLabel(systemName: icon, size: 36, weight: .bold)
        }
        .buttonStyle(SquishButtonStyle(scale: 0.88))
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tab == item ? Color.black : Color.white.opacity(0.78))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if tab == item {
                                Capsule().fill(settings.appTheme.accent)
                                    .matchedGeometryEffect(id: "tab", in: tabNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassCapsule()
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .sensoryFeedback(.selection, trigger: tab)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let rows = currentRows
        if needsRelogin && tab == .recent {
            reloginPrompt
        } else if let error, rows.isEmpty {
            placeholder(icon: "exclamationmark.triangle", text: error)
        } else if rows.isEmpty && loading {
            ProgressView().controlSize(.large)
        } else if rows.isEmpty {
            placeholder(icon: emptyIcon, text: emptyText)
        } else {
            List {
                if tab == .queue, let track = player.track {
                    NowPlayingCard(title: track.title, subtitle: track.artistLine, artwork: track.artworkURL,
                                   playing: player.isPlaying, accent: settings.appTheme.accent)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, track in
                        Button {
                            choose(track, at: index)
                        } label: {
                            TrackRow(title: track.title, subtitle: track.artistLine, artwork: track.thumbnailURL,
                                     duration: track.duration)
                                .rowAppear(index: index)
                        }
                        .buttonStyle(SquishButtonStyle(scale: 0.98))
                        .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .contextMenu { menu(for: track, at: index) }
                        .swipeActions(edge: .trailing) {
                            if tab != .queue {
                                Button {
                                    enqueue(track)
                                } label: {
                                    Label(String(localized: "В очередь"), systemImage: "text.badge.plus")
                                }
                                .tint(.green)
                            }
                        }
                    }
                } header: {
                    Text(sectionTitle)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.9))
                        .textCase(nil)
                }
                if tab == .search && canLoadMore {
                    Button {
                        Task { await runSearch(query.trimmingCharacters(in: .whitespacesAndNewlines), offset: results.count) }
                    } label: {
                        HStack {
                            Spacer()
                            if loading { ProgressView() } else { Text(String(localized: "Показать ещё")) }
                            Spacer()
                        }
                    }
                    .disabled(loading)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .refreshable { if tab != .search { await load(tab) } }
            .id(tab)
            .transition(.opacity)
        }
    }

    private var currentRows: [TrackSummary] {
        switch tab {
        case .queue: return queue
        case .recent: return recent
        case .search: return results
        }
    }

    private var sectionTitle: String {
        switch tab {
        case .queue: return String(localized: "Далее")
        case .recent: return String(localized: "Недавно играли")
        case .search: return String(localized: "Треки")
        }
    }

    private var emptyIcon: String {
        switch tab {
        case .queue: return "list.bullet"
        case .recent: return "clock"
        case .search: return "magnifyingglass"
        }
    }

    private var emptyText: String {
        switch tab {
        case .queue: return String(localized: "Очередь пуста")
        case .recent: return String(localized: "История пуста")
        case .search: return query.isEmpty ? String(localized: "Найдите трек по названию или исполнителю") : String(localized: "Ничего не найдено")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(String(localized: "Трек, исполнитель, альбом"), text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCapsule()
    }

    private var reloginPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.badge.exclamationmark").font(.system(size: 40))
            Text(String(localized: "Для истории прослушивания нужно заново войти в Spotify и разрешить доступ к недавним трекам."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(String(localized: "Войти заново")) {
                Task {
                    do {
                        try await auth.logIn()
                        needsRelogin = false
                        await load(.recent)
                    } catch SpotifyAuthError.cancelled {
                    } catch {
                        errors[.recent] = error.localizedDescription
                    }
                }
            }
            .glassButton(prominent: true, tint: settings.appTheme.accent)
        }
        .padding(32)
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 36))
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }

    @ViewBuilder
    private func menu(for track: TrackSummary, at index: Int) -> some View {
        Button {
            choose(track, at: index)
        } label: {
            Label(tab == .queue ? String(localized: "Перейти к треку") : String(localized: "Слушать"), systemImage: "play.fill")
        }
        if tab != .queue {
            Button {
                enqueue(track)
            } label: {
                Label(String(localized: "Добавить в очередь"), systemImage: "text.badge.plus")
            }
        }
        if let url = Self.spotifyURL(track.uri) {
            Button {
                UIApplication.shared.open(url)
            } label: {
                Label(String(localized: "Открыть в Spotify"), systemImage: "arrow.up.forward.app")
            }
        }
    }

    // MARK: Actions

    private func choose(_ track: TrackSummary, at index: Int) {
        switch tab {
        case .queue:
            player.playFromQueue(track, at: index)
        case .recent:
            player.play(track, context: track.contextURI)
        case .search:
            player.play(track, context: nil)
        }
        dismiss()
    }

    private func enqueue(_ track: TrackSummary) {
        Task {
            guard await player.addToQueue(track) else { return }
            queuedCount += 1
            queuedTitle = track.title
            let shown = queuedCount
            try? await Task.sleep(for: .seconds(2))
            if queuedCount == shown { queuedTitle = nil }
        }
    }

    private func load(_ tab: Tab) async {
        guard tab != .search else { return }
        if tab == .recent && !auth.hasScope(Self.recentScope) {
            needsRelogin = true
            return
        }
        #if DEBUG
        if DemoTrack.current != nil, tab == .queue {
            queue = DemoQueue.tracks
            return
        }
        #endif
        loading = true
        errors[tab] = nil
        defer { loading = false }
        do {
            switch tab {
            case .queue: queue = try await player.upcomingTracks()
            case .recent: recent = try await player.recentTracks()
            case .search: break
            }
        } catch SpotifyAPIError.missingScope {
            needsRelogin = true
        } catch is CancellationError {
        } catch {
            errors[tab] = error.localizedDescription
        }
    }

    private func runSearch(_ text: String, offset: Int) async {
        guard !text.isEmpty else { return }
        loading = true
        errors[.search] = nil
        defer { loading = false }
        do {
            let page = try await player.searchTracks(text, offset: offset)
            guard text == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            if offset == 0 {
                results = page
            } else {
                let known = Set(results.map(\.uri))
                results += page.filter { !known.contains($0.uri) }
            }
            canLoadMore = page.count >= 10 && results.count < 100
        } catch is CancellationError {
        } catch {
            errors[.search] = error.localizedDescription
        }
    }

    /// `spotify:track:abc` → `https://open.spotify.com/track/abc` (opens the Spotify app).
    private static func spotifyURL(_ uri: String) -> URL? {
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify" else { return nil }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
    }
}

private struct TrackRow: View {
    let title: String
    let subtitle: String
    let artwork: URL?
    let duration: Double

    var body: some View {
        HStack(spacing: 12) {
            CoverThumb(url: artwork, size: 50, radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if duration > 0 {
                Text(PlaybackBar.format(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// What is playing right now: a larger cover and live bars.
private struct NowPlayingCard: View {
    let title: String
    let subtitle: String
    let artwork: URL?
    let playing: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 14) {
            CoverThumb(url: artwork, size: 68, radius: 12)
                .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "Сейчас играет"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            EqualizerBars(playing: playing, color: accent)
        }
        .padding(12)
        .glassCard(radius: 22)
    }
}

private struct CoverThumb: View {
    let url: URL?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill().transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
    }
}

/// The first rows slide up one after another when a list opens; later ones just appear.
private struct RowAppear: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                guard !shown else { return }
                if index < 10 {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82).delay(Double(index) * 0.035)) { shown = true }
                } else {
                    shown = true
                }
            }
    }
}

private extension View {
    func rowAppear(index: Int) -> some View { modifier(RowAppear(index: index)) }
}
