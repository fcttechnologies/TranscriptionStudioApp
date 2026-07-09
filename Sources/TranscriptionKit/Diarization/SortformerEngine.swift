// SortformerEngine — the NVIDIA Streaming Sortformer 4-spk v2 diarizer (CC-BY-4.0) on Core AI.
//
// The exported `.aimodel` is the stateless fixed-buffer core; this host owns everything
// stateful: the NeMo mel frontend (SortformerMel), the 188-frame streaming chunk loop, and the
// AOSC speaker-cache compression. Ported 1:1 from the Core AI model zoo's
// `SortformerDiarizer.swift` + `host_loop.py` (BSD-3-Clause), itself a faithful re-impl of
// NeMo `sortformer_modules.py` (inference path, permute_spk=false).
//
// ⚠️ The currently-published model does not specialize on this toolchain — see
// Documentation/SORTFORMER-STATUS.md. The mel frontend, AOSC math, and streaming loop below are
// unit-verified independently of the model (mel golden gate + AOSC synthetic gates); the live
// forward pass lights up once a re-exported model loads. SpeakerKit is the shipping default.

import Foundation

/// Fixed streaming parameters (metadata.json / NeMo model_config.yaml).
public enum SortformerConfig {
    public static let spkcacheLen = 188
    public static let fifoLen = 0
    public static let chunkLen = 188
    public static let leftCtx = 1, rightCtx = 1
    public static let sub = 8
    public static let updatePeriod = 188
    public static let silPerSpk = 3
    public static let nSpk = 4
    public static let scoresBoostLatest: Float = 0.05
    public static let silThreshold: Float = 0.2
    public static let predScoreThreshold: Float = 0.25
    public static let strongRate = 0.75, weakRate = 1.5, minPosRate = 0.5
    public static let maxIndex = 99_999
    public static let emb = 512
    public static let mel = 128
    // fixed-buffer graph shapes
    public static let tfMax = 1520, spk = 188, peMax = 190, tDim = 378
    public static let frameSec = 0.08          // 8 subsample * 10 ms hop

    /// dw_striding output length: 3 stages of (l-1)/2 + 1 (k=3, stride=2, pad=1).
    public static func preEncodeLen(_ tf: Int) -> Int {
        var l = tf
        for _ in 0..<3 { l = (l - 1) / 2 + 1 }
        return l
    }
}

/// The AOSC + silence-profile + segmentation math, as free functions on plain arrays so the
/// verification suite can gate them on synthetic tensors (incl. the padded-count top-k trap)
/// with no model. All indexing matches NeMo `sortformer_modules.py` 1:1.
public enum SortformerAOSC {
    typealias C = SortformerConfig

