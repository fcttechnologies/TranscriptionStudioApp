// The serve's test harness: a real server on its own ephemeral port, driven by injected
// engines so nothing here needs a model on disk, plus the small HTTP client the route suites
// speak to it with.

import Foundation
import Testing
@testable import transcribe_cli
#if canImport(Darwin)
import Darwin
#endif

struct HarnessFailure: Error { let message: String }

/// An unused port, found by binding one and letting go of it.
func ephemeralPort() throws -> UInt16 {
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

/// Start a server on its own port and wait for it to answer `/health`.
func startTestServer(speech: WarmTTSEngine = WarmTTSEngine(idleTimeout: 600, makeEngine: { MockTtsEngine() }),
                     asr: @escaping @Sendable () -> any AsrEngine = { MockAsrEngine() },
                     diarizer: @escaping @Sendable () -> any DiarizationEngine = { MockDiarizationEngine() })
    async throws -> URL {
    let port = try ephemeralPort()
    let server = TranscribeServer(
        port: port,
        warm: WarmEngine(idleTimeout: 0, makeEngine: asr),
        diarization: WarmDiarizer(idleTimeout: 0, makeEngine: diarizer),
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

struct Reply {
    let status: Int
    let body: Data
    let contentType: String?

    var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
    var text: String { String(decoding: body, as: UTF8.self) }
}

func post(_ base: URL, _ path: String, body: Data,
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

func get(_ base: URL, _ path: String) async throws -> Reply {
    let (data, response) = try await URLSession.shared.data(from: base.appending(path: path))
    let http = try #require(response as? HTTPURLResponse)
    return Reply(status: http.statusCode, body: data,
                 contentType: http.value(forHTTPHeaderField: "Content-Type"))
}

func jsonBody(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

/// A `multipart/form-data` body: one file part, plus any plain fields.
func multipartBody(boundary: String, filename: String, fileBytes: Data,
                   fields: [String: String] = [:]) -> Data {
    var body = Data()
    for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(Data(#"Content-Disposition: form-data; name="file"; filename="\#(filename)""#.utf8))
    body.append(Data("\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
    body.append(fileBytes)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
}

/// Poll a job to a terminal state, the way a client does.
func pollJob(_ base: URL, _ jobID: String) async throws -> [String: Any] {
    for _ in 0..<400 {
        let reply = try await get(base, "jobs/\(jobID)")
        let body = try #require(reply.json)
        if (body["state"] as? String) != "running" { return body }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw HarnessFailure(message: "job \(jobID) never reached a terminal state")
}
