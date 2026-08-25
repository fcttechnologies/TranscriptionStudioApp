// `POST /speak` over a real socket, plus the existing routes beside it — the serve API is
// additive by contract (the Jarvis `transcribe` tool runs against the installed copy 24/7), so
// the old shapes are pinned here alongside the new one. Each test gets its own server on its own
// ephemeral port, driven by `MockTtsEngine`, so nothing here needs a model on disk.

import Foundation
import Testing
@testable import transcribe_cli
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Harness

private struct HarnessFailure: Error { let message: String }

/// A `TtsEngine` that fails the way a broken model does — validation passes, synthesis doesn't.
private actor FailingTtsEngine: TtsEngine {
    private let failure: TtsEngineError

    init(failure: TtsEngineError) { self.failure = failure }

    nonisolated func validate(text: String, voice: String?, language: String?) throws {}
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {}
    func synthesize(text: String, voice: String?, language: String?) async throws -> SynthesizedSpeech {
        throw failure
    }
}

/// An unused port, found by binding one and letting go of it.
private func ephemeralPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HarnessFailure(message: "socket() failed") }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw HarnessFailure(message: "bind(0) failed") }
    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &assigned) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard named == 0 else { throw HarnessFailure(message: "getsockname failed") }
    return UInt16(bigEndian: assigned.sin_port)
}

