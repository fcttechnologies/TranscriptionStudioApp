import SwiftUI

/// An LED-segment input meter driven by a smoothed level in [0,1]. Honest by construction —
/// each segment lights when the level clears its threshold, so a steady input reads as a
/// steady meter (the controller owns the fast-attack/slow-release ballistics). Green through
/// amber to red as the signal approaches clip.
public struct LevelMeter: View {
    let level: Float
    var barCount: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(level: Float, barCount: Int = DesignMetrics.levelMeterBarCount) {
        self.level = level
        self.barCount = barCount
    }

    private func isLit(_ index: Int) -> Bool {
        let threshold = Float(index + 1) / Float(barCount)
        return level >= threshold - (0.5 / Float(barCount))
    }

    private func color(_ index: Int) -> Color {
        let fraction = Double(index) / Double(max(barCount - 1, 1))
        return switch fraction {
        case ..<0.6: .green
        case ..<0.85: .yellow
        default: .red
        }
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: DesignMetrics.levelMeterBarSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                let lit = isLit(index)
                RoundedRectangle(cornerRadius: DesignMetrics.levelMeterCorner, style: .continuous)
                    .fill(lit ? color(index) : Color.secondary.opacity(0.18))
                    .frame(width: DesignMetrics.levelMeterBarWidth,
                           height: barHeight(index))
                    .animation(reduceMotion ? nil : DesignMetrics.liveFollowSpring, value: lit)
            }
        }
        .frame(height: DesignMetrics.levelMeterHeight)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let min = DesignMetrics.levelMeterHeight * 0.4
        let step = (DesignMetrics.levelMeterHeight - min) / CGFloat(max(barCount - 1, 1))
        return min + step * CGFloat(index)
    }
}
