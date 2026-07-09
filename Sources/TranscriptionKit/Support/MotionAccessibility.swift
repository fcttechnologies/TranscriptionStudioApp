import SwiftUI

/// Subtle tactile press feedback for custom/plain controls. Under Reduce Motion, the feedback
/// collapses from scale to a small opacity dim so the control still acknowledges the press
/// without vestibular movement.
public struct PressableButtonStyle: ButtonStyle {
    public var pressedScale: CGFloat
    public var pressedOpacity: Double
    public var animation: Animation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(pressedScale: CGFloat = 0.97,
                pressedOpacity: Double = 0.82,
                animation: Animation = .easeOut(duration: 0.16)) {
        self.pressedScale = pressedScale
        self.pressedOpacity = pressedOpacity
        self.animation = animation
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? pressedScale : 1))
            .opacity(reduceMotion && configuration.isPressed ? pressedOpacity : 1)
            .animation(animation, value: configuration.isPressed)
    }
}

/// Reduce-Motion-aware animation + transition helpers. Every animated surface honors the
/// setting from one place: suppress sliding/translating motion, substitute a cross-fade.
extension AnyTransition {
    /// A move+fade transition that collapses to a plain cross-fade under Reduce Motion.
    public static func motionAware(_ edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: edge).combined(with: .opacity)
    }
}

extension View {
    /// Apply an animation that is suppressed (passed `nil`) under Reduce Motion. Mirrors
    /// `.animation(_:value:)` but gates the animation on the accessibility setting.
    @ViewBuilder
    public func motionAwareAnimation<V: Equatable>(_ animation: Animation?,
                                                   value: V,
                                                   reduceMotion: Bool) -> some View {
        self.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// Run `withAnimation` only when Reduce Motion is off; otherwise apply the changes with no
/// animation. For imperative animation sites (auto-scroll, live-transcript follow) that
/// aren't expressed as a `.animation` modifier.
@MainActor
public func withMotionAwareAnimation(_ animation: Animation,
                                     reduceMotion: Bool,
                                     _ body: () -> Void) {
    if reduceMotion {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    } else {
        withAnimation(animation, body)
    }
}
