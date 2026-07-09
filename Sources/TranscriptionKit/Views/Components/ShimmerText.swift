import SwiftUI

/// Text with a soft highlight sweeping across it — the "still being decided" state for a
/// provisional (unconfirmed ASR / preview-diarized) transcript turn, in place of a spinner.
/// Under Reduce Motion it renders as a calm dimmed label (no vestibular movement). Adapted
/// from the Personal Context chat "Thinking…" treatment.
public struct ShimmerText: View {
    let text: String
    var font: Font
    var color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ text: String, font: Font = .body, color: Color = .secondary) {
        self.text = text
        self.font = font
        self.color = color
    }

    public var body: some View {
        let label = Text(text).font(font)
        Group {
            if reduceMotion {
                label.foregroundStyle(color.opacity(DesignMetrics.provisionalOpacity))
            } else {
                label
                    .foregroundStyle(color.opacity(DesignMetrics.provisionalOpacity))
                    .overlay {
                        GeometryReader { proxy in
                            ShimmerBand(width: proxy.size.width, color: color)
                        }
                        .mask(alignment: .leading) { label }
                        .allowsHitTesting(false)
                    }
            }
        }
        .accessibilityLabel(Text(text))
    }
}

/// The travelling highlight band, driven by a looping phase animator (constant motion →
/// `.linear`, per motion-craft).
private struct ShimmerBand: View {
    let width: CGFloat
    let color: Color

    var body: some View {
        let bandWidth = max(width * 0.4, DesignMetrics.shimmerMinBandWidth)
        LinearGradient(
            colors: [.clear, color.opacity(DesignMetrics.shimmerHighlightOpacity), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: bandWidth)
        .phaseAnimator([false, true]) { band, travelling in
            band.offset(x: travelling ? width + bandWidth : -bandWidth)
        } animation: { _ in
            .linear(duration: DesignMetrics.shimmerDuration)
        }
    }
}
