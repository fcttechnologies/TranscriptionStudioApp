import Foundation
import OSLog
import FCTIntelligence

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
    /// PCC / on-device availability probe. Injectable so the escalation decision is testable
    /// without Apple Intelligence hardware, mirroring `statusProvider`. Reuses FCTIntelligence's
    /// entitlement-safe probe (constructing PCC unentitled is an uncatchable `fatalError`).
    private let availability: any ModelAvailabilityProbing
    /// The live on-device context window, in tokens. Injectable for the same reason; production
    /// reads the real `SystemLanguageModel` value at runtime rather than a hardcoded constant.
    private let contextSizeProvider: @Sendable () -> Int

    public init(statusProvider: @escaping @Sendable () -> IntelligenceStatus =
                { SessionIntelligence.currentStatus() },
                availability: any ModelAvailabilityProbing = ModelAvailability(),
                contextSizeProvider: @escaping @Sendable () -> Int =
                { AIModelProfile.onDeviceContextSize }) {
        self.statusProvider = statusProvider
        self.availability = availability
        self.contextSizeProvider = contextSizeProvider
    }

    public var status: IntelligenceStatus { statusProvider() }

    /// A tight summary plus key points, as formatted text.
    public func summarize(transcript: String) async throws -> String {
        try await generate(instructions: Self.summaryInstructions, transcript: transcript) { body in
            "Summarize this transcript.\n\nTranscript:\n\(body)"
        }
    }

    /// A concise answer grounded strictly in the transcript.
    public func answer(question: String, transcript: String) async throws -> String {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await generate(instructions: Self.qaInstructions, transcript: transcript) { body in
            "Transcript:\n\(body)\n\nQuestion: \(trimmedQuestion)"
        }
    }

    // MARK: Generation

    /// Run one generation verb. Escalates to Private Cloud Compute *only* when the transcript
    /// overflows the live on-device context budget and PCC is available; otherwise stays
    /// on-device, trimming the transcript to the on-device budget (the previous behavior).
    /// `buildPrompt` assembles the verb's prompt from a transcript body already trimmed to the
    /// chosen tier's budget.
    private func generate(instructions: String, transcript: String,
                          buildPrompt: @Sendable (String) -> String) async throws -> String {
        let status = statusProvider()
        guard status.isAvailable else { throw IntelligenceError.unavailable(status.message) }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntelligenceError.emptyTranscript
        }
        #if canImport(FoundationModels)
        switch plannedTier(forTranscriptCharacters: transcript.count) {
        case .privateCloudCompute:
            do {
                // `plannedTier` returns `.privateCloudCompute` only once `availability.isPCCAvailable`
                // is true, so constructing the PCC model here is safely past its entitlement guard.
                // `contextSize` is `async throws` on the PCC model, so it's read inside this `do`:
                // any failure fetching it (or generating) degrades to the trimmed on-device path.
                let pcc = PrivateCloudComputeLanguageModel()
                let budget = Self.transcriptCharacterBudget(contextTokens: try await pcc.contextSize)
                let prompt = buildPrompt(Self.trimmedForContext(transcript, maxCharacters: budget))
                let session = LanguageModelSession(model: pcc, instructions: Instructions(instructions))
                let response = try await session.respond(to: Prompt(prompt))
                Logger.models.info("Intelligence generation complete (Private Cloud Compute)")
                return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                // A mid-flight PCC failure (network / quota) degrades to the trimmed on-device
                // path rather than surfacing an error where on-device would have produced an answer.
                Logger.models.info("Private Cloud Compute generation failed — degrading to on-device")
                return try await generateOnDevice(instructions: instructions, transcript: transcript,
                                                  buildPrompt: buildPrompt)
            }
        case .onDevice:
            return try await generateOnDevice(instructions: instructions, transcript: transcript,
                                              buildPrompt: buildPrompt)
        }
        #else
        throw IntelligenceError.unavailable(IntelligenceUnavailable.notSupported.message)
        #endif
    }

    #if canImport(FoundationModels)
    /// The on-device path: trim the transcript to the live on-device budget and generate locally.
    private func generateOnDevice(instructions: String, transcript: String,
                                  buildPrompt: @Sendable (String) -> String) async throws -> String {
        let budget = Self.transcriptCharacterBudget(contextTokens: contextSizeProvider())
        let prompt = buildPrompt(Self.trimmedForContext(transcript, maxCharacters: budget))
        let session = LanguageModelSession(instructions: Instructions(instructions))
        let response = try await session.respond(to: Prompt(prompt))
        Logger.models.info("Intelligence generation complete (on-device)")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif

    // MARK: Escalation decision (pure — testable without a live model)

    /// The tiers an app-side generation can run at. On-device is the default; PCC is the overflow
    /// escalation for long transcripts (roadmap §8).
    enum GenerationTier: Sendable, Equatable {
        case onDevice
        case privateCloudCompute
    }

    /// The tier a transcript of `transcriptCharacters` runs at right now, resolving the injected
    /// availability + context-size seams. Pure of the model — the escalation decision itself,
    /// wired to its live inputs.
    func plannedTier(forTranscriptCharacters transcriptCharacters: Int) -> GenerationTier {
        let budget = Self.transcriptCharacterBudget(contextTokens: contextSizeProvider())
        return Self.generationTier(transcriptCharacters: transcriptCharacters,
                                   onDeviceBudget: budget,
                                   isPCCAvailable: availability.isPCCAvailable)
    }

    /// Escalate to PCC only when the transcript overflows the on-device budget AND PCC is
    /// available; otherwise stay on-device. Pure — the whole policy in one testable function.
    static func generationTier(transcriptCharacters: Int, onDeviceBudget: Int,
                               isPCCAvailable: Bool) -> GenerationTier {
        guard transcriptCharacters > onDeviceBudget, isPCCAvailable else { return .onDevice }
        return .privateCloudCompute
    }

    /// Characters of transcript that fit a model whose context window is `contextTokens` tokens,
    /// after reserving headroom for the instructions, the question, prompt scaffolding, and the
    /// model's response. Latin-script tokens run ~3–4 characters (Apple's context-window guidance);
    /// at the base on-device window (4,096 tokens) this reproduces the previous ~12k-character
    /// ceiling, and grows automatically on a device/model with a larger window.
    static func transcriptCharacterBudget(contextTokens: Int) -> Int {
        max(0, contextTokens - reservedContextTokens) * charactersPerToken
    }

    static let charactersPerToken = 4
    static let reservedContextTokens = 1_024

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

    /// Trim a transcript to `maxCharacters`, marking where it was cut. The generic length clamp;
    /// summarize/answer compute `maxCharacters` from the chosen tier's live context budget (see
    /// `transcriptCharacterBudget(contextTokens:)`), while other callers pass a fixed budget.
    static func trimmedForContext(_ transcript: String, maxCharacters: Int = 12_000) -> String {
        guard transcript.count > maxCharacters else { return transcript }
        return String(transcript.prefix(maxCharacters)) + "\n…(transcript truncated)"
    }
}
