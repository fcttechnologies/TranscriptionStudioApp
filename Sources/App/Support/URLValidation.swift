import Foundation

/// Shared shaping for the Mac-only link-ingest entry point — pure, so it's directly tested.
enum URLValidation {
    /// A pasteable transcription URL: an http(s) scheme with a host.
    static func isTranscribableURL(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespaces)) else { return false }
        return url.scheme?.hasPrefix("http") == true && url.host() != nil
    }

    /// The job title for a pasted link ("Link · youtube.com"), falling back to the raw string.
    static func suggestedTitle(for string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        return URL(string: trimmed)?.host().map { "Link · \($0)" } ?? trimmed
    }
}
