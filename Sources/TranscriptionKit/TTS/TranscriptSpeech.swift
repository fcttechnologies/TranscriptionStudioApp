import Foundation

/// The pure text side of read-aloud: what a transcript sounds like when spoken, and how an
/// arbitrarily long one is cut into synthesis passages. Both halves are deliberately
/// engine-free so they're unit-testable and any `TtsEngine` speaks the same words.
public enum TranscriptSpeech {
    /// How many characters one synthesis passage may carry. Each passage is one engine call
    /// whose audio is scheduled and then discarded, so this is the read-aloud memory bound:
    /// a transcript of any length costs one passage's audio at a time, never its own total.
    /// ~1,500 characters ≈ a minute and a half of speech.
    public static let passageCharacterLimit = 1_500

    /// The spoken rendition of a session's transcript, mirroring the copy-transcript rule:
    /// a single voice reads as clean paragraphs; several voices keep their speaker names so
    /// the listener can follow who said what.
    public static func text(for turns: [TranscriptTurn]) -> String {
        switch TranscriptLayoutMode.decide(turns: turns) {
        case .flat:
            return turns.flatMap(\.lines).map(\.text).joined(separator: "\n")
        case .grouped:
            return turns.map { turn in
                "\(turn.speaker.displayName): " + turn.lines.map(\.text).joined(separator: " ")
            }.joined(separator: "\n")
        }
    }

    /// Cut spoken text into passages of at most `limit` characters, breaking on sentence
    /// boundaries (falling back to word boundaries, then to a hard cut for a single unbroken
    /// run) so a passage never ends mid-thought when the text offers any better seam.
    public static func passages(from text: String,
                                limit: Int = passageCharacterLimit) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > limit else { return [trimmed] }

        var passages: [String] = []
        var remaining = Substring(trimmed)
        while !remaining.isEmpty {
            if remaining.count <= limit {
                passages.append(String(remaining))
                break
            }
            let window = remaining.prefix(limit)
            let cut = sentenceCut(in: window) ?? wordCut(in: window) ?? window.endIndex
            passages.append(String(remaining[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines))
            remaining = remaining[cut...].drop { $0.isWhitespace || $0.isNewline }
        }
        return passages.filter { !$0.isEmpty }
    }

    /// The index just past the last sentence terminator in the window, if any.
    private static func sentenceCut(in window: Substring) -> Substring.Index? {
        var last: Substring.Index?
        var index = window.startIndex
        while index < window.endIndex {
            let character = window[index]
            if character == "\n" {
                last = window.index(after: index)
            } else if ".!?".contains(character) {
                let next = window.index(after: index)
                // A terminator counts only when followed by whitespace or the window's edge,
                // so "3.5" or "v2.0" never reads as a sentence end.
                if next == window.endIndex || window[next].isWhitespace {
                    last = next
                }
            }
            index = window.index(after: index)
        }
        return last
    }

    /// The index of the last whitespace in the window, if any.
    private static func wordCut(in window: Substring) -> Substring.Index? {
        window.lastIndex(where: \.isWhitespace)
    }
}
