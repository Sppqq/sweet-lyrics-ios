import SwiftUI

/// The "what does this mean" sheet: the line (or the whole song) explained, the phrases worth a
/// note, and who the artists are. Glass on iOS 26, like the system's own sheets; it opens at half
/// height over the lyrics and can be pulled up.
struct LineExplanationView: View {
    let request: ExplainRequest
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private enum Mode: Hashable { case line, song }
    @State private var mode: Mode
    @State private var answer: LineExplanation?
    @State private var failure: String?
    @State private var shown = false
    @State private var attempt = 0
    @State private var expandedArtist: String?
    #if DEBUG
    @State private var detent: PresentationDetent = UserDefaults.standard.bool(forKey: "demoExplainLarge") ? .large : .medium
    #else
    @State private var detent: PresentationDetent = .medium
    #endif

    init(request: ExplainRequest) {
        self.request = request
        _mode = State(initialValue: request.index == nil ? .song : .line)
        _answer = State(initialValue: LineExplainer.cached(request))
        _shown = State(initialValue: LineExplainer.cached(request) != nil)
    }

    private var current: ExplainRequest { mode == .song ? request.with(index: nil) : request }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    songHeader
                    if request.index != nil { modePicker }
                    if mode == .line, let line = request.shownLine { quote(line) }
                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 32)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(mode == .song ? String(localized: "О песне") : String(localized: "О строке"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(String(localized: "Закрыть"))
                }
                if let answer {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            ShareSheet.present(shareText(answer))
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel(String(localized: "Поделиться"))
                    }
                }
            }
            .glassSheetBackground()
        }
        .task(id: TaskKey(mode: mode, attempt: attempt)) { await load() }
        .sensoryFeedback(.success, trigger: answer)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .modifier(SheetGlass())
    }

    private struct TaskKey: Hashable {
        var mode: Mode
        var attempt: Int
    }

    // MARK: Parts

    private var songHeader: some View {
        HStack(spacing: 12) {
            Group {
                if let artwork = player.track?.id == request.track.id ? player.artwork : nil {
                    Image(uiImage: artwork).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white.opacity(0.1))
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(request.track.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(request.track.artistLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var modePicker: some View {
        Picker(String(localized: "Что объяснить"), selection: $mode.animation(.spring(response: 0.45, dampingFraction: 0.85))) {
            Text(String(localized: "Строка")).tag(Mode.line)
            Text(String(localized: "Вся песня")).tag(Mode.song)
        }
        .pickerStyle(.segmented)
        .onChange(of: mode) { _, _ in
            answer = LineExplainer.cached(current)
            failure = nil
            shown = answer != nil
        }
    }

    private func quote(_ line: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Capsule()
                .fill(.white.opacity(0.85))
                .frame(width: 4)
            Text(line)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .transition(.blurReplace)
    }

    @ViewBuilder
    private var content: some View {
        if let answer {
            loaded(answer)
        } else if let failure {
            failed(failure)
        } else {
            loading
        }
    }

    private func loaded(_ answer: LineExplanation) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(answer.summary)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .staggeredReveal(shown, index: 0)
                Text(answer.meaning)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .staggeredReveal(shown, index: 1)
            }

            if !answer.notes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle(mode == .song ? String(localized: "Главное") : String(localized: "Детали"), symbol: "sparkle.magnifyingglass")
                    GlassGroup(spacing: 10) {
                        VStack(spacing: 10) {
                            ForEach(Array(answer.notes.enumerated()), id: \.element) { offset, note in
                                noteCard(note)
                                    .staggeredReveal(shown, index: 2 + offset)
                            }
                        }
                    }
                }
            }

            if !answer.artists.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle(answer.artists.count > 1 ? String(localized: "Об исполнителях") : String(localized: "Об исполнителе"),
                                 symbol: "person.wave.2")
                    ForEach(Array(answer.artists.enumerated()), id: \.element) { offset, artist in
                        artistCard(artist)
                            .staggeredReveal(shown, index: 2 + answer.notes.count + offset)
                    }
                }
            }

            Label(String(localized: "Объяснение написал ИИ, он может ошибаться."), systemImage: "sparkles")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.45))
                .staggeredReveal(shown, index: 3 + answer.notes.count + answer.artists.count)
        }
        .onAppear {
            // Next frame, so the pieces have a "before" to animate from.
            guard !shown else { return }
            DispatchQueue.main.async { shown = true }
        }
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.white.opacity(0.55))
    }

    private func noteCard(_ note: LineExplanation.Note) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(note.phrase)
                .font(.headline)
            Text(note.note)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(radius: 20)
    }

    private func artistCard(_ artist: LineExplanation.Artist) -> some View {
        let expanded = expandedArtist == artist.name
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name).font(.headline)
                    if let description = artist.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                Spacer(minLength: 8)
                if let link = artist.url.flatMap(URL.init(string:)) {
                    Button {
                        openURL(link)
                    } label: {
                        Text(String(localized: "Википедия"))
                            .font(.caption.weight(.semibold))
                    }
                    .glassButton()
                    .controlSize(.small)
                }
            }
            Text(artist.summary)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(expanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
            if !expanded {
                Text(String(localized: "Ещё"))
                    .font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(.pressable, radius: 20)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                expandedArtist = expanded ? nil : artist.name
            }
        }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .symbolEffect(.pulse, options: .repeating)
                Text(mode == .song ? String(localized: "Слушаю всю песню…") : String(localized: "Разбираю строку…"))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 10) {
                ForEach([0.92, 1, 0.84, 0.6], id: \.self) { width in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.12))
                        .frame(height: 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(x: width, anchor: .leading)
                }
            }
            .shimmer()
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(height: 76)
                .shimmer()
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.6))
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
            Button {
                failure = nil
                attempt += 1
            } label: {
                Label(String(localized: "Повторить"), systemImage: "arrow.clockwise")
            }
            .glassButton()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .transition(.blurReplace)
    }

    // MARK: Loading

    private func load() async {
        let request = current
        if let hit = LineExplainer.cached(request) {
            if answer != hit { answer = hit }
            return
        }
        answer = nil
        shown = false
        do {
            let result = try await LineExplainer.explain(request)
            guard !Task.isCancelled, current == request else { return }
            withAnimation(.easeOut(duration: 0.2)) { answer = result }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                failure = (error as? LocalizedError)?.errorDescription ?? String(localized: "Не получилось объяснить. Попробуйте ещё раз.")
            }
        }
    }

    private func shareText(_ answer: LineExplanation) -> String {
        var parts = ["\(request.track.title) — \(request.track.artistLine)"]
        if mode == .line, let line = request.shownLine { parts.append("«\(line)»") }
        parts.append(answer.summary)
        parts.append(answer.meaning)
        return parts.joined(separator: "\n\n")
    }
}

/// Before iOS 26 the sheet keeps the cover backdrop; on 26 the system's glass shows through.
private struct SheetGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.presentationBackground(.clear)
        }
    }
}
