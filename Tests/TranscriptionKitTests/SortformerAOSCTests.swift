// AOSC unit gates on synthetic tensors — no model. Covers the speaker-cache compression math and,
// specifically, the padded-count top-k indexing trap the conversion handoff documents: the
// `topkIndices` wrap length must be derived from the PADDED frame count (F + SIL_PER_SPK), not the
// pre-pad count. A pre-pad wrap shifts every real-frame index by SIL/speaker — invisible on a short
// clip, wrong on a long one — so this test asserts the wrap/disable behavior directly.

import Foundation
import Testing
@testable import TranscriptionKit

@Suite("Sortformer AOSC")
struct SortformerAOSCTests {
    typealias C = SortformerConfig

    /// compressSpkcache always returns exactly spkcacheLen rows, with the trailing silence slots
    /// disabled to the mean-silence embedding.
    @Test("compress keeps exactly spkcacheLen rows")
    func compressShape() {
        let S = C.nSpk, E = C.emb
        let F = 260   // > spkcacheLen so compression is meaningful
        var preds = [Float](repeating: 0, count: F * S)
        var emb = [Float](repeating: 0, count: F * E)
        // Two clear speakers alternating in blocks, with some silence frames.
        for f in 0..<F {
            let spk = (f / 20) % 2
            if (f / 20) % 5 == 4 {
                // silence block — low preds
                for s in 0..<S { preds[f * S + s] = 0.01 }
            } else {
                preds[f * S + spk] = 0.95
                for d in 0..<E { emb[f * E + d] = Float(spk) + 0.001 * Float(f) }
            }
        }
        let meanSil = [Float](repeating: -1, count: E)
        let (ne, np) = SortformerAOSC.compressSpkcache(embSeq: emb, preds: preds, frames: F, meanSil: meanSil)
        #expect(ne.count == C.spkcacheLen * E)
        #expect(np.count == C.spkcacheLen * S)
    }

    /// The trap: topkIndices must wrap by the PADDED count. We build a scores buffer where the top
    /// SPKCACHE_LEN entries are all real frames plus the appended silence rows; the silence rows
    /// (index >= F) must come back disabled, and every kept index must be a valid real-frame index
    /// in [0, F). A pre-pad wrap would fold silence indices onto real frames (never disabled).
    @Test("topkIndices wraps by the padded count and disables silence rows")
    func topkPaddedWrap() {
        let S = C.nSpk, K = C.spkcacheLen, SIL = C.silPerSpk
        let F = 200
        let Fp = F + SIL

        // Real-frame scores: a gentle ramp so ordering is deterministic; silence rows are +inf.
        var padded = [Float](repeating: 0, count: Fp * S)
        for f in 0..<F { for s in 0..<S { padded[f * S + s] = Float(f) * 0.001 + Float(s) * 0.01 } }
        for f in F..<Fp { for s in 0..<S { padded[f * S + s] = .infinity } }

        let (idx, disabled) = SortformerAOSC.topkIndices(padded, paddedFrames: Fp)
        #expect(idx.count == K)
        #expect(disabled.count == K)

        // The +inf silence rows are the largest, so at least SIL*S land in the top-K and must be
        // disabled (index >= F after wrap by Fp).
        let disabledCount = disabled.filter { $0 }.count
        #expect(disabledCount >= SIL, "expected the appended silence rows to be disabled, got \(disabledCount)")

        // Every enabled index is a real frame in [0, F) — the padded wrap guarantees this.
        for i in 0..<K where !disabled[i] {
            #expect(idx[i] >= 0 && idx[i] < F, "enabled index \(idx[i]) out of real-frame range [0,\(F))")
        }
    }

    /// The silence profile is the running mean of embeddings over frames whose preds sum below the
    /// silence threshold; non-silent frames don't move it.
    @Test("silence profile averages only silent frames")
    func silenceProfile() {
        let S = C.nSpk, E = C.emb
        let F = 10
        var preds = [Float](repeating: 0, count: F * S)
        var emb = [Float](repeating: 0, count: F * E)
        for f in 0..<F {
            if f % 2 == 0 {
                for s in 0..<S { preds[f * S + s] = 0.01 }   // silent (sum 0.04 < 0.2)
                for d in 0..<E { emb[f * E + d] = 4 }
            } else {
                preds[f * S + 0] = 0.9                        // speech
                for d in 0..<E { emb[f * E + d] = 100 }
            }
        }
        let (mean, n) = SortformerAOSC.silenceProfile([Float](repeating: 0, count: E), 0, emb, preds, frames: F)
        #expect(n == 5)                     // 5 silent frames
        #expect(abs(mean[0] - 4) < 1e-4)    // mean over silent frames only
    }

    /// Segmentation assigns each frame to the strongest speaker over 0.5, merges runs, and bridges
    /// short gaps within one speaker.
    @Test("segmentation merges runs and bridges short gaps")
    func segmentation() {
        // 30 frames: speaker 0 for 0..10, silence 10..12 (short gap), speaker 0 for 12..20,
        // then speaker 1 for 20..30.
        var frames = [[Float]]()
        for f in 0..<30 {
            var row: [Float] = [0.05, 0.05, 0.05, 0.05]
            if f < 10 || (f >= 12 && f < 20) { row[0] = 0.9 }
            else if f >= 20 { row[1] = 0.9 }
            frames.append(row)
        }
        let segs = SortformerAOSC.segments(from: frames, bridgeFrames: 6)
        // Speaker 0's two runs bridge across the 2-frame gap -> one turn [0,20); speaker 1 [20,30).
        #expect(segs.count == 2)
        #expect(segs[0].speaker == 0 && segs[0].start == 0 && segs[0].end == 20)
        #expect(segs[1].speaker == 1 && segs[1].start == 20 && segs[1].end == 30)
    }
}
