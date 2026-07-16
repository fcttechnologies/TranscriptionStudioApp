import Foundation
import Synchronization
import StateReporting

/// The seam `PipelineRecorder` uses to emit MetricKit state transitions. A protocol so the
/// recorder holds it optionally (nil in tests/previews) and tests can substitute a spy.
public protocol PipelineStateReporting: Sendable {
    /// Enter the state a pipeline stage maps to. A no-op when the stage is ambient
    /// (`PipelineStateLabel.label(for:) == nil`) or unchanged from the current state.
    func report(stage: PipelineStage)
    /// Leave the active state entirely (pipeline idle).
    func clear()
}

/// Emits StateReporting transitions for the pipeline domain, deduplicating so a transition
/// fires only when the coarse state *label* actually changes.
///
/// Deduplication matters for two reasons: StateReporting rate-limits and drops data if called
/// in a tight loop (streaming ASR/diarization record many events per second, all mapping to the
/// same label), and a real transition should mark a stage *boundary*, not every log line.
///
/// `Sendable` because `PipelineRecorder` is `Sendable` and `record(_:)` is called from many
/// isolation domains; the current-label state is guarded by a `Mutex`.
public final class PipelineStateReporter: PipelineStateReporting {
    /// The underlying transition sink. Injected so the dedup logic is testable with a spy;
    /// the production path forwards to a `StateReporter` for the pipeline domain.
    private let transition: @Sendable (String?) -> Void
    private let currentLabel = Mutex<String?>(nil)

    /// Test/seam initializer — the transition closure receives each fired label (`nil` = clear).
    public init(transition: @escaping @Sendable (String?) -> Void) {
        self.transition = transition
    }

    /// Production initializer — wires the shared `StateReporter` for the pipeline domain.
    /// `StateReporter.reporter(for:)` returns the same instance per domain process-wide, so
    /// creating this independently of `MetricsReporter`'s `MetricManager` is correct; the two
    /// coordinate purely through `PipelineStateLabel.stateDomain`.
    public convenience init() {
        let reporter = StateReporter.reporter(for: PipelineStateLabel.stateDomain)
        self.init(transition: { reporter.reportTransition(to: $0) })
    }

    /// The app-wide instance the live `AppModel` hands to its `PipelineRecorder`.
    public static let shared = PipelineStateReporter()

    public func report(stage: PipelineStage) {
        guard let label = PipelineStateLabel.label(for: stage) else { return }
        let fire = currentLabel.withLock { current -> Bool in
            guard current != label else { return false }
            current = label
            return true
        }
        if fire { transition(label) }
    }

    public func clear() {
        let fire = currentLabel.withLock { current -> Bool in
            guard current != nil else { return false }
            current = nil
            return true
        }
        if fire { transition(nil) }
    }
}
