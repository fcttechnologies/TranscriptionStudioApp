#if DEBUG
import FCTAccount
import SwiftUI

/// The shared FCT test account, read from the process environment.
///
/// The credential lives in the env store and is passed to the app at launch, never written into
/// this repo. Absent env vars mean the affordance simply isn't there, so a Debug build on a
/// machine that was never given the credential behaves exactly like a release one.
nonisolated enum DebugTestAccount {
    static let emailKey = "FCT_TEST_ACCOUNT_EMAIL"
    static let passwordKey = "FCT_TEST_ACCOUNT_PASSWORD"

    static var credentials: (email: String, password: String)? {
        let environment = ProcessInfo.processInfo.environment
        guard let email = environment[emailKey], !email.isEmpty,
              let password = environment[passwordKey], !password.isEmpty
        else { return nil }
        return (email, password)
    }
}

/// One tap to the signed-in state, for an agent driving a Debug build.
///
/// It sits on the front door rather than in Settings, because Settings does not exist until a
/// session does — signing in is the very thing being skipped. It calls the same
/// `AccountController.signIn` the typed form calls, so nothing about the real path is bypassed.
struct DebugTestAccountSignInBar: View {
    let controller: AccountController

    @State private var failure: String?

    var body: some View {
        if let credentials = DebugTestAccount.credentials {
            VStack(spacing: DesignMetrics.spacingS) {
                Button {
                    Task {
                        failure = nil
                        await controller.signIn(email: credentials.email, password: credentials.password)
                        if !controller.state.isSignedIn {
                            failure = "Sign-in failed for \(credentials.email)."
                        }
                    }
                } label: {
                    // Deliberately not localized: a Debug-only affordance in the shipped catalog is
                    // a string ten translators carry for a button no user ever sees.
                    Label {
                        Text(verbatim: "Sign in as test account")
                    } icon: {
                        Image(systemName: "ladybug")
                    }
                    .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled(controller.isWorking)
                .accessibilityIdentifier(A11yID.debugTestAccountSignIn)

                Text(verbatim: failure ?? credentials.email)
                    .font(.caption2)
                    .foregroundStyle(failure == nil ? Color.secondary : Color.red)
                    .accessibilityIdentifier(A11yID.debugTestAccountStatus)
            }
            .padding(.bottom, DesignMetrics.spacingM)
        }
    }
}
#endif
