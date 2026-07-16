import ActivityKit
import GlanceKit
import SwiftUI
import WidgetKit

/// A playing session on the Lock Screen and in the Dynamic Island: the session's identity
/// (kind tile + title), a self-advancing progress bar anchored to the transport's last
/// discontinuity, and a play/pause control acting through the app-process intent.
struct PlaybackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
            PlaybackLockScreenView(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    KindTile(systemImage: context.attributes.kindSystemImage)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.attributes.kindLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PlayPauseButton(isPlaying: context.state.isPlaying)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PlaybackProgress(state: context.state)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                RemainingText(state: context.state)
            } minimal: {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
            }
        }
    }
}

// MARK: - Lock Screen

private struct PlaybackLockScreenView: View {
    let attributes: PlaybackActivityAttributes
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                KindTile(systemImage: attributes.kindSystemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(attributes.kindLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                PlayPauseButton(isPlaying: state.isPlaying)
            }
            PlaybackProgress(state: state)
        }
        .padding(16)
    }
}

// MARK: - Shared pieces

/// The session-kind icon in its tinted rounded tile — the mini-player's identity mark.
private struct KindTile: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.body)
            .foregroundStyle(.tint)
            .frame(width: 36, height: 36)
            .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PlayPauseButton: View {
    let isPlaying: Bool

    var body: some View {
        Button(intent: TogglePlaybackActivityIntent()) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.15), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

/// The progress bar + the time row. While playing, both advance on their own across the
/// wall-clock span the state anchors (rate-scaled, so the bar completes exactly when the audio
/// does); paused shows the static position.
private struct PlaybackProgress: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 3) {
            if state.isPlaying,
               let span = PlaybackClock.wallClockSpan(position: state.position,
                                                      duration: state.duration,
                                                      rate: state.rate,
                                                      updatedAt: state.updatedAt) {
                ProgressView(timerInterval: span, countsDown: false) { EmptyView() }
                    currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: state.duration > 0 ? state.position / state.duration : 0)
            }
            HStack {
                if !state.isPlaying {
                    Text(clock(state.position))
                        .font(.caption2.weight(.medium))
                        .fontDesign(.rounded)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                RemainingText(state: state)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.accentColor)
    }
}

/// Time remaining: a self-advancing countdown while playing (wall-clock at the current rate),
/// a static reading while paused.
private struct RemainingText: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        if state.isPlaying,
           let span = PlaybackClock.wallClockSpan(position: state.position,
                                                  duration: state.duration,
                                                  rate: state.rate,
                                                  updatedAt: state.updatedAt) {
            Text(timerInterval: span, countsDown: true)
                .fontDesign(.rounded)
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: 60, alignment: .trailing)
        } else {
            Text("−" + clock(max(state.duration - state.position, 0)))
                .fontDesign(.rounded)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}
