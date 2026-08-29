import SwiftUI

/// The app's card surface — a rounded fill with a hairline seam (the VillainArc idiom: a faint
/// ring around the fill reads as a raised card without a heavy shadow). The seam is drawn in
/// both appearances, because a card's own edge is the only thing that separates it from a
/// same-colored backdrop, and a light-mode card fill and a light-mode window are both white.
/// One place owns the material so every surface in the app matches.
private struct CardStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let elevated: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    func body(content: Content) -> some View {
        content
            .background {
                if colorScheme == .dark {
                    shape.fill(.white.opacity(DesignMetrics.surfaceSeamOpacity))
                        .overlay {
                            shape.inset(by: DesignMetrics.surfaceRingWidth)
                                .fill(Color(white: 0.11))
                        }
                } else {
                    shape.fill(.background)
                        .overlay {
                            shape.strokeBorder(.black.opacity(DesignMetrics.surfaceSeamOpacity),
                                               lineWidth: DesignMetrics.surfaceRingWidth)
                        }
                }
            }
            .clipShape(shape)
            .shadow(color: elevated ? .black.opacity(DesignMetrics.cardShadowOpacity) : .clear,
                    radius: DesignMetrics.cardShadowRadius,
                    y: DesignMetrics.cardShadowY)
    }
}

extension View {
    /// Wrap content in the standard app card surface.
    func cardStyle(cornerRadius: CGFloat = DesignMetrics.cornerL, elevated: Bool = false) -> some View {
        modifier(CardStyle(cornerRadius: cornerRadius, elevated: elevated))
    }

    /// A subtle inset sub-surface (a well inside a card) using a thin material.
    func subSurface(cornerRadius: CGFloat = DesignMetrics.cornerM) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self.background(shape.fill(.quaternary.opacity(0.5))).clipShape(shape)
    }
}

extension ShapeStyle where Self == Color {
    /// The home feed's canvas — the grouped background the card surfaces sit on, a step off the
    /// card fill in both appearances so the cards read as raised. On macOS that step is
    /// `underPageBackgroundColor`: `windowBackgroundColor` is pure white in Light Aqua, the same
    /// value the card fills with, which would leave the feed's cards with no tonal separation.
    static var feedCanvas: Color {
        #if os(iOS)
        Color(.systemGroupedBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }
}

/// A small uppercase section label — the quiet header above a group of controls or rows.
struct SectionLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}
