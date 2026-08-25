import SwiftUI

/// The app's primary call-to-action: a filled, tinted capsule with press feedback that
/// collapses to an opacity dim under Reduce Motion (via `PressableButtonStyle`).
struct PrimaryButton: View {
    let title: LocalizedStringKey
    let systemImage: String?
    let tint: Color
    let action: () -> Void

    init(_ title: LocalizedStringKey,
                systemImage: String? = nil,
                tint: Color = .accentColor,
                action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignMetrics.spacingS) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, DesignMetrics.spacingL)
            .padding(.vertical, DesignMetrics.spacingM)
            .frame(minHeight: DesignMetrics.hitTarget)
            .frame(maxWidth: .infinity)
            .background(tint, in: Capsule())
            .foregroundStyle(.white)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// A compact circular icon button with press feedback — toolbar-style affordances that
/// live inside custom surfaces (where a plain `Button` wouldn't carry the app's feel).
struct CircleIconButton: View {
    let systemImage: String
    let tint: Color
    let action: () -> Void
    var accessibilityLabel: LocalizedStringKey

    init(systemImage: String,
                tint: Color = .primary,
                accessibilityLabel: LocalizedStringKey,
                action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: DesignMetrics.hitTarget, height: DesignMetrics.hitTarget)
                .foregroundStyle(tint)
                .background(.quaternary.opacity(0.6), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text(accessibilityLabel))
    }
}
