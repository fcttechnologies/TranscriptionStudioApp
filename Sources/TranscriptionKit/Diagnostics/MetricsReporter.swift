import Foundation
import MetricKit
import OSLog
import Synchronization

/// The production-diagnostics layer (roadmap §10). Subscribes to MetricKit's redesigned
/// Swift-first `MetricManager` and mirrors each daily metric report and each diagnostic event
/// (crash / hang / hitch / slow launch / CPU / memory) to OSLog, tagged with the pipeline stage
/// it happened during via StateReporting.
///
/// This is additive and orthogonal to the in-app inspector stack (`PipelineRecorder` /
/// `InspectorStore`): that is the live, developer-facing view of *this* run; this is the
/// **system-level, field** signal Fernando sees aggregated across real installs.
///
/// `MetricManager` is an instantiable class (not the old shared singleton) — create one, enable
/// the pipeline state-reporting domain on it, and hold it for the app's lifetime. Its
/// `metricReports` / `diagnosticReports` are non-throwing `AsyncSequence`s iterated in long-lived
/// tasks. The system delivers reports on its own schedule (metrics daily; diagnostics when an
/// event occurs and the device is sampling), so in normal runs these loops sit idle.
public final class MetricsReporter: Sendable {
    private let manager: MetricManager
    private let started = Mutex(false)

    public init() {
        manager = MetricManager(
            enabledStateReportingDomains: [StateReportingDomain(rawValue: PipelineStateLabel.stateDomain)]
        )
    }

    /// Begin consuming metric and diagnostic reports. Idempotent — safe to call from a
    /// `.task` that may re-run.
    public func start() {
        let go = started.withLock { s -> Bool in
            guard !s else { return false }
            s = true
            return true
        }
        guard go else { return }

        let manager = self.manager
        Task.detached {
            for await report in manager.metricReports {
                Logger.metrics.info("\(Self.summary(for: report).logLine, privacy: .public)")
            }
        }
        Task.detached {
            for await report in manager.diagnosticReports {
                Logger.metrics.error("\(Self.summary(for: report).logLine, privacy: .public)")
            }
        }
    }

    // MARK: - Diagnostic adapter (unconstructible report → own value type)

    /// Reduce a system `DiagnosticReport` to the pure `DiagnosticSummary` the formatter logs.
    static func summary(for report: DiagnosticReport) -> DiagnosticSummary {
        let states = report.environment.states.map(reportedState(from:))
        switch report.result {
        case .crash(let d):
            var bits: [String] = []
            if let signal = d.signal { bits.append("signal \(signal)") }
            if let type = d.exceptionType { bits.append("exc \(type)") }
            if let category = d.terminationCategory, let name = categoryName(category) {
                bits.append(name)
            }
            return DiagnosticSummary(kind: .crash, detail: joined(bits), states: states)
        case .hang(let d):
            let secs = d.hangDuration.converted(to: .seconds).value
            return DiagnosticSummary(kind: .hang, detail: MetricsFormat.seconds(secs), states: states)
        case .appLaunch(let d):
            let secs = d.launchDuration.converted(to: .seconds).value
            return DiagnosticSummary(kind: .appLaunch, detail: MetricsFormat.seconds(secs), states: states)
        case .cpuException(let d):
            let cpu = d.totalCPUTime.converted(to: .seconds).value
            let sampled = d.totalSampledTime.converted(to: .seconds).value
            let detail = "\(MetricsFormat.seconds(cpu)) CPU / \(MetricsFormat.seconds(sampled)) sampled"
            return DiagnosticSummary(kind: .cpuException, detail: detail, states: states)
        case .diskWriteException:
            return DiagnosticSummary(kind: .diskWriteException, detail: nil, states: states)
        case .memoryException:
            return DiagnosticSummary(kind: .memoryException, detail: nil, states: states)
        @unknown default:
            return DiagnosticSummary(kind: .crash, detail: "unknown diagnostic", states: states)
        }
    }

    /// The termination categories worth naming in a crash log line; others aren't decoded.
    private static func categoryName(_ category: CrashDiagnostic.TerminationCategory) -> String? {
        switch category {
        case .watchdog: "watchdog"
        case .badAccess: "badAccess"
        case .abnormal: "abnormal"
        case .illegalInstruction: "illegalInstruction"
        default: nil
        }
    }

