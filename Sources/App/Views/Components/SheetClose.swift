import SwiftUI

/// Every sheet's one way out: the system close-role button — the circular gray `xmark`
/// (App Store / Music pattern) on iOS, the standard Esc-bound cancellation slot on macOS.
/// No sheet carries a "Done" button.
struct SheetCloseToolbar: ToolbarContent {
    let dismiss: () -> Void

    init(dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
    }

    var body: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .cancellationAction) {
            Button(role: .close) { dismiss() }
                .accessibilityIdentifier(A11yID.sheetClose)
        }
        #else
        ToolbarItem(placement: .topBarTrailing) {
            Button(role: .close) { dismiss() }
                .accessibilityIdentifier(A11yID.sheetClose)
        }
        #endif
    }
}
