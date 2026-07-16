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
public struct HistogramBucket: Sendable, Equatable {
    public let lowerBound: Double
    public let upperBound: Double
    public let count: Int

    public init(lowerBound: Double, upperBound: Double, count: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.count = count
    }
}

/// A histogram collapsed to the two numbers worth logging from the field: how many samples it
/// held, and their bucket-midpoint-weighted average (an approximation — MetricKit gives buckets,
/// not raw values, so the true mean is unknowable, but the midpoint estimate is honest and
/// stable). `nil` average when there were no samples.
public struct HistogramSummary: Sendable, Equatable {
    public let sampleCount: Int
    public let approximateAverage: Double?

    public init(buckets: [HistogramBucket]) {
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
public enum DiagnosticKind: String, Sendable, CaseIterable {
    case crash, hang, cpuException, diskWriteException, appLaunch, memoryException

    /// Human-legible headline for a log line.
    public var display: String {
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
public struct ReportedStateSummary: Sendable, Equatable {
    public let domain: String
    public let label: String
    public let durationSeconds: Double?

    public init(domain: String, label: String, durationSeconds: Double?) {
        self.domain = domain
        self.label = label
        self.durationSeconds = durationSeconds
    }
}

/// A single diagnostic event summarized for OSLog: what it was, an event-specific detail, and
/// the app states active when it happened — the bridge that turns "hang" into "hang during
/// diarization."
public struct DiagnosticSummary: Sendable, Equatable {
    public let kind: DiagnosticKind
    /// Event-specific detail — a duration ("3.20s"), a crash signal, etc. `nil` when there's none.
    public let detail: String?
    public let states: [ReportedStateSummary]

    public init(kind: DiagnosticKind, detail: String?, states: [ReportedStateSummary]) {
        self.kind = kind
        self.detail = detail
        self.states = states
    }

    /// The pipeline stage the diagnostic is attributed to, if the pipeline domain was active.
    public var pipelineState: String? {
        states.first { $0.domain == PipelineStateLabel.stateDomain }?.label
    }

    /// The OSLog line — public metrics only, no content, no stacks.
    public var logLine: String {
        var parts = [kind.display]
        if let detail, !detail.isEmpty { parts.append(detail) }
        if let pipelineState { parts.append("during: \(pipelineState)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Metric report summaries

/// One named metric value, already formatted for logging.
public struct MetricValueSummary: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    public var text: String { "\(name)=\(value)" }
}

/// The subset of a daily metric report scoped to one recorded app state (MetricKit populates
/// state entries with responsiveness + runtime metrics only).
public struct StateMetricBreakdown: Sendable, Equatable {
    public let stateLabel: String
    public let values: [MetricValueSummary]

    public init(stateLabel: String, values: [MetricValueSummary]) {
        self.stateLabel = stateLabel
        self.values = values
    }
}

/// A daily `MetricReport` reduced to a compact OSLog digest: the full-day aggregate values plus
/// the per-app-state breakdown (which is where "hang time attributed to diarization" shows up).
public struct MetricReportSummary: Sendable, Equatable {
    public let timeRange: String
    public let values: [MetricValueSummary]
    public let stateBreakdowns: [StateMetricBreakdown]

    public init(timeRange: String, values: [MetricValueSummary], stateBreakdowns: [StateMetricBreakdown]) {
        self.timeRange = timeRange
        self.values = values
        self.stateBreakdowns = stateBreakdowns
    }

    /// The OSLog line for the whole report.
    public var logLine: String {
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
public enum MetricsFormat {
    /// A duration in seconds → a compact "N.NNs" (or "N ms" under a second).
    public static func seconds(_ value: Double) -> String {
        if value < 1 { return String(format: "%.0fms", value * 1000) }
        return String(format: "%.2fs", value)
    }

    /// A byte count → a human size via `ByteCountFormatStyle` (memory footprints).
    public static func bytes(_ value: Double) -> String {
        Int64(value.rounded()).formatted(.byteCount(style: .memory))
    }
}
