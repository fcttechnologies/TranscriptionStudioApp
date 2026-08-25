import Foundation

/// Derives a session title from a Photos-picker import's filename. Pulled out of the
/// `#if os(iOS)`-gated `PickedPhotosVideo` below so it stays unit-testable on every platform
/// `swift test` runs on (macOS included).
enum PhotosVideoTitle {
    /// The filename's stem (extension stripped), or "Imported video" when the picker hands
    /// back nothing usable (an empty name, or a bare extension with no stem).
    static func sessionTitle(forFilename filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        return stem.isEmpty ? "Imported video" : stem
    }
}

#if os(iOS)
import CoreTransferable
import PhotosUI
import UniformTypeIdentifiers

/// A video picked from the iOS Photos library, copied out to a temp file this app owns. The
/// picker's `ReceivedTransferredFile.file` is only guaranteed to exist inside the `importing`
/// closure (per `FileRepresentation`'s contract), so it's copied out immediately rather than
/// handed back directly.
struct PickedPhotosVideo: Transferable {
    let url: URL
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: destination)
            let title = PhotosVideoTitle.sessionTitle(forFilename: received.file.lastPathComponent)
            return Self(url: destination, title: title)
        }
    }
}
#endif
