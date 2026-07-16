import Foundation
import UniformTypeIdentifiers

/// Pure routing decision for a shared attachment: given the type identifiers an
/// `NSItemProvider` advertises, decide whether it's a media file to transcribe (iOS), a web
/// link to transcribe (macOS), or something we don't handle. Pulled out of the extension's
/// view controller so the file-vs-url decision is unit-testable without a share sheet.
public enum SharedItemClassifier {
    public enum Kind: Equatable, Sendable {
        /// A movie or audio file — stage its bytes and transcribe (iOS).
        case mediaFile
        /// A web URL — capture the string and transcribe (macOS).
        case webURL
        case unsupported
    }

    /// Classify by UTI conformance. A web URL wins only when it's genuinely a URL and *not*
    /// also a media file (some providers advertise several); media is checked first because a
    /// shared movie/audio is always the transcription target when present.
    public static func classify(typeIdentifiers: [String]) -> Kind {
        let types = typeIdentifiers.compactMap { UTType($0) }
        if types.contains(where: { $0.conforms(to: .movie) || $0.conforms(to: .audio) }) {
            return .mediaFile
        }
        // `.url` covers web links; exclude file URLs, which arrive as their concrete media UTI
        // above rather than as `public.url`.
        if types.contains(where: { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }) {
            return .webURL
        }
        return .unsupported
    }
}
