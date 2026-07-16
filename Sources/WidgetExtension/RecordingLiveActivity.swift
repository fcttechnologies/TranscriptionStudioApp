import ActivityKit
import GlanceKit
import SwiftUI
import WidgetKit

/// The live recording on the Lock Screen and in the Dynamic Island: state dot, a running
/// elapsed clock (self-advancing — updates only refresh the waveform and pause state), the
/// live input trace, and pause/stop controls that act through the app-process intents.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingLockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        RecordingStateLabel(isPaused: context.state.isPaused)
                        RecordingClock(state: context.state, font: .title2)
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 10) {
                        RecordingPauseButton(isPaused: context.state.isPaused)
                        RecordingStopButton()
                    }
                    .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LevelTrace(levels: context.state.levels, accent: .red)
                        .frame(height: 28)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "mic.fill")
                    .foregroundStyle(.red)
            } compactTrailing: {
                RecordingClock(state: context.state, font: .body,
                               widths: (42, 52, 68))
                    .foregroundStyle(.red)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Lock Screen

private struct RecordingLockScreenView: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                RecordingStateLabel(isPaused: state.isPaused)
                RecordingClock(state: state, font: .title)
            }
            LevelTrace(levels: state.levels, accent: .red)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
            RecordingPauseButton(isPaused: state.isPaused)
            RecordingStopButton()
        }
        .padding(16)
    }
}

// MARK: - Shared pieces

/// "Recording" with the red dot, or "Paused" with the amber one — the app's recording-dot idiom.
private struct RecordingStateLabel: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isPaused ? Color.orange : Color.red)
                .frame(width: 7, height: 7)
            Text(isPaused ? "Paused" : "Recording")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// The elapsed clock: self-advancing while running (its anchor is placed so `now − anchor` is
/// the elapsed time), a static reading while paused.
private struct RecordingClock: View {
    let state: RecordingActivityAttributes.ContentState
    var font: Font = .title2
    var widths: (base: CGFloat, tenMinute: CGFloat, hour: CGFloat) = (60, 72, 92)

    var body: some View {
        if let anchor = state.timerAnchor {
            ElapsedTimerText(anchor: anchor, font: font, widths: widths)
                .frame(maxWidth: nil, alignment: .leading)
        } else {
            Text(clock(state.elapsed))
                .font(font.weight(.semibold))
                .fontDesign(.rounded)
                .monospacedDigit()
        }
    }
}

private struct RecordingPauseButton: View {
    let isPaused: Bool

    var body: some View {
        Button(intent: ToggleRecordingPauseActivityIntent()) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.15), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
    }
}

private struct RecordingStopButton: View {
    var body: some View {
        Button(intent: StopRecordingActivityIntent()) {
            Image(systemName: "stop.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.red, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop recording")
    }
}

/// The quantized level trace — the app's `LiveWaveform` reading, redrawn from the compact
/// 0…100 buckets the content state carries. Newest at the trailing edge, older bars fading.
struct LevelTrace: View {
    let levels: [UInt8]
    var accent: Color

    var body: some View {
        Canvas { context, size in
            let count = max(levels.count, 1)
            let barWidth: CGFloat = 3
            let spacing = (size.width - CGFloat(count) * barWidth) / CGFloat(max(count - 1, 1))
            let midY = size.height / 2
            for (index, level) in levels.enumerated() {
                let magnitude = max(CGFloat(level) / 100, 0.08)
                let barHeight = magnitude * size.height
                let x = CGFloat(index) * (barWidth + spacing)
                let rect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
                let freshness = Double(index + 1) / Double(count)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(accent.opacity(0.35 + 0.65 * freshness)))
            }
        }
        .accessibilityHidden(true)
    }
}
