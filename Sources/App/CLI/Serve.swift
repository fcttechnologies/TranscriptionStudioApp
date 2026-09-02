import Foundation
import OSLog
#if canImport(Darwin)
import Darwin
#endif

/// `transcribe-cli --serve` — a native, on-device transcription and speech HTTP service on
/// localhost. It holds the recognition, diarization and synthesis models warm across requests,
/// each on its own idle clock, so repeat calls skip the per-process model load.
///
/// Endpoints:
///   POST /jobs           JSON  {"source": {"url": …}, "options": {"language": …}}  -> {job_id}
///                        or multipart/form-data: a `file` part carrying the media, plus an
///                        optional `language` field
///   GET  /jobs/{job_id}        -> {state, title, segments, transcript, error}
///   POST /speak          {text, voice?, language?} -> audio/wav (on-device synthesis,
///                        chunked-streamed as it is produced; see `handleSpeak`)
///   GET  /  or  /health        -> 200 "ok"  (readiness)
///
/// Transcription is always one job shape: a URL or an upload starts a job, and the caller polls
/// it to a terminal state. Every job runs the app's own pipeline — ingest, speaker separation,
/// recognition, fusion — so `segments` carry a `speaker` label and `transcript` carries
/// `Speaker N:` prefixes whenever more than one voice was actually distinguished, and a solo
/// clip comes back as plain prose (`ServeTranscript`).
///
/// Blocking POSIX sockets, thread-per-connection: a local single-user service has trivial
/// concurrency, and a blocking accept/recv/send loop is far easier to get correct than an async
/// buffering state machine. The async engine/ingest are bridged from each connection thread with
/// a semaphore (`runBlocking`).

// MARK: - Warm engine (model lifecycle)

/// Holds the recognition engine across requests. Lazy-loads on first use, releases after
/// `idleTimeout` seconds idle (0 = never release — the "warm"/"eager" modes), reloads on demand.
/// An actor so concurrent connection threads can't race the load/release.
///
/// `makeEngine` is the same seam `WarmTTSEngine` carries: this actor names a concrete engine
/// only in that one default argument, so a test can drive the routes without a model on disk.
actor WarmEngine {
    private let idleTimeout: TimeInterval
    private let forcedLanguage: String?
    private let makeEngine: @Sendable () -> any AsrEngine
    private var engine: (any AsrEngine)?
    private var lastUsed = Date()

    init(modelName: String, forcedLanguage: String?, idleTimeout: TimeInterval) {
        self.init(idleTimeout: idleTimeout, forcedLanguage: forcedLanguage) {
            WhisperKitAsrEngine(modelName: modelName, forcedLanguage: forcedLanguage)
        }
    }

    init(idleTimeout: TimeInterval, forcedLanguage: String? = nil,
         makeEngine: @escaping @Sendable () -> any AsrEngine) {
        self.idleTimeout = idleTimeout
        self.forcedLanguage = forcedLanguage
        self.makeEngine = makeEngine
    }

    /// Load the model if it isn't resident, returning the ready engine. Idempotent.
    @discardableResult
    func ensureLoaded(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void = { _ in }) async throws -> any AsrEngine {
        lastUsed = Date()
        if let engine { return engine }
        let e = makeEngine()
        try await e.prepare(onProgress: onProgress)
        engine = e
        return e
    }

    /// Transcribe prepared 16 kHz mono samples, returning the model's timestamped segments.
    /// Keeping the segments — instead of flattening to one wall of text — is what lets the serve
    /// API expose per-moment timestamps and what the speaker fusion attributes against.
    /// `language` is nil for Whisper's own auto-detect.
    func transcribe(samples: [Float], language: String?) async throws -> [AsrSegment] {
        let e = try await ensureLoaded()
        lastUsed = Date()
        return try await e.transcribe(samples: samples, track: .mixed, wordTimestamps: false,
                                      language: language ?? forcedLanguage)
    }

    /// Transcribe prepared 16 kHz mono samples with word timestamps — the cloning engine's
    /// prompt-matching ASR, riding the same warm model (and idle clock) as every transcription.
    func transcribeWithWordTimestamps(samples: [Float]) async throws -> [AsrSegment] {
        let e = try await ensureLoaded()
        lastUsed = Date()
        return try await e.transcribe(samples: samples, track: .mixed, wordTimestamps: true)
    }

    /// Release the model if it's been idle past the timeout (the idle reaper calls this).
    func reapIfIdle() {
        guard idleTimeout > 0, engine != nil else { return }
        if Date().timeIntervalSince(lastUsed) > idleTimeout { engine = nil }
    }
}

// MARK: - Warm diarizer (model lifecycle)

