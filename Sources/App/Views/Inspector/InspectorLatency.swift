import Charts
import FCTCore
import SwiftUI

/// Per-stage latency: the latest duration for each stage plus a sparkline of its recent
/// history, so a stage that's drifting slower under concurrent load is visible at a glance.
struct InspectorLatency: View {
    let store: InspectorStore

    /// Recent timed durations per stage (oldest→newest), from the event ring.
    private var series: [(stage: PipelineStage, values: [Double])] {
        var byStage: [PipelineStage: [Double]] = [:]
        for event in store.events {
            if let duration = event.duration { byStage[event.stage, default: []].append(duration) }
        }
        return PipelineStage.allCases.compactMap { stage in
            guard let values = byStage[stage], !values.isEmpty else { return nil }
            return (stage, Array(values.suffix(40)))
        }
    }

    var body: some View {
        let series = series
        InspectorCard(title: "Stage latency") {
            if series.isEmpty {
                Text("No timed stages yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: DesignMetrics.spacingM) {
                    ForEach(series, id: \.stage) { entry in
                        LatencyRow(stage: entry.stage, values: entry.values)
                    }
                }
            }
        }
    }
}

private struct LatencyRow: View {
    let stage: PipelineStage
    let values: [Double]

    private var latest: Double { values.last ?? 0 }

    var body: some View {
        HStack(spacing: DesignMetrics.spacingM) {
            VStack(alignment: .leading, spacing: 1) {
                Text(stage.rawValue).font(.caption.weight(.medium))
                Text(format(latest)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(width: 96, alignment: .leading)

            Chart(Array(values.enumerated()), id: \.offset) { index, value in
                LineMark(x: .value("n", index), y: .value("ms", value * 1000))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.accentColor)
                AreaMark(x: .value("n", index), y: .value("ms", value * 1000))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.accentColor.opacity(0.12))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: DesignMetrics.sparklineHeight)
        }
    }

    private func format(_ seconds: Double) -> String {
        seconds >= 1 ? "\(Format.fixed(seconds, decimals: 2)) s" : "\(Format.fixed(seconds * 1000, decimals: 0)) ms"
    }
}
