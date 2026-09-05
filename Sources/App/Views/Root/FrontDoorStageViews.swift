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

/// The speech models, coming down since launch; this is where the person first sees it.
///
/// The models are ~1.2 GB and the app cannot transcribe a thing without them. They start
/// downloading the moment the app first launches, in the background, on Wi-Fi, before the
/// account and the onboarding are through, so by the time the door opens most of the bytes are
/// usually here. This stage shows that progress and lets the person go on in; it never blocks.
/// When nothing is coming (no Wi-Fi, or a fetch that failed) it becomes the offer: fetch now on
/// this network, or later, where "later" means the first job fetches what it needs.
struct FrontDoorSpeechModelView: View {
    let answered: () -> Void

    @Environment(AppModel.self) private var app
    private var downloader: SpeechModelDownloader { .shared }

    var body: some View {
        VStack(spacing: DesignMetrics.spacingL) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("Speech models", comment: "Front door: the speech models stage")
                .font(.headline)

            Text(
                "Transcription runs entirely on this device, so the speech models live here too. They're about 1.2 GB and come down in the background, even while the app is closed.",
                comment: "Front door: why the speech models are large and that they download on their own"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: DesignMetrics.playbackBarMaxWidth)

            switch downloader.state {
            case .downloading(let fraction):
                VStack(spacing: DesignMetrics.spacingS) {
                    ProgressView(value: fraction)
                    Text("Downloading… \(Int((fraction * 100).rounded()))%", comment: "Front door: background download progress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: DesignMetrics.playbackBarMaxWidth)
                Button("Continue", action: answered)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(A11yID.frontDoorSpeechModelSkip)

            case .complete:
                // Nothing to decide once it has landed: the screen has served its purpose.
                ProgressView().onAppear(perform: answered)

            case .failed(let message):
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                offer

            case .idle:
                switch app.enginePrewarmState {
                case .preparing(let phase, let fraction):
                    VStack(spacing: DesignMetrics.spacingS) {
                        if let fraction { ProgressView(value: fraction) } else { ProgressView() }
                        Text(verbatim: phase).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: DesignMetrics.playbackBarMaxWidth)
                case .ready:
                    ProgressView().onAppear(perform: answered)
                case .failed(let message):
                    Text(verbatim: message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    offer
                case .idle:
                    offer
                }
            }
        }
        .padding(DesignMetrics.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.feedCanvas)
        .accessibilityIdentifier(A11yID.frontDoorSpeechModel)
    }

    /// Fetch now on this network (the engines' on-demand path), or go on in.
    private var offer: some View {
        VStack(spacing: DesignMetrics.spacingM) {
            Button("Download Now") { app.prewarmDefaultEngine() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(A11yID.frontDoorSpeechModelDownload)
            Button("Later", action: answered)
                .buttonStyle(.borderless)
                .accessibilityIdentifier(A11yID.frontDoorSpeechModelSkip)
        }
    }
}