/// Holds the speaker-separation engine across requests, on the same discipline `WarmEngine`
/// holds the ASR one and against its own idle clock — the backend seam picks Sortformer where
/// its model is provisioned and SpeakerKit everywhere else (`DiarizationBackend`).
///
/// Separation is best-effort by contract: `turns(for:)` never throws. A diarizer that can't
/// load, or a pass that fails, yields no turns, and the job still returns its transcript with
/// no speaker labels — the same call the app's own pipeline makes, for the same reason. The
/// failure is logged rather than swallowed silently.
actor WarmDiarizer {
    private let idleTimeout: TimeInterval
    private let makeEngine: @Sendable () -> any DiarizationEngine
    private var engine: (any DiarizationEngine)?
    private var lastUsed = Date()

    init(idleTimeout: TimeInterval,
         makeEngine: @escaping @Sendable () -> any DiarizationEngine = { DiarizationBackend.default.makeEngine() }) {
        self.idleTimeout = idleTimeout
        self.makeEngine = makeEngine
    }

    /// Load the model if it isn't resident, returning the ready engine. Idempotent.
    @discardableResult
    func ensureLoaded() async throws -> any DiarizationEngine {
        lastUsed = Date()
        if let engine { return engine }
        let e = makeEngine()
        try await e.prepare { _ in }
        engine = e
        return e
    }

    /// The diarized speaker turns for a complete 16 kHz mono buffer; empty when separation
    /// was unavailable or failed.
    func turns(for samples: [Float]) async -> [SpeakerTurn] {
        do {
            let e = try await ensureLoaded()
            let result = try await e.diarize(samples: samples)
            lastUsed = Date()
            return result.turns
        } catch {
            Logger.diarization.error(
                "serve: speaker separation unavailable, transcribing without speakers: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Release the model if it's been idle past the timeout (the idle reaper calls this).
    func reapIfIdle() {
        guard idleTimeout > 0, engine != nil else { return }
        if Date().timeIntervalSince(lastUsed) > idleTimeout { engine = nil }
    }
}

// MARK: - Warm TTS engine (model lifecycle)

/// Holds the speech-synthesis engine across requests, on exactly the discipline `WarmEngine`
/// holds the ASR one: lazy-load on first use, release after `idleTimeout` seconds idle, reload
/// on demand, one actor so concurrent connection threads can't race the load/release.
///
/// It keeps its *own* `lastUsed` clock, which is the whole reason the two are separate actors:
/// a service busy transcribing all day never keeps a synthesis model resident, and a service
/// busy speaking never keeps the ASR model resident. Each pays only for what it's used for.
///
/// `makeEngine` is the seam the plan's later cloning engine arrives through — this actor never
/// names a concrete engine except in that one default argument.
actor WarmTTSEngine {
    private let idleTimeout: TimeInterval
    private let makeEngine: @Sendable () -> any TtsEngine
    private var engine: (any TtsEngine)?
    private var lastUsed = Date()

    init(idleTimeout: TimeInterval,
         makeEngine: @escaping @Sendable () -> any TtsEngine = { TTSKitTtsEngine() }) {
        self.idleTimeout = idleTimeout
        self.makeEngine = makeEngine
    }

    /// Whether the model is currently resident (what the idle reaper's effect is measured by).
    var isResident: Bool { engine != nil }

    /// Load the model if it isn't resident, returning the ready engine. Idempotent.
    @discardableResult
    func ensureLoaded(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void = { _ in }) async throws -> any TtsEngine {
        lastUsed = Date()
        if let engine { return engine }
        let e = makeEngine()
        try await e.prepare(onProgress: onProgress)
        engine = e
        return e
    }

    /// Synthesize one utterance, loading the model first if it isn't resident.
    ///
    /// The request is validated *before* the load, against an unloaded engine — validation is
    /// model-free by the seam's contract, so an empty text or a typo'd voice is rejected without
    /// pulling a gigabyte of weights into memory.
    func synthesize(text: String, voice: String?, language: String?) async throws -> SynthesizedSpeech {
        try (engine ?? makeEngine()).validate(text: text, voice: voice, language: language)
        let e = try await ensureLoaded()
        lastUsed = Date()
        return try await e.synthesize(text: text, voice: voice, language: language)
    }

    /// Streaming counterpart of `synthesize` — same validate-before-load discipline, chunks
    /// forwarded as the engine produces them. The idle clock is refreshed again when the run
    /// ends, so a synthesis longer than the idle timeout can't be reaped the moment it finishes.
    func synthesizeStreaming(text: String, voice: String?, language: String?,
                             onChunk: @escaping @Sendable (SynthesizedSpeechChunk) -> Bool) async throws {
        try (engine ?? makeEngine()).validate(text: text, voice: voice, language: language)
        let e = try await ensureLoaded()
        lastUsed = Date()
        defer { lastUsed = Date() }
        try await e.synthesizeStreaming(text: text, voice: voice, language: language, onChunk: onChunk)
    }

    /// Release the model if it's been idle past the timeout (the idle reaper calls this).
    func reapIfIdle() {
        guard idleTimeout > 0, engine != nil else { return }
        if Date().timeIntervalSince(lastUsed) > idleTimeout { engine = nil }
    }
}

// MARK: - Transcript segments

/// One timestamped transcript segment (seconds). The serve API returns these alongside the flat
/// `transcript` so a caller can line words up with a moment (frame↔transcript mapping).
/// `speaker` is a 1-based label matching the `Speaker N:` the transcript renders, and is set
/// only on a job where separation distinguished more than one voice.
struct TranscriptSegment: Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String
    let speaker: Int?

    init(start: Double, end: Double, text: String, speaker: Int? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

extension [TranscriptSegment] {
    /// The flat transcript: trimmed segment texts joined by a single space (each segment is
    /// already trimmed, so no double spaces the raw WhisperKit join would leave).
    var flatText: String {
        map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The JSON-serializable form for a response body.
    var jsonArray: [[String: Any]] {
        map { segment in
            var object: [String: Any] = ["start": segment.start, "end": segment.end, "text": segment.text]
            if let speaker = segment.speaker { object["speaker"] = speaker }
            return object
        }
    }
}

/// Fuses recognition with speaker separation into the shape a job returns.
///
/// Separation always runs, but it only ever shows in the result when it found something to
/// show: labels ride the segments, and the transcript carries `Speaker N:` prefixes, exactly
/// when the fusion distinguished more than one voice. One voice — the ordinary case for a
/// dictation clip or a monologue — reads as plain prose, so nothing pays for a distinction
/// that wasn't made.
enum ServeTranscript {
    /// The rendered result for one job: its segments and its flat transcript.
    static func build(asr: [AsrSegment], turns: [SpeakerTurn]) -> (segments: [TranscriptSegment], transcript: String) {
        let attributed = TranscriptFuser.attribute(asr: asr, turns: turns)
        // The test is what the RESULT would distinguish, not how many speakers the diarizer
        // reported: a turn no segment was attributed to would otherwise put `Speaker 1:` on
        // every line of a clip that reads as one voice.
        var voices: Set<Int> = []
        for segment in attributed {
            if case .speaker(let index) = segment.speaker { voices.insert(index) }
        }
        let labelled = voices.count > 1

        let segments = attributed.map { segment in
            TranscriptSegment(start: segment.asr.start,
                              end: segment.asr.end,
                              text: segment.asr.text.trimmingCharacters(in: .whitespacesAndNewlines),
                              speaker: labelled ? label(for: segment.speaker) : nil)
        }
        return (segments, labelled ? render(attributed) : segments.flatText)
    }

    /// The wire label for a speaker: 1-based, so it reads as the `Speaker N` beside it. An
    /// unattributed segment carries none.
    private static func label(for speaker: SpeakerID) -> Int? {
        if case .speaker(let index) = speaker { return index + 1 }
        return nil
    }

    /// One line per run of consecutive segments sharing a speaker, each named the way the app
    /// names it.
    private static func render(_ attributed: [AttributedSegment]) -> String {
        var lines: [String] = []
        var current: SpeakerID?
        var texts: [String] = []

        func flush() {
            guard let current, !texts.isEmpty else { return }
            lines.append("\(current.displayName): \(texts.joined(separator: " "))")
            texts = []
        }

        for segment in attributed {
            let text = segment.asr.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if segment.speaker != current {
                flush()
                current = segment.speaker
            }
            texts.append(text)
        }
        flush()
        return lines.joined(separator: "\n")
    }
}

// MARK: - Job store (async URL jobs)

/// One transcription job's state — the fields `GET /jobs/{id}` answers with. `title` is the
/// media's own name: an upload's filename, or what yt-dlp reported for a URL, and so it lands
/// partway through a URL job rather than at creation.
struct JobRecord: Sendable {
    var state: String
    var title: String?
    var transcript: String?
    var segments: [TranscriptSegment]?
    var error: String?
    let createdAt: Date
}

/// In-memory job store (jobs do not survive a restart). An actor for safe concurrent
/// create/finish/get across connection threads and the background job Tasks.
actor ServeJobStore {
    private var jobs: [String: JobRecord] = [:]

    func create(_ id: String, title: String? = nil) {
        jobs[id] = JobRecord(state: "running", title: title, transcript: nil, segments: nil,
                             error: nil, createdAt: Date())
    }

    func setTitle(_ id: String, _ title: String) {
        jobs[id]?.title = title
    }

    func finish(_ id: String, transcript: String, segments: [TranscriptSegment]) {
        jobs[id]?.state = "done"
        jobs[id]?.transcript = transcript
        jobs[id]?.segments = segments
    }

    func fail(_ id: String, error: String) {
        jobs[id]?.state = "error"
        jobs[id]?.error = error
    }

    func get(_ id: String) -> JobRecord? { jobs[id] }

    /// Drop terminal jobs older than the retention window so the store can't grow unbounded.
    func prune(retentionSeconds: TimeInterval = 86_400) {
        let now = Date()
        for (id, job) in jobs where job.state != "running"
            && now.timeIntervalSince(job.createdAt) > retentionSeconds {
            jobs[id] = nil
        }
    }
}

// MARK: - Job requests

/// What a `POST /jobs` asked for. The media arrives one of two ways — named as a URL in a JSON
/// body, or carried whole in a multipart upload — and the options apply the same either way.
enum JobSource {
    case url(String, language: String?)
    case upload(filename: String, data: Data, language: String?)

    /// Read the request, or throw the refusal the caller answers 400 with.
    init(request: HTTPRequest) throws {
        if let boundary = request.multipartBoundary {
            let parts = parseMultipart(body: request.body, boundary: boundary)
            guard let file = parts.first(where: { $0.name == "file" }), !file.data.isEmpty else {
                throw ServeError(#"a multipart upload needs a "file" part carrying the media"#)
            }
            let language = parts.first { $0.name == "language" }
                .map { String(decoding: $0.data, as: UTF8.self) }
            self = .upload(filename: file.filename ?? "upload",
                           data: file.data,
                           language: try Self.resolveLanguage(language))
            return
        }

        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            throw ServeError(#"expected a JSON body {"source": {"url": …}} or a multipart upload"#)
        }
        let source = body["source"] as? [String: Any]
        guard let url = (source?["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else {
            throw ServeError(#"no media to transcribe: give "source": {"url": …}, or upload a file"#)
        }
        let options = body["options"] as? [String: Any]
        self = .url(url, language: try Self.resolveLanguage(options?["language"] as? String))
    }

    /// The Whisper language code a job decodes with: nil for auto-detect, which is both the
    /// default and what `"auto"` asks for. Anything else is a BCP-47 tag, and one Whisper has
    /// no language for is refused rather than quietly auto-detected — a caller that named a
    /// language would otherwise never learn its hint did nothing.
    private static func resolveLanguage(_ requested: String?) throws -> String? {
        let tag = (requested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, tag.lowercased() != "auto" else { return nil }
        guard let code = WhisperKitAsrEngine.whisperLanguageCode(forTag: tag) else {
            throw ServeError(#"unknown language "\#(tag)" — use "auto" or a BCP-47 tag (e.g. "es", "pt-BR")"#)
        }
        return code
    }
}

// MARK: - HTTP server

final class TranscribeServer: @unchecked Sendable {
    private let port: UInt16
    private let warm: WarmEngine
    private let diarization: WarmDiarizer
    private let speech: WarmTTSEngine
    private let jobs = ServeJobStore()
    private let downloader = URLIngestService()

    init(port: UInt16, warm: WarmEngine, diarization: WarmDiarizer, speech: WarmTTSEngine) {
        self.port = port
        self.warm = warm
        self.diarization = diarization
        self.speech = speech
    }

    /// Bind localhost:port and accept forever, a detached thread per connection. Throws (exits
    /// the process) only on a bind/listen failure — a per-connection error is contained.
    func run() throws {
        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw ServeError("socket() failed: \(errnoString())") }

        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // localhost only — never the open internet
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(listenFD)
            throw ServeError("bind :\(port) failed: \(errnoString()) (is the port already in use?)")
        }
        guard listen(listenFD, 16) == 0 else {
            close(listenFD)
            throw ServeError("listen failed: \(errnoString())")
        }
        FileHandle.standardError.write(Data("transcribe-cli serve: listening on 127.0.0.1:\(port)\n".utf8))

        while true {
            let conn = accept(listenFD, nil, nil)
            if conn < 0 { continue }
            Thread.detachNewThread { [weak self] in self?.handleConnection(conn) }
        }
    }

    // MARK: connection handling

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }
        // A peer that disconnects mid-response must surface as a failed `send`, never a
        // process-killing SIGPIPE — routine now that /speak streams and a client may stop
        // listening as soon as it has heard enough.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        guard let request = readRequest(fd) else {
            sendJSON(fd, status: 400, body: ["error": "bad request"])
            return
        }
        route(request, fd: fd)
    }

    private func route(_ req: HTTPRequest, fd: Int32) {
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/health"):
            sendText(fd, status: 200, body: "ok")

        case ("POST", "/jobs"):
            handleCreateJob(req, fd: fd)

        case ("GET", let path) where path.hasPrefix("/jobs/"):
            handleGetJob(String(path.dropFirst("/jobs/".count)), fd: fd)

        case ("POST", "/speak"):
            handleSpeak(req, fd: fd)

        default:
            sendJSON(fd, status: 404, body: ["error": "not found"])
        }
    }

    // MARK: endpoints

    /// Start a job from either source and answer with its id. A JSON body names a URL; a
    /// multipart body carries the media itself. Both run the same pipeline and are polled the
    /// same way, so a caller's only fork is how it hands the media over.
    private func handleCreateJob(_ req: HTTPRequest, fd: Int32) {
        let source: JobSource
        do {
            source = try JobSource(request: req)
        } catch {
            sendJSON(fd, status: 400, body: ["error": humanError(error)])
            return
        }

        let jobID = UUID().uuidString
        switch source {
        case let .url(url, language):
            runBlocking { await self.jobs.create(jobID) }
            startURLJob(jobID, url: url, language: language)
        case let .upload(filename, data, language):
            // Staged to disk before the job id goes out: a job that answers `running` and has
            // already lost its media would only report the failure a poll later.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcribe-serve-\(jobID)\(safeExtension(for: filename))")
            do {
                try data.write(to: tempURL)
            } catch {
                sendJSON(fd, status: 500, body: ["error": humanError(error)])
                return
            }
            runBlocking { await self.jobs.create(jobID, title: mediaTitle(for: filename)) }
            startUploadJob(jobID, mediaURL: tempURL, language: language)
        }
        sendJSON(fd, status: 200, body: ["job_id": jobID])
    }

    /// Download the URL's audio, then run the job over it. The media's own title lands as soon
    /// as yt-dlp has reported it, so a poll during a long transcription already names the job.
    private func startURLJob(_ jobID: String, url: String, language: String?) {
        Task.detached { [self] in
            let downloadJobID = UUID()
            defer { downloader.cleanup(jobID: downloadJobID) }
            do {
                let audioURL = try await downloader.downloadAudio(url: url, jobID: downloadJobID) { _ in }
                if let title = URLIngestService.title(forJobID: downloadJobID) {
                    await jobs.setTitle(jobID, title)
                }
                try await run(jobID, mediaURL: audioURL, language: language)
            } catch {
                await jobs.fail(jobID, error: humanError(error))
            }
        }
    }

    /// Run the job over an upload already staged on disk, removing it either way.
    private func startUploadJob(_ jobID: String, mediaURL: URL, language: String?) {
        Task.detached { [self] in
            defer { try? FileManager.default.removeItem(at: mediaURL) }
            do {
                try await run(jobID, mediaURL: mediaURL, language: language)
            } catch {
                await jobs.fail(jobID, error: humanError(error))
            }
        }
    }

    /// The pipeline both sources land in: one decode of the media, separation and recognition
    /// over the same buffer, then fusion. Separation runs on every job and never fails one.
    private func run(_ jobID: String, mediaURL: URL, language: String?) async throws {
        let samples = try FileIngestService.loadSamples(from: mediaURL)
        let turns = await diarization.turns(for: samples)
        let asr = try await warm.transcribe(samples: samples, language: language)
        let (segments, transcript) = ServeTranscript.build(asr: asr, turns: turns)
        if transcript.isEmpty {
            await jobs.fail(jobID, error: "Transcription produced empty text")
        } else {
            await jobs.finish(jobID, transcript: transcript, segments: segments)
        }
    }

    /// A job that no longer exists reports as one that failed rather than as a missing
    /// resource: the poller asked what became of a job, and "it is gone" is the answer, in the
    /// one shape its loop already reads. Jobs live in memory, so a restart mid-poll is exactly
    /// when this fires.
    private func handleGetJob(_ jobID: String, fd: Int32) {
        guard let job = runBlocking({ await self.jobs.get(jobID) }) else {
            sendJSON(fd, status: 200, body: ["state": "error", "title": NSNull(),
                                             "transcript": NSNull(), "segments": NSNull(),
                                             "error": "job not found"])
            return
        }
        sendJSON(fd, status: 200, body: [
            "state": job.state,
            "title": job.title ?? NSNull(),
            "transcript": job.transcript ?? NSNull(),
            "segments": job.segments?.jsonArray ?? NSNull(),
            "error": job.error ?? NSNull(),
        ])
    }

    /// Synthesize speech from text, streaming the audio as it is produced — a chunked
    /// `audio/wav` body whose header carries the unknown-length sentinel (`StreamingWav`), so
    /// a client can start playing before synthesis finishes while a client that just reads to
    /// EOF still ends up with a playable 16-bit mono WAV.
    ///
    /// Nothing is sent until the first audio chunk exists: every failure up to that point —
    /// bad JSON, invalid voice, a model that can't load, an engine that produced nothing —
    /// still answers in the same `{"error": …}` JSON shape every other route uses. A failure
    /// *after* audio has been sent can't change the status line anymore, so the connection is
    /// closed without the terminal chunk and the truncated transfer is the client's error
    /// signal — and is logged here, because that wire signal is the only one the client gets
    /// and it carries no reason. A client that disconnects mid-stream cancels the synthesis.
    private func handleSpeak(_ req: HTTPRequest, fd: Int32) {
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            sendJSON(fd, status: 400, body: ["error": "expected a JSON body: {text, voice?, language?}"])
            return
        }
        let text = obj["text"] as? String ?? ""
        let voice = obj["voice"] as? String
        let language = obj["language"] as? String

        // Producer: the async synthesis, handing chunks across to this blocking connection
        // thread. Buffering is unbounded, which is bounded in practice by the utterance's own
        // total PCM size — exactly what the old complete-body path held in memory anyway.
        let queue = SpeakStreamQueue()
        Task { [speech] in
            do {
                try await speech.synthesizeStreaming(text: text, voice: voice, language: language) { chunk in
                    queue.push(chunk)
                }
                queue.finish(error: nil)
            } catch {
                queue.finish(error: error)
            }
        }

        // Consumer: block for the first event, which decides the status line.
        switch queue.next() {
        case .failed(let error):
            sendJSON(fd, status: speakErrorStatus(error), body: ["error": humanError(error)])
        case .finished:
            // The seam contract makes a no-audio success an engine error before this point;
            // if it ever happens, it's the server's fault, not the caller's.
            sendJSON(fd, status: 500, body: ["error": "synthesis produced no audio"])
        case .chunk(let first):
            guard sendChunkedHead(fd, contentType: "audio/wav"),
                  sendBodyChunk(fd, StreamingWav.header(sampleRate: first.sampleRate)),
                  sendBodyChunk(fd, StreamingWav.pcm16Data(first.samples)) else {
                queue.consumerGone()
                return
            }
            var sent = 1
            while true {
                switch queue.next() {
                case .chunk(let chunk):
                    guard sendBodyChunk(fd, StreamingWav.pcm16Data(chunk.samples)) else {
                        queue.consumerGone()
                        return
                    }
                    sent += 1
                case .finished:
                    sendChunkedEnd(fd)
                    return
                case .failed(let error):
                    // The 200 head is already out, so the truncated transfer stays the client's
                    // error signal — but it names no reason, so this is the only place the
                    // reason exists at all.
                    Logger.tts.error("""
                        /speak failed after \(sent, privacy: .public) chunks had been streamed; \
                        the client sees a truncated transfer: \(humanError(error), privacy: .public)
                        """)
                    return
                }
            }
        }
    }
}

// MARK: - Speak stream hand-off

/// Hands synthesis chunks from the async producer task to the blocking connection thread —
/// a condition-variable queue, the one place the serve's async and blocking worlds meet with
/// data flowing continuously. `consumerGone()` is the back-channel: once the client stops
/// reading, `push` answers `false`, the engine's `onChunk` contract turns that into a
/// cancelled synthesis, and the producer stops burning compute.
final class SpeakStreamQueue: @unchecked Sendable {
    enum Event {
        case chunk(SynthesizedSpeechChunk)
        case finished
        case failed(Error)
    }

    private let condition = NSCondition()
    private var chunks: [SynthesizedSpeechChunk] = []
    private var terminal: Event?   // .finished or .failed, once the producer is done
    private var cancelled = false

    /// Producer side: enqueue a chunk; returns whether the consumer still wants more.
    @discardableResult
    func push(_ chunk: SynthesizedSpeechChunk) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !cancelled else { return false }
        chunks.append(chunk)
        condition.signal()
        return true
    }

    /// Producer side: no more chunks — completed, or failed with `error`.
    func finish(error: Error?) {
        condition.lock()
        defer { condition.unlock() }
        terminal = error.map { .failed($0) } ?? .finished
        condition.signal()
    }

    /// Consumer side: block until the next event. Chunks drain in order before the terminal
    /// event is reported, so a fast producer's tail is never dropped.
    func next() -> Event {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if !chunks.isEmpty { return .chunk(chunks.removeFirst()) }
            if let terminal { return terminal }
            condition.wait()
        }
    }

    /// Consumer side: the client stopped reading — stop accepting chunks so the producer
    /// cancels.
    func consumerGone() {
        condition.lock()
        defer { condition.unlock() }
        cancelled = true
        chunks.removeAll()
    }
}

/// 400 when the request was at fault (nothing to say, an unknown voice or language), 500 when
/// the engine was — the same split the file's other routes make between a client and a server
/// failure.
func speakErrorStatus(_ error: Error) -> Int {
    (error as? TtsEngineError)?.isInvalidRequest == true ? 400 : 500
}

// MARK: - Async → blocking bridge

/// Run an async operation from a blocking socket thread, waiting for its result. The service's
/// per-connection threads are blocking; the engine + ingest are async — this bridges the two.
private func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
        box.value = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

/// Throwing variant — rethrows the async operation's error on the calling (blocking) thread.
private func runBlockingThrowing<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<Result<T, Error>>()
    Task {
        do { box.value = .success(try await operation()) }
        catch { box.value = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.value!.get()
}

private final class ResultBox<T>: @unchecked Sendable { var value: T? }

// MARK: - HTTP request parsing

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// The multipart boundary from `Content-Type: multipart/form-data; boundary=…`, if present.
    var multipartBoundary: String? {
        guard let ctype = headers["content-type"], ctype.contains("multipart/form-data") else { return nil }
        for part in ctype.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("boundary=") {
                var b = String(trimmed.dropFirst("boundary=".count))
                if b.hasPrefix("\"") && b.hasSuffix("\"") && b.count >= 2 { b = String(b.dropFirst().dropLast()) }
                return b
            }
        }
        return nil
    }
}

