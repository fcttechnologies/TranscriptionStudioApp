// SortformerAOSC — the pure AOSC + silence-profile + segmentation math for the NVIDIA Streaming
// Sortformer 4-spk v2 diarizer, plus the fixed streaming parameters.
//
// Free functions on plain arrays (no model, no state), so the verification suite can gate them on
// synthetic tensors. Ported 1:1 from the Core AI model zoo's `host_loop.py` (BSD-3-Clause), a
// faithful re-impl of NeMo `sortformer_modules.py` (inference path, permute_spk=false). The stateful
// streaming core that drives these lives in SortformerCore.swift; the engine wrapper in
// SortformerEngine.swift.

import Foundation

/// Fixed streaming parameters (metadata.json / NeMo model_config.yaml).
enum SortformerConfig {
    static let spkcacheLen = 188
    static let fifoLen = 0
    static let chunkLen = 188
    static let leftCtx = 1, rightCtx = 1
    static let sub = 8
    static let updatePeriod = 188
    static let silPerSpk = 3
    static let nSpk = 4
    static let scoresBoostLatest: Float = 0.05
    static let silThreshold: Float = 0.2
    static let predScoreThreshold: Float = 0.25
    static let strongRate = 0.75, weakRate = 1.5, minPosRate = 0.5
    static let maxIndex = 99_999
    static let emb = 512
    static let mel = 128
    // fixed-buffer graph shapes
    static let tfMax = 1520, spk = 188, peMax = 190, tDim = 378
    static let frameSec = 0.08          // 8 subsample * 10 ms hop

    /// dw_striding output length: 3 stages of (l-1)/2 + 1 (k=3, stride=2, pad=1).
    static func preEncodeLen(_ tf: Int) -> Int {
        var l = tf
        for _ in 0..<3 { l = (l - 1) / 2 + 1 }
        return l
    }
}

/// The AOSC + silence-profile + segmentation math, as free functions on plain arrays so the
/// verification suite can gate them on synthetic tensors (incl. the padded-count top-k trap)
/// with no model. All indexing matches NeMo `sortformer_modules.py` 1:1.
enum SortformerAOSC {
    typealias C = SortformerConfig

    /// Update the running mean-silence embedding over popped frames (preds sum < sil_threshold).
    static func silenceProfile(
        _ meanSil: [Float], _ nSil: Int, _ embSeq: [Float], _ preds: [Float], frames F: Int
    ) -> ([Float], Int) {
        let E = C.emb, S = C.nSpk
        var silCount = 0
        var silSum = [Float](repeating: 0, count: E)
        for f in 0..<F {
            var psum: Float = 0
            for s in 0..<S { psum += preds[f * S + s] }
            if psum < C.silThreshold {
                silCount += 1
                for d in 0..<E { silSum[d] += embSeq[f * E + d] }
            }
        }
        if silCount == 0 { return (meanSil, nSil) }
        let updN = nSil + silCount
        var out = [Float](repeating: 0, count: E)
        let denom = Float(max(updN, 1))
        for d in 0..<E { out[d] = (meanSil[d] * Float(nSil) + silSum[d]) / denom }
        return (out, updN)
    }

    static func logPredScores(_ preds: [Float], frames F: Int) -> [Float] {
        let S = C.nSpk
        var scores = [Float](repeating: 0, count: F * S)
        let logHalf = Float(log(0.5))
        for f in 0..<F {
            var l1sum: Float = 0
            for s in 0..<S { l1sum += log(max(1 - preds[f * S + s], C.predScoreThreshold)) }
            for s in 0..<S {
                let lp = log(max(preds[f * S + s], C.predScoreThreshold))
                let l1 = log(max(1 - preds[f * S + s], C.predScoreThreshold))
                scores[f * S + s] = lp - l1 + l1sum - logHalf
            }
        }
        return scores
    }

    static func disableLowScores(_ preds: [Float], _ scores: [Float], frames F: Int, minPos: Int) -> [Float] {
        let S = C.nSpk
        let ninf = -Float.infinity
        var out = scores
        for f in 0..<F { for s in 0..<S where !(preds[f * S + s] > 0.5) { out[f * S + s] = ninf } }
        var posCount = [Int](repeating: 0, count: S)
        for f in 0..<F { for s in 0..<S where out[f * S + s] > 0 { posCount[s] += 1 } }
        for f in 0..<F {
            for s in 0..<S {
                let isSpeech = preds[f * S + s] > 0.5
                let isPos = out[f * S + s] > 0
                if !isPos && isSpeech && posCount[s] >= minPos { out[f * S + s] = ninf }
            }
        }
        return out
    }

    /// Boost the `nBoost` highest scores per speaker by `-scale·log(0.5)` (per column, in place).
    static func boostTopk(_ scores: inout [Float], frames F: Int, nBoost: Int, scale: Float) {
        let S = C.nSpk
        let add = -scale * Float(log(0.5))
        let k = min(nBoost, F)
        if k <= 0 { return }
        for s in 0..<S {
            var idx = Array(0..<F)
            idx.sort { scores[$0 * S + s] > scores[$1 * S + s] }
            for i in 0..<k { scores[idx[i] * S + s] += add }
        }
    }

