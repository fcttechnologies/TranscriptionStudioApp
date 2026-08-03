// The streaming half of the `TtsEngine` seam: ordered incremental chunks, cancellation, and
// the single-chunk default that lets a non-streaming engine serve a streaming consumer.
// The TTSKit engine's own streaming needs the real model and is covered by the serve
// end-to-end verification; what's provable here is the seam contract, via `MockTtsEngine`.

import Foundation
import Synchronization
import Testing
@testable import TranscriptionKit

/// A minimal conformer that implements only the required methods, so these tests pin the
/// protocol-extension default (one chunk, delivered when synthesis completes).
private actor SingleShotEngine: TtsEngine {
    nonisolated func validate(text: String, voice: String?, language: String?) throws {}
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {}
    func synthesize(text: String, voice: String?, language: String?) async throws -> SynthesizedSpeech {
        SynthesizedSpeech(samples: [0.1, 0.2, 0.3], sampleRate: 16_000)
    }
}

/// Collects streamed chunks across the `@Sendable` callback boundary.
private final class ChunkCollector: Sendable {
    private let storage = Mutex<[SynthesizedSpeechChunk]>([])

    /// Append the chunk; returns whether the consumer wants more (false from chunk `cancelAfter`).
    func take(_ chunk: SynthesizedSpeechChunk, cancelAfter: Int = .max) -> Bool {
        storage.withLock {
            $0.append(chunk)
            return $0.count < cancelAfter
        }
    }

    var chunks: [SynthesizedSpeechChunk] { storage.withLock { $0 } }
}

@Suite("TtsEngine streaming seam")
struct TtsStreamingTests {
    @Test func defaultImplementationDeliversTheWholeUtteranceAsOneChunk() async throws {
        let engine = SingleShotEngine()
        let collector = ChunkCollector()

        try await engine.synthesizeStreaming(text: "Hello.", voice: nil, language: nil) {
            collector.take($0)
        }

        let chunks = collector.chunks
        #expect(chunks.count == 1)
        #expect(chunks[0].samples == [0.1, 0.2, 0.3])
        #expect(chunks[0].sampleRate == 16_000)
    }

    @Test func mockStreamsSeveralOrderedChunksThatReassembleTheCompleteUtterance() async throws {
        let engine = MockTtsEngine()
        try await engine.prepare { _ in }
        let complete = try await engine.synthesize(text: "A sentence long enough to split.",
                                                   voice: nil, language: nil)
        let collector = ChunkCollector()

        try await engine.synthesizeStreaming(text: "A sentence long enough to split.",
                                             voice: nil, language: nil) {
            collector.take($0)
        }

        let chunks = collector.chunks
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.sampleRate == complete.sampleRate })
        #expect(chunks.flatMap(\.samples) == complete.samples)
    }

    @Test func returningFalseStopsTheStreamAfterThatChunk() async throws {
        let engine = MockTtsEngine()
        try await engine.prepare { _ in }
        let collector = ChunkCollector()

        try await engine.synthesizeStreaming(text: "A sentence long enough to split.",
                                             voice: nil, language: nil) {
            collector.take($0, cancelAfter: 1)
        }

        #expect(collector.chunks.count == 1)
    }

    @Test func streamingValidatesBeforeProducingAnything() async throws {
        let engine = MockTtsEngine()
        try await engine.prepare { _ in }
        let collector = ChunkCollector()

        await #expect(throws: TtsEngineError.unsupportedVoice("gandalf", supported: MockTtsEngine.supportedVoices)) {
            try await engine.synthesizeStreaming(text: "Hello.", voice: "gandalf", language: nil) {
                collector.take($0)
            }
        }
        #expect(collector.chunks.isEmpty)
    }
}
