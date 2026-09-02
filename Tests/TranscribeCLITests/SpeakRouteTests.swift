// `POST /speak` over a real socket. Each test gets its own server on its own ephemeral port
// (`ServeTestSupport`), driven by `MockTtsEngine`, so nothing here needs a model on disk.

import Foundation
import Testing
@testable import transcribe_cli

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

/// Readiness and the catch-all, which every client hits before anything else.
@Suite("Serve routes")
struct ServeRouteTests {
    @Test func healthAndRootAnswerOk() async throws {
        let base = try await startTestServer()
        for path in ["", "health"] {
            let reply = try await get(base, path)
            #expect(reply.status == 200)
            #expect(reply.text == "ok")
            #expect(reply.contentType == "text/plain")
        }
    }

    @Test func anUnknownRouteIs404() async throws {
        let reply = try await get(try await startTestServer(), "no/such/route")
        #expect(reply.status == 404)
        #expect(reply.json?["error"] as? String == "not found")
    }
}
