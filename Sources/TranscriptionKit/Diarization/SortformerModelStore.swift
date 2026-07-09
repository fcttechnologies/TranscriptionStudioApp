// SortformerModelStore — locates the Sortformer Core AI artifacts, provisions them (a locally
// present model is used as-is; otherwise Hugging Face is fetched with progress), and verifies
// integrity before any load.
//
// Verification is MANIFEST-DRIVEN: expected byte sizes (and optional SHA-256) are read from a
// small `sortformer_manifest.json` written next to the artifacts. This matters because a
// re-exported model has a *different* size than the HF original — a hard-coded size would reject
// the fix. When no manifest is present, the built-in default (the HF-original sizes) applies, so
// the plain HF download path still gets a strict guard. A partially-written `.aimodel` permanently
// poisons Core AI's on-device specialization cache, so the big graph is always size-checked before
// it reaches the runtime. Mirrors scripts/fetch-models.sh for the HF path.

import CryptoKit
import Foundation

public enum SortformerModelError: Error, LocalizedError {
    case sizeMismatch(file: String, expected: Int, got: Int)
    case hashMismatch(file: String)
    case downloadFailed(file: String, underlying: Error)
    case httpError(file: String, status: Int)
    case missingArtifact(String)

    public var errorDescription: String? {
        switch self {
        case .sizeMismatch(let f, let e, let g):
            "\(f) is \(g) bytes, expected \(e) — refusing to load a partial artifact"
        case .hashMismatch(let f): "\(f) failed its SHA-256 check — refusing to load"
        case .downloadFailed(let f, let u): "failed downloading \(f): \(u.localizedDescription)"
        case .httpError(let f, let s): "HTTP \(s) fetching \(f)"
        case .missingArtifact(let f): "required artifact missing: \(f)"
        }
    }
}

/// Per-file integrity expectation. `sha256` is optional (size-only when absent).
public struct SortformerManifestEntry: Codable, Sendable {
    public let name: String     // path relative to the Models root
    public let bytes: Int
    public let sha256: String?
    public init(name: String, bytes: Int, sha256: String? = nil) {
        self.name = name; self.bytes = bytes; self.sha256 = sha256
    }
}

/// The integrity manifest for a provisioned model set.
public struct SortformerManifest: Codable, Sendable {
    public let files: [SortformerManifestEntry]
    public init(files: [SortformerManifestEntry]) { self.files = files }

    public static let filename = "sortformer_manifest.json"

    /// The HF-original sizes (used when no local manifest is present).
    public static let hfDefault = SortformerManifest(files: [
        .init(name: "sortformer_mel_filters_128x257.f32", bytes: 128 * 257 * 4),
        .init(name: "sortformer_float16.aimodel/main.mlirb", bytes: 236_655_368),
    ])
}

/// Progress across the artifact fetch, for first-run UX.
public struct SortformerDownloadProgress: Sendable {
    public let file: String
    public let fraction: Double?   // 0...1 for the current file, nil when indeterminate
    public let completedFiles: Int
    public let totalFiles: Int
}

public struct SortformerModelStore: Sendable {
    /// The HF-original expected sizes, exposed for scripts/tests (see also SortformerManifest.hfDefault).
    public static let mainMlirbBytes = 236_655_368
    public static let melFilterBytes = 128 * 257 * 4   // 131584

    static let base = "https://huggingface.co/mlboydaisuke/Streaming-Sortformer-Diar-CoreAI/resolve/main"

    public let root: URL

