import SwiftUI

/// The circular sheet-close affordance (the App Store / Music pattern): a small gray
/// translucent circle with a bold `xmark`, top-trailing in every sheet. The app's one way
/// out of a sheet — there are no "Done" toolbar buttons.
public struct SheetCloseButton: View {
    let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: DesignMetrics.closeGlyphSize, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: DesignMetrics.closeButtonSize, height: DesignMetrics.closeButtonSize)
                .background(.quaternary.opacity(0.6), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close")
        .accessibilityIdentifier("sheet.close")
    }
}

/// The app's sheet shell: a quiet header row — title, any per-sheet action controls, the
/// circular close — over the sheet's content. One component so every sheet (Settings,
/// Inspector, session detail, live recording, intelligence) dismisses identically.
public struct StudioSheet<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let accessory: () -> Accessory

    @Environment(\.dismiss) private var dismiss

    public init(_ title: String,
                @ViewBuilder content: @escaping () -> Content,
                @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.content = content
        self.accessory = accessory
    }

    public init(_ title: String, @ViewBuilder content: @escaping () -> Content)
        where Accessory == EmptyView {
        self.init(title, content: content, accessory: { EmptyView() })
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignMetrics.spacingM) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                accessory()
                SheetCloseButton { dismiss() }
            }
            .padding(.horizontal, DesignMetrics.spacingL)
            .padding(.vertical, DesignMetrics.spacingM)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }
}
