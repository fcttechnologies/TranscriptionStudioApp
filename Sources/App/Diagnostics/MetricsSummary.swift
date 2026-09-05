import FCTCore
import Foundation

// The pure decision + formatting layer for MetricKit production diagnostics.
//
// MetricKit's own report types (`MetricReport`, `DiagnosticReport`, the `MetricResult` /
// `DiagnosticResult` payloads) can't be constructed in a test — they only arrive from the
// system. So the layer that *decides what to log and how* is written over these plain value
// types instead, which are trivially constructible, and `MetricsReporter` owns a thin adapter
// that fills them in from the real (unconstructible) reports. That keeps every formatting and
// summarization rule unit-testable.
//
// Privacy: these carry only metrics, durations, counts, and app-state labels — never transcript
// content. Call-stack trees from diagnostics are deliberately not captured here.

// MARK: - Histogram summarization

/// One bucket of a MetricKit duration/size histogram, reduced to plain numbers (seconds, bytes,
/// etc. — the unit is fixed by the metric the adapter read it from).
struct HistogramBucket: Sendable, Equatable {
    let lowerBound: Double
    let upperBound: Double
    let count: Int

    init(lowerBound: Double, upperBound: Double, count: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.count = count
    }
}

/// A histogram collapsed to the two numbers worth logging from the field: how many samples it
/// held, and their bucket-midpoint-weighted average (an approximation — MetricKit gives buckets,
/// not raw values, so the true mean is unknowable, but the midpoint estimate is honest and
/// stable). `nil` average when there were no samples.
struct HistogramSummary: Sendable, Equatable {
    let sampleCount: Int
    let approximateAverage: Double?

    init(buckets: [HistogramBucket]) {
        let total = buckets.reduce(0) { $0 + $1.count }
        sampleCount = total
        guard total > 0 else { approximateAverage = nil; return }
        let weighted = buckets.reduce(0.0) { acc, b in
            acc + ((b.lowerBound + b.upperBound) / 2) * Double(b.count)
        }
        approximateAverage = weighted / Double(total)
    }
}

// MARK: - Diagnostic summaries

/// The kind of a single MetricKit diagnostic event (the `DiagnosticResult` cases we handle).
enum DiagnosticKind: String, Sendable, CaseIterable {
    case crash, hang, cpuException, diskWriteException, appLaunch, memoryException

    /// Human-legible headline for a log line.
    var display: String {
        switch self {
        case .crash: "crash"
        case .hang: "hang"
        case .cpuException: "cpu exception"
        case .diskWriteException: "disk-write exception"
        case .appLaunch: "slow launch"
        case .memoryException: "memory termination"
        }
    }
}

/// One app state that was active when a diagnostic fired (a MetricKit `ReportedState`), reduced
/// to what a log line needs.
struct ReportedStateSummary: Sendable, Equatable {
    let domain: String
    let label: String
    let durationSeconds: Double?

    init(domain: String, label: String, durationSeconds: Double?) {
        self.domain = domain
        self.label = label
        self.durationSeconds = durationSeconds
    }
}

/// A single diagnostic event summarized for OSLog: what it was, an event-specific detail, and
/// the app states active when it happened — the bridge that turns "hang" into "hang during
/// diarization."
struct DiagnosticSummary: Sendable, Equatable {
    let kind: DiagnosticKind
    /// Event-specific detail — a duration ("3.20s"), a crash signal, etc. `nil` when there's none.
    let detail: String?
    let states: [ReportedStateSummary]

    init(kind: DiagnosticKind, detail: String?, states: [ReportedStateSummary]) {
        self.kind = kind
        self.detail = detail
        self.states = states
    }

    /// The pipeline stage the diagnostic is attributed to, if the pipeline domain was active.
    var pipelineState: String? {
        states.first { $0.domain == PipelineStateLabel.stateDomain }?.label
    }

    /// The OSLog line — public metrics only, no content, no stacks.
    var logLine: String {
        var parts = [kind.display]
        if let detail, !detail.isEmpty { parts.append(detail) }
        if let pipelineState { parts.append("during: \(pipelineState)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Metric report summaries

/// One named metric value, already formatted for logging.
struct MetricValueSummary: Sendable, Equatable {
    let name: String
    let value: String

    init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    var text: String { "\(name)=\(value)" }
}

/// The subset of a daily metric report scoped to one recorded app state (MetricKit populates
/// state entries with responsiveness + runtime metrics only).
struct StateMetricBreakdown: Sendable, Equatable {
    let stateLabel: String
    let values: [MetricValueSummary]

    init(stateLabel: String, values: [MetricValueSummary]) {
        self.stateLabel = stateLabel
        self.values = values
    }
}

/// A daily `MetricReport` reduced to a compact OSLog digest: the full-day aggregate values plus
/// the per-app-state breakdown (which is where "hang time attributed to diarization" shows up).
struct MetricReportSummary: Sendable, Equatable {
    let timeRange: String
    let values: [MetricValueSummary]
    let stateBreakdowns: [StateMetricBreakdown]

    init(timeRange: String, values: [MetricValueSummary], stateBreakdowns: [StateMetricBreakdown]) {
        self.timeRange = timeRange
        self.values = values
        self.stateBreakdowns = stateBreakdowns
    }

    /// The OSLog line for the whole report.
    var logLine: String {
        var parts = ["metrics [\(timeRange)]"]
        if !values.isEmpty {
            parts.append(values.map(\.text).joined(separator: " · "))
        }
        for breakdown in stateBreakdowns where !breakdown.values.isEmpty {
            let inner = breakdown.values.map(\.text).joined(separator: ", ")
            parts.append("[\(breakdown.stateLabel)] \(inner)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Shared formatting

/// Formatting helpers shared by the adapters — kept here so the number→string rules are pure
/// and testable (and identical between diagnostics and metrics).
enum MetricsFormat {
    /// A duration in seconds → a compact "N.NNs" (or "N ms" under a second).
    static func seconds(_ value: Double) -> String {
        if value < 1 { return "\(Format.fixed(value * 1000, decimals: 0))ms" }
        return "\(Format.fixed(value, decimals: 2))s"
    }

    /// A byte count → a human size via `ByteCountFormatStyle` (memory footprints).
    static func bytes(_ value: Double) -> String {
        Int64(value.rounded()).formatted(.byteCount(style: .memory))
    }
}
