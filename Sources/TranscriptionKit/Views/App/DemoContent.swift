import Foundation
import SwiftData

/// A second diarizer for the inspector's A/B comparison — a UI-demo stand-in for the real
/// SpeakerKit cross-check backend. It segments on a slightly different rhythm than the
/// primary mock so the two timelines visibly differ (the whole point of an A/B). Replaced by
/// the real cross-check engine behind the same protocol.
public final class PreviewAltDiarizer: DiarizationEngine, Sendable {
    public let backendName = "SpeakerKit (demo)"

    public init() {}

    public func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        onProgress(EnginePreparationProgress(phase: "Ready", fraction: 1))
    }

    public func diarize(samples: [Float]) async throws -> DiarizationResult {
        let duration = Double(samples.count) / AudioChunk.sampleRate
        let turns = Self.turns(duration: duration)
        return DiarizationResult(turns: turns, frames: Self.frames(turns: turns, duration: duration))
    }

    public func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<DiarizationUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var horizon: TimeInterval = 0
                do {
                    for try await chunk in chunks { horizon = max(horizon, chunk.endTime) }
                    let turns = Self.turns(duration: horizon)
                    continuation.yield(DiarizationUpdate(turns: turns,
                                                         frames: Self.frames(turns: turns, duration: horizon)))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Alternates on a 3.3s rhythm and slips in a third speaker — a plausibly different read.
    private static func turns(duration: TimeInterval) -> [SpeakerTurn] {
        guard duration > 0 else { return [] }
        var out: [SpeakerTurn] = []
        var cursor: TimeInterval = 0
        var index = 0
        while cursor < duration {
            let end = min(cursor + 3.3, duration)
            let speaker = index % 5 == 4 ? 2 : index % 2
            out.append(SpeakerTurn(speakerIndex: speaker, start: cursor, end: end,
                                   confidence: 0.82, isCommitted: true))
            cursor = end
            index += 1
        }
        return out
    }

    private static func frames(turns: [SpeakerTurn], duration: TimeInterval) -> SpeakerFrameMatrix {
        let count = Int(duration / 0.08)
        var activities = [[Float]](repeating: [0.05, 0.05, 0.05, 0.05], count: count)
        for turn in turns {
            let startFrame = max(Int(turn.start / 0.08), 0)
            let endFrame = min(Int(turn.end / 0.08), count)
            guard startFrame < endFrame, (0...3).contains(turn.speakerIndex) else { continue }
            for frame in startFrame..<endFrame { activities[frame][turn.speakerIndex] = 0.88 }
        }
        return SpeakerFrameMatrix(activities: activities, committedFrameCount: count)
    }
}

/// Seeds a demoable sample session so Library, session detail, and playback are never empty
/// on first launch — a short two-speaker conversation with archived (synthesized) audio, so
/// tap-to-play seeks to real, audible per-speaker tones.
public enum DemoContent {
    @MainActor
    public static func seedSampleSession(into context: ModelContext) {
        let lines: [(text: String, slot: Int, avgLogprob: Float, noSpeech: Float)] = [
            ("Good morning — thanks for hopping on the call today.", 0, -0.18, 0.01),
            ("Happy to. I read through the proposal last night and had a few thoughts.", 1, -0.24, 0.02),
            ("Great. Let's start with the timeline — we're aiming to ship the first milestone in March.", 0, -0.31, 0.03),
            ("March feels tight given the integration work. I'd add two weeks of buffer.", 1, -0.52, 0.06),
            ("That's fair. Let's lock April fifteenth and communicate it this week.", 0, -0.22, 0.02),
            ("Agreed. I'll draft the update and send it around tomorrow morning.", 1, -0.19, 0.01),
        ]
        let turnLength: TimeInterval = 4
        let session = TranscriptSession(title: "Sample meeting · product sync", kind: .meetingRecording)
        session.status = .complete
        session.duration = Double(lines.count) * turnLength
        session.fullText = lines.map(\.text).joined(separator: " ")

        var turns: [SpeakerTurn] = []
        for (index, line) in lines.enumerated() {
            let start = Double(index) * turnLength
            let end = start + turnLength
            turns.append(SpeakerTurn(speakerIndex: line.slot, start: start, end: end, confidence: 0.9))
            let stored = StoredSegment(start: start, end: end, text: line.text)
            stored.speaker = index == 0 ? .me : .speaker(line.slot)
            stored.speakerConfidence = 0.9
            stored.avgLogprob = line.avgLogprob
            stored.noSpeechProb = line.noSpeech
            stored.compressionRatio = 1.4
            stored.session = session
            session.segments?.append(stored)
        }

        let fileName = "\(session.id.uuidString).wav"
        let samples = AudioFileIO.synthesize(turns: turns.map { ($0.start, $0.end, $0.speakerIndex) },
                                             totalDuration: session.duration)
        if let saved = try? AudioFileIO.writeWAV(samples: samples, fileName: fileName) {
            session.audioFileName = saved
        }
        context.insert(session)
        try? context.save()
    }
}
