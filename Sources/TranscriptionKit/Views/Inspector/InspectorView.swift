import SwiftUI

/// The Inspector — a first-class surface, not a debug dump. It makes the pipeline legible:
/// a live event feed, per-stage latencies, the diarizer's raw speaker-activity heatmap, the
/// ASR confidence table, system-load charts, and a diarizer A/B compare. Mac renders it as a
/// trailing column; iOS as a sheet. Everything reads the diagnostics spine (`InspectorStore`)
/// plus the live controller — no model is trusted blindly, all of it is shown.
public struct InspectorView: View {
    @Environment(AppModel.self) private var app

    enum Tab: String, CaseIterable, Identifiable {
        case live, latency, speakers, asr, load, compare
        var id: String { rawValue }
        var title: String {
            switch self {
            case .live: "Live"
            case .latency: "Latency"
            case .speakers: "Speakers"
            case .asr: "ASR"
            case .load: "Load"
            case .compare: "A/B"
            }
        }
        var systemImage: String {
            switch self {
            case .live: "dot.radiowaves.left.and.right"
            case .latency: "timer"
            case .speakers: "person.2.wave.2"
            case .asr: "text.badge.checkmark"
            case .load: "cpu"
            case .compare: "rectangle.split.2x1"
            }
        }
    }

    @State private var tab: Tab = .live

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector view", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Image(systemName: tab.systemImage).tag(tab)
                        .accessibilityLabel(tab.title)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(DesignMetrics.spacingM)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DesignMetrics.spacingL) {
                    switch tab {
                    case .live: InspectorEventFeed(store: app.inspector)
                    case .latency: InspectorLatency(store: app.inspector)
                    case .speakers: InspectorHeatmap(store: app.inspector,
                                                     sessionID: app.recording.sessionID)
                    case .asr: InspectorAsrTable(segments: app.recording.segments)
                    case .load: InspectorLoad(store: app.inspector)
                    case .compare: InspectorDiarizerAB(recording: app.recording,
                                                       crossCheck: app.crossCheckDiarizer)
                    }
                }
                .padding(DesignMetrics.spacingL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.background)
        .accessibilityIdentifier("inspector.panel")
    }
}

/// A titled inspector card wrapper — a small header over a bordered well.
struct InspectorCard<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingS) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(title)
                Spacer(minLength: 0)
                if let subtitle {
                    Text(subtitle).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            content
        }
    }
}
