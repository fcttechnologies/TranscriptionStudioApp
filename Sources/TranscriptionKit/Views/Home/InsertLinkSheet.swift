import SwiftUI

/// The "+ → Insert Link" prompt (macOS only — URL ingest needs yt-dlp/ffmpeg): paste a URL,
/// start the job, and land back on the feed where its progress row lives.
struct InsertLinkSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @FocusState private var fieldFocused: Bool

    private var isValid: Bool { URLValidation.isTranscribableURL(urlText) }

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

                Text("The audio is downloaded and transcribed entirely on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                PrimaryButton("Transcribe Link", systemImage: "arrow.down.circle", action: start)
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
        app.startTranscription(title: URLValidation.suggestedTitle(for: trimmed),
                               source: .url(trimmed))
        Task { await TranscriptionIntentDonations.donateTranscribeLink(urlString: trimmed) }
        dismiss()
    }
}
