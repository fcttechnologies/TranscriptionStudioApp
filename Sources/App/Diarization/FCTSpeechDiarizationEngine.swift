import FCTSpeech
import Foundation

/// Transcription Studio's diarizer on FCT's own runtime: NVIDIA's Streaming Sortformer 4spk-v2.1,
/// converted by us, the encoder on the Neural Engine, NeMo's streaming update in Swift
/// (`~/Projects/FCTSpeech`). Four speakers is the model's cap. DER 3.79% on VoxConverse (≤4
/// speakers, collar 0.25 s) against the human labels, ahead of every vendor asset it replaces.
///
/// Models live under the app's support directory at `FCTSpeech/sortformer/` (`Sortformer.mlmodelc`).
actor FCTSpeechDiarizationEngine: DiarizationEngine {
    nonisolated let backendName = "FCTSpeech Sortformer"
    nonisolated var supportsStreaming: Bool { true }
    private let modelsDirectory: URL
    private let install: SpeechModelInstaller
    private var diarizer: SortformerDiarizer?
    private var preparationTask: Task<Void, Error>?

    init(root: URL = SpeechModel.root(), install: @escaping SpeechModelInstaller = SpeechModel.install) {
        self.modelsDirectory = SpeechModel.sortformer.directory(under: root)
        self.install = install
    }

    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        if diarizer != nil { onProgress(EnginePreparationProgress(phase: "Ready", fraction: 1)); return }
        if let preparationTask { try await preparationTask.value; return }
        let task = Task {
            try await install(.sortformer) { onProgress(EnginePreparationProgress(phase: "Downloading Sortformer", fraction: $0)) }
            onProgress(EnginePreparationProgress(phase: "Loading Sortformer", fraction: nil))
            diarizer = try SortformerDiarizer(directory: modelsDirectory)
            onProgress(EnginePreparationProgress(phase: "Ready", fraction: 1))
        }
        preparationTask = task
        defer { preparationTask = nil }
        try await task.value
    }

    func diarize(samples: [Float]) async throws -> DiarizationResult {
        guard let diarizer else { throw AsrEngineError.notPrepared }
        let frames = try diarizer.activity(samples: samples)
        let built = Self.build(frames: frames, committedFrameCount: frames.count)
        return DiarizationResult(turns: built.turns, frames: built.matrix)
    }

    nonisolated func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<DiarizationUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runLive(chunks: chunks) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runLive(chunks: AsyncThrowingStream<AudioChunk, Error>, emit: @Sendable (DiarizationUpdate) -> Void) async throws {
        guard let diarizer else { throw AsrEngineError.notPrepared }
        let live = try SortformerLive(diarizer: diarizer)
        for try await chunk in chunks {
            try Task.checkCancellation()
            if !(try live.feed(chunk.samples)).isEmpty {
                let built = Self.build(frames: live.frames, committedFrameCount: live.frames.count)
                emit(DiarizationUpdate(turns: built.turns, frames: built.matrix))
            }
        }
        _ = try live.finish()
        let built = Self.build(frames: live.frames, committedFrameCount: live.frames.count)
        emit(DiarizationUpdate(turns: built.turns, frames: built.matrix))
    }

    /// Per-frame activity → per-speaker turns (overlap allowed) with a mean-activity confidence.
    static func build(frames: [[Float]], committedFrameCount: Int) -> (turns: [SpeakerTurn], matrix: SpeakerFrameMatrix) {
        let frameSec = SortformerDiarizer.frameSeconds
        var turns: [SpeakerTurn] = []
        for seg in SortformerAOSC.speakerSegments(from: frames) {
            var sum: Float = 0
            for f in seg.start..<seg.end { sum += frames[f][seg.speaker] }
            let conf = seg.end > seg.start ? sum / Float(seg.end - seg.start) : 0
            turns.append(SpeakerTurn(speakerIndex: seg.speaker, start: Double(seg.start) * frameSec,
                                     end: Double(seg.end) * frameSec, confidence: conf,
                                     isCommitted: seg.end <= committedFrameCount))
        }
        let matrix = SpeakerFrameMatrix(activities: frames, committedFrameCount: min(committedFrameCount, frames.count), frameDuration: frameSec)
        return (turns, matrix)
    }
}