/// Read one HTTP/1.1 request off the socket: recv until the header terminator (`\r\n\r\n`), parse
/// the request line + headers, then read exactly `Content-Length` more bytes for the body. Returns
/// nil on a malformed request or a closed connection.
private func readRequest(_ fd: Int32) -> HTTPRequest? {
    var buffer = Data()
    let headerTerminator = Data("\r\n\r\n".utf8)
    var headerEndRange: Range<Data.Index>?

    // Read until we have the full header block (bounded so a hostile client can't grow it forever).
    while headerEndRange == nil {
        guard let chunk = recvChunk(fd), !chunk.isEmpty else { return nil }
        buffer.append(chunk)
        headerEndRange = buffer.range(of: headerTerminator)
        if buffer.count > 1_048_576, headerEndRange == nil { return nil }  // 1 MB header cap
    }
    guard let headerEnd = headerEndRange else { return nil }

    let headerText = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
    var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
    guard !lines.isEmpty else { return nil }

    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return nil }
    let method = String(requestLine[0])
    let path = String(requestLine[1])

    var headers: [String: String] = [:]
    for line in lines where !line.isEmpty {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        headers[key] = value
    }

    // Read the body by Content-Length (already have whatever arrived past the header terminator).
    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
    var body = Data(buffer[headerEnd.upperBound...])
    while body.count < contentLength {
        guard let chunk = recvChunk(fd), !chunk.isEmpty else { break }
        body.append(chunk)
    }
    if body.count > contentLength { body = body.prefix(contentLength) }

    return HTTPRequest(method: method, path: path, headers: headers, body: body)
}

