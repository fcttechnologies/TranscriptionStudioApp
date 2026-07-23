import Foundation
import TranscriptionKit
import TranscriptionMacKit
#if canImport(Darwin)
import Darwin
#endif

/// `transcribe-cli --serve` — a native, on-device transcription HTTP service that is a drop-in
/// replacement for the old FastAPI Transcription Studio server on the same `:8000` API. It holds
/// one warm WhisperKit engine (same on-demand / warm / eager model lifecycle the old app had) so
/// repeat calls skip the per-process model load, and it serves the exact three endpoints the
/// Jarvis `transcribe` tool's "service" engine calls — so retiring the old app is just swapping
/// which binary the LaunchAgent runs; no client change.
///
/// Endpoints (matching the old app byte-for-byte where the tool reads):
///   POST /api/jobs/start        {url}            -> {job_id, message}   (async URL job)
///   GET  /api/jobs/{job_id}                       -> job record (transcript + timestamped segments)
///   POST /api/transcribe/file   multipart file    -> {job_id, transcript, segments, filename}
///   GET  /            or /health                   -> 200 "ok"           (readiness)
///
/// Blocking POSIX sockets, thread-per-connection: a local single-user service has trivial
/// concurrency, and a blocking accept/recv/send loop is far easier to get correct than an async
/// buffering state machine. The async engine/ingest are bridged from each connection thread with
/// a semaphore (`runBlocking`).

// MARK: - Warm engine (model lifecycle)

