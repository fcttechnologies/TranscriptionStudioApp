import Foundation

/// The cloning engine's voice roster: named reference clips, loaded from a voice-profile JSON.
///
/// The profile file is the single home of "which clips are the voice" — the same file the
/// Jarvis voicebox reads — so re-picking a reference clip there changes the voice everywhere
/// with no code edit. Only `primary` and each reference's `ref_audio` matter here; the
/// profile's other fields (register notes, the full-clip `ref_text`) are documentation for
/// humans. `ref_text` is deliberately NOT used for synthesis: the model truncates the prompt
/// clip to 5 seconds and trusts the transcript it's handed, so a transcript describing words
/// past the cut makes it *speak* them — the engine derives a transcript matched to the audible
/// window with word-timestamped ASR instead (`PromptTranscript`).
public struct CloningVoiceProfile: Sendable {
    /// One reference clip: the voice id callers pass and the clip it clones from.
    public struct Reference: Sendable {
        public let id: String
        public let audioURL: URL

        public init(id: String, audioURL: URL) {
            self.id = id
            self.audioURL = audioURL
        }
    }

    /// Voice id → reference, every id the profile defines.
    public let references: [String: Reference]
    /// The voice used when a caller asks for none.
    public let primaryVoice: String

    public init(references: [String: Reference], primaryVoice: String) {
        self.references = references
        self.primaryVoice = primaryVoice
    }

    /// The voice ids, sorted for stable help text and error copy.
    public var voiceIDs: [String] { references.keys.sorted() }

    /// Load a profile file. `ref_audio` paths resolve relative to the profile's own folder.
    public static func load(from url: URL) throws -> CloningVoiceProfile {
        struct File: Decodable {
            struct Ref: Decodable { let ref_audio: String }
            let primary: String
            let references: [String: Ref]
        }
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        } catch {
            throw TtsEngineError.synthesisFailed(
                "couldn't read the voice profile at \(url.path): \(error.localizedDescription)")
        }
        let base = url.deletingLastPathComponent()
        let references = file.references.reduce(into: [String: Reference]()) { result, entry in
            result[entry.key] = Reference(
                id: entry.key,
                audioURL: URL(fileURLWithPath: entry.value.ref_audio, relativeTo: base).standardizedFileURL)
        }
        guard references[file.primary] != nil else {
            throw TtsEngineError.synthesisFailed(
                "the voice profile's primary \"\(file.primary)\" isn't in its references")
        }
        guard !references.isEmpty else {
            throw TtsEngineError.synthesisFailed("the voice profile defines no references")
        }
        return CloningVoiceProfile(references: references, primaryVoice: file.primary)
    }
}

/// Builds the prompt transcript matched to what is actually audible in the model's truncated
/// prompt window. Pure — the ASR words come in, the matched text comes out — so the matching
/// rules are unit-testable without a model.
public enum PromptTranscript {
    /// The prompt window the model keeps (it truncates the clip here, mid-word if need be).
    public static let promptWindowSeconds: TimeInterval = 5.0
    /// Words ending inside this band before the cut are dropped too: a word the cut clipped
    /// is transcribed by ASR as ending exactly at the audio's end, and a transcript claiming
    /// a word the audio only half-contains makes the model speak the difference. Dropping a
    /// genuinely complete final word costs nothing audible; keeping a half-word does.
    public static let cutGuardSeconds: TimeInterval = 0.05

    /// The transcript of the words fully audible before the cut, in spoken order.
    public static func matchedText(words: [AsrWord],
                                   window: TimeInterval = promptWindowSeconds,
                                   guardBand: TimeInterval = cutGuardSeconds) -> String {
        words
            .filter { $0.end <= window - guardBand }
            .sorted { $0.start < $1.start }
            .map { $0.word.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Splits synthesis text into per-call chunks for the cloning engine, which can generate at
/// most ~5.9 s of audio per call (the port's fixed vocoder buckets). Sentences are the chunk
/// unit — the bench shipped exactly this and Fernando rated the chunked long passage best of
/// the field, so the seams are proven inaudible. Pure and unit-testable.
public enum SentenceChunker {
    /// The text split into sentences (terminator kept), trimmed, empties dropped. Text with
    /// no sentence terminator comes back whole.
    public static func sentences(in text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                chunks.append(current)
                current = ""
            }
        }
        chunks.append(current)
        return chunks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// A chunk split in two at the word boundary nearest its middle — the fallback when a
    /// single sentence still overflows the per-call cap. Nil when it can't be split further
    /// (one word, or no whitespace), which the caller surfaces as the model's own too-long
    /// error rather than looping forever.
    public static func halves(of chunk: String) -> (String, String)? {
        let words = chunk.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }
        let middle = words.count / 2
        let first = words[..<middle].joined(separator: " ")
        let second = words[middle...].joined(separator: " ")
        return (first, second)
    }
}
