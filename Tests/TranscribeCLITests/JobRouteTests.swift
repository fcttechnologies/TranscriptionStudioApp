// `POST /jobs` and `GET /jobs/{id}` — the one job shape, over a real socket, with stub engines
// so the whole async path (stage → separate → recognize → fuse → store → poll) runs without a
// model on disk. The URL source's own request shape is covered by `JobSourceTests` below, which
// reads it without running yt-dlp.

import Foundation
import Testing
@testable import transcribe_cli

// MARK: - Stub engines

/// Returns fixed segments and remembers the language it was asked to decode with.
private final class StubAsrEngine: AsrEngine, @unchecked Sendable {
    private let segments: [AsrSegment]
    private(set) var lastLanguage: String?

    init(segments: [AsrSegment]) { self.segments = segments }

    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {}

    func transcribe(samples: [Float], track: AudioTrack, wordTimestamps: Bool) async throws -> [AsrSegment] {
        try await transcribe(samples: samples, track: track, wordTimestamps: wordTimestamps, language: nil)
    }

    func transcribe(samples: [Float], track: AudioTrack, wordTimestamps: Bool,
                    language: String?) async throws -> [AsrSegment] {
        lastLanguage = language
        return segments
    }

    func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<AsrUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct StubFailure: LocalizedError {
    let errorDescription: String?
}

private final class FailingAsrEngine: AsrEngine, Sendable {
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {}
    func transcribe(samples: [Float], track: AudioTrack, wordTimestamps: Bool) async throws -> [AsrSegment] {
        throw StubFailure(errorDescription: "the model fell over")
    }
    func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<AsrUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Returns fixed turns, and reports whether it was asked at all.
private final class StubDiarizer: DiarizationEngine, @unchecked Sendable {
    let backendName = "Stub"
    private let turns: [SpeakerTurn]
    private(set) var diarizeCount = 0

    init(turns: [SpeakerTurn]) { self.turns = turns }

    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {}

    func diarize(samples: [Float]) async throws -> DiarizationResult {
        diarizeCount += 1
        return DiarizationResult(turns: turns, frames: SpeakerFrameMatrix(activities: [],
                                                                          committedFrameCount: 0,
                                                                          frameDuration: 0.08))
    }

    func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<DiarizationUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class FailingDiarizer: DiarizationEngine, Sendable {
    let backendName = "Failing"
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        throw StubFailure(errorDescription: "no separation model here")
    }
    func diarize(samples: [Float]) async throws -> DiarizationResult {
        throw StubFailure(errorDescription: "no separation model here")
    }
    func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<DiarizationUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Counts how many engines were built, and takes long enough preparing that every concurrent
/// caller is genuinely inside the load window rather than racing a few bytecodes.
private final class CountingDiarizerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var built = 0

    var buildCount: Int { lock.withLock { built } }

    func make() -> any DiarizationEngine {
        lock.withLock { built += 1 }
        return SlowDiarizer()
    }
}

private final class SlowDiarizer: DiarizationEngine, Sendable {
    let backendName = "Slow"
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        try await Task.sleep(for: .milliseconds(200))
    }
    func diarize(samples: [Float]) async throws -> DiarizationResult {
        DiarizationResult(turns: [], frames: SpeakerFrameMatrix(activities: [],
                                                                committedFrameCount: 0,
                                                                frameDuration: 0.08))
    }
    func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<DiarizationUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

// MARK: - Fixtures

/// Four seconds of real, decodable audio — the upload has to survive `FileIngestService`.
private func mediaBytes(seconds: Double = 4) throws -> Data {
    let count = Int(AudioChunk.sampleRate * seconds)
    let samples = (0..<count).map { Float(sin(Double($0) * 0.05)) * 0.2 }
    return try AudioFileIO.encodeAAC(samples: samples)
}

private func asr(_ start: Double, _ end: Double, _ text: String) -> AsrSegment {
    AsrSegment(track: .mixed, start: start, end: end, text: text)
}

private func turn(_ speaker: Int, _ start: Double, _ end: Double) -> SpeakerTurn {
    SpeakerTurn(speakerIndex: speaker, start: start, end: end, confidence: 0.9)
}

private let boundary = "----TranscribeCLITestBoundary"

private func upload(_ base: URL, filename: String = "clip.m4a", bytes: Data,
                    fields: [String: String] = [:]) async throws -> Reply {
    try await post(base, "jobs",
                   body: multipartBody(boundary: boundary, filename: filename,
                                       fileBytes: bytes, fields: fields),
                   contentType: "multipart/form-data; boundary=\(boundary)")
}

// MARK: - Tests

@Suite("POST /jobs — uploads")
struct UploadJobTests {

