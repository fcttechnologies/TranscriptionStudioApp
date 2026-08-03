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

/// Builds the prompt the model actually gets: a transcript of the words fully audible inside
/// the 5-second window, plus the moment to cut the clip so the audio contains *exactly* those
/// words. Pure — ASR words in, text + cut point out — so the matching rules are unit-testable
/// without a model.
///
/// Both halves matter. A transcript describing words past the cut makes the model speak them;
/// and audio carrying a clipped word the transcript can't describe makes the model *complete*
/// that dangling sound at the start of every generation (a stray "a…" on each chunk, heard
/// live). So the clip is trimmed at the last kept word's end and the transcript stops there
/// too — each describes the other exactly.
public enum PromptTranscript {
    /// The most prompt the model keeps (it would truncate here itself, mid-word if need be).
    public static let promptWindowSeconds: TimeInterval = 5.0
    /// Words ending inside this band before the window's edge are dropped: a word the window
    /// clipped is transcribed by ASR as ending exactly at the audio's end, and dropping a
    /// genuinely complete final word costs nothing audible where keeping a half-word bleeds.
    public static let cutGuardSeconds: TimeInterval = 0.05
    /// Breathing room after the last kept word's ASR end — word-end timestamps run a shade
    /// early, and cutting into the word's own tail would recreate the clipped-word problem
    /// one word up.
    public static let tailPadSeconds: TimeInterval = 0.08
    /// A prompt shorter than this loses too much voice conditioning to be worth a cleaner
    /// ending — below it, the full matched window wins over a sentence boundary.
    public static let minSentenceCutSeconds: TimeInterval = 3.0

    /// A derived prompt: the matched transcript and where to cut the clip so the audio holds
    /// exactly those words. `clipSeconds` is 0 when nothing survived the window.
    public struct MatchedPrompt: Sendable, Equatable {
        public let text: String
        public let clipSeconds: TimeInterval

        public init(text: String, clipSeconds: TimeInterval) {
            self.text = text
            self.clipSeconds = clipSeconds
        }
    }

    /// The words fully audible before the cut, in spoken order, with the clip cut placed just
    /// past the last of them — never into a dropped word, never past the window.
    ///
    /// When the window's edge lands mid-sentence, the prompt is pulled back to the last
    /// sentence boundary instead (if that keeps at least `minSentenceCut` of clip): a prompt
    /// ending mid-phrase — "…They were such a" — makes the model *complete the phrase* at the
    /// start of every generation, an audible stray syllable on every chunk. A clip with no
    /// internal boundary keeps its full window unchanged.
    public static func matched(words: [AsrWord],
                               window: TimeInterval = promptWindowSeconds,
                               guardBand: TimeInterval = cutGuardSeconds,
                               tailPad: TimeInterval = tailPadSeconds,
                               minSentenceCut: TimeInterval = minSentenceCutSeconds) -> MatchedPrompt {
        let ordered = words.sorted { $0.start < $1.start }
        var kept = ordered.filter { $0.end <= window - guardBand }
        var firstExcluded = ordered.first { $0.end > window - guardBand }

        if let lastKept = kept.last, !endsASentence(lastKept.word),
           let boundary = kept.lastIndex(where: { endsASentence($0.word) }),
           kept[boundary].end >= minSentenceCut {
            firstExcluded = kept[boundary + 1]
            kept = Array(kept[...boundary])
        }

        let text = kept
            .map { $0.word.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let lastKept = kept.last else { return MatchedPrompt(text: text, clipSeconds: 0) }

        var cut = min(lastKept.end + tailPad, window)
        // Don't pad into an excluded word — that would re-admit the very sound the exclusion
        // exists to keep out.
        if let firstExcluded, firstExcluded.start > lastKept.end {
            cut = min(cut, firstExcluded.start)
        }
        return MatchedPrompt(text: text, clipSeconds: cut)
    }

    /// Whether an ASR word carries sentence-final punctuation (Whisper attaches it to the
    /// word's own token, e.g. "ceremonies.").
    private static func endsASentence(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?")
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
