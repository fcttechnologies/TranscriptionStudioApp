import Foundation

/// The bridge between the app's own pipeline stages and MetricKit's **state reporting**.
///
/// MetricKit (SDK 27) can attribute a production hang, hitch, or crash to the *app state* it
/// happened during. We report each heavy pipeline stage as a state in one reverse-DNS domain,
/// so a field diagnostic reads "hang during diarization," not just "hang."
///
/// Pure and framework-free by design: the mapping and the domain string are the single source
/// of truth shared by `PipelineStateReporter` (which emits transitions) and `MetricsReporter`
/// (which enables the domain on its `MetricManager`). Keeping it free of any MetricKit /
/// StateReporting import makes the decision layer unit-testable on its own.
enum PipelineStateLabel {
    /// The one StateReporting domain the app segments metrics by. Reverse-DNS, stable across
    /// versions (changing it starts a fresh, uncorrelated data series in Apple's aggregation).
    static let stateDomain = "com.fcttechnologies.TranscriptionStudio.pipeline"

    /// Coarse, human-legible state label for a pipeline stage — the string a field hang/hitch/
    /// crash report is attributed to. Several fine-grained stages fold into one label
    /// (`mel`/`diarizePreview`/`diarizeCommit` → "diarization") because the field signal wants
    /// the *feature* that was running, not the internal sub-step.
    ///
    /// Returns `nil` for ambient stages that shouldn't drive the active state: `.system`
    /// (load samples, lifecycle) fires interleaved with real work, so reporting it would
    /// clobber the meaningful state a concurrent hang should be attributed to.
    static func label(for stage: PipelineStage) -> String? {
        switch stage {
        case .download, .extract, .ingest: "ingest"
        case .capture: "capture"
        case .mel, .diarizePreview, .diarizeCommit: "diarization"
        case .asr: "transcription"
        case .fusion: "fusion"
        case .persistence: "persistence"
        case .system: nil
        }
    }
}
