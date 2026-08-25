// MetricKit production-diagnostics layer (roadmap §10) — the pure decision + formatting pieces.
//
// The MetricKit report payloads (`MetricReport`, `DiagnosticReport`, `MetricResult`, …) only
// arrive from the system and can't be constructed, so `MetricsReporter`'s adapters that read
// them aren't unit-testable directly. Everything the adapters *produce* — the stage→state
// mapping, histogram summarization, and every log-line format — is written over constructible
// value types and covered here.

import Foundation
import Synchronization
import Testing
@testable import TranscriptionStudio

@Suite("PipelineStateLabel")
struct PipelineStateLabelTests {
    @Test func mapsHeavyStagesToCoarseLabels() {
        #expect(PipelineStateLabel.label(for: .download) == "ingest")
        #expect(PipelineStateLabel.label(for: .extract) == "ingest")
        #expect(PipelineStateLabel.label(for: .ingest) == "ingest")
        #expect(PipelineStateLabel.label(for: .capture) == "capture")
        #expect(PipelineStateLabel.label(for: .mel) == "diarization")
        #expect(PipelineStateLabel.label(for: .diarizePreview) == "diarization")
        #expect(PipelineStateLabel.label(for: .diarizeCommit) == "diarization")
        #expect(PipelineStateLabel.label(for: .asr) == "transcription")
        #expect(PipelineStateLabel.label(for: .fusion) == "fusion")
        #expect(PipelineStateLabel.label(for: .persistence) == "persistence")
    }

    @Test func ambientSystemStageHasNoLabel() {
        #expect(PipelineStateLabel.label(for: .system) == nil)
    }

    @Test func everyStageIsDecided() {
        // No stage traps or returns an unexpected value — full-enum coverage guard.
        for stage in PipelineStage.allCases {
            let label = PipelineStateLabel.label(for: stage)
            if stage == .system {
                #expect(label == nil)
            } else {
                #expect(label != nil)
            }
        }
    }
}

@Suite("PipelineStateReporter dedup")
struct PipelineStateReporterTests {
    /// A thread-safe sink capturing each fired transition (`nil` = clear).
    private final class Spy: Sendable {
        let fired = Mutex<[String?]>([])
        var transition: @Sendable (String?) -> Void {
            { label in self.fired.withLock { $0.append(label) } }
        }
        var values: [String?] { fired.withLock { $0 } }
    }

    @Test func firesOncePerLabelChangeAndCollapsesRepeats() {
        let spy = Spy()
        let reporter = PipelineStateReporter(transition: spy.transition)

        reporter.report(stage: .asr)          // transcription
        reporter.report(stage: .asr)          // same label — collapsed
        reporter.report(stage: .diarizeCommit) // diarization
        reporter.report(stage: .mel)          // still diarization — collapsed
        reporter.report(stage: .asr)          // back to transcription

        #expect(spy.values == ["transcription", "diarization", "transcription"])
    }

    @Test func ambientStageDoesNotClobberActiveState() {
        let spy = Spy()
        let reporter = PipelineStateReporter(transition: spy.transition)

        reporter.report(stage: .diarizeCommit)
        reporter.report(stage: .system)  // nil label — must not fire, must not clear
        reporter.report(stage: .mel)     // still diarization — collapsed

        #expect(spy.values == ["diarization"])
    }

    @Test func clearFiresOnceThenNoOpUntilNextState() {
        let spy = Spy()
        let reporter = PipelineStateReporter(transition: spy.transition)

        reporter.report(stage: .persistence)
        reporter.clear()
        reporter.clear()                 // already cleared — collapsed
        reporter.report(stage: .persistence) // re-enters — fires again

        #expect(spy.values == ["persistence", nil, "persistence"])
    }
}

@Suite("HistogramSummary")
struct HistogramSummaryTests {
    @Test func sumsSampleCountsAndWeightsMidpoints() {
        // Buckets [0,2]×3 (mid 1) and [2,4]×1 (mid 3): total 4, avg (1·3 + 3·1)/4 = 1.5
        let summary = HistogramSummary(buckets: [
            HistogramBucket(lowerBound: 0, upperBound: 2, count: 3),
            HistogramBucket(lowerBound: 2, upperBound: 4, count: 1)
        ])
        #expect(summary.sampleCount == 4)
        #expect(summary.approximateAverage == 1.5)
    }

