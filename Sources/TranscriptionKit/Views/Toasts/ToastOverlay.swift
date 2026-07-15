import SwiftUI

/// The visual for one toast — the app's card surface (never glass: a toast is content-layer
/// notice, and glass stays on chrome), a tinted leading glyph or a small spinner, title +
/// optional message, and an optional trailing action button. Swipe up or tap-through
/// dismisses; a body tap runs the action.
struct ToastView: View {
    let toast: Toast
    let center: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0

    /// Upward drag past this dismisses; anything less springs back.
    private let dismissThreshold: CGFloat = 36

    private var tint: Color {
        switch toast.style {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignMetrics.spacingM) {
            Group {
                if toast.isProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: toast.systemImage)
                        .font(.title3)
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.subheadline.weight(.semibold))
                if let message = toast.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                }
            }

            Spacer(minLength: 0)

            if let label = toast.actionLabel {
                Button(label) { center.runAction(for: toast) }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, DesignMetrics.spacingM)
        .padding(.horizontal, DesignMetrics.spacingL)
        .cardStyle(cornerRadius: DesignMetrics.toastCorner, elevated: true)
        .frame(maxWidth: DesignMetrics.toastMaxWidth)
        .contentShape(.rect)
        .offset(y: min(dragOffset, 0))
        .gesture(dragGesture)
        .onTapGesture {
            if toast.action != nil { center.runAction(for: toast) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text([toast.title, toast.message].compactMap { $0 }.joined(separator: ". ")))
        .accessibilityAddTraits(toast.action != nil ? .isButton : [])
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                center.suspendAutoDismiss(for: toast.id)
                dragOffset = min(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height < -dismissThreshold {
                    center.dismiss(id: toast.id)
                    return
                }
                withAnimation(reduceMotion ? nil : DesignMetrics.snappySpring) { dragOffset = 0 }
                center.resumeAutoDismiss(for: toast.id)
            }
    }
}

/// The top-aligned host that renders the current toast. Sits as a ZStack sibling to the app
/// content so it respects the safe area, and its empty region (a `Spacer`) passes touches
/// straight through to the content below.
struct ToastHost: View {
    let center: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let toast = center.current {
                ToastView(toast: toast, center: center)
                    .padding(.horizontal, DesignMetrics.spacingM)
                    .padding(.top, DesignMetrics.spacingS)
                    .transition(.motionAware(.top, reduceMotion: reduceMotion))
                    .id(toast.id)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : DesignMetrics.standardSpring, value: center.current?.id)
    }
}

public extension View {
    /// Install the shared in-app toast layer above this view. Apply once at each app root;
    /// toasts raised through `ToastCenter.shared` surface here.
    func toastOverlay(center: ToastCenter = .shared) -> some View {
        ZStack(alignment: .top) {
            self
            ToastHost(center: center)
        }
    }
}
