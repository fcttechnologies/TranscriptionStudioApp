import SwiftUI

/// The Apple-Music-style mini-player: a floating glass capsule in the home's bottom safe-area
/// bar. While recording it carries the live pulse — the animated waveform of what the mic is
/// hearing — and expands to the full live-recording sheet on tap. During playback it shows
/// the loaded session and expands to its transcript. Absent when nothing is active.
struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if app.recording.isActive {
                RecordingMiniPlayer(recording: app.recording) {
                    app.activeSheet = .liveRecording
                }
            } else if app.readAloud.isActive, let nowSpeaking = app.readAloud.nowSpeaking {
                SpeakingMiniPlayer(readAloud: app.readAloud, nowSpeaking: nowSpeaking) {
                    app.openSession(id: nowSpeaking.sessionID)
                }
            } else if app.playback.hasLoadedAudio, let nowPlaying = app.playback.nowPlaying {
                PlaybackMiniPlayer(playback: app.playback, nowPlaying: nowPlaying) {
                    app.openSession(id: nowPlaying.sessionID)
                }
            }
        }
        .transition(.motionAware(.bottom, reduceMotion: reduceMotion))
        .animation(reduceMotion ? nil : DesignMetrics.standardSpring,
                   value: app.recording.isActive || app.readAloud.isActive || app.playback.hasLoadedAudio)
    }
}

/// The recording pill — pulsing dot, live waveform, elapsed clock, pause/resume. Preparing
/// and finishing read as their own quiet states so the pill narrates the whole run.
private struct RecordingMiniPlayer: View {
    let recording: RecordingController
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            HStack(spacing: DesignMetrics.spacingM) {
                switch recording.phase {
                case .preparing(let progress):
                    ProgressView().controlSize(.small)
                    Text(preparingLine(progress))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                case .finishing:
                    ProgressView().controlSize(.small)
                    Text("Finishing transcript…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                case .recording, .idle:
                    RecordingDot(isPaused: recording.isPaused)
                    LiveWaveform(levels: recording.waveform, accent: .red,
                                 height: DesignMetrics.miniPlayerWaveHeight)
                        .frame(width: DesignMetrics.miniPlayerWaveWidth)
                        .clipped()
                    Text(TimeFormat.clock(recording.elapsed))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                    Button {
                        recording.isPaused ? recording.resume() : recording.pause()
                    } label: {
                        Image(systemName: recording.isPaused ? "play.fill" : "pause.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel(recording.isPaused ? "Resume" : "Pause")
                    .accessibilityIdentifier(A11yID.miniPlayerRecordPauseToggle)
                }
            }
            .padding(.horizontal, DesignMetrics.spacingL)
            .frame(height: DesignMetrics.miniPlayerHeight)
            .containerRelativeFrame(.horizontal) { width, _ in
                DesignMetrics.feedWidth(forContainer: width)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, DesignMetrics.spacingL)
        .accessibilityIdentifier(A11yID.homeMiniPlayerRecording)
        .accessibilityLabel("Recording, \(TimeFormat.clock(recording.elapsed)) elapsed. Opens the live recording.")
    }

    private func preparingLine(_ progress: EnginePreparationProgress) -> String {
        guard let fraction = progress.fraction else { return progress.phase }
        return "\(progress.phase) \(Int(fraction * 100))%"
    }
}

/// The read-aloud pill — the on-device voice speaking a transcript. Shows model preparation
/// as its own quiet state (the first use downloads the synthesis model), then the speaking
/// title with pause/resume and a stop that puts the voice away. Expands to the transcript.
private struct SpeakingMiniPlayer: View {
    let readAloud: ReadAloudController
    let nowSpeaking: ReadAloudController.NowSpeaking
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            HStack(spacing: DesignMetrics.spacingM) {
                switch readAloud.phase {
                case .preparing(let phaseText, let fraction):
                    ProgressView().controlSize(.small)
                    Text(fraction.map { "\(phaseText) \(Int($0 * 100))%" } ?? phaseText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                case .speaking, .paused, .idle:
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.body)
                        .foregroundStyle(.tint)
                        .frame(width: DesignMetrics.miniPlayerTileSize,
                               height: DesignMetrics.miniPlayerTileSize)
                        .background(Color.accentColor.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: DesignMetrics.cornerS, style: .continuous))
                        .symbolEffect(.variableColor.iterative,
                                      isActive: readAloud.phase == .speaking)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(nowSpeaking.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(readAloud.phase == .paused ? "Paused" : "Speaking")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        readAloud.togglePause()
                    } label: {
                        Image(systemName: readAloud.phase == .paused ? "play.fill" : "pause.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel(readAloud.phase == .paused ? "Resume speaking" : "Pause speaking")
                    .accessibilityIdentifier(A11yID.miniPlayerSpeakPauseToggle)
                }
                Button {
                    readAloud.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Stop speaking")
            }
            .padding(.horizontal, DesignMetrics.spacingL)
            .frame(height: DesignMetrics.miniPlayerHeight)
            .containerRelativeFrame(.horizontal) { width, _ in
                DesignMetrics.feedWidth(forContainer: width)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, DesignMetrics.spacingL)
        .accessibilityIdentifier(A11yID.homeMiniPlayerSpeaking)
        .accessibilityLabel("Speaking \(nowSpeaking.title). Opens the transcript.")
    }
}

/// The playback pill — kind-tinted tile, title, playhead, play/pause, and a dismiss that
/// puts the audio away. Expands to the session's transcript on tap.
private struct PlaybackMiniPlayer: View {
    let playback: PlaybackController
    let nowPlaying: PlaybackController.NowPlaying
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            HStack(spacing: DesignMetrics.spacingM) {
                Image(systemName: SessionKindStyle.icon(nowPlaying.kind))
                    .font(.body)
                    .foregroundStyle(SessionKindStyle.tint(nowPlaying.kind))
                    .frame(width: DesignMetrics.miniPlayerTileSize,
                           height: DesignMetrics.miniPlayerTileSize)
                    .background(SessionKindStyle.tint(nowPlaying.kind).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: DesignMetrics.cornerS, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(nowPlaying.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(TimeFormat.clock(playback.currentTime)) / \(TimeFormat.clock(playback.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                Button {
                    let wasPlaying = playback.isPlaying
                    playback.togglePlayPause()
                    Task {
                        if wasPlaying {
                            await TranscriptionIntentDonations.donatePausePlayback()
                        } else {
                            let entity = TranscriptSessionEntity(id: nowPlaying.sessionID.uuidString,
                                                                 title: nowPlaying.title,
                                                                 date: Date(),
                                                                 kindLabel: SessionKindStyle.label(nowPlaying.kind),
                                                                 duration: playback.duration,
                                                                 textPreview: "")
                            await TranscriptionIntentDonations.donatePlayTranscript(entity)
                        }
                    }
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                Button {
                    playback.unload()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Close player")
            }
            .padding(.horizontal, DesignMetrics.spacingL)
            .frame(height: DesignMetrics.miniPlayerHeight)
            .containerRelativeFrame(.horizontal) { width, _ in
                DesignMetrics.feedWidth(forContainer: width)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, DesignMetrics.spacingL)
        .accessibilityIdentifier(A11yID.homeMiniPlayerPlayback)
        .accessibilityLabel("Now playing \(nowPlaying.title). Opens the transcript.")
    }
}

/// A pulsing red dot while live, steady amber while paused (shared with the live sheet).
struct RecordingDot: View {
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
