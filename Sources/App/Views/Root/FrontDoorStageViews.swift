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

/// The speech model, offered rather than sprung.
///
/// The models are ~700 MB (the recognizer for this locale and the diarizer) and the app cannot
/// transcribe a thing without them. Before this stage existed they arrived on their own — correct,
/// and silent: the download simply began, and the first person to learn its size was whoever
/// watched a cellular bill or waited out a first transcription that seemed to hang. Naming the
/// number and offering the choice costs one screen, once, and it is the difference between a
/// first run that explains itself and one that doesn't.
///
/// **Skipping is a real answer, not a deferral.** "Later" restores exactly the old behaviour —
/// the model still downloads on its own when it is first needed — so nothing is broken by
/// declining and nobody is trapped on this screen.
struct FrontDoorSpeechModelView: View {
    let answered: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: DesignMetrics.spacingL) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("Get the speech models", comment: "Front door: the speech model download offer")
                .font(.headline)

            Text(
                "Transcription runs entirely on this device, which means the speech models have to live here too. They're about 700 MB — worth getting on Wi-Fi now rather than partway through your first recording.",
                comment: "Front door: why the speech model is large and why now is a good time"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: DesignMetrics.playbackBarMaxWidth)

            switch app.enginePrewarmState {
            case .preparing(let phase, let fraction):
                VStack(spacing: DesignMetrics.spacingS) {
                    if let fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Text(verbatim: phase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: DesignMetrics.playbackBarMaxWidth)

            case .ready:
                // Nothing to decide once it has landed: the screen has served its purpose and
                // leaving a button here would only ask the reader to confirm a finished fact.
                ProgressView().onAppear(perform: answered)

            case .failed(let message):
                // A failed warmup is not a dead end — the first real job retries — so this says
                // what happened and still lets the reader through.
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                actions

            case .idle:
                actions
            }
        }
        .padding(DesignMetrics.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.feedCanvas)
        .accessibilityIdentifier(A11yID.frontDoorSpeechModel)
    }

    private var actions: some View {
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
