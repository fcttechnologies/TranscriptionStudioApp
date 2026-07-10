import Foundation
import Observation
import SwiftData

/// Drives a live recording end to end against the engine contracts: it prepares the ASR and
/// diarization engines (with observable progress) before capture starts, fans one (or two, in
/// meeting mode) capture streams into them, fuses their outputs into an attributed transcript
/// in real time, feeds the diagnostics spine (pipeline events, raw speaker frames, system
/// load), and on stop drains the engines' final passes before archiving the audio and
/// persisting a session.
///
/// It knows only the protocols and the mocks, so the real WhisperKit + Sortformer engines
/// replace the injected instances with no change here or in any view.
@MainActor
@Observable
public final class RecordingController {

    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case room, meeting
        public var id: String { rawValue }
        public var title: String {
            switch self { case .room: "Room"; case .meeting: "Meeting" }
        }
        public var systemImage: String {
            switch self { case .room: "mic"; case .meeting: "person.2.wave.2" }
        }
        public var detail: String {
            switch self {
            case .room: "Your mic — your voice and the room."
            case .meeting: "System audio + mic — calls and meetings."
            }
        }
    }

    /// The recording lifecycle. `preparing` carries the live model-provisioning progress so the
    /// Record UI can show "Downloading speech model… 40%"; `finishing` covers the post-stop drain
    /// (the ASR final decode and, for a non-streaming diarizer, the full-buffer pass).
    public enum Phase: Equatable, Sendable {
        case idle
        case preparing(EnginePreparationProgress)
        case recording
        case finishing
    }

    /// A run-ending failure surfaced to the UI as a human sentence (capture failed, ASR model
    /// couldn't be prepared). Identifiable so a view can drive `.alert(item:)` off it.
    public struct RecordingError: Identifiable, Sendable, Equatable {
        public let id = UUID()
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    // Live, observed state.
    public private(set) var phase: Phase = .idle
    /// True only while capture is actively running (not during preparing/finishing).
    public var isRecording: Bool { phase == .recording }
    /// True whenever a run is underway in any phase — the Record surface shows the live layout.
    public var isActive: Bool { phase != .idle }
    public private(set) var isPaused = false
    public private(set) var mode: Mode = .room
    public private(set) var elapsed: TimeInterval = 0
    /// Smoothed input level [0,1] for the meter.
    public private(set) var level: Float = 0
    /// Recent normalized levels for the scrolling waveform (newest last).
    public private(set) var waveform: [Float] = []
    /// The fused live transcript (committed prefix + provisional tail).
    public private(set) var segments: [AttributedSegment] = []
    /// The session id this run diagnoses under (frames land in the inspector keyed by it).
    public private(set) var sessionID = UUID()
    /// The primary diarizer's latest turns — the top track of the inspector's A/B compare.
    public private(set) var liveTurns: [SpeakerTurn] = []
    /// Set when the diarizer couldn't be prepared: the run continues ASR-only and the live UI
    /// shows a "transcribing without speakers" notice.
    public private(set) var diarizationUnavailable = false
    /// The last run-ending error, for the Record surface's banner/alert. Cleared on the next start.
    public private(set) var lastError: RecordingError?

    // Injected contracts.
    private let asr: any AsrEngine
    private let diarizer: any DiarizationEngine
    private let recorder: PipelineRecorder
    private let inspector: InspectorStore
    private let loadSampler: SystemLoadSampler
    private let modelContext: ModelContext
    private let settings: AppSettings
    private let captureFactory: CaptureFactory

    /// How long the finishing phase waits for the engines' final passes to drain before it
    /// force-cancels them. The full-buffer confirm decode of large-v3-turbo can take seconds.
    private let drainTimeout: Duration

    // Run bookkeeping.
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var captureTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var consumerTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var sources: [CaptureSource] = []
    @ObservationIgnored private var diarTrack: AudioTrack = .mixed
    /// When the diarizer is a full-clip backend, its track's samples are buffered here and run
    /// through one `diarize(samples:)` during the finishing phase.
    @ObservationIgnored private var useFullBufferDiar = false
    @ObservationIgnored private var diarBuffer: [Float] = []
    @ObservationIgnored private var latestAsrByTrack: [AudioTrack: AsrUpdate] = [:]
    @ObservationIgnored private var latestTurns: [SpeakerTurn] = []
    @ObservationIgnored private var latestFrames = SpeakerFrameMatrix(activities: [], committedFrameCount: 0)
    @ObservationIgnored private var archive: [Float] = []
    /// Guards the teardown path so simultaneous capture failures tear the run down only once.
    @ObservationIgnored private var isTearingDown = false
    @ObservationIgnored private var startInstant = ContinuousClock.now
    @ObservationIgnored private var accumulatedElapsed: TimeInterval = 0
    @ObservationIgnored private var lastAsrInstant = ContinuousClock.now
    @ObservationIgnored private var lastDiarInstant = ContinuousClock.now

    public init(asr: any AsrEngine,
                diarizer: any DiarizationEngine,
                recorder: PipelineRecorder,
                inspector: InspectorStore,
                loadSampler: SystemLoadSampler,
                modelContext: ModelContext,
                settings: AppSettings,
                captureFactory: @escaping CaptureFactory = RecordingController.mockCaptureFactory,
                drainTimeout: Duration = .seconds(60)) {
        self.asr = asr
        self.diarizer = diarizer
        self.recorder = recorder
        self.inspector = inspector
        self.loadSampler = loadSampler
        self.modelContext = modelContext
        self.settings = settings
        self.captureFactory = captureFactory
        self.drainTimeout = drainTimeout
    }

    /// Read-only view of the mixed archive buffer captured so far — the inspector's diarizer A/B
    /// runs its cross-check pass on these real samples rather than on synthesized audio.
    public var archivedSamples: [Float] { archive }

    /// A capture input: a source and the tracks it will emit. A room mic emits one track;
    /// a meeting source emits two (`.microphone` + `.system`) on one shared clock — chunks
    /// are routed by their own `track` tag, so both shapes flow through the same fan-out.
    public struct CaptureInput {
        public let source: any CaptureSource
        public let tracks: [AudioTrack]
        public init(source: any CaptureSource, tracks: [AudioTrack]) {
            self.source = source
            self.tracks = tracks
        }
    }

    /// Builds the capture inputs for a recording run. The shells inject the real hardware
    /// factory (mic / ScreenCaptureKit); previews and tests keep the mock default.
    public typealias CaptureFactory = @MainActor (Mode, UUID, PipelineRecorder) -> [CaptureInput]

    /// The default factory: deterministic mock sources (previews, tests, engine-less demos).
    public static let mockCaptureFactory: CaptureFactory = { mode, _, _ in
        switch mode {
        case .room:
            [CaptureInput(source: MockCaptureSource(track: .mixed), tracks: [.mixed])]
        case .meeting:
            [CaptureInput(source: MockCaptureSource(track: .microphone), tracks: [.microphone]),
             CaptureInput(source: MockCaptureSource(track: .system), tracks: [.system])]
        }
    }

    // MARK: Lifecycle

    /// Begin a run: reset, enter the preparing phase, and kick off engine preparation + capture.
    /// Synchronous entry (a Button/menu action); the async work runs on `startTask`.
    public func start(mode: Mode) {
        guard phase == .idle else { return }
        reset(mode: mode)
        phase = .preparing(EnginePreparationProgress(phase: "Preparing engines…", fraction: nil))
        startTask = Task { [weak self] in await self?.runStart(mode: mode) }
    }

    /// Prepare the engines (with progress), then, if ASR is ready, wire capture and go live.
    private func runStart(mode: Mode) async {
        recorder.record(PipelineEvent(sessionID: sessionID, stage: .system,
                                      message: "Preparing engines (\(mode.title))",
                                      metadata: ["mode": mode.rawValue]))

        // ASR is mandatory — a failure to prepare it fails the whole start with a visible error.
        do {
            try await asr.prepare { [weak self] progress in
                Task { @MainActor in self?.reportPreparing(progress) }
            }
        } catch {
            failStart(message: "Couldn't start recording — \(error.localizedDescription)")
            return
        }
        guard phase != .idle else { return }   // stopped/failed while preparing

        // The diarizer is best-effort: if it can't be prepared, record ASR-only and tell the user.
        var diarizerReady = false
        do {
            try await diarizer.prepare { [weak self] progress in
                Task { @MainActor in self?.reportPreparing(progress) }
            }
            diarizerReady = true
        } catch {
            diarizationUnavailable = true
            recorder.record(PipelineEvent(sessionID: sessionID, stage: .system, level: .warning,
                                          message: "Diarizer unavailable — transcribing without speakers",
                                          metadata: ["error": error.localizedDescription]))
        }
        guard phase != .idle else { return }

        beginCapture(mode: mode, diarizerReady: diarizerReady)
    }

    /// Wire the capture fan-out, the ASR/diarizer consumers, and the clock, then flip to recording.
    private func beginCapture(mode: Mode, diarizerReady: Bool) {
        isPaused = false
        startInstant = .now
        lastAsrInstant = .now
        lastDiarInstant = .now
        phase = .recording
        loadSampler.start()
        recorder.record(PipelineEvent(sessionID: sessionID, stage: .capture,
                                      message: "Recording started (\(mode.title))",
                                      metadata: ["mode": mode.rawValue]))

        let inputs = captureFactory(mode, sessionID, recorder)
        sources = inputs.map(\.source)
        let allTracks = inputs.flatMap(\.tracks)
        // The diarizer runs on the first non-mic track (mixed in room, system in meeting).
        diarTrack = allTracks.first { $0 != .microphone } ?? allTracks[0]

        let streamingDiar = diarizerReady && diarizer.supportsStreaming
        useFullBufferDiar = diarizerReady && !diarizer.supportsStreaming

        // Per-track derived streams for the ASR engine, plus one for the diarizer.
        var asrStreams: [(AudioTrack, AsyncThrowingStream<AudioChunk, Error>)] = []
        var asrConts: [AudioTrack: AsyncThrowingStream<AudioChunk, Error>.Continuation] = [:]
        for track in allTracks {
            let (stream, cont) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
            asrStreams.append((track, stream))
            asrConts[track] = cont
        }
        var diarStream: AsyncThrowingStream<AudioChunk, Error>?
        var diarCont: AsyncThrowingStream<AudioChunk, Error>.Continuation?
        if streamingDiar {
            let (stream, cont) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
            diarStream = stream
            diarCont = cont
        }

        // Fan-out: consume each capture source once, routing every chunk by its own track tag
        // (a meeting source emits two tracks on one stream) into ASR (+ the diarizer for its
        // track, streaming or buffered), the meter/waveform, and the archive buffer.
        let asrRouting = asrConts
        let diarSink = diarCont
        let diarTrack = self.diarTrack
        for input in inputs {
            let source = input.source
            let ownedTracks = input.tracks
            let feedsDiarSource = ownedTracks.contains(diarTrack)
            let task = Task { [weak self] in
                do {
                    try await source.start()
                    for try await chunk in source.chunks {
                        guard let self else { break }
                        await self.waitWhilePaused()
                        self.ingest(chunk: chunk)
                        asrRouting[chunk.track]?.yield(chunk)
                        if chunk.track == diarTrack {
                            if let diarSink {
                                diarSink.yield(chunk)
                            } else {
                                self.accumulateDiar(chunk)
                            }
                        }
                    }
                } catch {
                    self?.handleCaptureFailure(error)
                }
                for track in ownedTracks { asrRouting[track]?.finish() }
                if feedsDiarSource { diarSink?.finish() }
            }
            captureTasks.append(task)
        }

        // Consume each ASR update stream.
        for (track, stream) in asrStreams {
            let updates = asr.stream(chunks: stream)
            let task = Task { [weak self] in
                do {
                    for try await update in updates {
                        guard let self else { break }
                        self.apply(asr: update, track: track)
                    }
                } catch { /* stream ended */ }
            }
            consumerTasks.append(task)
        }

        // Consume the diarizer update stream (streaming backends only).
        if let diarStream {
            let updates = diarizer.stream(chunks: diarStream)
            let task = Task { [weak self] in
                do {
                    for try await update in updates {
                        guard let self else { break }
                        self.apply(diar: update)
                    }
                } catch { /* stream ended */ }
            }
            consumerTasks.append(task)
        }

        // Elapsed clock.
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.isRecording else { return }
                if !self.isPaused { self.tickElapsed() }
                self.decayLevelIfIdle()
            }
        }
    }

    /// Update the preparing progress the UI shows — ignored once we've left the preparing phase.
    private func reportPreparing(_ progress: EnginePreparationProgress) {
        guard case .preparing = phase else { return }
        phase = .preparing(progress)
    }

    /// ASR preparation failed: surface the error and return to idle without starting capture.
    private func failStart(message: String) {
        loadSampler.stop()
        phase = .idle
        lastError = RecordingError(message)
        recorder.record(PipelineEvent(sessionID: sessionID, stage: .system, level: .error,
                                      message: "Recording start failed", metadata: ["error": message]))
    }

    /// Dismiss the surfaced run-ending error (from the Record surface's alert).
    public func clearError() { lastError = nil }

    public func pause() {
        guard isRecording, !isPaused else { return }
        accumulatedElapsed += seconds(ContinuousClock.now - startInstant)
        isPaused = true
        recorder.record(PipelineEvent(sessionID: sessionID, stage: .capture, message: "Paused"))
    }

    public func resume() {
        guard isRecording, isPaused else { return }
        startInstant = .now
        isPaused = false
        recorder.record(PipelineEvent(sessionID: sessionID, stage: .capture, message: "Resumed"))
    }

    /// Stop, drain the engines' final passes, archive the audio, persist the session, and return
    /// its id (nil if nothing captured). Enters the `finishing` phase for the duration of the drain.
    @discardableResult
    public func stop() async -> UUID? {
        guard phase == .recording else { return nil }
        isTearingDown = true
        phase = .finishing
        isPaused = false
        clockTask?.cancel(); clockTask = nil

        // Stop sources: their `chunks` streams finish, which finishes the ASR/diar input streams,
        // which lets the consumer tasks emit their final committed state and complete naturally.
        for source in sources { await source.stop() }

        let drained = await drainConsumers(timeout: drainTimeout)
        if !drained {
            recorder.record(PipelineEvent(sessionID: sessionID, stage: .system, level: .warning,
                                          message: "Finishing timed out — cancelling engine tasks"))
            for task in captureTasks { task.cancel() }
            for task in consumerTasks { task.cancel() }
        }

        // Non-streaming diarizer: one full-buffer pass over the diar track, then re-fuse.
        if useFullBufferDiar { await runFullBufferDiarization() }

        captureTasks.removeAll()
        consumerTasks.removeAll()
        sources.removeAll()
        loadSampler.stop()

        let id = await persist(segments: segments)
        phase = .idle
        isTearingDown = false
        return id
    }

    /// Await the capture + consumer tasks' natural completion, up to `timeout`. Returns true if
    /// they drained on their own; false if the timeout fired first (caller then cancels them).
    private func drainConsumers(timeout: Duration) async -> Bool {
        let pending = captureTasks + consumerTasks
        guard !pending.isEmpty else { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for task in pending { _ = await task.value }
                return true
            }
            group.addTask {
                do { try await Task.sleep(for: timeout); return false }
                catch { return true }
            }
            let drained = await group.next() ?? true
            group.cancelAll()
            return drained
        }
    }

    /// Run the full-buffer diarizer once over the buffered diar track and re-fuse the transcript.
    private func runFullBufferDiarization() async {
        guard !diarBuffer.isEmpty else { return }
        do {
            let result = try await diarizer.diarize(samples: diarBuffer)
            latestTurns = result.turns
            latestFrames = result.frames
            liveTurns = result.turns
            inspector.setSpeakerFrames(result.frames, for: sessionID)
            recorder.record(PipelineEvent(sessionID: sessionID, stage: .diarizeCommit,
                                          message: "Full-buffer diarization",
                                          metadata: ["turns": "\(result.turns.count)"]))
            refuse()
        } catch {
            recorder.record(PipelineEvent(sessionID: sessionID, stage: .diarizeCommit, level: .warning,
                                          message: "Full-buffer diarization failed",
                                          metadata: ["error": error.localizedDescription]))
        }
    }

    /// A capture source failed mid-run (mic permission, SCK stream error): surface it and tear the
    /// run down cleanly. Records the event regardless of phase; only the first live failure stops it.
    private func handleCaptureFailure(_ error: Error) {
        recorder.record(PipelineEvent(sessionID: sessionID, stage: .capture, level: .error,
                                      message: "Capture failed: \(error.localizedDescription)"))
        guard phase == .recording, !isTearingDown else { return }
        isTearingDown = true
        lastError = RecordingError("Recording stopped — \(error.localizedDescription)")
        Task { [weak self] in await self?.teardownAfterFailure() }
    }

    /// Tear down a run that a capture failure ended: stop remaining sources, drain, persist what
    /// was captured. Mirrors `stop()` but is entered from the failure path (which already set the
    /// teardown guard and the error).
    private func teardownAfterFailure() async {
        phase = .finishing
        isPaused = false
        clockTask?.cancel(); clockTask = nil
        for source in sources { await source.stop() }
        let drained = await drainConsumers(timeout: drainTimeout)
        if !drained {
            for task in captureTasks { task.cancel() }
            for task in consumerTasks { task.cancel() }
        }
        if useFullBufferDiar { await runFullBufferDiarization() }
        captureTasks.removeAll()
        consumerTasks.removeAll()
        sources.removeAll()
        loadSampler.stop()
        _ = await persist(segments: segments)
        phase = .idle
        isTearingDown = false
    }

    // MARK: Ingest + fuse

    private func ingest(chunk: AudioChunk) {
        let rms = Self.rms(chunk.samples)
        // Fast attack, slow release ballistics for a natural meter.
        let coefficient = rms > level ? DesignMetrics.levelAttack : DesignMetrics.levelRelease
        level += (rms - level) * coefficient
        waveform.append(min(rms * 3, 1))
        if waveform.count > DesignMetrics.waveformSampleCount * 2 {
            waveform.removeFirst(waveform.count - DesignMetrics.waveformSampleCount * 2)
        }
        // Mix every track into the archive at the chunk's time offset — mic and system
        // share one session clock, so summing yields the full mixed meeting audio.
        mixIntoArchive(chunk)
    }

    private func mixIntoArchive(_ chunk: AudioChunk) {
        let startSample = Int(chunk.startTime * AudioChunk.sampleRate)
        let needed = startSample + chunk.samples.count
        if archive.count < needed { archive.append(contentsOf: repeatElement(0, count: needed - archive.count)) }
        for (offset, sample) in chunk.samples.enumerated() {
            archive[startSample + offset] += sample
        }
    }

    /// Buffer a diar-track chunk (positioned by its session clock) for the full-buffer pass.
    private func accumulateDiar(_ chunk: AudioChunk) {
        let startSample = Int(chunk.startTime * AudioChunk.sampleRate)
        let needed = startSample + chunk.samples.count
        if diarBuffer.count < needed { diarBuffer.append(contentsOf: repeatElement(0, count: needed - diarBuffer.count)) }
        for (offset, sample) in chunk.samples.enumerated() {
            diarBuffer[startSample + offset] = sample
        }
    }

    private func apply(asr update: AsrUpdate, track: AudioTrack) {
        let interval = seconds(ContinuousClock.now - lastAsrInstant)
        lastAsrInstant = .now
        latestAsrByTrack[track] = update
        recorder.record(PipelineEvent(sessionID: sessionID, stage: .asr, level: .debug,
                                      message: "ASR update (\(track.rawValue))",
                                      duration: interval,
                                      metadata: ["confirmed": "\(update.confirmed.count)",
                                                 "unconfirmed": "\(update.unconfirmed.count)"]))
        refuse()
    }

    private func apply(diar update: DiarizationUpdate) {
        let interval = seconds(ContinuousClock.now - lastDiarInstant)
        lastDiarInstant = .now
        let committedAdvanced = update.frames.committedFrameCount > latestFrames.committedFrameCount
        latestTurns = update.turns
        latestFrames = update.frames
        liveTurns = update.turns
        inspector.setSpeakerFrames(update.frames, for: sessionID)
        recorder.record(PipelineEvent(sessionID: sessionID,
                                      stage: committedAdvanced ? .diarizeCommit : .diarizePreview,
                                      level: .debug,
                                      message: committedAdvanced ? "Committed chunk" : "Preview pass",
                                      duration: interval,
                                      metadata: ["frames": "\(update.frames.activities.count)",
                                                 "turns": "\(update.turns.count)"]))
        refuse()
    }

    /// Re-fuse the merged ASR segments across tracks with the latest diarized turns.
    private func refuse() {
        let merged = latestAsrByTrack.values.flatMap { $0.confirmed + $0.unconfirmed }
            .sorted { $0.start < $1.start }
        let fused = TranscriptFuser.attribute(asr: merged, turns: latestTurns, micIsMe: mode == .meeting)
        segments = fused
        recorder.record(PipelineEvent(sessionID: sessionID, stage: .fusion, level: .debug,
                                      message: "Fused transcript",
                                      metadata: ["segments": "\(fused.count)"]))
    }

    // MARK: Persistence

    private func persist(segments: [AttributedSegment]) async -> UUID? {
        guard !segments.isEmpty else { return nil }
        let kind: SessionKind = mode == .meeting ? .meetingRecording : .roomRecording
        let session = TranscriptSession(title: Self.defaultTitle(for: mode), kind: kind)
        session.id = sessionID
        session.status = .complete
        session.duration = elapsed
        session.fullText = segments.map(\.asr.text).joined(separator: " ")

        // Archive the mixed audio so the session is re-playable / re-runnable.
        let fileName = "\(sessionID.uuidString).wav"
        let samples = archive.isEmpty
            ? AudioFileIO.synthesize(turns: latestTurns.map { ($0.start, $0.end, $0.speakerIndex) },
                                     totalDuration: elapsed)
            : archive
        if let saved = try? AudioFileIO.writeWAV(samples: samples, fileName: fileName) {
            session.audioFileName = saved
        }

        for attributed in segments {
            let stored = StoredSegment(from: attributed)
            stored.session = session
            session.segments?.append(stored)
        }
        modelContext.insert(session)
        recorder.record(PipelineEvent(sessionID: sessionID, stage: .persistence,
                                      message: "Session saved",
                                      metadata: ["segments": "\(segments.count)"]))
        try? modelContext.save()
        TranscriptSpotlightIndex.index(session)
        return sessionID
    }

    // MARK: Helpers

    private func reset(mode: Mode) {
        self.mode = mode
        sessionID = UUID()
        elapsed = 0
        accumulatedElapsed = 0
        level = 0
        waveform = []
        segments = []
        liveTurns = []
        latestAsrByTrack = [:]
        latestTurns = []
        latestFrames = SpeakerFrameMatrix(activities: [], committedFrameCount: 0)
        archive = []
        diarBuffer = []
        diarTrack = .mixed
        useFullBufferDiar = false
        diarizationUnavailable = false
        lastError = nil
        isTearingDown = false
    }

    private func tickElapsed() {
        elapsed = accumulatedElapsed + seconds(ContinuousClock.now - startInstant)
    }

    private func decayLevelIfIdle() {
        if isPaused { level += (0 - level) * DesignMetrics.levelRelease }
    }

    private func waitWhilePaused() async {
        while isPaused && isRecording {
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumSquares / Float(samples.count)).squareRoot()
    }

    private static func defaultTitle(for mode: Mode) -> String {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        return "\(mode.title) recording · \(stamp)"
    }
}

/// `Duration → seconds` for the pipeline's `TimeInterval` fields.
func seconds(_ duration: Duration) -> TimeInterval {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
