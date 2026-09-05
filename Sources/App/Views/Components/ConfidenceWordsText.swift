import SwiftUI

/// The verbatim/confidence display's per-word treatment: the transcript reads normally, and
/// only the words the model was unsure about carry a subtle dotted underline in `accent` — so a
/// verifier (a paralegal, a journalist checking a quote) sees exactly which words to double-check
/// against the audio instead of proofreading the whole line. An accuracy aid, not a heatmap:
/// confident words show nothing.
///
/// Built from `Confidence.spans`, which degrades to a single whole-line span (flagged by the
/// segment score) when per-word probabilities weren't captured — so this renders cleanly with or
/// without word timestamps. the engines' own reduction, so it stays app-side (the generic score→underline
/// affordance is `FCTComponentsUI.ConfidenceText`).
///
/// Reusable-bit flag: the span→AttributedString-with-dotted-underline construction is engine-
/// agnostic and could generalize to `FCTComponentsUI` alongside `ConfidenceText` if another
/// surface ever needs per-token flagging; kept here for now (no FCTFoundation writes this pass).
struct ConfidenceWordsText: View {
    let spans: [ConfidenceSpan]
    let accent: Color
    var font: Font = .body

    var body: some View {
        Text(attributed)
            .font(font)
            .foregroundStyle(.primary)
            .accessibilityLabel(Text(spans.map(\.text).joined()))
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for span in spans {
            var run = AttributedString(span.text)
            if span.isLowConfidence {
                run.underlineStyle = Text.LineStyle(pattern: .dot, color: accent)
            }
            result.append(run)
        }
        return result
    }
}
