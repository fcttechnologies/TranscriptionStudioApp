import SwiftUI

/// The live transcript: speaker-attributed turns streaming in, provisional tail shimmering,
/// with auto-follow scroll that yields the moment the user scrolls up (and a "jump to live"
/// affordance to re-engage). Motion-aware throughout.
struct LiveTranscriptView: View {
    let segments: [AttributedSegment]

    @State private var autoFollow = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(segments: [AttributedSegment]) {
        self.segments = segments
    }

    private var turns: [TranscriptTurn] { TranscriptTurn.group(segments) }
    /// Changes on both new segments and provisional-tail growth, so follow tracks either.
    private var scrollKey: String { "\(segments.count)-\(segments.last?.asr.text.count ?? 0)" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignMetrics.turnSpacing) {
                    ForEach(turns) { turn in
                        TranscriptTurnView(turn: turn)
                            .id(turn.id)
                            .transition(.motionAware(.bottom, reduceMotion: reduceMotion))
                    }
                    Color.clear.frame(height: 1).id("live")
                }
                .padding(DesignMetrics.spacingL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 48
            } action: { _, nearBottom in
                if autoFollow != nearBottom { autoFollow = nearBottom }
            }
            .onChange(of: scrollKey) {
                guard autoFollow else { return }
                withMotionAwareAnimation(DesignMetrics.liveFollowSpring, reduceMotion: reduceMotion) {
                    proxy.scrollTo("live", anchor: .bottom)
                }
            }
            .overlay(alignment: .bottom) {
                if !autoFollow {
                    jumpToLive(proxy)
                        .transition(.motionAware(.bottom, reduceMotion: reduceMotion))
                        .padding(.bottom, DesignMetrics.spacingL)
                }
            }
            .animation(reduceMotion ? nil : DesignMetrics.snappySpring, value: autoFollow)
        }
    }

    private func jumpToLive(_ proxy: ScrollViewProxy) -> some View {
        Button {
            autoFollow = true
            withMotionAwareAnimation(DesignMetrics.liveFollowSpring, reduceMotion: reduceMotion) {
                proxy.scrollTo("live", anchor: .bottom)
            }
        } label: {
            Label("Jump to live", systemImage: "arrow.down.to.line")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, DesignMetrics.spacingM)
                .padding(.vertical, DesignMetrics.spacingS)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier("record.jumpToLive")
    }
}
