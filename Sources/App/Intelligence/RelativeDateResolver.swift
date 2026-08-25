import Foundation

/// Turns a date/time *phrase* the model extracted ("July 20, 2026", "next Tuesday", "by Friday")
/// into a concrete `Date` when one is detectable — ordinary, testable Swift, never a second model
/// call. Keeps the model's job as pure extraction and the date-math here (the roadmap's split).
///
/// Backed by `NSDataDetector`, which resolves *absolute* phrases deterministically. Relative phrases
/// ("next Tuesday") resolve against the current moment — acceptable because extraction runs right
/// after a session completes, so "now" ≈ the conversation date; a phrase with no detectable date
/// yields `nil`, and the original phrase is always preserved alongside on the model.
enum RelativeDateResolver {
    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue
    )

    /// The first concrete date detectable in `text`, or `nil` when the phrase carries no date.
    static func resolve(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let detector else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return detector.firstMatch(in: trimmed, options: [], range: range)?.date
    }
}
