// GlanceKit's pure math — the level downsampling a recording Live Activity's content state
// carries, and the wall-clock span a playback activity's self-advancing progress rides on.
// (The now-playing info mapping lives in FCTFoundation with `NowPlayingCoordinator`; its tests
// ride there, in FCTGlanceablesTests.)

import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("ActivityLevels — waveform downsampling")
struct ActivityLevelsTests {
    @Test func emptyInputYieldsSilence() {
        #expect(ActivityLevels.downsample([], to: 4) == [0, 0, 0, 0])
    }

    @Test func zeroBucketsYieldNothing() {
        #expect(ActivityLevels.downsample([0.5], to: 0) == [])
    }

    @Test func fewerSamplesThanBucketsLeftPadWithSilence() {
        // The trace stays right-aligned: newest at the trailing edge, silence before the start.
        #expect(ActivityLevels.downsample([0.5, 1], to: 4) == [0, 0, 50, 100])
    }

    @Test func exactFitQuantizesInOrder() {
        #expect(ActivityLevels.downsample([0, 0.25, 0.5, 1], to: 4) == [0, 25, 50, 100])
    }

    @Test func reductionKeepsEachWindowsPeak() {
        // 8 → 4: pairs reduce to their louder half — a mean would flatten short bursts.
        let levels: [Float] = [0.1, 0.9, 0.2, 0.3, 0.8, 0.1, 0.0, 0.4]
        #expect(ActivityLevels.downsample(levels, to: 4) == [90, 30, 80, 40])
    }

    @Test func outOfRangeInputIsClamped() {
        #expect(ActivityLevels.downsample([-0.5, 2.0], to: 2) == [0, 100])
    }
}

@Suite("PlaybackClock — the wall-clock span")
struct PlaybackClockTests {
    private let anchor = Date(timeIntervalSince1970: 1_000_000)

    @Test func atNormalSpeedTheSpanMirrorsTheMedia() {
        let span = PlaybackClock.wallClockSpan(position: 30, duration: 90, rate: 1, updatedAt: anchor)
        #expect(span == anchor.addingTimeInterval(-30)...anchor.addingTimeInterval(60))
    }

    @Test func doubleSpeedHalvesTheWallClock() {
        let span = PlaybackClock.wallClockSpan(position: 30, duration: 90, rate: 2, updatedAt: anchor)
        #expect(span == anchor.addingTimeInterval(-15)...anchor.addingTimeInterval(30))
    }

    @Test func zeroRateHasNoSpan() {
        #expect(PlaybackClock.wallClockSpan(position: 30, duration: 90, rate: 0, updatedAt: anchor) == nil)
    }

    @Test func zeroDurationHasNoSpan() {
        #expect(PlaybackClock.wallClockSpan(position: 0, duration: 0, rate: 1, updatedAt: anchor) == nil)
    }

    @Test func aPositionPastTheEndHasNoSpan() {
        #expect(PlaybackClock.wallClockSpan(position: 91, duration: 90, rate: 1, updatedAt: anchor) == nil)
    }

    @Test func startingAtZeroAnchorsTheLowerBoundAtNow() {
        let span = PlaybackClock.wallClockSpan(position: 0, duration: 60, rate: 1, updatedAt: anchor)
        #expect(span?.lowerBound == anchor)
        #expect(span?.upperBound == anchor.addingTimeInterval(60))
    }
}
