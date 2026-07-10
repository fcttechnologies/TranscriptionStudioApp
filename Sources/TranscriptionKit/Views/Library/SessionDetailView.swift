import SwiftUI
import SwiftData
import AppIntents

/// A saved session's transcript with playback. Renders the stored attributed segments as
/// speaker turns (with the subtle confidence affordance), and — when the session's audio was
/// archived — plays it back, seeking to a tapped segment's start so the ear-vs-label check is
/// one click. Exact per-segment confidence numbers live in the Inspector's ASR table.
public struct SessionDetailView: View {
    let session: TranscriptSession

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var playingLineID: String?
    @State private var hasAudio = false
    @State private var showingIntelligence = false

    public init(session: TranscriptSession) {
        self.session = session
    }

    private var turns: [TranscriptTurn] {
        TranscriptTurn.group(stored: session.segments ?? [])
    }
    private var lineStarts: [(id: String, start: TimeInterval)] {
        turns.flatMap { $0.lines }.map { (id: $0.id, start: $0.start) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignMetrics.turnSpacing) {
                    header
                    ForEach(turns) { turn in
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
                Button("Copy transcript", systemImage: "doc.on.doc") { copyTranscript() }
                    .accessibilityIdentifier("session.copy")
            }
        }
        .sheet(isPresented: $showingIntelligence) {
            SessionIntelligenceSheet(session: session)
        }
        .modifier(PlayheadTracker(playback: app.playback, lineStarts: lineStarts,
                                  playingLineID: $playingLineID))
        // Onscreen awareness: let Siri / Apple Intelligence know which transcript is showing.
        .appEntityIdentifier(EntityIdentifier(for: TranscriptSessionEntity.self,
                                              identifier: session.id.uuidString))
        .onAppear { hasAudio = app.playback.load(fileName: session.audioFileName) }
        .onDisappear { app.playback.stop() }
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
