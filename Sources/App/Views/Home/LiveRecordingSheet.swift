import SwiftUI

/// The mini-player's expanded form — the full live-recording view as a sheet. Closing it
/// never touches the run (the recording keeps going in the mini-player); Stop is the only
/// way to end it. Split into subviews that each read only the controller properties they
/// render, so a level tick doesn't re-run the transcript (per-property observation isolation).
struct LiveRecordingSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Live-caption mode: the transcript region becomes a large, high-contrast caption stage for
    /// reading at a distance. Off by default; toggled from the toolbar while a run is live.
    @State private var captionMode = false

    var body: some View {
        NavigationStack {
            Group {
                switch app.recording.phase {
                case .preparing(let progress):
                    PreparingView(progress: progress)
                case .recording, .finishing:
                    live
                case .idle:
                    // The run ended elsewhere (stop from the toolbar, a capture failure) —
                    // there's nothing live to show.
                    Color.clear.onAppear { dismiss() }
                }
            }
            .navigationTitle(captionMode ? "Captions" : "Recording")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if app.recording.isActive {
                    captionToggle
                }
                SheetCloseToolbar { dismiss() }
            }
        }
        #if os(macOS)
        .frame(width: DesignMetrics.macDetailSheetSize.width,
               height: DesignMetrics.macDetailSheetSize.height)
        #endif
    }

    private var live: some View {
        VStack(spacing: 0) {
            LiveHeader(recording: app.recording)
            NoticeBar(recording: app.recording)
            Divider()
            if captionMode {
                LiveCaptionRegion(recording: app.recording)
            } else {
                LiveTranscriptRegion(recording: app.recording)
            }
            Divider()
            LiveControls(recording: app.recording, app: app)
        }
        .background(.background)
    }

    /// Toolbar toggle between the standard transcript and the large caption stage.
    private var captionToggle: some ToolbarContent {
        ToolbarItem(placement: captionTogglePlacement) {
            Button {
                captionMode.toggle()
            } label: {
                Label(captionMode ? "Hide captions" : "Show captions",
                      systemImage: captionMode ? "captions.bubble.fill" : "captions.bubble")
            }
            .accessibilityIdentifier(A11yID.recordCaptionToggle)
            .help(captionMode ? "Switch back to the transcript" : "Large captions for reading at a distance")
        }
    }

    private var captionTogglePlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .automatic
        #endif
    }
}

/// The live-caption stage (isolated so it re-renders on segment changes only, like the
/// transcript region — a level tick doesn't re-run it).
private struct LiveCaptionRegion: View {
    let recording: RecordingController

    var body: some View {
        LiveCaptionView(segments: recording.segments,
                        showsSpeakers: !recording.diarizationUnavailable)
    }
}

/// The preparing phase — model download/load progress, shown before capture begins.
private struct PreparingView: View {
    let progress: EnginePreparationProgress

    var body: some View {
        VStack(spacing: DesignMetrics.spacingL) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction) {
                    Text(progress.phase)
                } currentValueLabel: {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                .frame(maxWidth: 320)
            } else {
                ProgressView { Text(progress.phase) }
            }
        }
        .padding(DesignMetrics.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityIdentifier(A11yID.recordPreparing)
    }
}

/// Elapsed clock, live REC indicator, level meter, and the scrolling waveform.
private struct LiveHeader: View {
    let recording: RecordingController

    var body: some View {
        VStack(spacing: DesignMetrics.spacingM) {
            HStack(alignment: .center, spacing: DesignMetrics.spacingM) {
                RecordingDot(isPaused: recording.isPaused)
                Text(TimeFormat.clock(recording.elapsed))
                    .font(.system(size: DesignMetrics.elapsedFont, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier(A11yID.recordElapsed)
                Spacer()
                Label(recording.mode.title, systemImage: recording.mode.systemImage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                LevelMeter(level: recording.level)
            }
            LiveWaveform(levels: recording.waveform, accent: .red)
                .subSurface()
        }
        .padding(DesignMetrics.spacingL)
    }
}

/// A small in-line notice: "diarization unavailable — transcribing without speakers", shown
/// when the diarizer couldn't be prepared so the run degrades to ASR-only.
private struct NoticeBar: View {
    let recording: RecordingController

    var body: some View {
        if recording.diarizationUnavailable {
            Label("Diarization unavailable — transcribing without speakers.",
                  systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignMetrics.spacingL)
                .padding(.bottom, DesignMetrics.spacingS)
                .accessibilityIdentifier(A11yID.recordDiarizationUnavailable)
        }
    }
}

/// The live transcript region (isolated so it re-renders on segment changes only).
private struct LiveTranscriptRegion: View {
    let recording: RecordingController

    var body: some View {
        if recording.segments.isEmpty {
            ContentUnavailableView {
                Label("Listening…", systemImage: "waveform")
            } description: {
                Text("Speaker-attributed transcript will appear here as you speak.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LiveTranscriptView(segments: recording.segments)
        }
    }
}

/// Pause / resume and stop while recording; a "Finishing transcript…" indicator while the
/// engines drain their final passes after stop.
private struct LiveControls: View {
    let recording: RecordingController
    let app: AppModel

    var body: some View {
        Group {
            if recording.phase == .finishing {
                finishing
            } else {
                controls
            }
        }
        .padding(DesignMetrics.spacingL)
    }

    private var finishing: some View {
        HStack(spacing: DesignMetrics.spacingM) {
            ProgressView()
                .controlSize(.small)
            Text("Finishing transcript…")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(A11yID.recordFinishing)
    }

    private var controls: some View {
        HStack(spacing: DesignMetrics.spacingL) {
            if recording.isPaused {
                CircleIconButton(systemImage: "play.fill", tint: .accentColor,
                                 accessibilityLabel: "Resume") { recording.resume() }
            } else {
                CircleIconButton(systemImage: "pause.fill", tint: .accentColor,
                                 accessibilityLabel: "Pause") { recording.pause() }
            }
            Spacer()
            Text("\(recording.segments.count) segments")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button {
                // The stop flow swaps this sheet for the saved session's transcript.
                app.stopRecordingAndOpen()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, DesignMetrics.spacingL)
                    .padding(.vertical, DesignMetrics.spacingM)
                    .background(Color.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier(A11yID.recordStop)
        }
    }
}
