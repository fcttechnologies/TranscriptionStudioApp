import SwiftUI

/// The beat between the gate letting a session through and the front door deciding where it goes.
/// No copy: it is one frame in the ordinary case, and naming a wait that isn't happening is worse
/// than saying nothing.
struct FrontDoorLaunchingView: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.feedCanvas)
            .accessibilityIdentifier(A11yID.frontDoorLaunching)
    }
}

/// The account's first pull, named. A returning user watching this knows their library is on its
/// way; the same second spent under an empty "no sessions yet" reads as their library being gone.
struct FrontDoorRestoringView: View {
    var body: some View {
        VStack(spacing: DesignMetrics.spacingL) {
            ProgressView()
                .controlSize(.large)
            Text("Restoring your library…", comment: "Front door: the account's first pull is running")
                .font(.headline)
            Text(
                "Getting your transcripts, highlights and speakers from your account.",
                comment: "Front door: what the account's first pull is fetching"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(DesignMetrics.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.feedCanvas)
        .accessibilityIdentifier(A11yID.frontDoorRestoring)
    }
}

/// The pull could not complete. It says so and offers the retry, rather than falling through to a
/// feed that would claim the library is empty on the strength of a question nobody answered.
struct FrontDoorRestoreFailedView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: DesignMetrics.spacingL) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Couldn’t restore your library", comment: "Front door: the first pull failed")
                .font(.headline)
            Text(verbatim: message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(A11yID.frontDoorRetry)
        }
        .padding(DesignMetrics.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.feedCanvas)
        .accessibilityIdentifier(A11yID.frontDoorRestoreFailed)
    }
}