    private static func reportedState(from state: MetricManager.ReportedState) -> ReportedStateSummary {
        ReportedStateSummary(
            domain: state.domain,
            label: state.label,
            durationSeconds: state.duration.converted(to: .seconds).value
        )
    }

    // MARK: - Metric adapter (unconstructible report → own value type)

    /// Reduce a daily system `MetricReport` to the pure `MetricReportSummary` the formatter logs.
    /// Summarizes the field-relevant subset the roadmap names (launch, hangs, hitches, memory,
    /// terminations); other metric groups are noted by name rather than decoded, keeping this
    /// minimal and resilient to the beta payload shape.
    static func summary(for report: MetricReport) -> MetricReportSummary {
        let range = report.timeRange
        let rangeText = "\(range.start.formatted(date: .abbreviated, time: .omitted))"

        var values: [MetricValueSummary] = []
        for result in report.intervalEntries.fullDayEntry.values {
            values.append(contentsOf: intervalValues(from: result))
        }

        let breakdowns = report.stateEntries.map { stateEntry in
            StateMetricBreakdown(
                stateLabel: stateEntry.state.label,
                values: stateEntry.values.flatMap(stateValues(from:))
            )
        }.filter { !$0.values.isEmpty }

        return MetricReportSummary(timeRange: rangeText, values: values, stateBreakdowns: breakdowns)
    }

    /// Full-day interval metrics worth a line. Histogram metrics collapse to sample-count +
    /// approximate average; scalar metrics format directly.
    private static func intervalValues(from result: MetricResult) -> [MetricValueSummary] {
        switch result {
        case .timeToFirstDraw(let m):
            return histogramValue("launch", durations: m.histogram)
        case .peakMemory(let m):
            return [MetricValueSummary(name: "peakMem",
                                       value: MetricsFormat.bytes(m.value.converted(to: .bytes).value))]
        case .foregroundTermination(let m):
            return terminationValue("fgTerm", m.memoryLimitTerminationCount,
                                    m.badAccessTerminationCount, m.abnormalTerminationCount,
                                    m.watchdogTerminationCount)
        case .backgroundTermination(let m):
            return terminationValue("bgTerm", m.memoryLimitTerminationCount,
                                    m.badAccessTerminationCount, m.abnormalTerminationCount,
                                    m.watchdogTerminationCount)
        default:
            return stateValues(from: result)
        }
    }

    /// Responsiveness / runtime metrics that appear in both interval and per-state entries.
    /// Hang time is a duration histogram; hitch time is a dimensionless ratio.
    private static func stateValues(from result: MetricResult) -> [MetricValueSummary] {
        switch result {
        case .hangTime(let m): return histogramValue("hang", durations: m.histogram)
        case .hitchTime(let m): return ratioValue("hitch", m.ratio.value)
        default: return []
        }
    }

    private static func ratioValue(_ name: String, _ ratio: Double) -> [MetricValueSummary] {
        guard ratio > 0 else { return [] }
        return [MetricValueSummary(name: name, value: String(format: "%.4f", ratio))]
    }

    private static func histogramValue(_ name: String, durations: Histogram<UnitDuration>) -> [MetricValueSummary] {
        let summary = HistogramSummary(buckets: durations.buckets.map {
            HistogramBucket(lowerBound: $0.lowerBound.converted(to: .seconds).value,
                            upperBound: $0.upperBound.converted(to: .seconds).value,
                            count: $0.count)
        })
        guard summary.sampleCount > 0, let avg = summary.approximateAverage else { return [] }
        return [MetricValueSummary(name: name,
                                   value: "~\(MetricsFormat.seconds(avg))×\(summary.sampleCount)")]
    }

    private static func terminationValue(_ name: String, _ counts: Int...) -> [MetricValueSummary] {
        let total = counts.reduce(0, +)
        guard total > 0 else { return [] }
        return [MetricValueSummary(name: name, value: "\(total)")]
    }

    private static func joined(_ bits: [String]) -> String? {
        bits.isEmpty ? nil : bits.joined(separator: " ")
    }
}
