import FCTCore
import SwiftUI

/// The ASR confidence table: each segment's log mean token probability shown raw, beside the
/// legibility score it collapses to. These are exactly the "exact values" the transcript's
/// subtle underline hints at.
struct InspectorAsrTable: View {
    let segments: [AttributedSegment]

    var body: some View {
        InspectorCard(title: "ASR confidence", subtitle: "\(segments.count) seg") {
            if segments.isEmpty {
                Text("No transcript segments yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    ForEach(segments) { segment in
                        AsrRow(segment: segment)
                        Divider().opacity(0.35)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: DesignMetrics.spacingS) {
            Text("time").frame(width: 40, alignment: .leading)
            Text("logp").frame(width: 44, alignment: .trailing)
            Text("score").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold).monospaced())
        .foregroundStyle(.secondary)
        .padding(.vertical, DesignMetrics.spacingXS)
    }
}

private struct AsrRow: View {
    let segment: AttributedSegment

    private var score: Float { Confidence.asrScore(segment.asr) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DesignMetrics.spacingS) {
                Text(TimeFormat.clock(segment.asr.start))
                    .frame(width: 40, alignment: .leading)
                Text(Format.fixed(Double(segment.asr.avgLogprob), decimals: 2))
                    .frame(width: 44, alignment: .trailing)
                Text("\(Int((score * 100).rounded()))%")
                    .foregroundStyle(score < DesignMetrics.lowConfidenceThreshold ? .orange : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption2.monospacedDigit())
            Text(segment.asr.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, DesignMetrics.eventRowVPadding)
    }
}
