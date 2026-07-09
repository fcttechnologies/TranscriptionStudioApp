import SwiftUI

/// Diarizer A/B: the primary backend's turn timeline stacked over the cross-check backend's,
/// on the same span, so disagreement is visible at a glance — the community Sortformer
/// conversion is presumed guilty until it agrees with an independent read. Driven by the
/// mocks now; the real SpeakerKit cross-check drops in behind the same protocol.
struct InspectorDiarizerAB: View {
    let primary: [SpeakerTurn]
    let crossCheck: any DiarizationEngine

    @State private var altTurns: [SpeakerTurn] = []
    @State private var altName = ""

    private var duration: TimeInterval { primary.map(\.end).max() ?? 0 }

    var body: some View {
        InspectorCard(title: "Diarizer A/B") {
            if primary.isEmpty {
                Text("Record or run a session to compare backends.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: DesignMetrics.spacingM) {
                    timeline(name: "Sortformer (primary)", turns: primary)
                    timeline(name: altName.isEmpty ? crossCheck.backendName : altName, turns: altTurns)
                    agreement
                }
                .task(id: duration) { await runCrossCheck() }
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
    private var agreement: some View {
        if !altTurns.isEmpty {
            let score = Self.frameAgreement(primary, altTurns, duration: duration)
            HStack(spacing: DesignMetrics.spacingXS) {
                Image(systemName: score > 0.75 ? "checkmark.seal" : "exclamationmark.triangle")
                    .foregroundStyle(score > 0.75 ? .green : .orange)
                Text("\(Int((score * 100).rounded()))% frame agreement")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func runCrossCheck() async {
        guard duration > 0 else { return }
        let sampleCount = Int(duration * AudioChunk.sampleRate)
        let samples = [Float](repeating: 0, count: max(sampleCount, 1))
        if let result = try? await crossCheck.diarize(samples: samples) {
            altTurns = result.turns
            altName = crossCheck.backendName
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
