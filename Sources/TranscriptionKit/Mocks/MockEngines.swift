import Foundation

/// Deterministic fake engines so the UI lane builds real surfaces against real contract
/// shapes before the model lanes land — and so tests exercise flows without models.

public final class MockAsrEngine: AsrEngine, Sendable {
    public init() {}

    public func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        for step in 1...4 {
            try await Task.sleep(for: .milliseconds(150))
            onProgress(EnginePreparationProgress(phase: "Loading mock model", fraction: Double(step) / 4))
        }
    }

    public func transcribe(samples: [Float],
                           track: AudioTrack,
                           wordTimestamps: Bool) async throws -> [AsrSegment] {
        let duration = Double(samples.count) / AudioChunk.sampleRate
        let sentences = [
            "This is a mock transcription segment.",
            "The quick brown fox jumps over the lazy dog.",
            "On-device speech recognition placeholder text.",
            "Speaker changes are simulated every few seconds."
        ]
        var out: [AsrSegment] = []
        var cursor: TimeInterval = 0
        var index = 0
        while cursor < duration {
            let end = min(cursor + 3.5, duration)
            out.append(AsrSegment(track: track, start: cursor, end: end,
                                  text: sentences[index % sentences.count],
                                  avgLogprob: -0.25, noSpeechProb: 0.02, compressionRatio: 1.4))
            cursor = end
            index += 1
        }
        return out
    }

    public func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<AsrUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var confirmed: [AsrSegment] = []
                var accumulatedSeconds: TimeInterval = 0
                var track: AudioTrack = .mixed
                do {
                    for try await chunk in chunks {
                        accumulatedSeconds = max(accumulatedSeconds, chunk.endTime)
                        track = chunk.track
                        let live = AsrSegment(track: track,
                                              start: max(accumulatedSeconds - 2, 0),
                                              end: accumulatedSeconds,
                                              text: "…listening (mock)…",
                                              isConfirmed: false)
                        if accumulatedSeconds - (confirmed.last?.end ?? 0) > 4 {
                            confirmed.append(AsrSegment(track: track,
                                                        start: confirmed.last?.end ?? 0,
                                                        end: accumulatedSeconds,
                                                        text: "Mock confirmed sentence \(confirmed.count + 1).",
                                                        avgLogprob: -0.3, noSpeechProb: 0.05,
                                                        compressionRatio: 1.5))
                        }
                        continuation.yield(AsrUpdate(confirmed: confirmed, unconfirmed: [live]))
                    }
                    continuation.yield(AsrUpdate(confirmed: confirmed, unconfirmed: []))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public final class MockDiarizationEngine: DiarizationEngine, Sendable {
    public let backendName = "Mock"

    public init() {}

    public func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        onProgress(EnginePreparationProgress(phase: "Mock diarizer ready", fraction: 1))
    }

    public func diarize(samples: [Float]) async throws -> DiarizationResult {
        let duration = Double(samples.count) / AudioChunk.sampleRate
        let turns = Self.alternatingTurns(duration: duration, committed: true)
        return DiarizationResult(turns: turns,
                                 frames: Self.frames(for: turns, duration: duration, committedAll: true))
    }

    public func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<DiarizationUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var horizon: TimeInterval = 0
                do {
                    for try await chunk in chunks {
                        horizon = max(horizon, chunk.endTime)
                        let committedHorizon = max(horizon - 5, 0)
                        var turns = Self.alternatingTurns(duration: committedHorizon, committed: true)
                        turns += Self.alternatingTurns(duration: horizon, committed: false)
                            .filter { $0.end > committedHorizon }
                        continuation.yield(DiarizationUpdate(
                            turns: turns,
                            frames: Self.frames(for: turns, duration: horizon, committedAll: false)))
                    }
                    let final = Self.alternatingTurns(duration: horizon, committed: true)
                    continuation.yield(DiarizationUpdate(
                        turns: final,
                        frames: Self.frames(for: final, duration: horizon, committedAll: true)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Speaker 0 and 1 alternate every 4 seconds.
    private static func alternatingTurns(duration: TimeInterval, committed: Bool) -> [SpeakerTurn] {
        guard duration > 0 else { return [] }
        var out: [SpeakerTurn] = []
        var cursor: TimeInterval = 0
        var speaker = 0
        while cursor < duration {
            let end = min(cursor + 4, duration)
            out.append(SpeakerTurn(speakerIndex: speaker, start: cursor, end: end,
                                   confidence: 0.9, isCommitted: committed))
            cursor = end
            speaker = 1 - speaker
        }
        return out
    }

    private static func frames(for turns: [SpeakerTurn],
                               duration: TimeInterval,
                               committedAll: Bool) -> SpeakerFrameMatrix {
        let frameCount = Int(duration / 0.08)
        var activities = [[Float]](repeating: [0.05, 0.05, 0.05, 0.05], count: frameCount)
        for turn in turns {
            let startFrame = max(Int(turn.start / 0.08), 0)
            let endFrame = min(Int(turn.end / 0.08), frameCount)
            guard startFrame < endFrame, (0...3).contains(turn.speakerIndex) else { continue }
            for frame in startFrame..<endFrame {
                activities[frame][turn.speakerIndex] = 0.92
            }
        }
        let committedCount = committedAll
            ? frameCount
            : (turns.filter(\.isCommitted).map { Int($0.end / 0.08) }.max() ?? 0)
        return SpeakerFrameMatrix(activities: activities,
                                  committedFrameCount: min(committedCount, frameCount))
    }
}

/// Synthesizes a sine-tone chunk stream in real time — drives the record UI with zero
/// hardware or permissions.
public final class MockCaptureSource: CaptureSource, @unchecked Sendable {
    public let chunks: AsyncThrowingStream<AudioChunk, Error>
    private let continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    private var task: Task<Void, Never>?
    private let track: AudioTrack

    public init(track: AudioTrack = .mixed) {
        self.track = track
        (chunks, continuation) = AsyncThrowingStream.makeStream()
    }

    public func start() async throws {
        let track = self.track
        let continuation = self.continuation
        task = Task {
            var elapsed: TimeInterval = 0
            let chunkSeconds = 0.5
            let sampleCount = Int(AudioChunk.sampleRate * chunkSeconds)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(chunkSeconds))
                let samples = (0..<sampleCount).map { index in
                    Float(sin(2 * .pi * 220 * (elapsed + Double(index) / AudioChunk.sampleRate))) * 0.1
                }
                continuation.yield(AudioChunk(track: track, samples: samples, startTime: elapsed))
                elapsed += chunkSeconds
            }
        }
    }

    public func stop() async {
        task?.cancel()
        continuation.finish()
    }
}