    /// NeMo `_get_topk_indices`: `scores` is the PADDED `[(F+SIL)·S]` buffer, so n_frames := F+SIL
    /// and n_frames_no_sil := F. The remainder wraps by the PADDED count — deriving it from the
    /// pre-pad count instead shifts every real-frame index by SIL/speaker (invisible on a short
    /// clip, wrong on a long one; the trap the zoo's handoff documents). Returns spkcacheLen frame
    /// indices into `[0,F)` plus a disabled mask.
    static func topkIndices(_ scores: [Float], paddedFrames Fp: Int) -> (idx: [Int], disabled: [Bool]) {
        let S = C.nSpk, K = C.spkcacheLen
        let nNoSil = Fp - C.silPerSpk
        // flat[s*Fp + f] = scores[f*S + s]  (permute(0,2,1).reshape)
        var flat = [Float](repeating: 0, count: S * Fp)
        for s in 0..<S { for f in 0..<Fp { flat[s * Fp + f] = scores[f * S + s] } }
        var order = Array(0..<(S * Fp))
        order.sort { flat[$0] > flat[$1] }
        var top = Array(order[0..<K])
        for i in 0..<K where flat[top[i]] == -Float.infinity { top[i] = C.maxIndex }
        top.sort()
        var idx = [Int](repeating: 0, count: K)
        var disabled = [Bool](repeating: false, count: K)
        for i in 0..<K {
            let wasMax = top[i] == C.maxIndex
            let rem = wasMax ? 0 : top[i] % Fp
            let dis = wasMax || rem >= nNoSil
            disabled[i] = dis
            idx[i] = dis ? 0 : rem
        }
        return (idx, disabled)
    }

    /// Compress `frames` cache rows down to spkcacheLen most-important frames.
    static func compressSpkcache(embSeq: [Float], preds: [Float], frames F: Int, meanSil: [Float])
        -> (emb: [Float], preds: [Float])
    {
        let S = C.nSpk, E = C.emb, K = C.spkcacheLen
        let perSpk = K / S - C.silPerSpk
        let strong = Int((Double(perSpk) * C.strongRate).rounded(.down))
        let weak = Int((Double(perSpk) * C.weakRate).rounded(.down))
        let minPos = Int((Double(perSpk) * C.minPosRate).rounded(.down))

        var scores = logPredScores(preds, frames: F)
        scores = disableLowScores(preds, scores, frames: F, minPos: minPos)
        if C.scoresBoostLatest > 0 {
            for f in C.spkcacheLen..<max(C.spkcacheLen, F) { for s in 0..<S { scores[f * S + s] += C.scoresBoostLatest } }
        }
        boostTopk(&scores, frames: F, nBoost: strong, scale: 2)
        boostTopk(&scores, frames: F, nBoost: weak, scale: 1)

        // append SIL_PER_SPK rows of +inf -> padded [(F+SIL) * S]
        let Fp = F + C.silPerSpk
        var padded = scores
        padded.append(contentsOf: [Float](repeating: .infinity, count: C.silPerSpk * S))
        let (idx, disabled) = topkIndices(padded, paddedFrames: Fp)

        var ne = [Float](repeating: 0, count: K * E)
        var np = [Float](repeating: 0, count: K * S)
        for i in 0..<K {
            if disabled[i] {
                for d in 0..<E { ne[i * E + d] = meanSil[d] }
            } else {
                let g = idx[i]
                for d in 0..<E { ne[i * E + d] = embSeq[g * E + d] }
                for s in 0..<S { np[i * S + s] = preds[g * S + s] }
            }
        }
        return (ne, np)
    }

    /// Per-frame 4-speaker activity -> speaker turns. A frame goes to the strongest speaker with
    /// activity > 0.5 (else silence); contiguous same-speaker frames merge, and gaps ≤ bridgeFrames
    /// within one speaker are bridged so a brief pause doesn't split a turn.
    static func segments(from frames: [[Float]], bridgeFrames: Int = 6) -> [(speaker: Int, start: Int, end: Int)] {
        var lab = [Int](repeating: -1, count: frames.count)
        for (f, act) in frames.enumerated() {
            var best = -1; var bestV: Float = 0.5
            for s in 0..<act.count where act[s] > bestV { bestV = act[s]; best = s }
            lab[f] = best
        }
        var segs = [(speaker: Int, start: Int, end: Int)]()
        var i = 0
        while i < lab.count {
            let s = lab[i]
            if s < 0 { i += 1; continue }
            var j = i + 1
            while j < lab.count && lab[j] == s { j += 1 }
            segs.append((s, i, j))
            i = j
        }
        var merged = [(speaker: Int, start: Int, end: Int)]()
        for seg in segs {
            if let last = merged.last, last.speaker == seg.speaker,
               seg.start - last.end <= bridgeFrames {
                merged[merged.count - 1] = (last.speaker, last.start, seg.end)
            } else {
                merged.append(seg)
            }
        }
        return merged
    }
}
