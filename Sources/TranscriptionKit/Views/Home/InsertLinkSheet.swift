import SwiftUI

/// The "+ → Insert Link" prompt: paste a URL and start it. On the Mac the audio is downloaded and
/// transcribed locally; on iOS (no yt-dlp/ffmpeg) the link is queued as a `.pendingRemote` job for
/// a Mac to pick up over CloudKit — so the copy and the presence badge adapt to the platform.
struct InsertLinkSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @FocusState private var fieldFocused: Bool

    private var isValid: Bool { URLValidation.isTranscribableURL(urlText) }

    /// iOS queues the link for a Mac; the Mac transcribes it itself.
    private var transcribesLocally: Bool { app.urlDownloader != nil }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DesignMetrics.spacingL) {
                HStack(spacing: DesignMetrics.spacingS) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    TextField("Paste a TikTok, YouTube, or media URL", text: $urlText)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .onSubmit(start)
                        .accessibilityIdentifier("insertLink.urlField")
                }
                .padding(DesignMetrics.spacingM)
                .cardStyle(cornerRadius: DesignMetrics.cornerM)
                .overlay(RoundedRectangle(cornerRadius: DesignMetrics.cornerM)
                    .strokeBorder(.separator, lineWidth: 0.5))

                Text(transcribesLocally
                     ? "The audio is downloaded and transcribed entirely on this Mac."
                     : "iOS can't download links itself — this is queued and transcribed on your Mac, then synced back here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !transcribesLocally {
                    MacPresenceBadge()
                }

                PrimaryButton(transcribesLocally ? "Transcribe Link" : "Send to Your Mac",
                              systemImage: transcribesLocally ? "arrow.down.circle" : "arrow.up.forward.app",
                              action: start)
                    .disabled(!isValid)
                    .opacity(isValid ? 1 : 0.5)
                    .accessibilityIdentifier("insertLink.start")

                Spacer(minLength: 0)
            }
            .padding(DesignMetrics.spacingXL)
            .background(.background)
            .navigationTitle("Insert Link")
            .toolbar {
                SheetCloseToolbar { dismiss() }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 260)
        #endif
        .onAppear { fieldFocused = true }
    }

    private func start() {
        guard isValid else { return }
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        app.submitLink(urlString: trimmed, title: URLValidation.suggestedTitle(for: trimmed))
        Task { await TranscriptionIntentDonations.donateTranscribeLink(urlString: trimmed) }
        dismiss()
    }
}
