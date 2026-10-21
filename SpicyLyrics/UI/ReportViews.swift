import PhotosUI
import SwiftUI

/// Settings → Reports: whether errors may be sent by themselves, and a form to report a problem.
struct ReportSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Отправлять отчёты об ошибках"), isOn: $settings.sendsReports)
            } footer: {
                Text(String(localized: "Когда что-то ломается, приложение анонимно отправит разработчику журнал: версия приложения, модель телефона и iOS, названия треков, тайминги и настройки. Без аккаунта Spotify, ключей, токенов и имён ваших устройств. Не чаще пяти раз в день. Отчёты разбирает разработчик вместе с ИИ-ассистентом (Claude, Anthropic): он читает их через GitHub. Хранятся до 90 дней после последнего сообщения."))
            }

            Section {
                NavigationLink {
                    ReportComposeView()
                        .settingsPage()
                        .navigationTitle(String(localized: "Сообщить о проблеме"))
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label(String(localized: "Сообщить о проблеме"), systemImage: "exclamationmark.bubble")
                }
            } footer: {
                Text(String(localized: "Опишите, что не так, приложите фото и журнал. Отчёт увидят разработчик и его ИИ-ассистент (Claude)."))
            }

            if !reports.threads.isEmpty {
                Section {
                    ForEach(reports.threads) { thread in
                        NavigationLink {
                            ReportThreadView(threadID: thread.id)
                                .settingsPage()
                                .navigationTitle(String(localized: "Отчёт"))
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            ThreadRow(thread: thread, unread: reports.isUnread(thread))
                        }
                    }
                } header: {
                    Text(String(localized: "Мои отчёты"))
                } footer: {
                    Text(String(localized: "Здесь появляются ответы разработчика. Можно ответить в той же переписке."))
                }
            }
        }
        .task { await reports.refreshThreads(force: true) }
        .refreshable { await reports.refreshThreads(force: true) }
    }

    private var reports: ReportService { .shared }
}

private struct ThreadRow: View {
    let thread: ReportService.Thread
    let unread: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(thread.note.isEmpty ? String(localized: "Без описания") : thread.note)
                    .lineLimit(1)
                Spacer()
                if unread {
                    Circle().fill(.blue).frame(width: 8, height: 8)
                }
            }
            HStack(spacing: 6) {
                StatusBadge(status: thread.status)
                Text(thread.date.formatted(date: .abbreviated, time: .omitted))
                if let answer = thread.messages.last {
                    Text("· " + (answer.fromDeveloper ? String(localized: "ответ разработчика") : String(localized: "ваше сообщение")))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.25), in: Capsule())
            .foregroundStyle(color)
    }

    private var title: String {
        switch status {
        case "in_progress": return String(localized: "В работе")
        case "closed": return String(localized: "Закрыт")
        default: return String(localized: "Открыт")
        }
    }

    private var color: Color {
        switch status {
        case "in_progress": return .orange
        case "closed": return .gray
        default: return .blue
        }
    }
}