/// One `recv` up to 64 KB. Returns nil on error, empty Data on a clean close.
private func recvChunk(_ fd: Int32) -> Data? {
    var tmp = [UInt8](repeating: 0, count: 65_536)
    let n = recv(fd, &tmp, tmp.count, 0)
    if n < 0 { return nil }
    if n == 0 { return Data() }
    return Data(tmp[0..<n])
}

// MARK: - Multipart

/// One `multipart/form-data` part: its form-field name, the filename it declared if it carried
/// one, and its raw bytes.
struct MultipartPart {
    let name: String
    let filename: String?
    let data: Data
}

/// Split a `multipart/form-data` body into its named parts. Works on raw `Data` throughout (a
/// file part's bytes are binary, never UTF-8). A part with no `name` is skipped: it can't be
/// asked for.
func parseMultipart(body: Data, boundary: String) -> [MultipartPart] {
    let delimiter = Data("--\(boundary)".utf8)
    let headerSeparator = Data("\r\n\r\n".utf8)
    let closing = Data("--".utf8)

    guard let first = body.range(of: delimiter) else { return [] }
    var cursor = first.upperBound
    var parts: [MultipartPart] = []

    while cursor < body.endIndex, !body[cursor...].starts(with: closing) {
        guard let headerEnd = body.range(of: headerSeparator, in: cursor..<body.endIndex),
              let next = body.range(of: Data("\r\n--\(boundary)".utf8),
                                    in: headerEnd.upperBound..<body.endIndex) else { return parts }
        let header = String(decoding: body[cursor..<headerEnd.lowerBound], as: UTF8.self)
        if let name = attribute("name", from: header) {
            parts.append(MultipartPart(name: name,
                                       filename: attribute("filename", from: header),
                                       data: Data(body[headerEnd.upperBound..<next.lowerBound])))
        }
        cursor = next.upperBound
    }
    return parts
}