    /// Defaults to `~/Library/Application Support/TranscriptionStudio/Models`.
    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = base.appendingPathComponent("TranscriptionStudio/Models", isDirectory: true)
        }
    }

    public var modelURL: URL { root.appendingPathComponent("sortformer_float16.aimodel", isDirectory: true) }
    public var mainMlirbURL: URL { modelURL.appendingPathComponent("main.mlirb") }
    public var melFiltersURL: URL { root.appendingPathComponent("sortformer_mel_filters_128x257.f32") }
    public var metadataURL: URL { root.appendingPathComponent("metadata.json") }
    public var manifestURL: URL { root.appendingPathComponent(SortformerManifest.filename) }

    /// The active manifest: the local one if written next to the artifacts, else the HF default.
    public func effectiveManifest() -> SortformerManifest {
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(SortformerManifest.self, from: data) {
            return manifest
        }
        return .hfDefault
    }

    /// A structurally-complete model is present locally (files exist, non-empty). Provisioning
    /// treats such a directory as first-class and skips any network fetch.
    public var hasLocalArtifacts: Bool {
        let fm = FileManager.default
        func nonEmpty(_ url: URL) -> Bool {
            guard let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int else { return false }
            return size > 0
        }
        return nonEmpty(mainMlirbURL) && nonEmpty(melFiltersURL) && fm.fileExists(atPath: metadataURL.path)
    }

    /// All artifacts present and passing the effective manifest (size + optional hash).
    public var artifactsPresent: Bool {
        (try? verifyArtifacts()) != nil
    }

    /// Throws unless every manifest-listed file exists at its expected size (and hash, if given),
    /// and metadata.json is present.
    public func verifyArtifacts() throws {
        let manifest = effectiveManifest()
        for entry in manifest.files {
            let url = root.appendingPathComponent(entry.name)
            try verifySize(url, expected: entry.bytes, name: entry.name)
            if let sha = entry.sha256 { try verifyHash(url, expected: sha, name: entry.name) }
        }
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw SortformerModelError.missingArtifact("metadata.json")
        }
    }

    /// The librosa-slaney mel filterbank `[128, 257]` row-major, verified to size first.
    public func loadMelFilters() throws -> [Float] {
        let expected = effectiveManifest().files
            .first { $0.name.hasSuffix("mel_filters_128x257.f32") }?.bytes ?? Self.melFilterBytes
        try verifySize(melFiltersURL, expected: expected, name: "mel filterbank")
        let data = try Data(contentsOf: melFiltersURL)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Ensures a valid model set exists: a locally-provisioned model is used as-is; otherwise the
    /// HF original is downloaded, verified against the default manifest, and a local manifest written.
    public func provision(
        session: URLSession = .shared,
        onProgress: @Sendable (SortformerDownloadProgress) -> Void = { _ in }
    ) async throws {
        if hasLocalArtifacts, (try? verifyArtifacts()) != nil {
            return   // locally provisioned (re-export or prior fetch) — no network
        }
        try await download(session: session, onProgress: onProgress)
    }

    /// Downloads any missing/short artifact from Hugging Face and verifies every size against the
    /// default manifest. Idempotent; writes a local manifest on success.
    public func download(
        session: URLSession = .shared,
        onProgress: @Sendable (SortformerDownloadProgress) -> Void = { _ in }
    ) async throws {
        let files: [(rel: String, dest: URL, size: Int?)] = [
            ("metadata.json", metadataURL, nil),
            ("sortformer_mel_filters_128x257.f32", melFiltersURL, Self.melFilterBytes),
            ("sortformer_float16.aimodel/metadata.json", modelURL.appendingPathComponent("metadata.json"), nil),
            ("sortformer_float16.aimodel/main.hash", modelURL.appendingPathComponent("main.hash"), nil),
            ("sortformer_float16.aimodel/main.mlirb", mainMlirbURL, Self.mainMlirbBytes),
        ]
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)

        for (index, file) in files.enumerated() {
            if let size = file.size, (try? verifySize(file.dest, expected: size, name: file.rel)) != nil {
                onProgress(.init(file: file.rel, fraction: 1, completedFiles: index, totalFiles: files.count))
                continue
            }
            try await fetch(rel: file.rel, to: file.dest, session: session) { frac in
                onProgress(.init(file: file.rel, fraction: frac, completedFiles: index, totalFiles: files.count))
            }
            if let size = file.size {
                do {
                    try verifySize(file.dest, expected: size, name: file.rel)
                } catch {
                    // A partial big file poisons the spec cache — delete it so a retry is clean.
                    try? FileManager.default.removeItem(at: file.dest)
                    throw error
                }
            }
        }
        try? writeManifest(.hfDefault)
        try verifyArtifacts()
    }

    /// Write an integrity manifest next to the artifacts (used by the download path; a re-export
    /// lane writes its own with the new sizes).
    public func writeManifest(_ manifest: SortformerManifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: manifestURL)
    }

    // MARK: internals

    private func verifySize(_ url: URL, expected: Int, name: String) throws {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else {
            throw SortformerModelError.missingArtifact(name)
        }
        guard size == expected else {
            throw SortformerModelError.sizeMismatch(file: name, expected: expected, got: size)
        }
    }

    private func verifyHash(_ url: URL, expected: String, name: String) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SortformerModelError.missingArtifact(name)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(expected) == .orderedSame else {
            throw SortformerModelError.hashMismatch(file: name)
        }
    }

    private func fetch(rel: String, to dest: URL, session: URLSession,
                       onProgress: @Sendable (Double?) -> Void) async throws {
        guard let url = URL(string: "\(Self.base)/\(rel)") else {
            throw SortformerModelError.missingArtifact(rel)
        }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SortformerModelError.httpError(file: rel, status: http.statusCode)
            }
            let total = response.expectedContentLength
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            let handle = try FileHandle(forWritingTo: dest)
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(1 << 20)
            var written: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= (1 << 20) {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    onProgress(total > 0 ? Double(written) / Double(total) : nil)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
            }
            onProgress(1)
        } catch let error as SortformerModelError {
            throw error
        } catch {
            throw SortformerModelError.downloadFailed(file: rel, underlying: error)
        }
    }
}
