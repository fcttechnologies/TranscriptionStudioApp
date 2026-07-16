// Item A (roadmap §8): the PCC-escalation decision for long transcripts. The policy is pure and
// injectable, so every branch is exercised here without Apple Intelligence hardware — matching
// `SessionIntelligence`'s existing injectable-status posture.

import Foundation
import Testing
import FCTIntelligence
@testable import TranscriptionKit

@Suite("SessionIntelligence — PCC escalation")
struct SessionIntelligenceEscalationTests {

    /// A fixed availability answer — the seam that lets the escalation decision run without a
    /// live model or PCC entitlement.
    private struct FixedAvailability: ModelAvailabilityProbing {
        var isOnDeviceModelAvailable: Bool
        var isPCCAvailable: Bool
    }

    // MARK: Character budget from the live context window

    @Test func budgetAtBaseWindowReproducesThePreviousCeiling() {
        // Base on-device model: 4,096-token window → ~12k characters, matching the old constant.
        #expect(SessionIntelligence.transcriptCharacterBudget(contextTokens: 4_096) == 12_288)
    }

    @Test func budgetGrowsWithALargerWindow() {
        let small = SessionIntelligence.transcriptCharacterBudget(contextTokens: 4_096)
        let large = SessionIntelligence.transcriptCharacterBudget(contextTokens: 65_536)
        #expect(large > small)
    }

    @Test func budgetNeverGoesNegativeForATinyWindow() {
        #expect(SessionIntelligence.transcriptCharacterBudget(contextTokens: 100) == 0)
        #expect(SessionIntelligence.transcriptCharacterBudget(contextTokens: 0) == 0)
    }

    // MARK: The pure tier policy

    @Test func shortTranscriptStaysOnDeviceEvenWhenPCCIsAvailable() {
        let tier = SessionIntelligence.generationTier(
            transcriptCharacters: 500, onDeviceBudget: 12_288, isPCCAvailable: true)
        #expect(tier == .onDevice)
    }

    @Test func overflowEscalatesToPCCWhenAvailable() {
        let tier = SessionIntelligence.generationTier(
            transcriptCharacters: 50_000, onDeviceBudget: 12_288, isPCCAvailable: true)
        #expect(tier == .privateCloudCompute)
    }

    @Test func overflowStaysOnDeviceWhenPCCUnavailable() {
        // Degrades to today's trimmed on-device behavior — never an error where there wasn't one.
        let tier = SessionIntelligence.generationTier(
            transcriptCharacters: 50_000, onDeviceBudget: 12_288, isPCCAvailable: false)
        #expect(tier == .onDevice)
    }

    @Test func exactlyAtBudgetStaysOnDevice() {
        // The boundary is inclusive on-device: only a strict overflow escalates.
        let tier = SessionIntelligence.generationTier(
            transcriptCharacters: 12_288, onDeviceBudget: 12_288, isPCCAvailable: true)
        #expect(tier == .onDevice)
    }

    // MARK: The instance seam wiring availability + context size into the decision

    @Test func plannedTierEscalatesALongTranscriptWhenPCCIsAvailable() {
        let intelligence = SessionIntelligence(
            statusProvider: { .available },
            availability: FixedAvailability(isOnDeviceModelAvailable: true, isPCCAvailable: true),
            contextSizeProvider: { 4_096 })
        #expect(intelligence.plannedTier(forTranscriptCharacters: 100_000) == .privateCloudCompute)
        #expect(intelligence.plannedTier(forTranscriptCharacters: 200) == .onDevice)
    }

    @Test func plannedTierStaysOnDeviceForALongTranscriptWhenPCCIsUnavailable() {
        let intelligence = SessionIntelligence(
            statusProvider: { .available },
            availability: FixedAvailability(isOnDeviceModelAvailable: true, isPCCAvailable: false),
            contextSizeProvider: { 4_096 })
        #expect(intelligence.plannedTier(forTranscriptCharacters: 100_000) == .onDevice)
    }

    @Test func plannedTierRespectsALargerOnDeviceWindow() {
        // A device with a bigger on-device window keeps more work local before escalating.
        let intelligence = SessionIntelligence(
            statusProvider: { .available },
            availability: FixedAvailability(isOnDeviceModelAvailable: true, isPCCAvailable: true),
            contextSizeProvider: { 65_536 })
        // ~40k chars fits a 65,536-token window, so it stays on-device where a 4,096 window escalated.
        #expect(intelligence.plannedTier(forTranscriptCharacters: 40_000) == .onDevice)
    }
}