/// Pull a quoted `key="…"` attribute out of a part's header block.
private func attribute(_ key: String, from header: String) -> String? {
    var searchStart = header.startIndex
    while let marker = header.range(of: "\(key)=\"", range: searchStart..<header.endIndex) {
        // `filename="…"` ends in `name="…"`, so a match has to begin an attribute rather than
        // land inside a longer one.
        let previous = marker.lowerBound > header.startIndex
            ? header[header.index(before: marker.lowerBound)] : " "
        if !previous.isLetter, previous != "-" {
            let rest = header[marker.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            let value = String(rest[rest.startIndex..<end])
            return value.isEmpty ? nil : value
        }
        searchStart = marker.upperBound
    }
    return nil
}

/// A safe file extension for a temp upload: the real one if it's an allowed media type, else a
/// neutral `.audio` (never write a hostile suffix). `allowed` stores bare extensions (no dot).
private func safeExtension(for filename: String) -> String {
    let bare = (filename as NSString).pathExtension.lowercased()
    return SupportedMediaExtensions.allowed.contains(bare) ? ".\(bare)" : ".audio"
}

/// An upload's title: the media's own name, which means the filename without its container
/// suffix — a title means the same thing here as the one yt-dlp reports for a URL, and that one
/// never carries `.mp3`. A name that is nothing but a suffix keeps it rather than becoming empty.
func mediaTitle(for filename: String) -> String {
    let stem = (filename as NSString).deletingPathExtension
    return stem.isEmpty ? filename : stem
}

// MARK: - Responses

private func sendJSON(_ fd: Int32, status: Int, body: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    sendResponse(fd, status: status, contentType: "application/json", body: data)
}

private func sendText(_ fd: Int32, status: Int, body: String) {
    sendResponse(fd, status: status, contentType: "text/plain", body: Data(body.utf8))
}

private func sendResponse(_ fd: Int32, status: Int, contentType: String, body: Data) {
    let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : (status == 400 ? "Bad Request" : "Error"))
    let head = "HTTP/1.1 \(status) \(reason)\r\n"
        + "Content-Type: \(contentType)\r\n"
        + "Content-Length: \(body.count)\r\n"
        + "Connection: close\r\n\r\n"
    var out = Data(head.utf8)
    out.append(body)
    _ = sendAll(fd, out)
}

