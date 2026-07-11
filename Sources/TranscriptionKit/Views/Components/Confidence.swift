import Foundation

/// ASR confidence scoring for transcript text. The diarizer is presumed guilty until
/// verified, so every rendered segment can quietly signal how sure the model was — subtle
/// enough to stay out of the way, precise enough to guide the ear-vs-label check. The
/// generic score→dotted-underline affordance itself is `FCTComponentsUI.ConfidenceText`
/// (see `TranscriptTurnView`); this reduction is Whisper-specific and stays app-side.
public enum Confidence {
    /// Collapse Whisper's native signals into a single [0,1] legibility score:
    /// `exp(avgLogprob)` (token likelihood) discounted by the no-speech probability.
    public static func asrScore(_ segment: AsrSegment) -> Float {
        let likelihood = min(max(exp(segment.avgLogprob), 0), 1)
        return likelihood * (1 - min(max(segment.noSpeechProb, 0), 1))
    }
}
