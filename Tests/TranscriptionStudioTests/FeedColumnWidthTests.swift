import CoreGraphics
import Testing
@testable import TranscriptionStudio

/// The feed column's width rule, pinned at the three widths that decide it: a window narrower
/// than the floor, the default Mac window, and a wide one. The rule replaced a fixed 640pt cap,
/// which stranded the column in a wide window.
@Suite("Feed column width")
struct FeedColumnWidthTests {

    @Test func aNarrowWindowIsFilledRatherThanExceeded() {
        // Below the floor the column can only be the container: a 640pt minimum applied literally
        // would run the cards off the edge of a 500pt window.
        #expect(DesignMetrics.feedWidth(forContainer: 500) == 500)
        #expect(DesignMetrics.feedWidth(forContainer: 393) == 393)
    }

    @Test func theFloorHoldsUntilTheFractionOvertakesIt() {
        // 1000 * 0.62 = 620, under the floor, so the floor wins.
        #expect(DesignMetrics.feedWidth(forContainer: 1000) == DesignMetrics.feedMinWidth)
        // 1140 (the default window) * 0.62 = 706.8, past the floor, so the fraction wins.
        #expect(DesignMetrics.feedWidth(forContainer: 1140) == 1140 * DesignMetrics.feedWidthFraction)
    }

    @Test func aWideWindowIsCappedInsteadOfGrowingWithIt() {
        // 1760 * 0.62 = 1091.2 — past the cap, where a list of cards stops reading as a column.
        #expect(DesignMetrics.feedWidth(forContainer: 1760) == DesignMetrics.feedMaxWidth)
        #expect(DesignMetrics.feedWidth(forContainer: 3000) == DesignMetrics.feedMaxWidth)
    }

    @Test func theWidthNeverExceedsItsContainerAtAnySize() {
        for width in stride(from: CGFloat(200), through: 3000, by: 37) {
            #expect(DesignMetrics.feedWidth(forContainer: width) <= width)
        }
    }
}
