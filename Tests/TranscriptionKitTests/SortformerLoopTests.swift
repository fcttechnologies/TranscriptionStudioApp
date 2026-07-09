// Sortformer host-loop wiring + latency, WITHOUT the (currently unloadable) neural model.
//
// A FakeGraphRunner returns correctly-shaped preds/chunk_pe, so the full streaming machinery —
// real mel frontend, chunk loop, AOSC compression on a 60s+ buffer, preview/commit slicing,
// segmentation — runs end-to-end and is measured on this M4. The one thing faked is the neural
// forward's *values* (its latency is unknown until a re-exported model loads). This proves the host
// code is correct and gives real mel + host-overhead numbers.

import Foundation
import Testing
@testable import TranscriptionKit

/// A deterministic stand-in for the Core AI graph: emits preds that make alternating 15s chunks
/// favor speaker 0 then speaker 1 (so turns + AOSC compression actually exercise), plus zeroed
/// chunk_pe embeddings.
final class FakeGraphRunner: GraphRunner, @unchecked Sendable {
    let inputNames = ["chunk_mel", "spkcache", "valid"]
    let outputNames = ["preds", "chunk_pe"]
    // Serialized by the SortformerCore actor (one inference at a time), so no lock needed.
    private(set) var callCount = 0

    func run(_ inputs: [String: GraphTensor]) async throws -> [String: GraphTensor] {
        let call = callCount; callCount += 1

        let S = SortformerConfig.nSpk, E = SortformerConfig.emb
        let T = SortformerConfig.tDim          // 378
        let PE = SortformerConfig.peMax        // 190
        let spk = SortformerConfig.spk         // 188
        let speaker = call % 2                 // alternate speakers per chunk

        // preds [1,378,4]: chunk region (rows spk..) active for `speaker`; spkcache region low.
        var preds = [Float](repeating: 0.02, count: T * S)
        for f in spk..<T { preds[f * S + speaker] = 0.95 }
        // chunk_pe [1,190,512]: a small speaker-dependent constant so cache embeddings differ.
        let chunkPe = [Float](repeating: Float(speaker) + 0.01, count: PE * E)

        return [
            "preds": GraphTensor(values: preds, shape: [1, T, S]),
            "chunk_pe": GraphTensor(values: chunkPe, shape: [1, PE, E]),
        ]
    }
}

@Suite("Sortformer host loop (fake graph)")
struct SortformerLoopTests {
    /// Silence-ish mel input length (mel runs for real on these samples).
    private static func samples(seconds: Double) -> [Float] {
        let n = Int(seconds * AudioChunk.sampleRate)
        var out = [Float](repeating: 0, count: n)
        // low-amplitude tone so the mel has real (non-degenerate) structure
        for i in 0..<n { out[i] = 0.05 * Float(sin(2 * .pi * 200 * Double(i) / AudioChunk.sampleRate)) }
        return out
    }

    @Test("full-buffer diarize runs the loop + AOSC over a 60s+ clip",
          .enabled(if: SortformerModelStore().artifactsPresent))
    func fullBufferLoop() async throws {
        let fake = FakeGraphRunner()
        let engine = SortformerEngine(makeGraph: { _ in fake })
        // prepare() verifies artifacts + loads the real mel filterbank, then builds the core with
        // the fake graph (the neural load is bypassed; the mel + host loop are real).
        try await engine.prepare { _ in }

        let audio = Self.samples(seconds: 65)   // ~4-5 chunks -> AOSC compression fires
        let result = try await engine.diarize(samples: audio)
        // The loop produced frames and at least one turn (fake alternates speakers across chunks).
        #expect(result.frames.activities.count > 700)   // ~65s / 0.08s
        #expect(result.turns.count >= 2)
        #expect(fake.callCount >= 4)                     // multiple chunks -> compression exercised
        print("[LOOP] 65s: \(result.frames.activities.count) frames, \(result.turns.count) turns, \(fake.callCount) chunk forwards")
    }

    @Test("mel + host-loop latency on this machine",
          .enabled(if: SortformerModelStore().artifactsPresent))
    func melAndLoopLatency() async throws {
        let filters = try SortformerModelStore().loadMelFilters()
        let mel = SortformerMel(melFilters: filters)

        // Mel latency for a 15s chunk (one commit chunk's worth of audio).
        let chunk = Self.samples(seconds: 15)
        let clock = ContinuousClock()
        var t0 = clock.now
        let (_, frames) = mel.logMel(chunk)
        let melMs = seconds(t0, clock.now) * 1000
        print("[LAT] mel 15s -> \(frames) frames: \(String(format: "%.1f", melMs)) ms")
        #expect(frames > 0)

        // Host-loop overhead (fake forward) for a full 15s commit chunk.
        let fake = FakeGraphRunner()
        let engine = SortformerEngine(makeGraph: { _ in fake })
        try await engine.prepare { _ in }
        t0 = clock.now
        _ = try await engine.diarize(samples: chunk)
        let loopMs = seconds(t0, clock.now) * 1000
        print("[LAT] diarize 15s (mel + 1 fake commit): \(String(format: "%.1f", loopMs)) ms")

        // Preview cadence cost: stream the same 15s at 2s vs 4s preview intervals and count forwards.
        for interval in [2.0, 4.0] {
            let counter = FakeGraphRunner()
            let streamEngine = SortformerEngine(makeGraph: { _ in counter })
            streamEngine.previewInterval = interval
            try await streamEngine.prepare { _ in }
            let (stream, cont) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
            // Feed 0.5s chunks.
            Task {
                var t = 0.0
                let step = 0.5
                let per = Int(step * AudioChunk.sampleRate)
                let all = Self.samples(seconds: 15)
                var i = 0
                while i + per <= all.count {
                    cont.yield(AudioChunk(track: .mixed, samples: Array(all[i..<i+per]), startTime: t))
                    t += step; i += per
                }
                cont.finish()
            }
            let s0 = clock.now
            var updates = 0
            for try await _ in streamEngine.stream(chunks: stream) { updates += 1 }
            let ms = seconds(s0, clock.now) * 1000
            print("[LAT] stream 15s @ \(interval)s preview: \(counter.callCount) forwards, \(updates) updates, \(String(format: "%.1f", ms)) ms wall")
        }
    }

    private func seconds(_ a: ContinuousClock.Instant, _ b: ContinuousClock.Instant) -> TimeInterval {
        let d = a.duration(to: b)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
