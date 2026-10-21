import SwiftUI
import UIKit

/// The lyrics area when there are no lyrics, as Spicy Lyrics' `LyricsNotice.ts` builds it: the
/// cause in its own words, "Try again" where a refetch can help, and for causes worth a report
/// "Copy details" (no account, keys or tokens in them) and a report form with the details filled in.
struct LyricsNoticeView: View {
    let notice: LyricsNotice
    var failure: LyricsFailure?
    /// Offered for a local file: add its lyrics as TTML.
    var onOwnLyrics: (() -> Void)?

    @Environment(PlayerModel.self) private var player
    @State private var copyState = CopyState.idle
    @State private var reporting = false

    private enum CopyState { case idle, done }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: notice.icon)
                .font(.system(size: 40))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 84, height: 84)
                .glassCircle()
                .padding(.bottom, 4)
            Text(notice.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let body = notice.body {
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            actions
                .padding(.top, 4)
            if notice.report {
                Text(String(localized: "Код: \(notice.code)"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.4))
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $reporting) {
            NavigationStack {
                ReportComposeView(prefill: "\n\n" + details)
                    .navigationTitle(String(localized: "Сообщить о проблеме"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "Закрыть")) { reporting = false }
                        }
                    }
            }
        }
    }

    private var actions: some View {
        // Side by side when they fit, stacked on a narrow screen or with large type.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { buttons }
            VStack(spacing: 10) { buttons }
        }
        .glassButton()
    }

    @ViewBuilder
    private var buttons: some View {
        if notice.retry {
            Button {
                player.loadLyrics(force: true)
            } label: {
                Label(String(localized: "Повторить"), systemImage: "arrow.clockwise")
            }
            .glassButton(prominent: true, tint: .white)
            .foregroundStyle(.black)
        }
        if notice == .localTrack, let onOwnLyrics {
            Button(action: onOwnLyrics) {
                Label(String(localized: "Свой текст (TTML)"), systemImage: "doc.text")
            }
        }
        if notice.report {
            Button(action: copy) {
                // Both faces stay laid out, so the button doesn't change width when the label does.
                ZStack {
                    Label(String(localized: "Скопировать детали"), systemImage: "doc.on.doc")
                        .opacity(copyState == .idle ? 1 : 0)
                    Label(String(localized: "Скопировано"), systemImage: "checkmark")
                        .opacity(copyState == .done ? 1 : 0)
                }
                .animation(.easeInOut(duration: 0.2), value: copyState)
            }
            Button {
                reporting = true
            } label: {
                Label(String(localized: "Сообщить"), systemImage: "exclamationmark.bubble")
            }
        }
    }

    private func copy() {
        UIPasteboard.general.string = details
        copyState = .done
        Task {
            try? await Task.sleep(for: .seconds(2))
            copyState = .idle
        }
    }

    /// What "Copy details" puts on the clipboard, fenced so a chat keeps the columns aligned.
    /// Nothing identifying: no account, no keys, no tokens.
    private var details: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (info?["CFBundleVersion"] as? String ?? "?") + ")"
        let track = player.track
        let time = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: " UTC")
        let rows: [(String, String?)] = [
            ("Notice", notice.code),
            ("Answered by", failure?.source),
            ("Error", failure?.detail.replacingOccurrences(of: "\n", with: "; ")),
            ("Track", track.map { $0.artists.isEmpty ? $0.title : "\($0.title) by \($0.artistLine)" }),
            ("Track ID", track?.id),
            ("Player", player.playbackSource.title),
            ("Sweet Lyrics", version),
            ("iOS", UIDevice.current.systemVersion),
            ("Device", UIDevice.current.model),
            ("Time", time),
        ]
        let lines = rows.compactMap { label, value in
            value.map { (label + ":").padding(toLength: 14, withPad: " ", startingAt: 0) + $0 }
        }
        return (["**Sweet Lyrics notice**", "```"] + lines + ["```"]).joined(separator: "\n")
    }
}