// MARK: Chunked transfer (the streaming /speak body)

/// The 200 head of a chunked response. Returns whether the peer took it.
func sendChunkedHead(_ fd: Int32, contentType: String) -> Bool {
    let head = "HTTP/1.1 200 OK\r\n"
        + "Content-Type: \(contentType)\r\n"
        + "Transfer-Encoding: chunked\r\n"
        + "Connection: close\r\n\r\n"
    return sendAll(fd, Data(head.utf8))
}

/// One chunked-encoding frame: hex size, CRLF, the bytes, CRLF. Empty data is skipped — a
/// zero-length frame IS the terminator, so sending one mid-stream would truncate the body.
func sendBodyChunk(_ fd: Int32, _ data: Data) -> Bool {
    guard !data.isEmpty else { return true }
    var out = Data("\(String(data.count, radix: 16))\r\n".utf8)
    out.append(data)
    out.append(contentsOf: Array("\r\n".utf8))
    return sendAll(fd, out)
}

/// The terminal zero-length chunk that marks a chunked body complete.
func sendChunkedEnd(_ fd: Int32) {
    _ = sendAll(fd, Data("0\r\n\r\n".utf8))
}

/// Send every byte or report failure (the peer closed / stopped reading).
private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        var sent = 0
        let base = raw.bindMemory(to: UInt8.self).baseAddress!
        while sent < data.count {
            let n = send(fd, base + sent, data.count - sent, 0)
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}

// MARK: - Errors

struct ServeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func humanError(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

private func errnoString() -> String { String(cString: strerror(errno)) }
