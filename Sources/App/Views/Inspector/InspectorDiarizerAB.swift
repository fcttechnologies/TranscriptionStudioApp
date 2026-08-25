import SwiftUI

/// Diarizer A/B: the primary backend's turn timeline stacked over the cross-check backend's,
/// on the same span, so disagreement is visible at a glance — the community Sortformer
/// conversion is presumed guilty until it agrees with an independent read. The cross-check runs
/// **on demand** (a button), preparing its engine first and diarizing the recording's *real*
/// archived audio, rather than auto-rerunning on every live update over synthesized silence.
struct InspectorDiarizerAB: View {
    let recording: RecordingController
    let crossCheck: any DiarizationEngine

    @State private var run = CrossCheckRun()

    private var primary: [SpeakerTurn] { recording.liveTurns }
    private var duration: TimeInterval { max(primary.map(\.end).max() ?? 0, run.altTurns.map(\.end).max() ?? 0) }

    var body: some View {
        InspectorCard(title: "Diarizer A/B") {
            if primary.isEmpty {
                Text("Record or run a session to compare backends.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: DesignMetrics.spacingM) {
                    timeline(name: "Sortformer (primary)", turns: primary)
                    if !run.altTurns.isEmpty {
                        timeline(name: run.altName.isEmpty ? crossCheck.backendName : run.altName,
                                 turns: run.altTurns)
                        agreement
                    }
                    runControl
                }
            }
        }
    }

    private func timeline(name: String, turns: [SpeakerTurn]) -> some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingXS) {
            Text(name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            TurnTimeline(turns: turns, duration: duration)
                .frame(height: DesignMetrics.abTimelineHeight)
                .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.cornerS))
        }
    }

    @ViewBuilder
    private var runControl: some View {
        if run.isRunning {
            HStack(spacing: DesignMetrics.spacingS) {
                ProgressView().controlSize(.small)
                Text(run.phase ?? "Running \(crossCheck.backendName)…")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Button {
                Task { await runCrossCheck() }
            } label: {
                Label(run.altTurns.isEmpty ? "Run cross-check" : "Re-run cross-check",
                      systemImage: "rectangle.split.2x1")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("inspector.ab.run")
        }
        if let error = run.error {
            Text(error).font(.caption2).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var agreement: some View {
        let score = Self.frameAgreement(primary, run.altTurns, duration: duration)
        HStack(spacing: DesignMetrics.spacingXS) {
            Image(systemName: score > 0.75 ? "checkmark.seal" : "exclamationmark.triangle")
                .foregroundStyle(score > 0.75 ? .green : .orange)
            Text("\(Int((score * 100).rounded()))% frame agreement")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Prepare the cross-check engine, then diarize the recording's archived samples once.
    @MainActor
    private func runCrossCheck() async {
        let samples = recording.archivedSamples
        guard !samples.isEmpty else {
            run.error = "No recorded audio to cross-check yet."
            return
        }
        run.isRunning = true
        run.error = nil
        run.phase = "Preparing \(crossCheck.backendName)…"
        defer { run.isRunning = false; run.phase = nil }
        do {
            try await crossCheck.prepare { progress in
                Task { @MainActor in run.phase = progress.phase }
            }
            run.phase = "Running \(crossCheck.backendName)…"
            let result = try await crossCheck.diarize(samples: samples)
            run.altTurns = result.turns
            run.altName = crossCheck.backendName
        } catch {
            run.error = error.localizedDescription
        }
    }

    /// Fraction of 80ms frames where both backends name the same dominant speaker.
    nonisolated static func frameAgreement(_ a: [SpeakerTurn], _ b: [SpeakerTurn], duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        let step = 0.08
        let frames = Int(duration / step)
        guard frames > 0 else { return 0 }
        func speaker(at t: TimeInterval, in turns: [SpeakerTurn]) -> Int? {
            turns.first { $0.start <= t && t < $0.end }?.speakerIndex
        }
        var agree = 0
        for frame in 0..<frames {
            let t = Double(frame) * step
            if speaker(at: t, in: a) == speaker(at: t, in: b) { agree += 1 }
        }
        return Double(agree) / Double(frames)
    }
}

/// The cross-check run's view-local state: whether it's running, its progress phase, any error,
/// and the resulting turns. An `@Observable` reference so the model-download progress callback can
/// hop to the main actor and update it without capturing `@State` in a `@Sendable` closure.
@MainActor
@Observable
private final class CrossCheckRun {
    var isRunning = false
    var phase: String?
    var error: String?
    var altTurns: [SpeakerTurn] = []
    var altName = ""
}

/// A single diarization timeline: colored blocks per turn along the time axis.
private struct TurnTimeline: View {
    let turns: [SpeakerTurn]
    let duration: TimeInterval

    var body: some View {
        Canvas { context, size in
            guard duration > 0 else { return }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.gray.opacity(0.18)))
            for turn in turns {
                let x = size.width * CGFloat(turn.start / duration)
                let width = max(size.width * CGFloat((turn.end - turn.start) / duration), 1)
                let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                let color = DesignMetrics.speakerColor(slot: turn.speakerIndex)
                context.fill(Path(rect), with: .color(color.opacity(turn.isCommitted ? 0.85 : 0.45)))
            }
        }
    }
}
