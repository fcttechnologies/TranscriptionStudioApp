import SwiftUI

/// The diarizer's raw output: a 4-speaker activity heatmap, one column per pixel (sampled
/// from the frame matrix, so minutes of audio stay a constant-cost draw). Cell opacity is the
/// model's sigmoid activity; the committed/provisional boundary is drawn as a vertical seam.
/// This is the "what the model actually said" view — never a summary.
struct InspectorHeatmap: View {
    let store: InspectorStore
    let sessionID: UUID

    private var matrix: SpeakerFrameMatrix? { store.latestSpeakerFrames[sessionID] }

    var body: some View {
        InspectorCard(title: "Speaker activity",
                      subtitle: matrix.map { "\($0.activities.count) frames" }) {
            if let matrix, !matrix.activities.isEmpty {
                HStack(alignment: .top, spacing: DesignMetrics.spacingS) {
                    labels
                    Canvas { context, size in draw(matrix, context: context, size: size) }
                        .frame(height: DesignMetrics.heatmapRowHeight * CGFloat(DesignMetrics.heatmapSpeakerCount))
                        .background(.quaternary.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.cornerS))
                        .accessibilityLabel("Speaker activity heatmap, \(matrix.activities.count) frames")
                }
                legend(committed: matrix.committedFrameCount, total: matrix.activities.count)
            } else {
                Text("No diarizer frames yet — record or transcribe to populate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var labels: some View {
        VStack(spacing: 0) {
            ForEach(0..<DesignMetrics.heatmapSpeakerCount, id: \.self) { slot in
                HStack(spacing: 3) {
                    Circle().fill(DesignMetrics.speakerColor(slot: slot)).frame(width: 6, height: 6)
                    Text("\(slot + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(height: DesignMetrics.heatmapRowHeight)
            }
        }
    }

    private func draw(_ matrix: SpeakerFrameMatrix, context: GraphicsContext, size: CGSize) {
        let count = matrix.activities.count
        guard count > 0 else { return }
        let rowHeight = size.height / CGFloat(DesignMetrics.heatmapSpeakerCount)
        let columns = max(Int(size.width), 1)
        // Sample one column per pixel — constant cost regardless of clip length.
        for px in 0..<columns {
            let frame = min(Int(Double(px) / Double(columns) * Double(count)), count - 1)
            let activities = matrix.activities[frame]
            for slot in 0..<DesignMetrics.heatmapSpeakerCount {
                let activity = slot < activities.count ? activities[slot] : 0
                guard activity > 0.06 else { continue }
                let rect = CGRect(x: CGFloat(px), y: CGFloat(slot) * rowHeight,
                                  width: 1, height: rowHeight)
                context.fill(Path(rect),
                             with: .color(DesignMetrics.speakerColor(slot: slot).opacity(Double(activity))))
            }
        }
        // Committed / provisional seam.
        if matrix.committedFrameCount < count {
            let x = size.width * CGFloat(matrix.committedFrameCount) / CGFloat(count)
            var seam = Path()
            seam.move(to: CGPoint(x: x, y: 0))
            seam.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(seam, with: .color(.primary.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
    }

    private func legend(committed: Int, total: Int) -> some View {
        HStack(spacing: DesignMetrics.spacingM) {
            Text("Committed \(committed) · provisional \(max(total - committed, 0))")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
