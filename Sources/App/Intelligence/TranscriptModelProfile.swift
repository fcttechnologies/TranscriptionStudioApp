import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The three app-side Foundation Models "verbs" that own a `LanguageModelSession` call site.
/// Unifying them behind one dynamic-profile shape (roadmap §8) keeps each verb's instructions and
/// per-verb configuration in a single place, rather than three separate
/// `LanguageModelSession(instructions:)` construction sites drifting apart as verbs are added.
///
/// This enum carries no Foundation Models types, so the verb→instructions/temperature mapping is
/// pure and unit-testable on any platform; `TranscriptModelProfile` binds it to a live session.
enum TranscriptVerb: Sendable, CaseIterable {
    /// Summarize a whole transcript (`SessionIntelligence.summarize`).
    case summarize
    /// Answer a question grounded in one transcript (`SessionIntelligence.answer`).
    case ask
    /// Generate a short title for a transcript (`TitleGenerator`).
    case title

    /// The trusted session instructions for this verb — the single source each session shape reads.
    var instructions: String {
        switch self {
        case .summarize: SessionIntelligence.summaryInstructions
        case .ask: SessionIntelligence.qaInstructions
        case .title: TitleGenerator.instructions
        }
    }

    /// The generation temperature this verb pins, or `nil` to use the model default. Title
    /// generation wants a low, near-deterministic value; summarize and ask use the default.
    var temperature: Double? {
        switch self {
        case .summarize, .ask: nil
        case .title: TitleGenerator.titleTemperature
        }
    }
}

#if canImport(FoundationModels)
/// One `LanguageModelSession.DynamicProfile` for all of Transcription Studio's app-side model work.
/// The active `verb` selects the instructions (and per-verb temperature) while every verb shares the
/// same session shape and runs on the caller-chosen `model` — the on-device default, or the PCC
/// model when a long transcript escalated (roadmap §8, Item A). This replaces the previously
/// separate summarize / ask / title session-construction sites with one coherent shape.
///
/// `model` is passed in already availability-checked and concrete: the PCC model is only ever
/// constructed by a caller that has confirmed PCC availability, so this profile never news up an
/// unentitled model (which would be an uncatchable `fatalError`).
struct TranscriptModelProfile: LanguageModelSession.DynamicProfile {
    let verb: TranscriptVerb
    let model: any LanguageModel

    var body: some LanguageModelSession.DynamicProfile {
        // Exactly one profile is active per request — `DynamicProfileBuilder` enforces it at
        // compile time. The only per-verb divergence is the optional temperature.
        if let temperature = verb.temperature {
            Profile { Instructions(verb.instructions) }
                .model(model)
                .temperature(temperature)
        } else {
            Profile { Instructions(verb.instructions) }
                .model(model)
        }
    }
}
#endif
