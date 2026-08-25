import SwiftUI

/// A scrolling waveform trace of recent input energy — mirrored bars, newest at the trailing
/// edge. Driven by a ring of recent normalized levels the controller maintains; drawn in a
/// `Canvas` so a minute of history stays a single cheap draw, not hundreds of views.
struct LiveWaveform: View {
    let levels: [Float]
    var accent: Color
    var height: CGFloat

    init(levels: [Float], accent: Color = .accentColor,
                height: CGFloat = DesignMetrics.waveformHeight) {
        self.levels = levels
        self.accent = accent
        self.height = height
    }

    var body: some View {
        Canvas { context, size in
            let count = DesignMetrics.waveformSampleCount
            let slot = DesignMetrics.waveformBarWidth + DesignMetrics.waveformBarSpacing
            let midY = size.height / 2
            // Right-align the trace: the most recent sample sits at the trailing edge.
            let visible = Array(levels.suffix(count))
            for (offset, level) in visible.enumerated() {
                let indexFromEnd = visible.count - 1 - offset
                let x = size.width - CGFloat(indexFromEnd) * slot - DesignMetrics.waveformBarWidth
                guard x >= 0 else { continue }
                let magnitude = max(CGFloat(level), DesignMetrics.waveformMinBarFraction)
                let barHeight = magnitude * size.height
                let rect = CGRect(x: x, y: midY - barHeight / 2,
                                  width: DesignMetrics.waveformBarWidth, height: barHeight)
                let path = Path(roundedRect: rect, cornerRadius: DesignMetrics.waveformBarWidth / 2)
                // Older samples fade back so the trace reads as moving forward in time.
                let freshness = Double(offset + 1) / Double(max(visible.count, 1))
                context.fill(path, with: .color(accent.opacity(0.35 + 0.65 * freshness)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