    @Test func anUploadRunsAsAJobAndPollsToDone() async throws {
        let base = try await startTestServer(
            asr: { StubAsrEngine(segments: [asr(0, 2, "Good morning."), asr(2, 4, "Here is the update.")]) },
            diarizer: { StubDiarizer(turns: [turn(0, 0, 4)]) })

        let started = try await upload(base, bytes: try mediaBytes())
        #expect(started.status == 200)
        let jobID = try #require(started.json?["job_id"] as? String)

        let job = try await pollJob(base, jobID)
        #expect(job["state"] as? String == "done")
        #expect(job["transcript"] as? String == "Good morning. Here is the update.")
        #expect(job["error"] is NSNull)
        let segments = try #require(job["segments"] as? [[String: Any]])
        #expect(segments.count == 2)
        #expect(segments.first?["text"] as? String == "Good morning.")
        #expect(segments.first?["start"] as? Double == 0)
    }

    /// The upload's own name is the job's title — a caller naming its saved transcript has
    /// something to name it after. Without the container suffix, so a title means the same
    /// thing here as the one yt-dlp reports for a URL.
    @Test func theUploadsNameIsTheJobsTitle() async throws {
        let base = try await startTestServer(
            asr: { StubAsrEngine(segments: [asr(0, 2, "Hello.")]) },
            diarizer: { StubDiarizer(turns: [turn(0, 0, 2)]) })

        let started = try await upload(base, filename: "board meeting.m4a", bytes: try mediaBytes())
        let job = try await pollJob(base, try #require(started.json?["job_id"] as? String))

        #expect(job["title"] as? String == "board meeting")
    }

    @Test func aNameThatIsNothingButASuffixKeepsIt() {
        #expect(mediaTitle(for: "board meeting.m4a") == "board meeting")
        #expect(mediaTitle(for: "notes.2026.m4a") == "notes.2026")
        #expect(mediaTitle(for: ".m4a") == ".m4a")
        #expect(mediaTitle(for: "upload") == "upload")
    }

    @Test func aSoloClipComesBackWithNoSpeakerLabels() async throws {
        let base = try await startTestServer(
            asr: { StubAsrEngine(segments: [asr(0, 2, "Good morning."), asr(2, 4, "Here is the update.")]) },
            diarizer: { StubDiarizer(turns: [turn(0, 0, 4)]) })

        let started = try await upload(base, bytes: try mediaBytes())
        let job = try await pollJob(base, try #require(started.json?["job_id"] as? String))
        let segments = try #require(job["segments"] as? [[String: Any]])

        #expect(segments.allSatisfy { $0["speaker"] == nil })
        #expect(job["transcript"] as? String == "Good morning. Here is the update.")
    }

    @Test func aMultiVoiceClipLabelsItsSegmentsAndItsTranscript() async throws {
        let base = try await startTestServer(
            asr: { StubAsrEngine(segments: [asr(0, 2, "Good morning."), asr(2, 4, "Happy to be here.")]) },
            diarizer: { StubDiarizer(turns: [turn(0, 0, 2), turn(1, 2, 4)]) })

        let started = try await upload(base, bytes: try mediaBytes())
        let job = try await pollJob(base, try #require(started.json?["job_id"] as? String))
        let segments = try #require(job["segments"] as? [[String: Any]])

        #expect(segments.map { $0["speaker"] as? Int } == [1, 2])
        #expect(job["transcript"] as? String
                == "Speaker 1: Good morning.\nSpeaker 2: Happy to be here.")
    }

    /// Separation runs on every job, so the diarizer is asked even for a clip that turns out to
    /// hold one voice — the result's plainness is a finding, not a skipped step.
    @Test func separationRunsOnEveryJob() async throws {
        let diarizer = StubDiarizer(turns: [turn(0, 0, 4)])
        let base = try await startTestServer(
            asr: { StubAsrEngine(segments: [asr(0, 2, "Good morning.")]) },
            diarizer: { diarizer })

        let started = try await upload(base, bytes: try mediaBytes())
        _ = try await pollJob(base, try #require(started.json?["job_id"] as? String))

        #expect(diarizer.diarizeCount == 1)
    }

    /// A separation model that won't load must not cost the caller a transcript.
    @Test func aFailingDiarizerStillReturnsTheTranscript() async throws {
        let base = try await startTestServer(
            asr: { StubAsrEngine(segments: [asr(0, 2, "Good morning.")]) },
            diarizer: { FailingDiarizer() })

        let started = try await upload(base, bytes: try mediaBytes())
        let job = try await pollJob(base, try #require(started.json?["job_id"] as? String))

        #expect(job["state"] as? String == "done")
        #expect(job["transcript"] as? String == "Good morning.")
        #expect(try #require(job["segments"] as? [[String: Any]]).allSatisfy { $0["speaker"] == nil })
    }

    @Test func aLanguageFieldReachesTheDecoder() async throws {
        let engine = StubAsrEngine(segments: [asr(0, 2, "Buenos días.")])
        let base = try await startTestServer(asr: { engine },
                                             diarizer: { StubDiarizer(turns: [turn(0, 0, 2)]) })

        let started = try await upload(base, bytes: try mediaBytes(), fields: ["language": "es-MX"])
        _ = try await pollJob(base, try #require(started.json?["job_id"] as? String))

        // The tag reaches the engine whole; the route reads its primary subtag.
        #expect(engine.lastLanguage == "es-MX")
    }

    @Test func noLanguageLeavesTheDecoderOnAutoDetect() async throws {
        let engine = StubAsrEngine(segments: [asr(0, 2, "Good morning.")])
        let base = try await startTestServer(asr: { engine },
                                             diarizer: { StubDiarizer(turns: [turn(0, 0, 2)]) })

        let started = try await upload(base, bytes: try mediaBytes())
        _ = try await pollJob(base, try #require(started.json?["job_id"] as? String))

        #expect(engine.lastLanguage == nil)
    }

    // MARK: failures

    @Test func aTranscriptionThatFailsEndsTheJobInErrorWithItsReason() async throws {
        let base = try await startTestServer(asr: { FailingAsrEngine() },
                                             diarizer: { StubDiarizer(turns: []) })

        let started = try await upload(base, bytes: try mediaBytes())
        let job = try await pollJob(base, try #require(started.json?["job_id"] as? String))

        #expect(job["state"] as? String == "error")
        #expect((job["error"] as? String)?.contains("fell over") == true)
    }

    @Test func mediaThatCannotBeDecodedEndsTheJobInError() async throws {
        let base = try await startTestServer(
            asr: { StubAsrEngine(segments: [asr(0, 2, "unreachable")]) },
            diarizer: { StubDiarizer(turns: []) })

        let started = try await upload(base, bytes: Data("not audio at all".utf8))
        let job = try await pollJob(base, try #require(started.json?["job_id"] as? String))

        #expect(job["state"] as? String == "error")
        #expect(job["error"] as? String != nil)
    }

    @Test func aTranscriptWithNoWordsEndsTheJobInError() async throws {
        let base = try await startTestServer(asr: { StubAsrEngine(segments: []) },
                                             diarizer: { StubDiarizer(turns: []) })

        let started = try await upload(base, bytes: try mediaBytes())
        let job = try await pollJob(base, try #require(started.json?["job_id"] as? String))

        #expect(job["state"] as? String == "error")
        #expect((job["error"] as? String)?.contains("empty") == true)
    }

    @Test func aMultipartWithNoFilePartIs400() async throws {
        let base = try await startTestServer()
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Content-Disposition: form-data; name=\"language\"\r\n\r\nes\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))

        let reply = try await post(base, "jobs", body: body,
                                   contentType: "multipart/form-data; boundary=\(boundary)")

        #expect(reply.status == 400)
        #expect((reply.json?["error"] as? String)?.contains("file") == true)
    }

    @Test func theStagedUploadIsRemovedWhenTheJobEnds() async throws {
        let base = try await startTestServer(
            asr: { StubAsrEngine(segments: [asr(0, 2, "Good morning.")]) },
            diarizer: { StubDiarizer(turns: [turn(0, 0, 2)]) })

        let started = try await upload(base, bytes: try mediaBytes())
        let jobID = try #require(started.json?["job_id"] as? String)
        _ = try await pollJob(base, jobID)

        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-serve-\(jobID).m4a")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }
}

@Suite("WarmDiarizer")
struct WarmDiarizerTests {
    /// Two jobs arriving together must not each pay for their own separation model. An actor
    /// suspends at `await`, so the load window is genuinely reentrant — `SlowDiarizer` holds it
    /// open long enough that both callers are inside it, which is what makes this test able to
    /// fail at all.
    @Test func concurrentFirstJobsLoadTheModelOnce() async throws {
        let factory = CountingDiarizerFactory()
        let warm = WarmDiarizer(idleTimeout: 0, makeEngine: { factory.make() })

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try? await warm.ensureLoaded() }
            }
        }

        #expect(factory.buildCount == 1)
    }

    @Test func aLoadThatFailedIsRetriedRatherThanPinned() async throws {
        let warm = WarmDiarizer(idleTimeout: 0, makeEngine: { FailingDiarizer() })

        await #expect(throws: (any Error).self) { try await warm.ensureLoaded() }
        // The turns call swallows the same failure — the job goes on without speakers.
        let turns = await warm.turns(for: [0, 0, 0])
        #expect(turns.isEmpty)
    }
}

@Suite("GET /jobs/{id}")
struct JobPollTests {
    /// Jobs live in memory, so a serve restart mid-poll is exactly when this fires. The poller
    /// asked what became of its job, and it gets that answer in the shape its loop reads.
    @Test func aJobThatDoesNotExistReportsErrorInBand() async throws {
        let reply = try await get(try await startTestServer(), "jobs/does-not-exist")

        #expect(reply.status == 200)
        #expect(reply.json?["state"] as? String == "error")
        #expect(reply.json?["error"] as? String == "job not found")
    }

    @Test func everyFieldIsPresentEvenWhenUnknown() async throws {
        let reply = try await get(try await startTestServer(), "jobs/does-not-exist")
        let body = try #require(reply.json)

        for key in ["state", "title", "transcript", "segments", "error"] {
            #expect(body[key] != nil, "\(key) missing from the poll shape")
        }
    }
}

// MARK: - The request shape

/// `JobSource` read directly, which is how the URL source is covered without running yt-dlp.
@Suite("POST /jobs — the request")
struct JobSourceTests {
    private func request(json object: [String: Any]) throws -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/jobs",
                    headers: ["content-type": "application/json"],
                    body: try JSONSerialization.data(withJSONObject: object))
    }

    @Test func aJsonBodyNamesAUrl() throws {
        let source = try JobSource(request: try request(json: ["source": ["url": "https://example.com/a"]]))
        guard case let .url(url, language) = source else { Issue.record("not a url source"); return }
        #expect(url == "https://example.com/a")
        #expect(language == nil)
    }

    @Test func theLanguageOptionIsKeptAsTheTagThatPicksTheModel() throws {
        for (tag, route) in [("pt-BR", AsrRoute.parakeet), ("ja", .senseVoice(.ja)), ("zh-Hant", .senseVoice(.zh))] {
            let source = try JobSource(request: try request(json: [
                "source": ["url": "https://example.com/a"],
                "options": ["language": tag],
            ]))
            guard case let .url(_, language) = source else { Issue.record("not a url source"); return }
            #expect(language == tag)
            #expect(AsrRoute.route(forTag: tag) == route)
        }
    }

    @Test func autoIsTheSameAsAskingForNothing() throws {
        let source = try JobSource(request: try request(json: [
            "source": ["url": "https://example.com/a"],
            "options": ["language": "auto"],
        ]))
        guard case let .url(_, language) = source else { Issue.record("not a url source"); return }
        #expect(language == nil)
    }

    /// A language neither recognizer covers is refused rather than quietly routed: a caller
    /// that named one would otherwise never learn its hint did nothing.
    @Test func aLanguageNoRecognizerCoversIsRefused() throws {
        #expect(throws: ServeError.self) {
            try JobSource(request: try self.request(json: [
                "source": ["url": "https://example.com/a"],
                "options": ["language": "klingon"],
            ]))
        }
    }

    @Test func aBodyWithNoSourceIsRefused() throws {
        #expect(throws: ServeError.self) {
            try JobSource(request: try self.request(json: ["options": ["language": "en"]]))
        }
    }

    @Test func anEmptyUrlIsRefused() throws {
        #expect(throws: ServeError.self) {
            try JobSource(request: try self.request(json: ["source": ["url": "   "]]))
        }
    }

    @Test func aBodyThatIsNotJsonIsRefused() throws {
        #expect(throws: ServeError.self) {
            try JobSource(request: HTTPRequest(method: "POST", path: "/jobs",
                                               headers: ["content-type": "application/json"],
                                               body: Data("not json".utf8)))
        }
    }
}

// MARK: - Multipart parsing

@Suite("multipart parsing")
struct MultipartTests {
    @Test func partsAreReadByName() {
        let body = multipartBody(boundary: boundary, filename: "clip.m4a",
                                 fileBytes: Data([0x01, 0x02, 0x03]),
                                 fields: ["language": "es"])
        let parts = parseMultipart(body: body, boundary: boundary)

        #expect(parts.count == 2)
        let file = parts.first { $0.name == "file" }
        #expect(file?.filename == "clip.m4a")
        #expect(file?.data == Data([0x01, 0x02, 0x03]))
        #expect(parts.first { $0.name == "language" }?.data == Data("es".utf8))
    }

    /// `filename="…"` ends in `name="…"`, so a naive search reads the filename as the field
    /// name and every part comes back called `clip.m4a`.
    @Test func aFilePartsNameIsNotItsFilename() {
        let body = multipartBody(boundary: boundary, filename: "clip.m4a", fileBytes: Data([0x01]))
        let parts = parseMultipart(body: body, boundary: boundary)

        #expect(parts.map(\.name) == ["file"])
    }

    @Test func binaryBytesSurviveIntact() {
        let bytes = Data((0...255).map { UInt8($0) })
        let body = multipartBody(boundary: boundary, filename: "clip.m4a", fileBytes: bytes)
        let parts = parseMultipart(body: body, boundary: boundary)

        #expect(parts.first?.data == bytes)
    }

    @Test func aBodyWithNoBoundaryYieldsNoParts() {
        #expect(parseMultipart(body: Data("raw bytes".utf8), boundary: boundary).isEmpty)
    }
}
