import SwiftUI
import FCTComponentsUI

/// One speaker turn rendered: a colored accent rail, the speaker chip, and the turn's lines.
/// Provisional lines shimmer; committed lines carry a subtle confidence underline. In the
/// library, lines are tappable (seek-to-play); with `karaoke` on, the playing line is lit and
/// the rest recede (the Apple Music lyrics treatment). `showsSpeaker: false` drops the chip +
/// accent rail entirely — the single-speaker flat layout.
struct TranscriptTurnView: View {
    let turn: TranscriptTurn
    var playingLineID: String?
    var onTapLine: ((TranscriptTurn.Line) -> Void)?
    var showsSpeaker: Bool
    var karaoke: Bool
    /// Verbatim/confidence display: when on, low-confidence words carry a subtle dotted
    /// underline (per-word when word timestamps were captured, else the whole segment). Off by
    /// default, so the live transcript and the default reading view are unaffected.
    var confidenceHighlighting: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(turn: TranscriptTurn,
                playingLineID: String? = nil,
                onTapLine: ((TranscriptTurn.Line) -> Void)? = nil,
                showsSpeaker: Bool = true,
                karaoke: Bool = false,
                confidenceHighlighting: Bool = false) {
        self.turn = turn
        self.playingLineID = playingLineID
        self.onTapLine = onTapLine
        self.showsSpeaker = showsSpeaker
        self.karaoke = karaoke
        self.confidenceHighlighting = confidenceHighlighting
    }

    private var accent: Color { DesignMetrics.color(for: turn.speaker) }

    var body: some View {
        HStack(alignment: .top, spacing: DesignMetrics.spacingM) {
            if showsSpeaker {
                RoundedRectangle(cornerRadius: DesignMetrics.turnAccentWidth / 2)
                    .fill(accent.opacity(0.7))
                    .frame(width: DesignMetrics.turnAccentWidth)
            }
            VStack(alignment: .leading, spacing: DesignMetrics.spacingS) {
                if showsSpeaker {
                    HStack(spacing: DesignMetrics.spacingS) {
                        SpeakerChip(speaker: turn.speaker, confidence: turn.speakerConfidence)
                        Text(TimeFormat.clock(turn.start))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                ForEach(turn.lines) { line in
                    lineView(line)
                }
            }
        }
        .padding(.vertical, DesignMetrics.spacingXS)
        .animation(reduceMotion ? nil : DesignMetrics.liveFollowSpring, value: playingLineID)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(turn.speaker.displayName): \(turn.lines.map(\.text).joined(separator: " "))"))
    }

    @ViewBuilder
    private func lineView(_ line: TranscriptTurn.Line) -> some View {
        let isPlaying = playingLineID == line.id
        // Karaoke: while a line is playing, the others recede; with no playhead everything
        // reads at full strength.
        let receded = karaoke && playingLineID != nil && !isPlaying
        Group {
            if line.isProvisional {
                ShimmerText(line.text, color: accent)
            } else if confidenceHighlighting {
                ConfidenceWordsText(spans: Confidence.spans(text: line.text,
                                                            words: line.words,
                                                            segmentScore: line.asrScore,
                                                            threshold: DesignMetrics.lowConfidenceThreshold),
                                    accent: accent)
            } else {
                ConfidenceText(line.text, score: Double(line.asrScore), accent: accent)
            }
        }
        .padding(.horizontal, onTapLine == nil ? 0 : DesignMetrics.spacingS)
        .padding(.vertical, onTapLine == nil ? 0 : DesignMetrics.spacingXS)
        .background {
            if isPlaying {
                RoundedRectangle(cornerRadius: DesignMetrics.cornerS, style: .continuous)
                    .fill(accent.opacity(0.14))
            }
        }
        .opacity(receded ? DesignMetrics.karaokeRecededOpacity : 1)
        .contentShape(Rectangle())
        .onTapGesture { onTapLine?(line) }
        .id(line.id)
        .help(onTapLine == nil ? "" : "Play from \(TimeFormat.clock(line.start))")
    }
}

/// Shared time formatting for the transcript surfaces.
enum TimeFormat {
    /// mm:ss (or h:mm:ss past an hour) for a session-relative timestamp.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
