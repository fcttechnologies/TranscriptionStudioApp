import Foundation

/// One item a Share extension staged for the host app to transcribe. Written as a JSON
/// manifest into the App Group drop-box; the host drains and enqueues it as a real job.
///
/// Two shapes, matching the two platforms' share inputs:
/// - `.file` (iOS): a media file whose bytes were copied into the drop-box (`stagedFilename`).
/// - `.url` (macOS): a web link captured as a string (`urlString`); no bytes staged.
struct PendingIngest: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case file
        case url
    }

    let id: UUID
    let kind: Kind
    /// The suggested job/session title (filename stem, or "Link · host").
    let title: String
    /// `.file` only — the staged media file's name inside the drop-box's `files/` dir.
    let stagedFilename: String?
    /// `.url` only — the shared web URL string.
    let urlString: String?
    let createdAt: Date

    init(id: UUID = UUID(),
                kind: Kind,
                title: String,
                stagedFilename: String? = nil,
                urlString: String? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.stagedFilename = stagedFilename
        self.urlString = urlString
        self.createdAt = createdAt
    }
}
