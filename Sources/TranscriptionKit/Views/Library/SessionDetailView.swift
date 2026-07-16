import SwiftUI
import SwiftData
import AppIntents

/// A saved session's transcript, presented as a sheet from the feed (and expanded from the
/// mini-player during playback). Renders the stored attributed segments as speaker turns
/// (with the subtle confidence affordance), and — when the session's audio was archived —
/// plays it back, seeking to a tapped segment's start so the ear-vs-label check is one
/// click. Closing the sheet mid-play hands the audio to the mini-player; exact per-segment
/// confidence numbers live in the Inspector's ASR table.
public struct SessionDetailView: View {
    let session: TranscriptSession

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var playingLineID: String?
    @State private var hasAudio = false
    @State private var exportFormat: TranscriptExport.Format?
    @State private var showingIntelligence = false
    @State private var isRenaming = false
    @State private var draftTitle = ""

    public init(session: TranscriptSession) {
        self.session = session
    }

    private var turns: [TranscriptTurn] {
        TranscriptTurn.group(stored: session.segments ?? [])
    }

    public var body: some View {
        let currentTurns = turns
        let currentLineStarts = currentTurns.flatMap { $0.lines }.map { (id: $0.id, start: $0.start) }
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignMetrics.turnSpacing) {
                        header
                        ForEach(currentTurns) { turn in
                            TranscriptTurnView(turn: turn,
                                               playingLineID: playingLineID,
                                               onTapLine: hasAudio ? { app.playback.play(from: $0.start) } : nil)
                        }
                    }
                    .padding(DesignMetrics.spacingL)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                if hasAudio {
                    Divider()
                    PlaybackBar(playback: app.playback)
                }
            }
            .background(.background)
            .navigationTitle(session.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem {
                    Button("Intelligence", systemImage: "sparkles") { showingIntelligence = true }
                        .accessibilityIdentifier("session.intelligence")
                }
                ToolbarItem {
                    Menu {
                        Button("Rename", systemImage: "pencil") { beginRenaming() }
                        Button("Copy Transcript", systemImage: "doc.on.doc") { copyTranscript() }
                        Menu {
                            ForEach(TranscriptExport.Format.allCases) { format in
                                Button(format.displayName) { exportFormat = format }
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .accessibilityIdentifier("session.more")
                }
                SheetCloseToolbar { dismiss() }
            }
        }
        #if os(macOS)
        .frame(width: DesignMetrics.macDetailSheetSize.width,
               height: DesignMetrics.macDetailSheetSize.height)
        #endif
        .fileExporter(isPresented: exportBinding,
                      document: exportDocument,
                      contentType: exportFormat.map(TranscriptExportDocument.contentType(for:)) ?? .plainText,
                      defaultFilename: exportFileName) { _ in
            exportFormat = nil
        }
        .sheet(isPresented: $showingIntelligence) {
            SessionIntelligenceSheet(session: session)
        }
        .alert("Rename Session", isPresented: $isRenaming) {
            TextField("Title", text: $draftTitle)
                .accessibilityIdentifier("session.renameField")
            Button("Cancel", role: .cancel) {}
            Button("Save") { commitRename() }
        }
        .modifier(PlayheadTracker(playback: app.playback, lineStarts: currentLineStarts,
                                  playingLineID: $playingLineID))
        // Onscreen awareness: let Siri / Apple Intelligence know which transcript is showing.
        .appEntityIdentifier(EntityIdentifier(for: TranscriptSessionEntity.self,
                                              identifier: session.id.uuidString))
        .onAppear {
            hasAudio = app.playback.prepare(session: session)
            let entity = TranscriptSessionEntity(session)
            Task { await TranscriptionIntentDonations.donateOpenTranscript(entity) }
        }
        // Engaged playback survives the sheet (the mini-player picks it up); audio that was
        // never played is put away.
        .onDisappear { app.playback.releaseIfIdle() }
    }

    // MARK: Export

    private var exportBinding: Binding<Bool> {
        Binding(get: { exportFormat != nil }, set: { if !$0 { exportFormat = nil } })
    }

    private var exportDocument: TranscriptExportDocument? {
        guard let exportFormat else { return nil }
        let text = TranscriptExport.render(TranscriptExport.items(from: session),
                                           as: exportFormat, title: session.title)
        return TranscriptExportDocument(text: text, format: exportFormat)
    }

    private var exportFileName: String {
        let base = session.title.isEmpty ? "Transcript" : session.title
        return "\(base).\(exportFormat?.fileExtension ?? "txt")"
    }

    private var header: some View {
        HStack(spacing: DesignMetrics.spacingM) {
            Label(SessionKindStyle.label(session.kind),
                  systemImage: SessionKindStyle.icon(session.kind))
                .font(.caption.weight(.semibold))
                .foregroundStyle(SessionKindStyle.tint(session.kind))
                .padding(.horizontal, DesignMetrics.spacingS)
                .padding(.vertical, DesignMetrics.speakerChipVPadding)
                .background(SessionKindStyle.tint(session.kind).opacity(0.12), in: Capsule())
            Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
            if session.duration > 0 {
                Text(TimeFormat.clock(session.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, DesignMetrics.spacingS)
    }

    // MARK: Rename

    private func beginRenaming() {
        draftTitle = session.title
        isRenaming = true
    }

    private func commitRename() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.title = trimmed
        try? modelContext.save()
        let entity = TranscriptSessionEntity(session)
        Task { await TranscriptionIntentDonations.donateRenameTranscript(entity, newTitle: trimmed) }
    }

    private func copyTranscript() {
        let text = turns.map { turn in
            "\(turn.speaker.displayName): " + turn.lines.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// Reads the playhead in isolation and maps it to the currently-playing line id, so the
/// per-tick playback update doesn't re-run the whole transcript body — only this modifier.
private struct PlayheadTracker: ViewModifier {
    let playback: PlaybackController
    let lineStarts: [(id: String, start: TimeInterval)]
    @Binding var playingLineID: String?

    func body(content: Content) -> some View {
        content.onChange(of: playback.currentTime) { _, time in
            let id = lineStarts.last(where: { $0.start <= time + 0.05 })?.id
            if id != playingLineID { playingLineID = playback.isPlaying ? id : nil }
        }
    }
}

/// The transport bar: play/pause, a scrubber, and the running / total time.
private struct PlaybackBar: View {
    let playback: PlaybackController

    private var seekBinding: Binding<Double> {
        Binding(get: { playback.currentTime },
                set: { playback.play(from: $0) })
    }

    var body: some View {
        HStack(spacing: DesignMetrics.spacingM) {
            CircleIconButton(systemImage: playback.isPlaying ? "pause.fill" : "play.fill",
                             tint: .accentColor,
                             accessibilityLabel: playback.isPlaying ? "Pause" : "Play") {
                playback.togglePlayPause()
            }
            Text(TimeFormat.clock(playback.currentTime))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Slider(value: seekBinding, in: 0...max(playback.duration, 0.1))
                .accessibilityIdentifier("session.scrubber")
            Text(TimeFormat.clock(playback.duration))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(DesignMetrics.spacingL)
        .background(.regularMaterial)
    }
}
