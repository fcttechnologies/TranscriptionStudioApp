import Foundation
import Testing
@testable import ShareKit

// The pure share-ingest logic: the extension→host URL scheme, the file-vs-url routing
// decision, and the App Group drop-box's stage/drain/remove — all testable without a share
// sheet or a real App Group container (the drop-box takes an injectable container dir).

@Suite("IngestURLScheme — extension→host handoff URL")
struct IngestURLSchemeTests {
    @Test func buildAndParseRoundTrips() {
        let id = UUID()
        let url = IngestURLScheme.ingestURL(id: id)
        #expect(url.scheme == "transcriptionstudio")
        #expect(url.host == "ingest")
        let parsed = IngestURLScheme.parseIngest(url)
        #expect(parsed != nil)
        #expect(parsed?.id == id)
    }

    @Test func rejectsForeignURLs() {
        #expect(IngestURLScheme.parseIngest(URL(string: "https://example.com")!) == nil)
        #expect(IngestURLScheme.parseIngest(URL(string: "transcriptionstudio://other")!) == nil)
        #expect(IngestURLScheme.parseIngest(URL(string: "othersheme://ingest")!) == nil)
    }

    @Test func acceptsIngestPingWithNoID() {
        // The host drains the whole box, so an id-less ping is still a valid trigger.
        let parsed = IngestURLScheme.parseIngest(URL(string: "transcriptionstudio://ingest")!)
        #expect(parsed != nil)
        #expect(parsed?.id == nil)
    }
}

@Suite("SharedItemClassifier — file vs url routing")
struct SharedItemClassifierTests {
    @Test func mediaFilesClassifyAsMediaFile() {
        #expect(SharedItemClassifier.classify(typeIdentifiers: ["public.movie"]) == .mediaFile)
        #expect(SharedItemClassifier.classify(typeIdentifiers: ["public.mpeg-4"]) == .mediaFile)
        #expect(SharedItemClassifier.classify(typeIdentifiers: ["public.audio"]) == .mediaFile)
        #expect(SharedItemClassifier.classify(typeIdentifiers: ["public.mp3"]) == .mediaFile)
        #expect(SharedItemClassifier.classify(typeIdentifiers: ["com.apple.quicktime-movie"]) == .mediaFile)
    }

    @Test func webURLClassifiesAsWebURL() {
        #expect(SharedItemClassifier.classify(typeIdentifiers: ["public.url"]) == .webURL)
    }

    @Test func mediaWinsWhenBothAdvertised() {
        // A shared movie that also advertises a url identifier is still the transcription target.
        #expect(SharedItemClassifier.classify(typeIdentifiers: ["public.url", "public.movie"]) == .mediaFile)
    }

    @Test func plainTextAndImageAreUnsupported() {
        #expect(SharedItemClassifier.classify(typeIdentifiers: ["public.plain-text"]) == .unsupported)
        #expect(SharedItemClassifier.classify(typeIdentifiers: ["public.image"]) == .unsupported)
        #expect(SharedItemClassifier.classify(typeIdentifiers: []) == .unsupported)
    }
}

@Suite("PendingIngest — manifest codability")
struct PendingIngestCodableTests {
    @Test func fileItemRoundTrips() throws {
        let item = PendingIngest(kind: .file, title: "Clip", stagedFilename: "abc.mp4")
        let decoded = try JSONDecoder().decode(PendingIngest.self, from: JSONEncoder().encode(item))
        #expect(decoded == item)
    }

    @Test func urlItemRoundTrips() throws {
        let item = PendingIngest(kind: .url, title: "Link · youtube.com", urlString: "https://youtube.com/x")
        let decoded = try JSONDecoder().decode(PendingIngest.self, from: JSONEncoder().encode(item))
        #expect(decoded == item)
    }
}

@Suite("IngestDropBox — stage / drain / remove")
struct IngestDropBoxTests {
    /// A fresh temp dir standing in for the App Group container.
    private func makeContainer() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropbox-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func stageURLThenDrainReturnsIt() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let staged = try IngestDropBox.stageURL("https://example.com/a", title: "Link · example.com", container: container)
        let drained = IngestDropBox.drain(container: container)
        #expect(drained.count == 1)
        #expect(drained.first == staged)
        #expect(drained.first?.kind == .url)
        #expect(drained.first?.urlString == "https://example.com/a")
    }

    @Test func stageFileCopiesBytesAndDrains() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        // A source "media" file to stage.
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        let payload = Data("audio-bytes".utf8)
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try IngestDropBox.stageFile(from: source, title: "My Clip", container: container)
        #expect(staged.kind == .file)
        #expect(staged.title == "My Clip")
        #expect(staged.stagedFilename?.hasSuffix(".m4a") == true)

        let fileURL = try #require(IngestDropBox.stagedFileURL(for: staged, container: container))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try Data(contentsOf: fileURL) == payload)

        #expect(IngestDropBox.drain(container: container).first == staged)
    }

    @Test func removeClearsManifestAndStagedBytes() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
        try Data("x".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try IngestDropBox.stageFile(from: source, title: "Clip", container: container)
        let fileURL = try #require(IngestDropBox.stagedFileURL(for: staged, container: container))

        IngestDropBox.remove(staged, container: container)
        #expect(IngestDropBox.drain(container: container).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func drainReturnsItemsOldestFirst() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let first = try IngestDropBox.stageURL("https://a.com", title: "a", container: container)
        // Ensure a distinct, later timestamp on the second item.
        let second = PendingIngest(kind: .url, title: "b", urlString: "https://b.com",
                                   createdAt: first.createdAt.addingTimeInterval(1))
        try JSONEncoder().encode(second).write(to: container
            .appendingPathComponent("PendingIngest")
            .appendingPathComponent("\(second.id.uuidString).json"))

        let drained = IngestDropBox.drain(container: container)
        #expect(drained.map(\.id) == [first.id, second.id])
    }
}