/// One report: what the user wrote, the developer's answers, their replies, and a field to reply.
struct ReportThreadView: View {
    let threadID: String
    @State private var draft = ""
    @State private var sending = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var reports: ReportService { .shared }
    private var thread: ReportService.Thread? { reports.threads.first { $0.id == threadID } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let thread {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            StatusBadge(status: thread.status)
                            Text(thread.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        bubble(thread.note.isEmpty ? String(localized: "Отчёт без описания") : thread.note,
                               fromDeveloper: false, date: thread.date)
                        ForEach(thread.messages) { message in
                            bubble(message.text, fromDeveloper: message.fromDeveloper, date: message.date)
                                .id(message.id)
                        }
                        if thread.isClosed {
                            Text(String(localized: "Отчёт закрыт. Если проблема осталась, напишите — он откроется снова."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
            }
            .onAppear {
                reports.markAnswersSeen()
                if let last = thread?.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: thread?.messages.count) { _, _ in
                reports.markAnswersSeen()
                if let last = thread?.messages.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .task { await reports.refreshThreads(force: true) }
        .refreshable { await reports.refreshThreads(force: true) }
    }

    private func bubble(_ text: String, fromDeveloper: Bool, date: Date) -> some View {
        VStack(alignment: fromDeveloper ? .leading : .trailing, spacing: 3) {
            Text(fromDeveloper ? String(localized: "Разработчик") : String(localized: "Вы"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassCard(fromDeveloper ? .regular : .tinted(Color.accentColor.opacity(0.6), interactive: false), radius: 18)
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: fromDeveloper ? .leading : .trailing)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(String(localized: "Ответить"), text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassCard(radius: 20)
                Button {
                    Task { await send() }
                } label: {
                    if sending {
                        ProgressView().frame(width: 34, height: 34)
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    }
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(String(localized: "Отправить"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .legacyBarMaterial()
    }

    private func send() async {
        guard let thread else { return }
        sending = true
        failure = nil
        defer { sending = false }
        do {
            try await reports.reply(to: thread, text: draft.trimmingCharacters(in: .whitespacesAndNewlines))
            draft = ""
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Describe a problem, attach up to three photos and the log, and send it.
struct ReportComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeLog = true
    @State private var picked: [PhotosPickerItem] = []
    /// The picked photos, compressed, each with the picker item it came from.
    @State private var photos: [PickedPhoto] = []
    @State private var unreadablePhotos = 0
    @State private var sending = false
    @State private var failure: String?
    @State private var sent = false

    private struct PickedPhoto {
        let item: PhotosPickerItem
        let jpeg: Data
    }

    /// `prefill` starts the message, e.g. with a lyrics notice's details.
    init(prefill: String = "") {
        _message = State(initialValue: prefill)
    }

    private var canSend: Bool {
        !sending && (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty || includeLog)
    }

    var body: some View {
        Form {
            Section(String(localized: "Что случилось")) {
                TextEditor(text: $message)
                    .frame(minHeight: 120)
                    .overlay(alignment: .topLeading) {
                        if message.isEmpty {
                            Text(String(localized: "Например: на этой песне текст отстаёт на секунду, после паузы всё нормально."))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }

            Section {
                PhotosPicker(selection: $picked, maxSelectionCount: 3, matching: .images) {
                    Label(String(localized: "Добавить фото"), systemImage: "photo.on.rectangle")
                }
                if !photos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(photos.indices, id: \.self) { index in
                                thumbnail(photos[index])
                            }
                        }
                    }
                }
                if unreadablePhotos > 0 {
                    Text(String(localized: "Не удалось прочитать фото: \(unreadablePhotos)"))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(String(localized: "Фото"))
            } footer: {
                Text(String(localized: "До трёх фото, например скриншот. Их увидят разработчик и его ИИ-ассистент (Claude)."))
            }

            Section {
                Toggle(String(localized: "Приложить журнал"), isOn: $includeLog)
            } footer: {
                Text(String(localized: "В журнале тайминги, ошибки, названия треков и настройки, без ключей, токенов и имён ваших устройств."))
            }

            Section {
                Button {
                    Task { await send() }
                } label: {
                    HStack {
                        Text(String(localized: "Отправить"))
                        Spacer()
                        if sending { ProgressView() }
                    }
                }
                .disabled(!canSend)
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        // A new selection cancels the loading of the previous one.
        .task(id: picked) { await load(picked) }
        .alert(String(localized: "Отправлено"), isPresented: $sent) {
            Button("OK") { dismiss() }
        } message: {
            Text(String(localized: "Спасибо! Отчёт ушёл разработчику."))
        }
    }

    @ViewBuilder
    private func thumbnail(_ photo: PickedPhoto) -> some View {
        if let image = UIImage(data: photo.jpeg) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button {
                        photos.removeAll { $0.item == photo.item }
                        picked.removeAll { $0 == photo.item }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .padding(3)
                    }
                    .buttonStyle(.plain)
                }
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        var loaded: [PickedPhoto] = []
        var unreadable = 0
        for item in items {
            // Already compressed (a photo was removed, the rest stay).
            if let known = photos.first(where: { $0.item == item }) {
                loaded.append(known)
                continue
            }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let jpeg = Self.compress(data) else {
                unreadable += 1
                continue
            }
            loaded.append(PickedPhoto(item: item, jpeg: jpeg))
        }
        guard !Task.isCancelled else { return }
        photos = loaded
        unreadablePhotos = unreadable
    }

    private func send() async {
        sending = true
        failure = nil
        defer { sending = false }
        do {
            try await ReportService.shared.send(
                kind: "manual", message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                photos: photos.map(\.jpeg), includeLog: includeLog)
            sent = true
        } catch {
            failure = error.localizedDescription
        }
    }

    /// A JPEG of at most ~1600 px and under 1.8 MB (the server takes 2 MB).
    private static func compress(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        var longestSide: CGFloat = 1600
        for quality in [0.7, 0.5, 0.35] {
            let scale = min(1, longestSide / max(image.size.width, image.size.height, 1))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            if let jpeg = scaled.jpegData(compressionQuality: quality), jpeg.count < 1_800_000 { return jpeg }
            longestSide *= 0.7
        }
        return nil
    }
}
