import Foundation
import SwiftUI

/// Confidence scoring + affordances for transcript text. The diarizer is presumed guilty
/// until verified, so every rendered segment can quietly signal how sure the model was —
/// subtle enough to stay out of the way, precise enough to guide the ear-vs-label check.
public enum Confidence {
    /// Collapse Whisper's native signals into a single [0,1] legibility score:
    /// `exp(avgLogprob)` (token likelihood) discounted by the no-speech probability.
    public static func asrScore(_ segment: AsrSegment) -> Float {
        let likelihood = min(max(exp(segment.avgLogprob), 0), 1)
        return likelihood * (1 - min(max(segment.noSpeechProb, 0), 1))
    }

    /// Underline opacity for a confidence score: low confidence → a visible dotted
    /// underline; high confidence → none. Linear across the token band.
    public static func underlineOpacity(_ score: Float) -> Double {
        let clamped = Double(min(max(score, 0), 1))
        return DesignMetrics.confidenceUnderlineOpacityLow * (1 - clamped)
    }
}

/// A committed transcript line that carries a subtle confidence affordance: a dotted
/// underline in the speaker's color whose weight rises as confidence falls. Exact numbers
/// live in the caller's context/hover detail, not on the glyphs.
public struct ConfidenceLine: View {
    let text: String
    let score: Float
    let accent: Color
    var font: Font

    public init(_ text: String, score: Float, accent: Color, font: Font = .body) {
        self.text = text
        self.score = score
        self.accent = accent
        self.font = font
    }

    public var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.primary)
            .overlay(alignment: .bottom) {
                let opacity = Confidence.underlineOpacity(score)
                if opacity > 0.02 {
                    DottedUnderline()
                        .stroke(accent.opacity(opacity),
                                style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .frame(height: 1)
                        .offset(y: 2)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(Text(text))
    }
}

/// A single horizontal line, used as a dashed underline path.
private struct DottedUnderline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return path
    }
}
