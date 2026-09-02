// The streamed `/speak` body — chunked transfer, the sentinel WAV header, and the three
// behaviors a body-level test can't see: audio arriving *before* synthesis finishes (proven
// with a gated engine, not a timer), a mid-stream failure aborting the transfer without the
// terminal chunk, and a vanished client cancelling the synthesis. The high-level URLSession
// tests in `SpeakRouteTests` keep pinning the decoded-body contract; these read the raw wire.

import Foundation
import Synchronization
import Testing
@testable import transcribe_cli
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Engines

/// Streams one chunk immediately, then holds the rest until the test releases the gate — the
/// deterministic proof that the route sends audio while synthesis is still running.
private final class GatedTtsEngine: TtsEngine, @unchecked Sendable {
    let firstChunk: [Float] = Array(repeating: 0.25, count: 4_800)
    let secondChunk: [Float] = Array(repeating: -0.25, count: 4_800)
    private let released = Mutex(false)

    func release() { released.withLock { $0 = true } }

    nonisolated func validate(text: String, voice: String?, language: String?) throws {}
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {}
    func synthesize(text: String, voice: String?, language: String?) async throws -> SynthesizedSpeech {
        SynthesizedSpeech(samples: firstChunk + secondChunk, sampleRate: 24_000)
    }

    func synthesizeStreaming(text: String, voice: String?, language: String?,
                             onChunk: @escaping @Sendable (SynthesizedSpeechChunk) -> Bool) async throws {
        _ = onChunk(SynthesizedSpeechChunk(samples: firstChunk, sampleRate: 24_000))
        while !released.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = onChunk(SynthesizedSpeechChunk(samples: secondChunk, sampleRate: 24_000))
    }
}

/// Streams one chunk, then fails — the mid-stream engine failure whose only remaining error
/// signal is the aborted transfer.
private final class MidStreamFailingEngine: TtsEngine, Sendable {
    nonisolated func validate(text: String, voice: String?, language: String?) throws {}
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {}
    func synthesize(text: String, voice: String?, language: String?) async throws -> SynthesizedSpeech {
        throw TtsEngineError.synthesisFailed("never used")
    }

    func synthesizeStreaming(text: String, voice: String?, language: String?,
                             onChunk: @escaping @Sendable (SynthesizedSpeechChunk) -> Bool) async throws {
        _ = onChunk(SynthesizedSpeechChunk(samples: Array(repeating: 0.1, count: 2_400), sampleRate: 24_000))
        throw TtsEngineError.synthesisFailed("the decoder fell over mid-utterance")
    }
}

/// Streams the first and third sentences of a three-sentence utterance and nothing for the
/// second — the shape the cloning engine now presents when the model can't synthesize a chunk.
private final class ChunkSkippingEngine: TtsEngine, Sendable {
    let first: [Float] = Array(repeating: 0.3, count: 4_800)
    let third: [Float] = Array(repeating: -0.3, count: 2_400)

    nonisolated func validate(text: String, voice: String?, language: String?) throws {}
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {}
    func synthesize(text: String, voice: String?, language: String?) async throws -> SynthesizedSpeech {
        SynthesizedSpeech(samples: first + third, sampleRate: 24_000)
    }

    func synthesizeStreaming(text: String, voice: String?, language: String?,
                             onChunk: @escaping @Sendable (SynthesizedSpeechChunk) -> Bool) async throws {
        _ = onChunk(SynthesizedSpeechChunk(samples: first, sampleRate: 24_000))
        // the second sentence is skipped: no chunk, no error
        _ = onChunk(SynthesizedSpeechChunk(samples: third, sampleRate: 24_000))
    }
}

/// Streams small chunks forever (bounded by a generous cap) until the consumer cancels;
/// records whether the cancellation ever arrived.
private final class EndlessTtsEngine: TtsEngine, Sendable {
    let sawCancel = Mutex(false)

    nonisolated func validate(text: String, voice: String?, language: String?) throws {}
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {}
    func synthesize(text: String, voice: String?, language: String?) async throws -> SynthesizedSpeech {
        SynthesizedSpeech(samples: [0], sampleRate: 24_000)
    }

