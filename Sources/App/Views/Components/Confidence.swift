import Foundation

/// One run of transcript text carrying a single confidence verdict — the unit the
/// verbatim/confidence display renders. When per-word probabilities were captured, each word
/// is its own span; otherwise a whole segment is one span. `isLowConfidence` is what the view
/// flags (a dotted underline under exactly the uncertain words).
struct ConfidenceSpan: Equatable, Sendable {
    let text: String
    let isLowConfidence: Bool

    init(text: String, isLowConfidence: Bool) {
        self.text = text
        self.isLowConfidence = isLowConfidence
    }
}

/// ASR confidence scoring for transcript text. The diarizer is presumed guilty until
/// verified, so every rendered segment can quietly signal how sure the model was — subtle
/// enough to stay out of the way, precise enough to guide the ear-vs-label check. The
/// generic score→dotted-underline affordance itself is `FCTComponentsUI.ConfidenceText`
/// (see `TranscriptTurnView`); this reduction is Whisper-specific and stays app-side.
enum Confidence {
    /// Collapse Whisper's native signals into a single [0,1] legibility score:
    /// `exp(avgLogprob)` (token likelihood) discounted by the no-speech probability.
    static func asrScore(_ segment: AsrSegment) -> Float {
        let likelihood = min(max(exp(segment.avgLogprob), 0), 1)
        return likelihood * (1 - min(max(segment.noSpeechProb, 0), 1))
    }

    /// Normalize a single word's model probability to a [0,1] confidence. WhisperKit already
    /// emits `AsrWord.probability` as a token probability, so this is a defensive clamp — the
    /// seam a future engine with a differently-scaled signal would normalize through.
    static func wordScore(_ probability: Float) -> Float {
        min(max(probability, 0), 1)
    }

    /// Break a segment into confidence-flagged spans for the verbatim/confidence display.
    ///
    /// When per-word probabilities were captured (word timestamps on), each word becomes its own
    /// span flagged by `wordScore`, so a verifier sees exactly which words to double-check.
    /// When they're absent — the common case, since word timestamps are off by default — it
    /// **degrades cleanly** to a single span covering the whole text, flagged by the segment's
    /// legibility `segmentScore`. A span is low-confidence when its score is below `threshold`.
    static func spans(text: String,
                             words: [AsrWord]?,
                             segmentScore: Float,
                             threshold: Float) -> [ConfidenceSpan] {
        if let words, !words.isEmpty {
            return words.map { ConfidenceSpan(text: $0.word, isLowConfidence: wordScore($0.probability) < threshold) }
        }
        return [ConfidenceSpan(text: text, isLowConfidence: segmentScore < threshold)]
    }
}
