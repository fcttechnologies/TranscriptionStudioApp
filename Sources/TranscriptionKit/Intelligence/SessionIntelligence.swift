import Foundation
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Why on-device intelligence isn't usable, with a user-facing message. Separated from the
/// live model so the gate logic is testable without Apple Intelligence hardware.
public enum IntelligenceUnavailable: Sendable, Equatable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case notSupported
    case other(String)

    public var message: String {
        switch self {
        case .deviceNotEligible, .notSupported:
            "Apple Intelligence isn't available on this device."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in Settings to summarize and ask about transcripts."
        case .modelNotReady:
            "Apple Intelligence is still getting ready. Try again in a moment."
        case .other(let detail):
            detail
        }
    }
}

/// On-device model status.
public enum IntelligenceStatus: Sendable, Equatable {
    case available
    case unavailable(IntelligenceUnavailable)

    public var isAvailable: Bool { self == .available }

    /// The user-facing explanation when not available (empty when available).
    public var message: String {
        switch self {
        case .available: ""
        case .unavailable(let reason): reason.message
        }
    }
}

public enum IntelligenceError: Error, Equatable {
    case unavailable(String)
    case emptyTranscript
}

/// On-device transcript intelligence: summaries and grounded Q&A over a transcript, powered by
/// Apple's Foundation Models. Everything runs locally — transcript text never leaves the
/// device and is never logged. Availability is gated at runtime; on hardware without Apple
/// Intelligence every call degrades to a thrown `IntelligenceError.unavailable` (never a crash).
///
/// The status source is injectable so the gate can be tested on any machine.
public struct SessionIntelligence: Sendable {
    private let statusProvider: @Sendable () -> IntelligenceStatus

    public init(statusProvider: @escaping @Sendable () -> IntelligenceStatus =
                { SessionIntelligence.currentStatus() }) {
        self.statusProvider = statusProvider
    }

    public var status: IntelligenceStatus { statusProvider() }

    /// A tight summary plus key points, as formatted text.
    public func summarize(transcript: String) async throws -> String {
        try await generate(
            instructions: Self.summaryInstructions,
            prompt: "Summarize this transcript.\n\nTranscript:\n\(Self.trimmedForContext(transcript))",
            transcript: transcript)
    }

    /// A concise answer grounded strictly in the transcript.
    public func answer(question: String, transcript: String) async throws -> String {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await generate(
            instructions: Self.qaInstructions,
            prompt: "Transcript:\n\(Self.trimmedForContext(transcript))\n\nQuestion: \(trimmedQuestion)",
            transcript: transcript)
    }

    // MARK: Generation

    private func generate(instructions: String, prompt: String, transcript: String) async throws -> String {
        let status = statusProvider()
        guard status.isAvailable else { throw IntelligenceError.unavailable(status.message) }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntelligenceError.emptyTranscript
        }
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: Instructions(instructions))
        let response = try await session.respond(to: Prompt(prompt))
        Logger.models.info("Intelligence generation complete")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw IntelligenceError.unavailable(IntelligenceUnavailable.notSupported.message)
        #endif
    }

    // MARK: Availability

    /// Read the live on-device model status. Guarded so builds/platforms without
    /// FoundationModels report `.notSupported` rather than failing to compile.
    public static func currentStatus() -> IntelligenceStatus {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady):
            return .unavailable(.modelNotReady)
        case .unavailable(let reason):
            return .unavailable(.other(String(describing: reason)))
        @unknown default:
            return .unavailable(.other(IntelligenceUnavailable.notSupported.message))
        }
        #else
        return .unavailable(.notSupported)
        #endif
    }

    /// Map any generation error into a user-facing sentence.
    public static func errorMessage(for error: Error) -> String {
        if case let IntelligenceError.unavailable(message) = error { return message }
        if case IntelligenceError.emptyTranscript = error { return "That transcript is empty." }
        #if canImport(FoundationModels)
        if let modelError = error as? LanguageModelError {
            switch modelError {
            case .contextSizeExceeded:
                return "That transcript is too long to process at once."
            case .guardrailViolation:
                return "That request was blocked by on-device safety guardrails."
            case .rateLimited, .timeout:
                return "Apple Intelligence is busy right now. Try again shortly."
            default:
                break
            }
        }
        #endif
        return "Something went wrong. Please try again."
    }

    // MARK: Prompt building

    static let summaryInstructions = """
        You summarize transcripts of conversations, meetings, and recordings.
        Write a tight 2–3 sentence overview, then a short list of the most important points \
        or decisions, one per line prefixed with "• ".
        Base everything only on the transcript. Do not invent details. Be concise and plain.
        """

    static let qaInstructions = """
        You answer questions about a transcript of a conversation, meeting, or recording.
        Use ONLY information stated in the transcript. If the answer isn't in the transcript, \
        say you couldn't find it. Keep the answer to a few sentences. Be concise and factual.
        """

    /// Keep the transcript within a safe context budget (~3k tokens) to avoid overflow on the
    /// on-device model; long transcripts are trimmed to the leading portion.
    static func trimmedForContext(_ transcript: String, maxCharacters: Int = 12_000) -> String {
        guard transcript.count > maxCharacters else { return transcript }
        return String(transcript.prefix(maxCharacters)) + "\n…(transcript truncated)"
    }
}