    func synthesizeStreaming(text: String, voice: String?, language: String?,
                             onChunk: @escaping @Sendable (SynthesizedSpeechChunk) -> Bool) async throws {
        for _ in 0..<2_000 {
            let wanted = onChunk(SynthesizedSpeechChunk(samples: Array(repeating: 0.2, count: 4_800),
                                                        sampleRate: 24_000))
            if !wanted {
                sawCancel.withLock { $0 = true }
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - Raw-wire client

/// A blocking POSIX client that reads the response as raw bytes — chunked framing included —
/// which URLSession would transparently decode away.
private struct RawSpeakClient {
    let fd: Int32

    init(port: UInt16, body: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: body)
        fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(connected == 0)
        // A regression that stops streaming should fail this suite, never hang it.
        var receiveTimeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var request = Data("""
        POST /speak HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Type: application/json\r
        Content-Length: \(data.count)\r
        Connection: close\r
        \r\n
        """.replacingOccurrences(of: "\r\n\n", with: "\r\n").utf8)
        request.append(data)
        _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    }

    /// Block until at least `count` bytes have arrived (fails the test on early EOF).
    func read(atLeast count: Int, into buffer: inout Data) throws {
        var tmp = [UInt8](repeating: 0, count: 65_536)
        while buffer.count < count {
            let n = recv(fd, &tmp, tmp.count, 0)
            try #require(n > 0, "connection closed after \(buffer.count) of \(count) expected bytes")
            buffer.append(contentsOf: tmp[0..<n])
        }
    }

    /// Read everything until the server closes.
    func readToEOF(into buffer: inout Data) {
        var tmp = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = recv(fd, &tmp, tmp.count, 0)
            guard n > 0 else { return }
            buffer.append(contentsOf: tmp[0..<n])
        }
    }

    func close() { _ = Darwin.close(fd) }
}

/// Start a server with the given engine on its own ephemeral port; returns the port once
/// `/health` answers.
private func startServer(engine: any TtsEngine) async throws -> UInt16 {
    let port = try ephemeralPortForStreaming()
    let server = TranscribeServer(
        port: port,
        warm: WarmEngine(idleTimeout: 0, makeEngine: { MockAsrEngine() }),
        diarization: WarmDiarizer(idleTimeout: 0, makeEngine: { MockDiarizationEngine() }),
        speech: WarmTTSEngine(idleTimeout: 600, makeEngine: { engine })
    )
    Thread.detachNewThread { try? server.run() }
    let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
    for _ in 0..<200 {
        if let (_, response) = try? await URLSession.shared.data(from: base.appending(path: "health")),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            return port
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw StreamingHarnessFailure(message: "server never came up on \(port)")
}

private struct StreamingHarnessFailure: Error { let message: String }

private func ephemeralPortForStreaming() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)
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
    try #require(bound == 0)
    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &assigned) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return UInt16(bigEndian: assigned.sin_port)
}

// MARK: - Tests