    /// Update the running mean-silence embedding over popped frames (preds sum < sil_threshold).
    public static func silenceProfile(
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
    public static func compressSpkcache(embSeq: [Float], preds: [Float], frames F: Int, meanSil: [Float])
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
    public static func segments(from frames: [[Float]], bridgeFrames: Int = 6) -> [(speaker: Int, start: Int, end: Int)] {
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

/// Turns a per-frame activity matrix (committed prefix + provisional tail) into the contract types.
enum SortformerTurns {
    static func build(frames: [[Float]], committedFrameCount: Int) -> (turns: [SpeakerTurn], matrix: SpeakerFrameMatrix) {
        let raw = SortformerAOSC.segments(from: frames)
        var turns: [SpeakerTurn] = []
        for seg in raw {
            var sum: Float = 0
            for f in seg.start..<seg.end { sum += frames[f][seg.speaker] }
            let conf = seg.end > seg.start ? sum / Float(seg.end - seg.start) : 0
            turns.append(SpeakerTurn(
                speakerIndex: seg.speaker,
                start: Double(seg.start) * SortformerConfig.frameSec,
                end: Double(seg.end) * SortformerConfig.frameSec,
                confidence: conf,
                isCommitted: seg.end <= committedFrameCount))
        }
        let matrix = SpeakerFrameMatrix(activities: frames,
                                        committedFrameCount: min(committedFrameCount, frames.count),
                                        frameDuration: SortformerConfig.frameSec)
        return (turns, matrix)
    }
}

/// Streaming diarizer core (actor-isolated: one inference at a time, persistent AOSC state).
actor SortformerCore {
    typealias C = SortformerConfig

    private let graph: GraphRunner
    private let mel: SortformerMel
    private let recorder: PipelineRecorder?
    private let sessionID: UUID?

    // persistent streaming state
    private var spkcache: [Float] = []
    private var spkFrames = 0
    private var spkcachePreds: [Float]? = nil
    private var meanSil = [Float](repeating: 0, count: C.emb)
    private var nSil = 0
    private var committed: [[Float]] = []   // committed per-frame preds
    private var stt = 0                       // next chunk start (mel frames)

    init(graph: GraphRunner, mel: SortformerMel, recorder: PipelineRecorder?, sessionID: UUID?) {
        self.graph = graph
        self.mel = mel
        self.recorder = recorder
        self.sessionID = sessionID
    }

    func reset() {
        spkcache = []; spkFrames = 0; spkcachePreds = nil
        meanSil = [Float](repeating: 0, count: C.emb); nSil = 0
        committed = []; stt = 0
    }

    // MARK: full-buffer diarize

    func diarizeFull(samples: [Float]) async throws -> DiarizationResult {
        reset()
        let (m, frames) = timedMel(samples)
        let all = try await runLoop(mel: m, melFrames: frames, upTo: frames, commit: true)
        committed = all; stt = frames
        let (turns, matrix) = SortformerTurns.build(frames: all, committedFrameCount: all.count)
        return DiarizationResult(turns: turns, frames: matrix)
    }

    // MARK: streaming

    /// Recompute mel over the full accumulated buffer, commit every fully-available 188-frame
    /// chunk (advancing AOSC state), then a stateless preview pass over the pending tail.
    /// Returns the whole-session update. `isFinal` commits the trailing partial chunk.
    func advance(samples: [Float], isFinal: Bool) async throws -> DiarizationUpdate {
        let (m, melFrames) = timedMel(samples)

        // COMMIT: process chunks whose right context is available (or everything, when final).
        while stt < melFrames {
            let end = min(stt + C.chunkLen * C.sub, melFrames)
            let isFull = (end - stt == C.chunkLen * C.sub)
            let haveRight = (melFrames - end) >= C.rightCtx * C.sub
            if !isFinal && !(isFull && haveRight) { break }
            let popPreds = try await commitChunk(mel: m, melFrames: melFrames, chunkEnd: end)
            committed.append(contentsOf: popPreds)
            stt = end
        }

        // PREVIEW: stateless pass over the pending tail [stt, melFrames), state untouched.
        var frames = committed
        var committedCount = committed.count
        if !isFinal && stt < melFrames {
            let preview = try await previewTail(mel: m, melFrames: melFrames)
            frames.append(contentsOf: preview)
            committedCount = committed.count
        }

        let (turns, matrix) = SortformerTurns.build(frames: frames, committedFrameCount: committedCount)
        if let recorder {
            recorder.record(PipelineEvent(
                sessionID: sessionID, stage: .diarizeCommit, level: .debug,
                message: "advance",
                metadata: ["committedFrames": "\(committed.count)",
                           "previewFrames": "\(frames.count - committed.count)",
                           "turns": "\(turns.count)"]))
        }
        return DiarizationUpdate(turns: turns, frames: matrix)
    }

    // MARK: chunk processing

    /// One committing chunk step: runs the graph, folds embeddings into the cache, updates the
    /// silence profile, compresses if the cache overflows, and returns this chunk's popped preds.
    private func commitChunk(mel m: [Float], melFrames: Int, chunkEnd end: Int) async throws -> [[Float]] {
        let (popEmbs, popPreds, spkRegionPreds, chunkFramesN) = try await forwardChunk(
            mel: m, melFrames: melFrames, chunkEnd: end, stage: .diarizeCommit)

        (meanSil, nSil) = SortformerAOSC.silenceProfile(meanSil, nSil, popEmbs, popPreds, frames: chunkFramesN)
        spkcache.append(contentsOf: popEmbs); spkFrames += chunkFramesN
        if spkcachePreds != nil { spkcachePreds!.append(contentsOf: popPreds) }

        if spkFrames > C.spkcacheLen {
            if spkcachePreds == nil {
                // First overflow: spkcache_preds = cat(preds[:Sc], pop_preds) — the Sc spkcache-region
                // rows from THIS run plus this chunk's popped preds (NeMo host_loop.py).
                spkcachePreds = spkRegionPreds + popPreds
            }
            let (ne, np) = SortformerAOSC.compressSpkcache(
                embSeq: spkcache, preds: spkcachePreds!, frames: spkFrames, meanSil: meanSil)
            spkcache = ne; spkcachePreds = np; spkFrames = C.spkcacheLen
        }

        var out = [[Float]](repeating: [Float](repeating: 0, count: C.nSpk), count: chunkFramesN)
        for f in 0..<chunkFramesN { for s in 0..<C.nSpk { out[f][s] = popPreds[f * C.nSpk + s] } }
        return out
    }

    /// Stateless preview over the pending tail — same forward, but nothing is committed.
    private func previewTail(mel m: [Float], melFrames: Int) async throws -> [[Float]] {
        let (_, popPreds, _, chunkFramesN) = try await forwardChunk(
            mel: m, melFrames: melFrames, chunkEnd: melFrames, stage: .diarizePreview)
        var out = [[Float]](repeating: [Float](repeating: 0, count: C.nSpk), count: chunkFramesN)
        for f in 0..<chunkFramesN { for s in 0..<C.nSpk { out[f][s] = popPreds[f * C.nSpk + s] } }
        return out
    }

    /// Extract the chunk's mel window, run the fixed-buffer graph, slice out this chunk's
    /// embeddings + preds (plus the spkcache-region preds, for the first cache overflow).
    /// `chunkEnd` is the exclusive mel-frame end of the chunk region.
    private func forwardChunk(mel m: [Float], melFrames: Int, chunkEnd end: Int, stage: PipelineStage)
        async throws -> (embs: [Float], preds: [Float], spkRegionPreds: [Float], count: Int)
    {
        let E = C.emb, S = C.nSpk
        let left = min(C.leftCtx * C.sub, stt)
        let right = min(C.rightCtx * C.sub, melFrames - end)
        let cstart = stt - left, cend = end + right, tf = cend - cstart

        // chunk_feat [tf,128] frame-major from mel-major [128, melFrames]
        var chunkFeat = [Float](repeating: 0, count: tf * C.mel)
        for f in 0..<tf {
            let col = cstart + f
            for mi in 0..<C.mel { chunkFeat[f * C.mel + mi] = m[mi * melFrames + col] }
        }

        let Sc = spkFrames   // spkcache length BEFORE this chunk folds in
        let (predsConcat, chunkPe, peLen) = try await engineForward(
            chunkFeat: chunkFeat, tf: tf, stage: stage)

        let lc = Int((Double(left) / Double(C.sub)).rounded())
        let rc = Int((Double(right) / Double(C.sub)).rounded(.up))
        let chunkFramesN = peLen - lc - rc

        var popEmbs = [Float](repeating: 0, count: chunkFramesN * E)
        for f in 0..<chunkFramesN {
            let src = (lc + f) * E
            for d in 0..<E { popEmbs[f * E + d] = chunkPe[src + d] }
        }
        var popPreds = [Float](repeating: 0, count: chunkFramesN * S)
        for f in 0..<chunkFramesN {
            let src = (Sc + lc + f) * S
            for s in 0..<S { popPreds[f * S + s] = predsConcat[src + s] }
        }
        let spkRegionPreds = Array(predsConcat[0..<(Sc * S)])
        return (popEmbs, popPreds, spkRegionPreds, chunkFramesN)
    }

    /// Drive the fixed-buffer graph: zero-pad the mel chunk, build spkcache + valid, run, and
    /// re-slice preds into the `[spkcache-region | chunk-region]` concat layout.
    private func engineForward(chunkFeat: [Float], tf: Int, stage: PipelineStage) async throws
        -> (predsConcat: [Float], chunkPe: [Float], peLen: Int)
    {
        let S = C.nSpk, E = C.emb
        let peLen = C.preEncodeLen(tf)
        let spkLen = spkFrames

        var chunkMel = [Float](repeating: 0, count: C.tfMax * C.mel)
        for i in 0..<min(chunkFeat.count, chunkMel.count) { chunkMel[i] = chunkFeat[i] }
        var spk188 = [Float](repeating: 0, count: C.spk * E)
        for i in 0..<min(spkcache.count, spk188.count) { spk188[i] = spkcache[i] }
        var valid = [Float](repeating: 0, count: C.tDim)
        for i in 0..<spkLen { valid[i] = 1 }
        for i in 0..<peLen { valid[C.spk + i] = 1 }

        let clock = ContinuousClock()
        let t0 = clock.now
        let out = try await graph.run([
            "chunk_mel": GraphTensor(values: chunkMel, shape: [1, C.tfMax, C.mel]),
            "spkcache": GraphTensor(values: spk188, shape: [1, C.spk, E]),
            "valid": GraphTensor(values: valid, shape: [1, C.tDim]),
        ])
        let elapsed = seconds(t0, clock.now)
        recorder?.record(PipelineEvent(
            sessionID: sessionID, stage: stage, level: .debug,
            message: stage == .diarizePreview ? "preview forward" : "commit forward",
            duration: elapsed, metadata: ["tf": "\(tf)", "peLen": "\(peLen)", "spkFrames": "\(spkLen)"]))

        guard let predsFixed = out["preds"]?.values, let chunkPeFixed = out["chunk_pe"]?.values else {
            throw GraphRunnerError.missingOutput("preds/chunk_pe")
        }

        var predsConcat = [Float](repeating: 0, count: (spkLen + peLen) * S)
        for f in 0..<spkLen { for s in 0..<S { predsConcat[f * S + s] = predsFixed[f * S + s] } }
        for f in 0..<peLen {
            for s in 0..<S { predsConcat[(spkLen + f) * S + s] = predsFixed[(C.spk + f) * S + s] }
        }
        let chunkPe = Array(chunkPeFixed[0..<peLen * E])
        return (predsConcat, chunkPe, peLen)
    }

    /// Run the whole streaming loop over a fixed mel buffer up to `upTo` mel frames (full-buffer path).
    private func runLoop(mel m: [Float], melFrames: Int, upTo: Int, commit: Bool) async throws -> [[Float]] {
        var total: [[Float]] = []
        while stt < upTo {
            let end = min(stt + C.chunkLen * C.sub, upTo)
            let pop = try await commitChunk(mel: m, melFrames: melFrames, chunkEnd: end)
            total.append(contentsOf: pop)
            stt = end
        }
        return total
    }

    private func timedMel(_ samples: [Float]) -> (mel: [Float], frames: Int) {
        let clock = ContinuousClock()
        let t0 = clock.now
        let result = mel.logMel(samples)   // log-mel, the model's frontend input
        let elapsed = seconds(t0, clock.now)
        recorder?.record(PipelineEvent(
            sessionID: sessionID, stage: .mel, level: .debug, message: "mel frontend",
            duration: elapsed, metadata: ["samples": "\(samples.count)", "frames": "\(result.frames)"]))
        return result
    }

    private func seconds(_ a: ContinuousClock.Instant, _ b: ContinuousClock.Instant) -> TimeInterval {
        let d = a.duration(to: b)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

/// The `DiarizationEngine` conformance: builds/loads the graph (opt-in), forwards to the core.
public final class SortformerEngine: DiarizationEngine, @unchecked Sendable {
    public let backendName = "Sortformer (Core AI)"

    private let store: SortformerModelStore
    private let recorder: PipelineRecorder?
    private let sessionID: UUID?
    private let makeGraph: @Sendable (URL) async throws -> GraphRunner
    private var core: SortformerCore?

    /// - Parameters:
    ///   - store: artifact locator/verifier.
    ///   - makeGraph: how to build the runtime from the model URL. Defaults to the raw Core AI
    ///     runner; tests inject a fake so the loop runs without the (currently unloadable) model.
    public init(store: SortformerModelStore = SortformerModelStore(),
                recorder: PipelineRecorder? = nil,
                sessionID: UUID? = nil,
                makeGraph: (@Sendable (URL) async throws -> GraphRunner)? = nil) {
        self.store = store
        self.recorder = recorder
        self.sessionID = sessionID
        if let makeGraph {
            self.makeGraph = makeGraph
        } else {
            self.makeGraph = { url in
                #if canImport(CoreAI)
                return try await CoreAIGraphRunner(modelURL: url)
                #else
                throw GraphRunnerError.unavailable("CoreAI framework not available on this platform")
                #endif
            }
        }
    }

    public func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        onProgress(EnginePreparationProgress(phase: "Verifying Sortformer artifacts", fraction: nil))
        // Local-first: a re-exported/provisioned model dir is used as-is; else fetch from HF.
        try await store.provision { p in
            onProgress(EnginePreparationProgress(phase: "Downloading \(p.file)", fraction: p.fraction))
        }
        try store.verifyArtifacts()
        onProgress(EnginePreparationProgress(phase: "Loading Sortformer graph", fraction: nil))
        let graph = try await makeGraph(store.modelURL)   // ⚠️ aborts on the current published model
        let mel = SortformerMel(melFilters: try store.loadMelFilters())
        core = SortformerCore(graph: graph, mel: mel, recorder: recorder, sessionID: sessionID)
        onProgress(EnginePreparationProgress(phase: "Sortformer ready", fraction: 1))
    }

    public func diarize(samples: [Float]) async throws -> DiarizationResult {
        guard let core else { throw GraphRunnerError.unavailable("prepare() not called") }
        return try await core.diarizeFull(samples: samples)
    }

    public func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<DiarizationUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [core, previewInterval] in
                guard let core else {
                    continuation.finish(throwing: GraphRunnerError.unavailable("prepare() not called"))
                    return
                }
                await core.reset()
                var buffer: [Float] = []
                var lastPreview: TimeInterval = 0
                do {
                    for try await chunk in chunks {
                        buffer.append(contentsOf: chunk.samples)
                        let elapsed = Double(buffer.count) / AudioChunk.sampleRate
                        // Commit whenever a chunk is available; preview on the cadence.
                        if elapsed - lastPreview >= previewInterval {
                            let update = try await core.advance(samples: buffer, isFinal: false)
                            continuation.yield(update)
                            lastPreview = elapsed
                        }
                    }
                    let final = try await core.advance(samples: buffer, isFinal: true)
                    continuation.yield(final)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Preview cadence in seconds (the two-tier design's provisional-label interval).
    public var previewInterval: TimeInterval = 3.0
}
