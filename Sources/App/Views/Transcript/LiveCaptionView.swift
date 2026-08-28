import SwiftUI

/// The live-caption stage: the streaming transcript rendered large and high-contrast for
/// reading at a distance — the accessibility-first face of a live recording (Deaf / hard-of-
/// hearing, a phone propped on a table). It reads the same fused `segments` the live sheet does,
/// windowed to the most recent lines by `LiveCaptionBuilder`, auto-following the newest text and
/// yielding the moment the reader scrolls back. Speaker-labeled when the diarizer is attributing,
/// a clean unlabeled flow when it isn't. Dynamic-Type-respecting with an in-view size control for
/// distance, and motion-aware throughout.
struct LiveCaptionView: View {
    let segments: [AttributedSegment]
    /// False when the diarizer is unavailable — captions render as one unlabeled flow.
    let showsSpeakers: Bool

    /// Reader-chosen size step (0…3), persisted so distance setup survives across recordings.
    @AppStorage("liveCaption.sizeStep") private var sizeStep = 1
    /// The largeTitle-relative base that Dynamic Type scales; the step multiplies it for distance.
    @ScaledMetric(relativeTo: .largeTitle) private var scaledBase: CGFloat = 34

    @State private var autoFollow = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(segments: [AttributedSegment], showsSpeakers: Bool) {
        self.segments = segments
        self.showsSpeakers = showsSpeakers
    }

    private static let sizeFactors: [CGFloat] = [0.8, 1.0, 1.3, 1.7]
    private var fontSize: CGFloat { scaledBase * Self.sizeFactors[min(max(sizeStep, 0), 3)] }

    private var lines: [CaptionLine] {
        LiveCaptionBuilder.lines(from: segments, showsSpeakers: showsSpeakers)
    }
    /// Changes on new lines and on the provisional tail growing, so follow tracks either.
    private var scrollKey: String { "\(lines.count)-\(lines.last?.text.count ?? 0)" }

    var body: some View {
        ZStack {
            if lines.isEmpty {
                listening
            } else {
                captions
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay(alignment: .bottomTrailing) { sizeControl }
    }

    private var listening: some View {
        VStack(spacing: DesignMetrics.spacingM) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
                .symbolEffect(.pulse, isActive: !reduceMotion)
            Text("Listening…")
                .font(.system(size: fontSize * 0.7, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Listening. Captions appear here as you speak.")
    }

    private var captions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: fontSize * 0.55) {
                    ForEach(lines) { line in
                        captionLine(line)
                            .id(line.id)
                            .transition(.motionAware(.bottom, reduceMotion: reduceMotion))
                    }
                    Color.clear.frame(height: 1).id("captionLive")
                }
                .padding(.horizontal, DesignMetrics.spacingXL)
                .padding(.vertical, DesignMetrics.spacingXXL)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 64
            } action: { _, nearBottom in
                if autoFollow != nearBottom { autoFollow = nearBottom }
            }
            .onChange(of: scrollKey) {
                guard autoFollow else { return }
                withMotionAwareAnimation(DesignMetrics.liveFollowSpring, reduceMotion: reduceMotion) {
                    proxy.scrollTo("captionLive", anchor: .bottom)
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

    @ViewBuilder
    private func captionLine(_ line: CaptionLine) -> some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingXS) {
            if let label = line.speakerLabel {
                Text(label)
                    .font(.system(size: fontSize * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignMetrics.color(for: line.speaker))
                    .accessibilityHidden(true)
            }
            Text(line.text)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(line.isProvisional ? AnyShapeStyle(.primary.opacity(0.55))
                                                     : AnyShapeStyle(.primary))
                .lineSpacing(fontSize * 0.14)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.speakerLabel.map { "\($0): \(line.text)" } ?? line.text)
    }

    private func jumpToLive(_ proxy: ScrollViewProxy) -> some View {
        Button {
            autoFollow = true
            withMotionAwareAnimation(DesignMetrics.liveFollowSpring, reduceMotion: reduceMotion) {
                proxy.scrollTo("captionLive", anchor: .bottom)
            }
        } label: {
            Label("Jump to live", systemImage: "arrow.down.to.line")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, DesignMetrics.spacingL)
                .padding(.vertical, DesignMetrics.spacingS)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier(A11yID.captionJumpToLive)
    }

    private var sizeControl: some View {
        HStack(spacing: DesignMetrics.spacingM) {
            Button {
                sizeStep = max(sizeStep - 1, 0)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.title3.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(sizeStep == 0)
            .accessibilityLabel("Smaller captions")

            Button {
                sizeStep = min(sizeStep + 1, 3)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.title3.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(sizeStep == 3)
            .accessibilityLabel("Larger captions")
        }
        .padding(.horizontal, DesignMetrics.spacingS)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(DesignMetrics.spacingL)
        .accessibilityIdentifier(A11yID.captionSizeControl)
    }
}