    @Test func emptyHistogramHasNoAverage() {
        let summary = HistogramSummary(buckets: [])
        #expect(summary.sampleCount == 0)
        #expect(summary.approximateAverage == nil)
    }

    @Test func zeroCountBucketsCollapseToNoSamples() {
        let summary = HistogramSummary(buckets: [HistogramBucket(lowerBound: 0, upperBound: 1, count: 0)])
        #expect(summary.sampleCount == 0)
        #expect(summary.approximateAverage == nil)
    }
}

@Suite("DiagnosticSummary formatting")
struct DiagnosticSummaryTests {
    private func pipelineState(_ label: String) -> ReportedStateSummary {
        ReportedStateSummary(domain: PipelineStateLabel.stateDomain, label: label, durationSeconds: 2)
    }

    @Test func attributesHangToTheActivePipelineStage() {
        let summary = DiagnosticSummary(kind: .hang, detail: "3.20s",
                                        states: [pipelineState("diarization")])
        #expect(summary.pipelineState == "diarization")
        #expect(summary.logLine == "hang · 3.20s · during: diarization")
    }

    @Test func omitsDuringClauseWhenNoPipelineStateActive() {
        let summary = DiagnosticSummary(kind: .appLaunch, detail: "8.10s", states: [])
        #expect(summary.pipelineState == nil)
        #expect(summary.logLine == "slow launch · 8.10s")
    }

    @Test func ignoresStatesFromOtherDomains() {
        let other = ReportedStateSummary(domain: "com.other.domain", label: "whatever", durationSeconds: 1)
        let summary = DiagnosticSummary(kind: .crash, detail: "signal 11", states: [other])
        #expect(summary.pipelineState == nil)
        #expect(summary.logLine == "crash · signal 11")
    }

    @Test func headlineOnlyWhenNoDetailOrState() {
        let summary = DiagnosticSummary(kind: .memoryException, detail: nil, states: [])
        #expect(summary.logLine == "memory termination")
    }
}

@Suite("MetricReportSummary formatting")
struct MetricReportSummaryTests {
    @Test func rendersFullDayValuesAndStateBreakdowns() {
        let summary = MetricReportSummary(
            timeRange: "Jul 15, 2026",
            values: [MetricValueSummary(name: "launch", value: "~420ms×5"),
                     MetricValueSummary(name: "peakMem", value: "180 MB")],
            stateBreakdowns: [StateMetricBreakdown(stateLabel: "diarization",
                                                   values: [MetricValueSummary(name: "hang", value: "~1.20s×2")])]
        )
        #expect(summary.logLine ==
                "metrics [Jul 15, 2026] · launch=~420ms×5 · peakMem=180 MB · [diarization] hang=~1.20s×2")
    }

    @Test func dropsEmptyStateBreakdowns() {
        let summary = MetricReportSummary(
            timeRange: "Jul 15, 2026",
            values: [MetricValueSummary(name: "hang", value: "~1.00s×1")],
            stateBreakdowns: [StateMetricBreakdown(stateLabel: "asr", values: [])]
        )
        #expect(summary.logLine == "metrics [Jul 15, 2026] · hang=~1.00s×1")
    }

    @Test func rangeOnlyWhenNoMetricsPresent() {
        let summary = MetricReportSummary(timeRange: "Jul 15, 2026", values: [], stateBreakdowns: [])
        #expect(summary.logLine == "metrics [Jul 15, 2026]")
    }
}

@Suite("MetricsFormat")
struct MetricsFormatTests {
    @Test func subSecondDurationsRenderAsMilliseconds() {
        #expect(MetricsFormat.seconds(0.42) == "420ms")
        #expect(MetricsFormat.seconds(0) == "0ms")
    }

    @Test func secondScaleDurationsRenderWithTwoDecimals() {
        #expect(MetricsFormat.seconds(3.2) == "3.20s")
        #expect(MetricsFormat.seconds(12) == "12.00s")
    }

    @Test func metricValueTextJoinsNameAndValue() {
        #expect(MetricValueSummary(name: "hang", value: "1s").text == "hang=1s")
    }
}