/// Holds the WhisperKit engine across requests. Lazy-loads on first use, releases after
/// `idleTimeout` seconds idle (0 = never release — the "warm"/"eager" modes), reloads on demand.
/// An actor so concurrent connection threads can't race the load/release.
actor WarmEngine {
    private let modelName: String
    private let forcedLanguage: String?
    private let idleTimeout: TimeInterval
    private var engine: WhisperKitAsrEngine?
    private var lastUsed = Date()

    init(modelName: String, forcedLanguage: String?, idleTimeout: TimeInterval) {
        self.modelName = modelName
        self.forcedLanguage = forcedLanguage
        self.idleTimeout = idleTimeout
    }

    /// Load the model if it isn't resident, returning the ready engine. Idempotent.
    @discardableResult
    func ensureLoaded(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void = { _ in }) async throws -> WhisperKitAsrEngine {
        lastUsed = Date()
        if let engine { return engine }
        let e = WhisperKitAsrEngine(modelName: modelName, forcedLanguage: forcedLanguage)
        try await e.prepare(onProgress: onProgress)
        engine = e
        return e
    }

    /// Transcribe a local media file, returning the model's timestamped segments (start/end/text).
    /// Keeping the segments — instead of flattening to one wall of text — is what lets the serve
    /// API expose per-moment timestamps, so a caller can map a transcript to what's on screen at
    /// each moment (the vidframes frame↔transcript fusion). Callers derive the flat transcript via
    /// `[TranscriptSegment].flatText`.
    func transcribeSegments(at url: URL) async throws -> [TranscriptSegment] {
        let samples = try FileIngestService.loadSamples(from: url)
        let e = try await ensureLoaded()
        lastUsed = Date()
        let segments = try await e.transcribe(samples: samples, track: .mixed, wordTimestamps: false)
        return segments.map {
            TranscriptSegment(start: $0.start, end: $0.end,
                              text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Release the model if it's been idle past the timeout (the idle reaper calls this).
    func reapIfIdle() {
        guard idleTimeout > 0, engine != nil else { return }
        if Date().timeIntervalSince(lastUsed) > idleTimeout { engine = nil }
    }
}

// MARK: - Transcript segments

/// One timestamped transcript segment (seconds). The serve API returns these alongside the flat
/// `transcript` so a caller can line words up with a moment (frame↔transcript mapping); mirrors
/// the one-shot CLI's `--json` `segments[]` shape.
struct TranscriptSegment: Sendable {
    let start: Double
    let end: Double
    let text: String
}

extension [TranscriptSegment] {
    /// The flat transcript: trimmed segment texts joined by a single space (each segment is
    /// already trimmed, so no double spaces the raw WhisperKit join would leave).
    var flatText: String {
        map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The JSON-serializable form for a response body.
    var jsonArray: [[String: Any]] {
        map { ["start": $0.start, "end": $0.end, "text": $0.text] }
    }
}

// MARK: - Job store (async URL jobs)

/// One async URL-transcription job's state, matching the fields the `transcribe` tool polls:
/// `state` ("running"/"done"/"error"), `transcript`, `segments`, `error`.
struct JobRecord: Sendable {
    var state: String
    var transcript: String?
    var segments: [TranscriptSegment]?
    var error: String?
    let createdAt: Date
}

/// In-memory job store (resets on restart, exactly like the old app's). An actor for safe
/// concurrent create/finish/get across connection threads and the background job Tasks.
actor JobStore {
    private var jobs: [String: JobRecord] = [:]

    func create(_ id: String) {
        jobs[id] = JobRecord(state: "running", transcript: nil, segments: nil, error: nil, createdAt: Date())
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

// MARK: - HTTP server

final class TranscribeServer: @unchecked Sendable {
    private let port: UInt16
    private let warm: WarmEngine
    private let jobs = JobStore()
    private let downloader = URLIngestService()

    init(port: UInt16, warm: WarmEngine) {
        self.port = port
        self.warm = warm
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

        case ("POST", "/api/jobs/start"):
            handleStartJob(req, fd: fd)

        case ("GET", let path) where path.hasPrefix("/api/jobs/"):
            let jobID = String(path.dropFirst("/api/jobs/".count))
            handleGetJob(jobID, fd: fd)

        case ("POST", "/api/transcribe/file"):
            handleTranscribeFile(req, fd: fd)

        default:
            sendJSON(fd, status: 404, body: ["error": "not found"])
        }
    }

    // MARK: endpoints

    private func handleStartJob(_ req: HTTPRequest, fd: Int32) {
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let url = (obj["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else {
            sendJSON(fd, status: 400, body: ["error": "missing url"])
            return
        }
        let jobID = UUID().uuidString
        runBlocking { await self.jobs.create(jobID) }
        // Detached background job — download + transcribe, then store the terminal result. The
        // client polls GET /api/jobs/{id} to a terminal state (exactly the old app's flow).
        Task.detached { [self] in
            let downloadJobID = UUID()
            do {
                let audioURL = try await downloader.downloadAudio(url: url, jobID: downloadJobID) { _ in }
                let segments = try await warm.transcribeSegments(at: audioURL)
                let text = segments.flatText
                downloader.cleanup(jobID: downloadJobID)
                if text.isEmpty {
                    await jobs.fail(jobID, error: "Transcription produced empty text")
                } else {
                    await jobs.finish(jobID, transcript: text, segments: segments)
                }
            } catch {
                downloader.cleanup(jobID: downloadJobID)
                await jobs.fail(jobID, error: humanError(error))
            }
        }
        sendJSON(fd, status: 200, body: ["job_id": jobID, "message": "Job started"])
    }

    private func handleGetJob(_ jobID: String, fd: Int32) {
        guard let job = runBlocking({ await self.jobs.get(jobID) }) else {
            sendJSON(fd, status: 200, body: ["state": "error", "error": "Job not found"])
            return
        }
        var body: [String: Any] = ["job_id": jobID, "state": job.state]
        body["transcript"] = job.transcript ?? NSNull()
        body["segments"] = job.segments?.jsonArray ?? NSNull()
        body["error"] = job.error ?? NSNull()
        sendJSON(fd, status: 200, body: body)
    }

    private func handleTranscribeFile(_ req: HTTPRequest, fd: Int32) {
        guard let boundary = req.multipartBoundary,
              let part = parseMultipartFile(body: req.body, boundary: boundary) else {
            sendJSON(fd, status: 400, body: ["error": "expected multipart file upload"])
            return
        }
        let jobID = UUID().uuidString
        let ext = safeExtension(for: part.filename)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-serve-\(jobID)\(ext)")
        do {
            try part.data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let segments = try runBlockingThrowing { try await self.warm.transcribeSegments(at: tempURL) }
            sendJSON(fd, status: 200, body: [
                "job_id": jobID, "transcript": segments.flatText, "filename": part.filename,
                "segments": segments.jsonArray,
            ])
        } catch {
            sendJSON(fd, status: 500, body: ["error": humanError(error), "job_id": jobID])
        }
    }
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

// MARK: - Multipart (single file part)

/// Extract the file part from a `multipart/form-data` body: the filename from its
/// Content-Disposition and the raw bytes between the part-header terminator and the closing
/// boundary. Works on raw `Data` throughout (the file bytes are binary, never UTF-8).
func parseMultipartFile(body: Data, boundary: String) -> (filename: String, data: Data)? {
    let dashBoundary = Data("--\(boundary)".utf8)
    guard let firstBoundary = body.range(of: dashBoundary) else { return nil }

    let headerSep = Data("\r\n\r\n".utf8)
    guard let headerEnd = body.range(of: headerSep, in: firstBoundary.upperBound..<body.endIndex) else { return nil }

    let partHeader = String(decoding: body[firstBoundary.upperBound..<headerEnd.lowerBound], as: UTF8.self)
    let filename = extractFilename(from: partHeader) ?? "upload"

    let contentStart = headerEnd.upperBound
    let closingBoundary = Data("\r\n--\(boundary)".utf8)
    guard let closing = body.range(of: closingBoundary, in: contentStart..<body.endIndex) else { return nil }

    return (filename, Data(body[contentStart..<closing.lowerBound]))
}

/// Pull `filename="…"` out of a Content-Disposition header block.
private func extractFilename(from header: String) -> String? {
    guard let marker = header.range(of: "filename=\"") else { return nil }
    let rest = header[marker.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    let name = String(rest[rest.startIndex..<end])
    return name.isEmpty ? nil : name
}

/// A safe file extension for a temp upload: the real one if it's an allowed media type, else a
/// neutral `.audio` (never write a hostile suffix). `allowed` stores bare extensions (no dot).
private func safeExtension(for filename: String) -> String {
    let bare = (filename as NSString).pathExtension.lowercased()
    return SupportedMediaExtensions.allowed.contains(bare) ? ".\(bare)" : ".audio"
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
    out.withUnsafeBytes { raw in
        var sent = 0
        let base = raw.bindMemory(to: UInt8.self).baseAddress!
        while sent < out.count {
            let n = send(fd, base + sent, out.count - sent, 0)
            if n <= 0 { break }
            sent += n
        }
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
