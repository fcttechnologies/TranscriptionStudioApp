import AppIntents
import Foundation
import UniformTypeIdentifiers

/// The file `ExportTranscriptIntent` hands back — a transcript rendered to a real file on disk,
/// modeled as a `FileEntity` (rather than a bare `IntentFile`) so it carries an ownership signal.
///
/// An exported transcript is the one moment a transcript's content *leaves the app's boundary* —
/// saved out, AirDropped, handed to another app. Everything inside TS is private to the person,
/// but an export is data being shared outward, so this conforms to `OwnershipProvidingEntity` and
/// reports `.shared`: Siri and Apple Intelligence then confirm before an *automated* export/share
/// (e.g. a hands-free Shortcut that exports and sends), instead of silently moving transcript
/// content off-device — matching TS's "nothing leaves your device without you knowing" posture.
/// As a `FileEntity` it still saves/shares/AirDrops like any other Shortcuts file result.
struct ExportedTranscriptFileEntity: FileEntity, OwnershipProvidingEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Exported Transcript",
                                          comment: "The AppEntity type name for a transcript exported to a file"))
    }

    /// The transcript interchange formats TS exports, as content types.
    static var supportedContentTypes: [UTType] {
        TranscriptExport.Format.allCases.map(TranscriptExportDocument.contentType(for:))
    }

    /// Identity is the on-disk file location (a `FileEntityIdentifier`), per `FileEntity`.
    var id: FileEntityIdentifier

    @Property(title: "Title")
    var title: String

    init(id: FileEntityIdentifier, title: String) {
        self.id = id
        self.title = title
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: "doc.text"))
    }

    /// An export shares transcript content outside the app, so the system treats it as shared
    /// data and confirms before acting on it automatically. (Private in-app entities need no
    /// signal — Siri assumes private by default.)
    var ownership: EntityOwnership { .shared }

    static let defaultQuery = ExportedTranscriptFileQuery()
}

/// Resolves an exported-transcript entity from its file identifier. The identifier already
/// locates the file on disk, so a resolution reconstructs the display title from the file name —
/// enough for the system to re-present a previously-produced export without re-rendering it.
struct ExportedTranscriptFileQuery: EntityQuery {
    init() {}

    func entities(for identifiers: [FileEntityIdentifier]) async throws -> [ExportedTranscriptFileEntity] {
        var results: [ExportedTranscriptFileEntity] = []
        for identifier in identifiers {
            let fileURL = try? await identifier.fileURL
            let title = fileURL?.deletingPathExtension().lastPathComponent ?? "Transcript"
            results.append(ExportedTranscriptFileEntity(id: identifier, title: title))
        }
        return results
    }
}
