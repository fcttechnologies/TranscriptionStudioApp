import Testing
import Foundation
import CoreSpotlight
import FoundationModels
import FCTIntelligence
@testable import TranscriptionKit

/// Library Q&A wiring + the read-only safety boundary — model-free. On-device answer quality is a
/// later with-Fernando device pass (see `Documentation/VERIFICATION.md`).
struct TranscriptLibraryAssistantTests {

    @Test func instructionsDeclareReadOnlyPrivateDataBoundary() {
        let instructions = TranscriptLibraryAssistant.instructions.lowercased()
        // The system prompt must state the read-only boundary and the own-data scope.
        #expect(instructions.contains("only read") || instructions.contains("can only read"))
        #expect(instructions.contains("never invent") || instructions.contains("only use the user"))
        #expect(instructions.contains("library") || instructions.contains("transcript"))
    }

    @Test func assistantUsesTheLibraryInstructions() {
        #expect(TranscriptLibraryAssistant.makeAssistant().instructions == TranscriptLibraryAssistant.instructions)
    }

    @Test func spotlightToolVetsAsReadOnly() {
        // The tool the assistant attaches must pass the read-only safety gate — a write-capable
        // tool would trip `vettedReadOnly`'s precondition and fail the build's test gate.
        let tool = TranscriptLibraryAssistant.makeTool()
        let vetted = AIToolSafety.vettedReadOnly([tool])
        #expect(vetted.count == 1)
        #expect(SpotlightSearchTool.capability == .readOnly)
    }

    @Test func hydratedItemCarriesTheFullTranscriptText() {
        let fullText = "We agreed Sergio would send the budget deck by Friday."
        let item = TranscriptLibraryAssistant.hydratedItem(id: "abc-123", title: "Budget meeting", fullText: fullText)

        #expect(item.uniqueIdentifier == "abc-123")
        #expect(item.domainIdentifier == TranscriptSpotlightIndex.indexName)
        #expect(item.attributeSet.title == "Budget meeting")
        // The delegate hydrates the full text (not the 280-char persisted preview) for the model.
        #expect(item.attributeSet.contentDescription == fullText)
    }

    @Test func hydratedItemBoundsAVeryLongTranscript() {
        // A transcript longer than the on-device context budget is trimmed the same way single-
        // session Q&A trims it — the persisted index is never inflated.
        let long = String(repeating: "word ", count: 5_000)
        let item = TranscriptLibraryAssistant.hydratedItem(id: "x", title: "Long", fullText: long)
        let description = item.attributeSet.contentDescription ?? ""
        #expect(!description.isEmpty && description.count < long.count)
    }
}
