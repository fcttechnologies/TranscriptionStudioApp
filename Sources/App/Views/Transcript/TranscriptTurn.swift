import Foundation

/// A rendered speaker turn: consecutive transcript segments from one speaker, grouped for
/// display so the UI shows "Speaker 2 said …" once with its lines beneath, not a chip per
/// segment. Value type, `Equatable`/`Identifiable` so SwiftUI diffs turns cheaply.
struct TranscriptTurn: Identifiable, Equatable {
    struct Line: Identifiable, Equatable {
        let id: String
        let text: String
        let start: TimeInterval
        let isProvisional: Bool
        /// Legibility score [0,1] for the segment-level confidence affordance.
        let asrScore: Float
        /// Per-word model probabilities when word timestamps were captured; nil otherwise.
        /// Feeds the confidence display's per-word flagging (degrades to `asrScore` when nil).
        let words: [AsrWord]?

        init(id: String, text: String, start: TimeInterval, isProvisional: Bool,
                    asrScore: Float, words: [AsrWord]? = nil) {
            self.id = id
            self.text = text
            self.start = start
            self.isProvisional = isProvisional
            self.asrScore = asrScore
            self.words = words
        }
    }

    let id: String
    let speaker: SpeakerID
    let speakerConfidence: Float
    let start: TimeInterval
    var lines: [Line]
    var isProvisional: Bool

    /// Group attributed segments (already time-sorted) into consecutive same-speaker turns.
    static func group(_ segments: [AttributedSegment]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for segment in segments {
            let line = Line(id: segment.id,
                            text: segment.asr.text,
                            start: segment.asr.start,
                            isProvisional: segment.isProvisional,
                            asrScore: Confidence.asrScore(segment.asr),
                            words: segment.asr.words)
            if var last = turns.last, last.speaker == segment.speaker {
                last.lines.append(line)
                last.isProvisional = last.isProvisional || segment.isProvisional
                turns[turns.count - 1] = last
            } else {
                turns.append(TranscriptTurn(id: segment.id,
                                            speaker: segment.speaker,
                                            speakerConfidence: segment.speakerConfidence,
                                            start: segment.asr.start,
                                            lines: [line],
                                            isProvisional: segment.isProvisional))
            }
        }
        return turns
    }

    /// Group stored segments (library history) into turns for the same rendering.
    static func group(stored: [StoredSegment]) -> [TranscriptTurn] {
        let sorted = stored.sorted { $0.start < $1.start }
        var turns: [TranscriptTurn] = []
        for segment in sorted {
            let asrScore = Confidence.asrScore(
                AsrSegment(track: .mixed, start: segment.start, end: segment.end, text: segment.text,
                           avgLogprob: segment.avgLogprob))
            let line = Line(id: segment.id.uuidString, text: segment.text, start: segment.start,
                            isProvisional: false, asrScore: asrScore, words: segment.words)
            if var last = turns.last, last.speaker == segment.speaker {
                last.lines.append(line)
                turns[turns.count - 1] = last
            } else {
                turns.append(TranscriptTurn(id: segment.id.uuidString, speaker: segment.speaker,
                                            speakerConfidence: segment.speakerConfidence,
                                            start: segment.start, lines: [line], isProvisional: false))
            }
        }
        return turns
    }
}
