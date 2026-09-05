import FCTCore
import SwiftUI

/// The live pipeline-event feed: newest-first, level-colored, stage-filterable, each row
/// carrying its stage, message, duration, and any structured metadata. This is the raw
/// structured log the app is built to surface — the #1 requirement, made legible.
struct InspectorEventFeed: View {
    let store: InspectorStore
    @State private var stageFilter: PipelineStage?

    private var events: [PipelineEvent] {
        let all = store.events.reversed()
        guard let stageFilter else { return Array(all) }
        return all.filter { $0.stage == stageFilter }
    }

    var body: some View {
        InspectorCard(title: "Pipeline events", subtitle: "\(store.events.count)") {
            filterBar
            if events.isEmpty {
                Text("No events yet — run a recording or a transcription.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, DesignMetrics.spacingM)
            } else {
                let visible = Array(events.prefix(200))
                let lastID = visible.last?.id
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { event in
                        EventRow(event: event)
                        if event.id != lastID { Divider().opacity(0.4) }
                    }
                }
            }
        }
    }

    private var filterBar: some View {
        Menu {
            Button("All stages") { stageFilter = nil }
            Divider()
            ForEach(PipelineStage.allCases, id: \.self) { stage in
                Button(stage.rawValue.capitalized) { stageFilter = stage }
            }
        } label: {
            HStack(spacing: DesignMetrics.spacingXS) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(stageFilter?.rawValue.capitalized ?? "All stages")
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// One event row: a level dot, stage tag, message, optional duration, and metadata chips.
private struct EventRow: View {
    let event: PipelineEvent

    var body: some View {
        HStack(alignment: .top, spacing: DesignMetrics.spacingS) {
            Circle()
                .fill(DesignMetrics.color(for: event.level))
                .frame(width: DesignMetrics.eventDotSize, height: DesignMetrics.eventDotSize)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignMetrics.spacingXS) {
                    Text(event.stage.rawValue)
                        .font(.caption2.weight(.semibold).monospaced())
                        .foregroundStyle(DesignMetrics.color(for: event.level))
                    Spacer(minLength: 0)
                    if let duration = event.duration {
                        Text(Self.ms(duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(event.message).font(.caption)
                if !event.metadata.isEmpty {
                    Text(event.metadata.sorted(by: { $0.key < $1.key })
                        .map { "\($0.key): \($0.value)" }.joined(separator: "  "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, DesignMetrics.eventRowVPadding)
    }

    private static func ms(_ seconds: TimeInterval) -> String {
        seconds >= 1 ? "\(Format.fixed(seconds, decimals: 2))s" : "\(Format.fixed(seconds * 1000, decimals: 0))ms"
    }
}
