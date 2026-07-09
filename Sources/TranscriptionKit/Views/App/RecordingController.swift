import Foundation
import Observation
import SwiftData

/// Drives a live recording end to end against the engine contracts: it fans one (or two, in
/// meeting mode) capture streams into the ASR and diarization engines, fuses their outputs
/// into an attributed transcript in real time, feeds the diagnostics spine (pipeline events,
/// raw speaker frames, system load), and on stop archives the audio and persists a session.
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

    // Live, observed state.
    public private(set) var isRecording = false
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

    // Injected contracts.
    private let asr: any AsrEngine
    private let diarizer: any DiarizationEngine
    private let recorder: PipelineRecorder
    private let inspector: InspectorStore
    private let loadSampler: SystemLoadSampler
    private let modelContext: ModelContext
    private let settings: AppSettings

    // Run bookkeeping.
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var sources: [CaptureSource] = []
    @ObservationIgnored private var latestAsrByTrack: [AudioTrack: AsrUpdate] = [:]
    @ObservationIgnored private var latestTurns: [SpeakerTurn] = []
    @ObservationIgnored private var latestFrames = SpeakerFrameMatrix(activities: [], committedFrameCount: 0)
    @ObservationIgnored private var archive: [Float] = []
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
                settings: AppSettings) {
        self.asr = asr
        self.diarizer = diarizer
        self.recorder = recorder
        self.inspector = inspector
        self.loadSampler = loadSampler
        self.modelContext = modelContext
        self.settings = settings
    }

    /// A capture input: its source and the track it carries.
    private struct Input { let source: CaptureSource; let track: AudioTrack }

    /// The tracks a mode records. Meeting separates the local mic ("Me") from system audio.
    private func inputs(for mode: Mode) -> [Input] {
        switch mode {
        case .room:
            [Input(source: MockCaptureSource(track: .mixed), track: .mixed)]
        case .meeting:
            [Input(source: MockCaptureSource(track: .microphone), track: .microphone),
             Input(source: MockCaptureSource(track: .system), track: .system)]
        }
    }

    // MARK: Lifecycle

    public func start(mode: Mode) {
        guard !isRecording else { return }
        reset(mode: mode)
        isRecording = true
        isPaused = false
        startInstant = .now
        lastAsrInstant = .now
        lastDiarInstant = .now
        loadSampler.start()
        recorder.record(PipelineEvent(sessionID: sessionID, stage: .capture,
                                      message: "Recording started (\(mode.title))",
                                      metadata: ["mode": mode.rawValue]))

        let inputs = inputs(for: mode)
        sources = inputs.map(\.source)
        // The diarizer runs on the first non-mic track (mixed in room, system in meeting).
        let diarTrack = inputs.first { $0.track != .microphone }?.track ?? inputs[0].track

        // Per-track derived streams for the ASR engine, plus one for the diarizer.
        var asrStreams: [(AudioTrack, AsyncThrowingStream<AudioChunk, Error>)] = []
        var diarStream: AsyncThrowingStream<AudioChunk, Error>?
        var asrConts: [AudioTrack: AsyncThrowingStream<AudioChunk, Error>.Continuation] = [:]
        var diarCont: AsyncThrowingStream<AudioChunk, Error>.Continuation?

        for input in inputs {
            let (stream, cont) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
            asrStreams.append((input.track, stream))
            asrConts[input.track] = cont
        }
        do {
            let (stream, cont) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
            diarStream = stream
            diarCont = cont
        }

        // Fan-out: consume each capture source once, feed ASR (+ diarizer for its track),
        // meter, waveform, and the archive buffer.
        for input in inputs {
            let source = input.source
            let track = input.track
            let asrCont = asrConts[track]
            let feedsDiar = (track == diarTrack)
            let task = Task { [weak self] in
                do {
                    try await source.start()
                    for try await chunk in source.chunks {
                        guard let self else { break }
                        await self.waitWhilePaused()
                        self.ingest(chunk: chunk, feedsDiar: feedsDiar)
                        asrCont?.yield(chunk)
                        if feedsDiar { diarCont?.yield(chunk) }
                    }
                } catch {
                    self?.recorder.record(PipelineEvent(sessionID: self?.sessionID,
                                                        stage: .capture, level: .error,
                                                        message: "Capture failed: \(error.localizedDescription)"))
                }
                asrCont?.finish()
                if feedsDiar { diarCont?.finish() }
            }
            tasks.append(task)
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
            tasks.append(task)
        }

        // Consume the diarizer update stream.
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
            tasks.append(task)
        }

        // Elapsed clock.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.isRecording else { return }
                if !self.isPaused { self.tickElapsed() }
                self.decayLevelIfIdle()
            }
        })
    }

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

    /// Stop, archive the audio, persist the session, and return its id (nil if nothing captured).
    @discardableResult
    public func stop() async -> UUID? {
        guard isRecording else { return nil }
        isRecording = false
        isPaused = false
        for source in sources { await source.stop() }
        for task in tasks { task.cancel() }
        // Give the engine streams a beat to emit their final committed state.
        try? await Task.sleep(for: .milliseconds(250))
        tasks.removeAll()
        sources.removeAll()
        loadSampler.stop()

        let finalSegments = segments
        let id = await persist(segments: finalSegments)
        return id
    }

    // MARK: Ingest + fuse

    private func ingest(chunk: AudioChunk, feedsDiar: Bool) {
        let rms = Self.rms(chunk.samples)
        // Fast attack, slow release ballistics for a natural meter.
        let coefficient = rms > level ? DesignMetrics.levelAttack : DesignMetrics.levelRelease
        level += (rms - level) * coefficient
        waveform.append(min(rms * 3, 1))
        if waveform.count > DesignMetrics.waveformSampleCount * 2 {
            waveform.removeFirst(waveform.count - DesignMetrics.waveformSampleCount * 2)
        }
        // Mix into the archive buffer at the chunk's time offset.
        if feedsDiar || sources.count == 1 {
            mixIntoArchive(chunk)
        }
    }

    private func mixIntoArchive(_ chunk: AudioChunk) {
        let startSample = Int(chunk.startTime * AudioChunk.sampleRate)
        let needed = startSample + chunk.samples.count
        if archive.count < needed { archive.append(contentsOf: repeatElement(0, count: needed - archive.count)) }
        for (offset, sample) in chunk.samples.enumerated() {
            archive[startSample + offset] += sample
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
        latestAsrByTrack = [:]
        latestTurns = []
        latestFrames = SpeakerFrameMatrix(activities: [], committedFrameCount: 0)
        archive = []
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
