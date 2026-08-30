import SwiftUI

#if os(macOS)
/// A scrolling surface's soft edges: content dissolves over the last few points of the scroll
/// view instead of being sliced mid-glyph at its boundary.
///
/// `scrollEdgeEffectStyle` is the system answer and it is the wrong tool here: it fades content
/// passing *under* chrome that sits in the scroll view's safe area. A macOS sheet lays its
/// cancellation bar out beside the content region rather than over it, so the scroll view has no
/// safe-area chrome, the effect has nothing to draw against, and the modifier is a no-op. The fade
/// is therefore drawn as a mask over the scroll view itself, which needs no chrome to exist.
///
/// macOS only. On iOS the bars are translucent and content genuinely does pass beneath them, so
/// the system already draws this and a second fade would double it.
private struct SoftScrollEdges: ViewModifier {
    let top: CGFloat
    let bottom: CGFloat

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { proxy in
                LinearGradient(stops: stops(forHeight: proxy.size.height),
                               startPoint: .top,
                               endPoint: .bottom)
            }
        }
    }

    /// Opaque through the middle, transparent at whichever edges were asked for. A surface too
    /// short to hold both fades gets none: a gradient whose stops cross would dim the whole
    /// surface, which is a worse defect than the hard edge it replaces.
    private func stops(forHeight height: CGFloat) -> [Gradient.Stop] {
        guard height > top + bottom, height > 0 else {
            return [Gradient.Stop(color: .black, location: 0),
                    Gradient.Stop(color: .black, location: 1)]
        }
        return [
            Gradient.Stop(color: .black.opacity(top > 0 ? 0 : 1), location: 0),
            Gradient.Stop(color: .black, location: top / height),
            Gradient.Stop(color: .black, location: 1 - bottom / height),
            Gradient.Stop(color: .black.opacity(bottom > 0 ? 0 : 1), location: 1)
        ]
    }
}
#endif

extension View {
    /// Fade this scrolling surface's content at its top and bottom edges instead of cutting it.
    /// A no-op off macOS — see ``SoftScrollEdges``.
    func softScrollEdges(top: CGFloat = DesignMetrics.scrollFadeLength,
                         bottom: CGFloat = DesignMetrics.scrollFadeLength) -> some View {
        #if os(macOS)
        modifier(SoftScrollEdges(top: top, bottom: bottom))
        #else
        self
        #endif
    }
}
