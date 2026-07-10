import SwiftUI
import UniformTypeIdentifiers

/// The Transcribe surface: paste a URL (Mac only) or drop / pick a media file, then watch
/// each job walk its step trail. Errors surface as human sentences on the card, never as an
/// alert with a stack trace. Shared across platforms; `showsURLField` gates the Mac-only URL
/// ingest (yt-dlp/ffmpeg don't run on iOS).
public struct TranscribeView: View {
    let showsURLField: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var urlText = ""
    @State private var isTargeted = false
    @State private var isImporting = false

    public init(showsURLField: Bool) {
        self.showsURLField = showsURLField
    }

    private var activeJobs: [TranscriptionJob] {
        app.jobs.jobs.sorted { $0.createdAt > $1.createdAt }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignMetrics.spacingXL) {
                if showsURLField { urlSection }
                dropSection
                if !activeJobs.isEmpty { jobsSection }
            }
            .padding(DesignMetrics.spacingXL)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Transcribe")
        .background(.background)
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: SupportedMediaExtensions.contentTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { startFile(url) }
            }
        }
    }

    // MARK: URL (Mac)

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingS) {
            SectionLabel("From a link")
            HStack(spacing: DesignMetrics.spacingS) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("Paste a TikTok, YouTube, or media URL", text: $urlText)
                    .textFieldStyle(.plain)
                    .onSubmit(startURL)
                    .accessibilityIdentifier("transcribe.urlField")
                if !urlText.isEmpty {
                    Button {
                        withAnimation(reduceMotion ? nil : DesignMetrics.snappySpring) { urlText = "" }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(DesignMetrics.spacingM)
            .cardStyle(cornerRadius: DesignMetrics.cornerM)
            .overlay(RoundedRectangle(cornerRadius: DesignMetrics.cornerM)
                .strokeBorder(.separator, lineWidth: 0.5))

            PrimaryButton("Transcribe link", systemImage: "arrow.down.circle", action: startURL)
                .disabled(!isValidURL)
                .opacity(isValidURL ? 1 : 0.5)
                .accessibilityIdentifier("transcribe.startURL")
        }
    }

    // MARK: File drop / pick

    private var dropSection: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingS) {
            SectionLabel("From a file")
            Button { isImporting = true } label: {
                VStack(spacing: DesignMetrics.spacingM) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                        .scaleEffect(isTargeted && !reduceMotion ? 1.08 : 1)
                    VStack(spacing: 2) {
                        Text("Drop audio or video here").font(.headline)
                        #if os(macOS)
                        Text("or click to choose a file").font(.subheadline).foregroundStyle(.secondary)
                        #else
                        Text("or tap to choose a file").font(.subheadline).foregroundStyle(.secondary)
                        #endif
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignMetrics.spacingXXL)
                .background {
                    RoundedRectangle(cornerRadius: DesignMetrics.cornerL, style: .continuous)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: DesignMetrics.cornerL, style: .continuous)
                        .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                                      style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.2, dash: [7, 5]))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(reduceMotion ? nil : DesignMetrics.snappySpring, value: isTargeted)
            .dropDestination(for: URL.self) { urls, _ in
                for url in urls { startFile(url) }
                return !urls.isEmpty
            } isTargeted: { isTargeted = $0 }
            .accessibilityIdentifier("transcribe.dropZone")
            .accessibilityLabel("Drop audio or video file, or activate to choose one")
        }
    }

    // MARK: Jobs

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingM) {
            SectionLabel("Jobs")
            ForEach(activeJobs) { job in
                JobProgressCard(job: job,
                                onCancel: { job.cancel() },
                                onOpen: { open(job) },
                                onDismiss: { app.jobs.remove(job) })
                .transition(.motionAware(.top, reduceMotion: reduceMotion))
            }
        }
        .animation(reduceMotion ? nil : DesignMetrics.standardSpring, value: activeJobs.map(\.id))
    }

    // MARK: Actions

    private var isValidURL: Bool {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else { return false }
        return url.scheme?.hasPrefix("http") == true && url.host != nil
    }

    private func startURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard isValidURL else { return }
        let title = URL(string: trimmed)?.host.map { "Link · \($0)" } ?? trimmed
        app.startTranscription(title: title, source: .url(trimmed))
        withAnimation(reduceMotion ? nil : DesignMetrics.snappySpring) { urlText = "" }
    }

    private func startFile(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        app.startTranscription(title: name.isEmpty ? "Audio file" : name, source: .file(url))
    }

    private func open(_ job: TranscriptionJob) {
        guard let id = job.resultSessionID else { return }
        app.selectedSessionID = id
        app.selectedSurface = .library
    }
}
