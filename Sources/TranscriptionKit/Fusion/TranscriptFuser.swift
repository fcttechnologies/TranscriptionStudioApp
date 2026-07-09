import Foundation

/// Who a piece of transcript belongs to, at the product level.
public enum SpeakerID: Sendable, Codable, Hashable {
    /// The local user — attributed structurally (the microphone track in meeting mode),
    /// not by the diarizer.
    case me
    /// An anonymous diarized speaker slot (0–3).
    case speaker(Int)
    /// No diarization coverage for the segment's span.
    case unknown

    public var displayName: String {
        switch self {
        case .me: "Me"
        case .speaker(let index): "Speaker \(index + 1)"
        case .unknown: "Unknown"
        }
    }
}

/// An ASR segment with its speaker attribution — the unit the transcript UI renders
/// and SwiftData persists.
public struct AttributedSegment: Sendable, Identifiable {
    public var id: String { asr.id }

    public let asr: AsrSegment
    public let speaker: SpeakerID
    /// Attribution confidence: the overlap-weighted mean of the winning turns' confidences,
    /// scaled by how much of the segment diarization actually covered. 0 for `.unknown`.
    public let speakerConfidence: Float
    /// True while either the text (unconfirmed ASR) or the label (preview diarization)
    /// may still change.
    public let isProvisional: Bool

    public init(asr: AsrSegment, speaker: SpeakerID, speakerConfidence: Float, isProvisional: Bool) {
        self.asr = asr
        self.speaker = speaker
        self.speakerConfidence = speakerConfidence
        self.isProvisional = isProvisional
    }
}

/// Pure attribution logic: overlap ASR segments with diarized turns on the time axis.
/// Deterministic and heavily unit-tested — this is where "who said what" is decided.
public enum TranscriptFuser {

    /// Attribute each ASR segment to a speaker.
    ///
    /// - Microphone-track segments are `.me` when `micIsMe` (meeting mode); diarized
    ///   turns only ever apply to the track they were computed from.
    /// - Otherwise the segment goes to the speaker whose turns overlap the largest share
    ///   of the segment's span, provided that share clears `minimumCoverage` of the
    ///   segment's duration; else `.unknown`.
    public static func attribute(asr: [AsrSegment],
                                 turns: [SpeakerTurn],
                                 micIsMe: Bool = false,
                                 minimumCoverage: Float = 0.3) -> [AttributedSegment] {
        asr.map { segment in
            if micIsMe && segment.track == .microphone {
                return AttributedSegment(asr: segment,
                                         speaker: .me,
                                         speakerConfidence: 1,
                                         isProvisional: !segment.isConfirmed)
            }
            return attributeOne(segment, turns: turns, minimumCoverage: minimumCoverage)
        }
    }

    private static func attributeOne(_ segment: AsrSegment,
                                     turns: [SpeakerTurn],
                                     minimumCoverage: Float) -> AttributedSegment {
        let duration = max(segment.end - segment.start, 0.001)
        // Overlap per speaker, and confidence-weighted overlap for the winner's score.
        var overlap: [Int: TimeInterval] = [:]
        var weightedConfidence: [Int: Double] = [:]
        var sawProvisionalTurn = false

        for turn in turns {
            let start = max(segment.start, turn.start)
            let end = min(segment.end, turn.end)
            guard end > start else { continue }
            let amount = end - start
            overlap[turn.speakerIndex, default: 0] += amount
            weightedConfidence[turn.speakerIndex, default: 0] += amount * Double(turn.confidence)
            if !turn.isCommitted { sawProvisionalTurn = true }
        }

        guard let (winner, winnerOverlap) = overlap.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }) else {
            return AttributedSegment(asr: segment, speaker: .unknown,
                                     speakerConfidence: 0,
                                     isProvisional: !segment.isConfirmed)
        }

        let coverage = Float(winnerOverlap / duration)
        guard coverage >= minimumCoverage else {
            return AttributedSegment(asr: segment, speaker: .unknown,
                                     speakerConfidence: 0,
                                     isProvisional: !segment.isConfirmed)
        }

        let meanTurnConfidence = Float(weightedConfidence[winner, default: 0] / winnerOverlap)
        return AttributedSegment(asr: segment,
                                 speaker: .speaker(winner),
                                 speakerConfidence: meanTurnConfidence * min(coverage, 1),
                                 isProvisional: !segment.isConfirmed || sawProvisionalTurn)
    }
}
