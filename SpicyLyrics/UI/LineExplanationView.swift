import SwiftUI

/// The "what does this mean" sheet: the line (or the whole song) explained, the phrases worth a
/// note, and who the artists are. Glass on iOS 26, like the system's own sheets; it opens at half
/// height over the lyrics and can be pulled up.
struct LineExplanationView: View {
    let request: ExplainRequest
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private enum Mode: Hashable { case line, song }
    @State private var mode: Mode
    @State private var answer: LineExplanation?
    @State private var failure: String?
    @State private var shown = false
    @State private var attempt = 0
    @State private var expandedArtist: String?
    /// The complaint sent about the answer on screen.
    @State private var complained: ExplanationComplaint?
    @State private var complaining = false
    @State private var askingComment = false
    @State private var commentDraft = ""
    @State private var complaintError: String?
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
            complained = nil
            complaintError = nil
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
        // The text writes itself in, then the cards rise one after another.
        let summaryTime = RevealText.duration(answer.summary)
        let cardsStart = 0.15 + summaryTime * 0.6 + RevealText.duration(answer.meaning) * 0.55
        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                RevealText(text: answer.summary, shown: shown)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                RevealText(text: answer.meaning, shown: shown, delay: summaryTime * 0.6)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if !answer.notes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle(mode == .song ? String(localized: "Главное") : String(localized: "Детали"), symbol: "sparkle.magnifyingglass")
                        .cardReveal(shown, delay: cardsStart)
                    // No glass container here: it draws its children's glass itself, and the
                    // cards came in ahead of their own reveal.
                    VStack(spacing: 10) {
                        ForEach(Array(answer.notes.enumerated()), id: \.element) { offset, note in
                            noteCard(note)
                                .cardReveal(shown, delay: cardsStart + 0.06 + Double(offset) * 0.08)
                        }
                    }
                }
            }

            if !answer.artists.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle(answer.artists.count > 1 ? String(localized: "Об исполнителях") : String(localized: "Об исполнителе"),
                                 symbol: "person.wave.2")
                        .cardReveal(shown, delay: cardsStart + 0.1 + Double(answer.notes.count) * 0.08)
                    ForEach(Array(answer.artists.enumerated()), id: \.element) { offset, artist in
                        artistCard(artist)
                            .cardReveal(shown, delay: cardsStart + 0.16 + Double(answer.notes.count + offset) * 0.08)
                    }
                }
            }

            footer(answer)
                .cardReveal(shown, delay: cardsStart + 0.2 + Double(answer.notes.count + answer.artists.count) * 0.08)
        }
        .onAppear {
            // Next frame, so the pieces have a "before" to animate from.
            guard !shown else { return }
            DispatchQueue.main.async { shown = true }
        }
    }

    // MARK: Complaints

    private func footer(_ answer: LineExplanation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(String(localized: "Объяснение написал ИИ, он может ошибаться."), systemImage: "sparkles")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.45))
            Group {
                if let complained {
                    HStack(spacing: 10) {
                        Label(String(localized: "Спасибо, учтём"), systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                            .symbolEffect(.bounce, value: complained)
                        Spacer(minLength: 0)
                        if complained.replacesAnswer {
                            Button {
                                explainAgain()
                            } label: {
                                Label(String(localized: "Объяснить заново"), systemImage: "arrow.clockwise")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .glassButton()
                        }
                    }
                    .transition(.blurReplace)
                } else {
                    Menu {
                        ForEach(ExplanationComplaint.allCases) { reason in
                            Button {
                                choose(reason, about: answer)
                            } label: {
                                Label(reason.title, systemImage: reason.symbol)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if complaining {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: "flag")
                            }
                            Text(String(localized: "Пожаловаться на ответ"))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassCapsule(.pressable)
                        .contentShape(Capsule())
                    }
                    .disabled(complaining || answer.id == nil)
                    .transition(.blurReplace)
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: complained)
            if let complaintError {
                Text(complaintError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .sensoryFeedback(.success, trigger: complained) { _, new in new != nil }
        .alert(String(localized: "Что не так с ответом?"), isPresented: $askingComment) {
            TextField(String(localized: "Коротко опишите"), text: $commentDraft)
            Button(String(localized: "Отправить")) { send(.other, comment: commentDraft, about: answer) }
            Button(String(localized: "Отмена"), role: .cancel) {}
        }
    }

    private func choose(_ reason: ExplanationComplaint, about answer: LineExplanation) {
        if reason == .other {
            commentDraft = ""
            askingComment = true
        } else {
            send(reason, comment: "", about: answer)
        }
    }

    private func send(_ reason: ExplanationComplaint, comment: String, about answer: LineExplanation) {
        let request = current
        complaining = true
        complaintError = nil
        Task {
            defer { complaining = false }
            do {
                try await LineExplainer.report(answer, for: request, reason: reason,
                                               comment: comment.trimmingCharacters(in: .whitespacesAndNewlines),
                                               installID: settings.installID)
                complained = reason
            } catch {
                complaintError = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "Не получилось отправить. Попробуйте ещё раз.")
            }
        }
    }

    /// After a complaint that dropped the answer: ask for a new one.
    private func explainAgain() {
        withAnimation(.easeOut(duration: 0.25)) {
            answer = nil
            failure = nil
            complained = nil
        }
        shown = false
        attempt += 1
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
        .padding(18)
        .background { IntelligenceGlow(cornerRadius: 26) }
        .glassCard(radius: 26)
        .transition(AnyTransition.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.96))))
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

/// Text that writes itself in: glyphs come out of a blur one after another, in a soft wave, like
/// Apple Intelligence's answers (iOS 18). Before iOS 18 the whole text fades and rises in.
struct RevealText: View {
    let text: String
    let shown: Bool
    var delay: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Longer text takes a little longer, within reason.
    static func duration(_ text: String) -> Double {
        min(1.8, 0.45 + Double(text.count) / 420)
    }

    var body: some View {
        if #available(iOS 18.0, *), !reduceMotion {
            Text(text)
                .textRenderer(RevealRenderer(progress: shown ? 1 : 0))
                .animation(shown ? .easeOut(duration: Self.duration(text)).delay(delay) : nil, value: shown)
        } else {
            Text(text)
                .opacity(shown ? 1 : 0)
                .offset(y: shown || reduceMotion ? 0 : 10)
                .animation(.easeOut(duration: 0.45).delay(delay), value: shown)
        }
    }
}

@available(iOS 18.0, *)
private struct RevealRenderer: TextRenderer, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// The part of the whole animation one glyph takes to arrive.
    private static let spread = 0.3

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let slices = layout.flatMap { line in line.flatMap { run in run.map { $0 } } }
        let count = Double(max(slices.count, 1))
        for (index, slice) in slices.enumerated() {
            let start = Double(index) / count * (1 - Self.spread)
            let local = min(max((progress - start) / Self.spread, 0), 1)
            guard local > 0 else { continue }
            if local >= 1 {
                context.draw(slice)
                continue
            }
            var glyph = context
            glyph.opacity = local
            glyph.addFilter(.blur(radius: (1 - local) * 6))
            glyph.translateBy(x: 0, y: (1 - local) * 6)
            glyph.draw(slice)
        }
    }
}

private extension View {
    /// Rises in with a spring after `delay`, a little smaller and blurred before.
    func cardReveal(_ shown: Bool, delay: Double) -> some View {
        modifier(CardReveal(shown: shown, delay: delay))
    }
}

private struct CardReveal: ViewModifier {
    var shown: Bool
    var delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduceMotion ? 0 : 8)
            .scaleEffect(shown || reduceMotion ? 1 : 0.94, anchor: .top)
            .offset(y: shown || reduceMotion ? 0 : 22)
            .animation(shown ? .spring(response: 0.6, dampingFraction: 0.8).delay(delay) : nil, value: shown)
    }
}
