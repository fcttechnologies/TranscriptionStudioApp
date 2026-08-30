// SortformerCore — the stateful streaming core of the NVIDIA Streaming Sortformer 4-spk v2
// diarizer (CC-BY-4.0) on Core AI.
//
// The exported `.aimodel` is the stateless fixed-buffer core; this host owns everything stateful:
// the NeMo mel frontend (SortformerMel), the 188-frame streaming chunk loop, and the AOSC
// speaker-cache compression. Ported 1:1 from the Core AI model zoo's `SortformerDiarizer.swift` +
// `host_loop.py` (BSD-3-Clause), itself a faithful re-impl of NeMo `sortformer_modules.py`
// (inference path, permute_spk=false). The pure AOSC math lives in SortformerAOSC.swift; the
// `DiarizationEngine` wrapper in SortformerEngine.swift.
//
// ⚠️ The currently-published model does not specialize on this toolchain — see
// Documentation/SORTFORMER-MODEL.md. The mel frontend, AOSC math, and streaming loop are
// unit-verified independently of the model (mel golden gate + AOSC synthetic gates); the live
// forward pass lights up once a re-exported model loads. SpeakerKit is the shipping default.

import Foundation

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

/// Streaming diarizer core (actor-isolated: one synchronous step at a time, persistent AOSC state).
///
/// The actor serializes each synchronous step, but is *reentrant* across `await` — so overlapping
/// whole operations (`reset()` + loop) on one instance would corrupt in-flight state. The
/// `SortformerEngine` wrapper serializes whole `diarize`/`stream` operations above this core.
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
