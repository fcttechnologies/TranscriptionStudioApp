// TitleGenerator's deterministic heuristic fallback and the availability gate around it — no
// Apple Intelligence hardware needed. The Foundation Models generation path itself isn't
// unit-testable (it needs real on-device inference), so these exercise everything around it:
// the pure heuristic, the empty/unavailable guards, and the apply-only-if-unchanged wiring.

import Foundation
import SwiftData
import Testing
@testable import TranscriptionStudio

@MainActor
@Suite("TitleGenerator")
struct TitleGeneratorTests {

    // MARK: - Heuristic fallback (pure)

    @Test func heuristicTakesFirstClauseCappedToSixWords() {
        let transcript = "We reviewed the quarterly numbers and the hiring plan for next year. Then we broke for lunch."
        #expect(TitleGenerator.heuristicTitle(from: transcript) == "We reviewed the quarterly numbers and")
    }

    @Test func heuristicStopsAtTheFirstSentenceEvenWhenShort() {
        #expect(TitleGenerator.heuristicTitle(from: "Dog walk notes. Talked about the marketing budget.")
            == "Dog walk notes")
    }

    @Test func heuristicStopsAtANewlineTooNotJustSentencePunctuation() {
        #expect(TitleGenerator.heuristicTitle(from: "Standup notes\nWe reviewed the roadmap") == "Standup notes")
    }

    @Test func heuristicCapitalizesTheFirstLetter() {
        #expect(TitleGenerator.heuristicTitle(from: "budget review for q3") == "Budget review for q3")
    }

    @Test func heuristicStripsWrappingQuotes() {
        #expect(TitleGenerator.heuristicTitle(from: "\"quick sync on hiring\"") == "Quick sync on hiring")
    }

    @Test func sanitizeStripsAModelTitlePreamble() {
        // The on-device model sometimes ignores "no preamble" and replies "Title: …" —
        // sanitize strips it (case-insensitively) before the word cap so the cap counts
        // real title words.
        #expect(TitleGenerator.sanitize("Title: Proposal Update and Timeline Discussion")
            == "Proposal Update and Timeline Discussion")
        #expect(TitleGenerator.sanitize("title: Budget sync") == "Budget sync")
        #expect(TitleGenerator.sanitize("Plain title with no preamble") == "Plain title with no preamble")
    }

    @Test func heuristicTrimsTrailingPunctuationFromTheCutWord() {
        // "numbers," is the 6th word — the cap lands mid-clause (no sentence-ending
        // punctuation before it), so its trailing comma, now the end of the whole title,
        // should be stripped.
        #expect(TitleGenerator.heuristicTitle(from: "We reviewed the quarterly review numbers, then broke for lunch")
            == "We reviewed the quarterly review numbers")
    }

    @Test func heuristicFallsBackToUntitledForEmptyTranscript() {
        #expect(TitleGenerator.heuristicTitle(from: "") == "Untitled Transcript")
    }

    @Test func heuristicFallsBackToUntitledForWhitespaceOnlyTranscript() {
        #expect(TitleGenerator.heuristicTitle(from: "   \n\t  ") == "Untitled Transcript")
    }

    @Test func heuristicFallsBackToUntitledWhenTheFirstClauseIsOnlyPunctuation() {
        #expect(TitleGenerator.heuristicTitle(from: "... um, next.") == "Untitled Transcript")
    }

    // MARK: - generateTitle availability gate

    @Test func generateTitleUsesHeuristicWhenModelUnavailable() async {
        let generator = TitleGenerator(statusProvider: { .unavailable(.deviceNotEligible) })
        let title = await generator.generateTitle(transcript: "We reviewed the budget for next quarter.")
        #expect(title == "We reviewed the budget for next")
    }

    @Test func generateTitleReturnsUntitledForEmptyTranscriptWithoutTouchingTheModel() async {
        // Status reports available, but the empty-transcript guard fires first — safe to run
        // without Apple Intelligence hardware since no model call happens.
        let generator = TitleGenerator(statusProvider: { .available })
        let title = await generator.generateTitle(transcript: "   ")
        #expect(title == "Untitled Transcript")
    }

    // MARK: - applyGeneratedTitle wiring

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: AppModelContainer.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    /// Polls up to half a second for the fire-and-forget Task inside `applyGeneratedTitle` to
    /// land — with the model unavailable there's no real inference in the way, so this
    /// resolves almost immediately.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<50 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func applyGeneratedTitleSetsTheHeuristicTitleWhenUnchanged() async throws {
        let context = try makeContext()
        let session = TranscriptSession(title: "recording.m4a", kind: .fileTranscription)
        session.fullText = "We reviewed the budget for next quarter and agreed on headcount."
        context.insert(session)
        try context.save()

        let generator = TitleGenerator(statusProvider: { .unavailable(.notSupported) })
        generator.applyGeneratedTitle(to: session, modelContext: context)

        await waitUntil { session.title != "recording.m4a" }
        #expect(session.title == "We reviewed the budget for next")
    }

    @Test func applyGeneratedTitleNeverOverwritesAManualRename() async throws {
        let context = try makeContext()
        let session = TranscriptSession(title: "recording.m4a", kind: .fileTranscription)
        session.fullText = "We reviewed the budget for next quarter."
        context.insert(session)
        try context.save()

        let generator = TitleGenerator(statusProvider: { .unavailable(.notSupported) })
        generator.applyGeneratedTitle(to: session, modelContext: context)
        // The user renames it before generation lands.
        session.title = "My custom name"

        await waitUntil { session.title != "recording.m4a" } // already true, but let any work settle
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(session.title == "My custom name")
    }
}
