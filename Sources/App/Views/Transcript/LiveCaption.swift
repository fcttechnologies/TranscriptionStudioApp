import Foundation

/// One line of live captioning: a recent speaker turn's words as a single flowing string, with
/// the speaker label shown only when it should lead the line — a real diarized speaker while the
/// diarizer is attributing. This is the unit `LiveCaptionView` renders large and high-contrast.
struct CaptionLine: Identifiable, Equatable {
    let id: String
    let speaker: SpeakerID
    /// The label shown above the text, or nil to render the text with no label — nil when
    /// diarization isn't attributing speakers (a single unlabeled flow) or the span is unattributed.
    let speakerLabel: String?
    /// The turn's words joined into one caption string.
    let text: String
    /// True while the tail is still unconfirmed ASR (rendered with the provisional treatment).
    let isProvisional: Bool

    init(id: String, speaker: SpeakerID, speakerLabel: String?, text: String, isProvisional: Bool) {
        self.id = id
        self.speaker = speaker
        self.speakerLabel = speakerLabel
        self.text = text
        self.isProvisional = isProvisional
    }
}

/// Pure caption windowing/formatting: turn the fused live transcript (`RecordingController.segments`)
/// into the handful of recent, large caption lines shown on-screen. No SwiftUI, no engine — a thin
/// presentation layer over the streaming ASR the live recorder already produces, kept deterministic
/// and fully unit-tested.
enum LiveCaptionBuilder {

    /// Default number of most-recent ASR segments kept on the caption stage. Windows by segment
    /// (not by turn) so a single continuous speaker can't grow one unbounded line.
    static let defaultWindow = 6

    /// Build the on-screen caption lines from the fused transcript.
    ///
    /// - Parameters:
    ///   - segments: the controller's live `segments` — time-sorted, committed prefix + provisional tail.
    ///   - maxSegments: how many of the most-recent segments to keep (bounds the stage regardless of
    ///     how the speakers break down — the newest, including the provisional tail, are always kept).
    ///   - showsSpeakers: whether diarization is attributing speakers. False (diarizer unavailable, or
    ///     nothing diarized yet) degrades to one unlabeled flow with no speaker chips.
    static func lines(from segments: [AttributedSegment],
                             maxSegments: Int = defaultWindow,
                             showsSpeakers: Bool) -> [CaptionLine] {
        let window = max(1, maxSegments)
        let recent = segments.count > window ? Array(segments.suffix(window)) : segments
        return TranscriptTurn.group(recent).map { turn in
            let text = turn.lines
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let label: String? = (showsSpeakers && turn.speaker != .unknown) ? turn.speaker.displayName : nil
            return CaptionLine(id: turn.id,
                               speaker: turn.speaker,
                               speakerLabel: label,
                               text: text,
                               isProvisional: turn.isProvisional)
        }
    }
}