/// Start a server on its own port and wait for it to answer `/health`. The ASR engine is real but
/// never loaded — no test here reaches a route that would load it.
private func startTestServer(speech: WarmTTSEngine) async throws -> URL {
    let port = try ephemeralPort()
    let server = TranscribeServer(
        port: port,
        warm: WarmEngine(modelName: "unused-in-tests", forcedLanguage: nil, idleTimeout: 0),
        speech: speech
    )
    Thread.detachNewThread { try? server.run() }

    let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
    for _ in 0..<200 {
        if let (data, response) = try? await URLSession.shared.data(from: base.appending(path: "health")),
           (response as? HTTPURLResponse)?.statusCode == 200,
           String(decoding: data, as: UTF8.self) == "ok" {
            return base
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw HarnessFailure(message: "test server never came up on port \(port)")
}

private struct Reply {
    let status: Int
    let body: Data
    let contentType: String?

    var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
    var text: String { String(decoding: body, as: UTF8.self) }
}

private func post(_ base: URL, _ path: String, body: Data,
                  contentType: String = "application/json") async throws -> Reply {
    var request = URLRequest(url: base.appending(path: path))
    request.httpMethod = "POST"
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    return Reply(status: http.statusCode, body: data,
                 contentType: http.value(forHTTPHeaderField: "Content-Type"))
}

private func get(_ base: URL, _ path: String) async throws -> Reply {
    let (data, response) = try await URLSession.shared.data(from: base.appending(path: path))
    let http = try #require(response as? HTTPURLResponse)
    return Reply(status: http.statusCode, body: data,
                 contentType: http.value(forHTTPHeaderField: "Content-Type"))
}

private func jsonBody(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

// MARK: - Tests

@Suite("POST /speak")
struct SpeakRouteTests {
    @Test func synthesizesTextIntoAWavBody() async throws {
        let engine = MockTtsEngine()
        let base = try await startTestServer(speech: WarmTTSEngine(idleTimeout: 600, makeEngine: { engine }))

        let reply = try await post(base, "speak", body: try jsonBody(["text": "Hello from the studio."]))

        #expect(reply.status == 200)
        #expect(reply.contentType == "audio/wav")
        #expect(reply.body.prefix(4) == Data("RIFF".utf8))
        #expect(reply.body.count > 44)
        #expect(await engine.prepareCount == 1)
    }

    @Test func takesAVoiceAndALanguage() async throws {
        let base = try await startTestServer(speech: WarmTTSEngine(idleTimeout: 600, makeEngine: { MockTtsEngine() }))

        let reply = try await post(base, "speak", body: try jsonBody([
            "text": "Hello.",
            "voice": MockTtsEngine.supportedVoices[1],
            "language": MockTtsEngine.supportedLanguages[1]
        ]))

        #expect(reply.status == 200)
        #expect(reply.contentType == "audio/wav")
    }

    @Test func longerTextProducesLongerAudio() async throws {
        let base = try await startTestServer(speech: WarmTTSEngine(idleTimeout: 600, makeEngine: { MockTtsEngine() }))

        let short = try await post(base, "speak", body: try jsonBody(["text": "Hi."]))
        let long = try await post(base, "speak", body: try jsonBody([
            "text": "Hi, and then a good deal more speech after that first short greeting."
        ]))

        #expect(short.status == 200)
        #expect(long.status == 200)
        #expect(long.body.count > short.body.count)
    }

    // MARK: failure modes

    @Test func missingTextIs400AndNeverLoadsTheModel() async throws {
        let engine = MockTtsEngine()
        let base = try await startTestServer(speech: WarmTTSEngine(idleTimeout: 600, makeEngine: { engine }))

        let reply = try await post(base, "speak", body: try jsonBody(["voice": "mock"]))

        #expect(reply.status == 400)
        #expect(reply.contentType == "application/json")
        #expect(reply.json?["error"] as? String != nil)
        #expect(await engine.prepareCount == 0)
    }

    @Test func emptyTextIs400() async throws {
        let base = try await startTestServer(speech: WarmTTSEngine(idleTimeout: 600, makeEngine: { MockTtsEngine() }))
        let reply = try await post(base, "speak", body: try jsonBody(["text": "   "]))
        #expect(reply.status == 400)
    }

    @Test func anUnknownVoiceIs400AndNamesTheOnesThatExist() async throws {
        let engine = MockTtsEngine()
        let base = try await startTestServer(speech: WarmTTSEngine(idleTimeout: 600, makeEngine: { engine }))

        let reply = try await post(base, "speak", body: try jsonBody(["text": "Hello.", "voice": "gandalf"]))

        #expect(reply.status == 400)
        let message = try #require(reply.json?["error"] as? String)
        #expect(message.contains("gandalf"))
        #expect(message.contains(MockTtsEngine.supportedVoices[0]))
        #expect(await engine.prepareCount == 0)
    }

    @Test func anUnknownLanguageIs400() async throws {
        let base = try await startTestServer(speech: WarmTTSEngine(idleTimeout: 600, makeEngine: { MockTtsEngine() }))
        let reply = try await post(base, "speak", body: try jsonBody(["text": "Hello.", "language": "klingon"]))
        #expect(reply.status == 400)
        #expect((reply.json?["error"] as? String)?.contains("klingon") == true)
    }

    @Test func aNonJsonBodyIs400() async throws {
        let base = try await startTestServer(speech: WarmTTSEngine(idleTimeout: 600, makeEngine: { MockTtsEngine() }))
        let reply = try await post(base, "speak", body: Data("not json at all".utf8))
        #expect(reply.status == 400)
        #expect(reply.json?["error"] as? String != nil)
    }

    /// An engine failure is the server's, not the caller's — 500, with the reason.
    @Test func anEngineFailureIs500() async throws {
        let warm = WarmTTSEngine(idleTimeout: 600,
                                 makeEngine: { FailingTtsEngine(failure: .synthesisFailed("the model produced no audio")) })
        let base = try await startTestServer(speech: warm)

        let reply = try await post(base, "speak", body: try jsonBody(["text": "Hello."]))

        #expect(reply.status == 500)
        #expect((reply.json?["error"] as? String)?.contains("no audio") == true)
    }

    @Test func aModelThatCantBeDownloadedIs500() async throws {
        let warm = WarmTTSEngine(idleTimeout: 600,
                                 makeEngine: { FailingTtsEngine(failure: .modelDownloadFailed(underlying: "offline")) })
        let base = try await startTestServer(speech: warm)

        let reply = try await post(base, "speak", body: try jsonBody(["text": "Hello."]))

        #expect(reply.status == 500)
        #expect((reply.json?["error"] as? String)?.contains("offline") == true)
    }

    @Test func speakIsPostOnly() async throws {
        let base = try await startTestServer(speech: WarmTTSEngine(idleTimeout: 600, makeEngine: { MockTtsEngine() }))
        let reply = try await get(base, "speak")
        #expect(reply.status == 404)
    }
}

/// The routes the Jarvis `transcribe` tool depends on, pinned unchanged beside the new one.
@Suite("Serve routes — /speak is additive")
struct ExistingRouteTests {
    private func base() async throws -> URL {
        try await startTestServer(speech: WarmTTSEngine(idleTimeout: 600, makeEngine: { MockTtsEngine() }))
    }

    @Test func healthAndRootStillAnswerOk() async throws {
        let base = try await base()
        for path in ["", "health"] {
            let reply = try await get(base, path)
            #expect(reply.status == 200)
            #expect(reply.text == "ok")
            #expect(reply.contentType == "text/plain")
        }
    }

    @Test func anUnknownJobStillReportsTheErrorStateInBand() async throws {
        let reply = try await get(try await base(), "api/jobs/does-not-exist")
        #expect(reply.status == 200)
        #expect(reply.json?["state"] as? String == "error")
        #expect(reply.json?["error"] as? String == "Job not found")
    }

    @Test func startingAJobWithoutAUrlIsStill400() async throws {
        let reply = try await post(try await base(), "api/jobs/start", body: try jsonBody(["nope": 1]))
        #expect(reply.status == 400)
        #expect(reply.json?["error"] as? String == "missing url")
    }

    @Test func fileTranscriptionStillRequiresMultipart() async throws {
        let reply = try await post(try await base(), "api/transcribe/file", body: Data("raw bytes".utf8))
        #expect(reply.status == 400)
        #expect(reply.json?["error"] as? String == "expected multipart file upload")
    }

    @Test func anUnknownRouteIsStill404() async throws {
        let reply = try await get(try await base(), "no/such/route")
        #expect(reply.status == 404)
        #expect(reply.json?["error"] as? String == "not found")
    }
}
