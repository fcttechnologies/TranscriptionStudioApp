import SwiftUI

/// The active-recording layout. Split into subviews that each read only the controller
/// properties they render, so a level tick doesn't re-run the transcript and a new segment
/// doesn't re-run the meter (per-property observation isolation).
struct RecordLiveView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            RecordHeader(recording: app.recording)
            Divider()
            RecordTranscript(recording: app.recording)
            Divider()
            RecordControls(recording: app.recording, app: app)
        }
        .background(.background)
    }
}

/// Elapsed clock, live REC indicator, level meter, and the scrolling waveform.
private struct RecordHeader: View {
    let recording: RecordingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DesignMetrics.spacingM) {
            HStack(alignment: .center, spacing: DesignMetrics.spacingM) {
                RecordingDot(isPaused: recording.isPaused)
                Text(TimeFormat.clock(recording.elapsed))
                    .font(.system(size: DesignMetrics.elapsedFont, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("record.elapsed")
                Spacer()
                Label(recording.mode.title, systemImage: recording.mode.systemImage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                LevelMeter(level: recording.level)
            }
            LiveWaveform(levels: recording.waveform, accent: .accentColor)
                .subSurface()
        }
        .padding(DesignMetrics.spacingL)
    }
}

/// A pulsing red dot while live, steady amber while paused.
private struct RecordingDot: View {
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(isPaused ? Color.orange : Color.red)
            .frame(width: 12, height: 12)
            .opacity(isPaused ? 1 : (pulsing ? 0.35 : 1))
            .animation(reduceMotion || isPaused ? nil
                       : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}

/// The live transcript region (isolated so it re-renders on segment changes only).
private struct RecordTranscript: View {
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

/// Pause / resume and stop, plus a caption of how many turns are captured so far.
private struct RecordControls: View {
    let recording: RecordingController
    let app: AppModel

    var body: some View {
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
                Task {
                    let id = await recording.stop()
                    if let id {
                        app.selectedSessionID = id
                        app.playback.load(fileName: nil)
                    }
                }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, DesignMetrics.spacingL)
                    .padding(.vertical, DesignMetrics.spacingM)
                    .background(Color.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier("record.stop")
        }
        .padding(DesignMetrics.spacingL)
    }
}
