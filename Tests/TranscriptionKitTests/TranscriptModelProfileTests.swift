// Item B (roadmap §8): the three app-side model verbs (summarize, ask, title) unified behind one
// dynamic-profile shape. The verb→instructions/temperature mapping is pure, so it's fully testable
// here without a live model; the `LanguageModelSession.DynamicProfile` wiring itself is verified by
// the build (its resolved config only exists against a live Foundation Models session).

import Foundation
import Testing
@testable import TranscriptionKit

@Suite("TranscriptVerb — unified app-side model verbs")
struct TranscriptModelProfileTests {

    @Test func eachVerbCarriesItsOwnInstructions() {
        #expect(TranscriptVerb.summarize.instructions == SessionIntelligence.summaryInstructions)
        #expect(TranscriptVerb.ask.instructions == SessionIntelligence.qaInstructions)
        #expect(TranscriptVerb.title.instructions == TitleGenerator.instructions)
    }

    @Test func instructionsAreDistinctAndNonEmpty() {
        let all = TranscriptVerb.allCases.map(\.instructions)
        #expect(Set(all).count == all.count)          // no two verbs share an instruction set
        #expect(all.allSatisfy { !$0.isEmpty })
    }

    @Test func onlyTitlePinsALowTemperature() {
        #expect(TranscriptVerb.title.temperature == TitleGenerator.titleTemperature)
        #expect(TranscriptVerb.summarize.temperature == nil)   // summarize/ask use the model default
        #expect(TranscriptVerb.ask.temperature == nil)
    }
}
