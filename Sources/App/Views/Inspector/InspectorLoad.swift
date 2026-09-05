import Charts
import FCTCore
import SwiftUI

/// System load while pipelines run — the answer to "does concurrent ASR + diarization
/// degrade on this device?" Thermal state (color-coded), whole-process CPU%, and memory
/// footprint, charted over time next to the latency view.
struct InspectorLoad: View {
    let store: InspectorStore

    private var samples: [SystemLoadSample] { store.loadSamples }
    private var latest: SystemLoadSample? { samples.last }

    var body: some View {
        InspectorCard(title: "System load", subtitle: "\(samples.count) samples") {
            if samples.isEmpty {
                Text("No load samples — sampling runs during a recording.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                thermalPill
                chart(title: "CPU", unit: "%", color: .blue) { Double($0.cpuPercent) }
                chart(title: "Memory", unit: "MB", color: .purple) {
                    Double($0.memoryFootprint) / 1_048_576
                }
            }
        }
    }

    @ViewBuilder
    private var thermalPill: some View {
        if let latest {
            HStack(spacing: DesignMetrics.spacingS) {
                Label {
                    Text("Thermal: \(DesignMetrics.thermalLabel(latest.thermalState))")
                        .font(.caption.weight(.medium))
                } icon: {
                    Circle().fill(DesignMetrics.color(for: latest.thermalState)).frame(width: 8, height: 8)
                }
                Spacer(minLength: 0)
                Text("CPU \(Format.fixed(latest.cpuPercent, decimals: 0))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func chart(title: String, unit: String, color: Color,
                       value: @escaping (SystemLoadSample) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) (\(unit))").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Chart(samples) { sample in
                LineMark(x: .value("t", sample.date), y: .value(title, value(sample)))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color)
                AreaMark(x: .value("t", sample.date), y: .value(title, value(sample)))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color.opacity(0.12))
            }
            .chartXAxis(.hidden)
            .frame(height: DesignMetrics.loadChartHeight)
        }
    }
}
