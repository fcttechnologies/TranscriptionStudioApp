import Foundation
import OSLog
import SwiftData

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Generates a short, human title from a finished transcript. Tries Apple's on-device
/// Foundation Models first; when the model isn't available (older device, Apple Intelligence
/// off, or a generation failure) it falls back to a deterministic heuristic. Either way this
/// never throws and never blocks a transcription job — title-gen is decoration, not a
/// critical path.
public struct TitleGenerator: Sendable {
    /// The longest a title is allowed to run, in words — shared by the model instructions
    /// and the heuristic fallback so either path yields the same shape of title.
    static let maxWords = 6
    static let fallbackTitle = "Untitled Transcript"

    private let statusProvider: @Sendable () -> IntelligenceStatus

    public init(statusProvider: @escaping @Sendable () -> IntelligenceStatus =
                SessionIntelligence.currentStatus) {
        self.statusProvider = statusProvider
    }

    /// Generates a title for `session` off the critical path: fires a detached generation
    /// and, once it resolves, applies it — but only if `session.title` is still what it was
    /// when this was called. That guard is what keeps a manual rename from being clobbered by
    /// a slower in-flight generation, with no extra state needed on the model.
    @MainActor
    public func applyGeneratedTitle(to session: TranscriptSession, modelContext: ModelContext) {
        let transcript = session.fullText
        let titleAtKickoff = session.title
        Task {
            let generated = await generateTitle(transcript: transcript)
            guard session.title == titleAtKickoff else { return }
            session.title = generated
            try? modelContext.save()
        }
    }

    /// Best-effort title for a transcript: the on-device model when Apple Intelligence is
    /// available, otherwise (or on any generation failure) the deterministic heuristic.
    /// Never throws.
    func generateTitle(transcript: String) async -> String {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.fallbackTitle
        }
        guard statusProvider().isAvailable else {
            return Self.heuristicTitle(from: transcript)
        }
        #if canImport(FoundationModels)
        do {
            let session = LanguageModelSession(instructions: Instructions(Self.instructions))
            let options = GenerationOptions(temperature: 0.3)
            let response = try await session.respond(to: Prompt(Self.prompt(for: transcript)), options: options)
            let sanitized = Self.sanitize(response.content)
            return sanitized.isEmpty ? Self.heuristicTitle(from: transcript) : sanitized
        } catch {
            Logger.models.error("Title generation failed — using heuristic fallback")
            return Self.heuristicTitle(from: transcript)
        }
        #else
        return Self.heuristicTitle(from: transcript)
        #endif
    }

    // MARK: Prompting

    static let instructions = """
        You write short, plain titles for transcripts of conversations, meetings, and \
        recordings. Reply with the title only — no quotes, no trailing punctuation, no \
        preamble like "Title:". \(maxWords) words or fewer. Base it only on the transcript.
        """

    static func prompt(for transcript: String) -> String {
        "Write a short title for this transcript.\n\nTranscript:\n" +
        SessionIntelligence.trimmedForContext(transcript, maxCharacters: 4_000)
    }

    // MARK: Heuristic fallback

    /// A deterministic title when Foundation Models isn't available: the transcript's first
    /// clause, trimmed to `maxWords`. Pure (no model, no I/O) — the path exercised in tests.
    static func heuristicTitle(from transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallbackTitle }
        let firstClause = trimmed.components(separatedBy: Self.clauseEnders).first ?? trimmed
        let sanitized = sanitize(firstClause)
        return sanitized.isEmpty ? fallbackTitle : sanitized
    }

    private static let clauseEnders = CharacterSet(charactersIn: ".!?\n")

    /// Strip wrapping quotes, cap to `maxWords`, and trim stray leading/trailing punctuation —
    /// shared by the model output and the heuristic clause.
    static func sanitize(_ raw: String) -> String {
        let dequoted = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        let words = dequoted.split(separator: " ", omittingEmptySubsequences: true).prefix(maxWords)
        guard !words.isEmpty else { return "" }
        let capped = words.joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard let first = capped.first else { return "" }
        return String(first).uppercased() + capped.dropFirst()
    }
}