@Suite("POST /speak — chunked streaming")
struct SpeakStreamingTests {
    /// The wire shape: chunked transfer, no Content-Length, and the sentinel WAV header — with
    /// the decoded PCM matching the engine's samples exactly.
    @Test func responseIsChunkedWithTheSentinelWavHeaderAndExactPcm() async throws {
        let engine = MockTtsEngine()
        let port = try await startServer(engine: engine)

        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/speak")))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": "Hello streaming world."])
        let (body, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "audio/wav")
        // URLSession consumes the chunked framing and reports the *decoded* transfer
        // ("Identity"); the raw `Transfer-Encoding: chunked` wire shape is pinned by
        // `audioArrivesBeforeSynthesisFinishes` below. What this layer can see is that the
        // response carried no Content-Length.
        #expect(http.value(forHTTPHeaderField: "Content-Length") == nil)

        let expectedSpeech = try await engine.synthesize(text: "Hello streaming world.",
                                                         voice: nil, language: nil)
        #expect(body.prefix(44) == StreamingWav.header(sampleRate: expectedSpeech.sampleRate))
        #expect(body.dropFirst(44) == StreamingWav.pcm16Data(expectedSpeech.samples))
    }

    /// The point of the change: the first audio bytes are on the wire while the engine is
    /// still gated mid-synthesis — no timer, no race; the engine cannot finish until the test
    /// has already read streamed audio.
    @Test func audioArrivesBeforeSynthesisFinishes() async throws {
        let engine = GatedTtsEngine()
        let port = try await startServer(engine: engine)

        let client = try RawSpeakClient(port: port, body: ["text": "Stream me."])
        defer { client.close() }

        // The WAV header plus the first PCM chunk: strictly fewer bytes than the route sends
        // before the gate (head + chunk framing ride on top), so this read can only complete
        // with audio that was streamed while synthesis was still running — if the route
        // buffered until synthesis completed, nothing would arrive and the read would time out.
        var received = Data()
        let firstPcm = StreamingWav.pcm16Data(engine.firstChunk)
        try client.read(atLeast: 44 + firstPcm.count, into: &received)
        let headerEnd = try #require(received.range(of: Data("\r\n\r\n".utf8))).upperBound
        let head = String(decoding: received[..<headerEnd], as: UTF8.self)
        #expect(head.contains("Transfer-Encoding: chunked"))

        engine.release()
        client.readToEOF(into: &received)
        #expect(received.suffix(5) == Data("0\r\n\r\n".utf8))   // terminal chunk: a complete body
        #expect(received.range(of: StreamingWav.pcm16Data(engine.secondChunk)) != nil)
    }

    /// A failure after audio has been sent can't change the 200 anymore — the connection closes
    /// WITHOUT the terminal chunk, so the truncated chunked body is the client's error signal.
    @Test func aMidStreamFailureAbortsTheTransferWithoutTheTerminalChunk() async throws {
        let port = try await startServer(engine: MidStreamFailingEngine())

        let client = try RawSpeakClient(port: port, body: ["text": "Fail partway."])
        defer { client.close() }
        var received = Data()
        client.readToEOF(into: &received)

        #expect(received.range(of: Data("200 OK".utf8)) != nil)      // audio had started
        #expect(received.suffix(5) != Data("0\r\n\r\n".utf8))        // …but never completed
    }

    /// A chunk the engine skipped is not a truncation: the transfer terminates properly and the
    /// decoded body is the surviving chunks back to back, so a client reads a complete WAV
    /// rather than an error.
    @Test func aSkippedChunkStillYieldsACompleteTerminatedBody() async throws {
        let engine = ChunkSkippingEngine()
        let port = try await startServer(engine: engine)

        let client = try RawSpeakClient(port: port, body: ["text": "One. 🫶 Three."])
        var raw = Data()
        client.readToEOF(into: &raw)
        client.close()
        #expect(raw.suffix(5) == Data("0\r\n\r\n".utf8))   // the terminal chunk: a complete body

        // Decoded, the gap left no marker and no silence between the survivors.
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/speak")))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": "One. 🫶 Three."])
        let (body, _) = try await URLSession.shared.data(for: request)
        #expect(body == StreamingWav.header(sampleRate: 24_000)
                + StreamingWav.pcm16Data(engine.first)
                + StreamingWav.pcm16Data(engine.third))
    }

    /// A client that stops listening cancels the synthesis — the engine sees `false` and stops
    /// burning compute on an utterance nobody is receiving.
    @Test func aVanishedClientCancelsTheSynthesis() async throws {
        let engine = EndlessTtsEngine()
        let port = try await startServer(engine: engine)

        let client = try RawSpeakClient(port: port, body: ["text": "Talk until I hang up."])
        var received = Data()
        try client.read(atLeast: 256, into: &received)   // proof the stream started
        client.close()

        for _ in 0..<400 {   // converges as soon as a send hits the closed socket
            if engine.sawCancel.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(engine.sawCancel.withLock { $0 })
    }
}
