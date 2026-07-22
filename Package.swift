// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TranscriptionStudio",
    platforms: [
        .macOS(.v27),
        .iOS(.v27)
    ],
    products: [
        // The shared, cross-platform core: engines (ASR, diarization, fusion),
        // capture, jobs, diagnostics, persistence, and the platform-agnostic UI.
        // Both the macOS app and the iOS app depend on this.
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"]),
        // The lean, Foundation-only sharing kit: the App Group drop-box, the ingest URL
        // scheme, and the shared-item classifier. Linked by BOTH the host app (via
        // TranscriptionKit) and the memory-capped Share extension — so it must stay free of
        // heavy deps (no WhisperKit/CoreAI).
        .library(name: "ShareKit", targets: ["ShareKit"]),
        // The lean, Foundation-only Background Assets kit: the WhisperKit model manifest schema
        // and the HuggingFace-URL / App-Group-staging / download-base path math. Linked by BOTH
        // the host app (via TranscriptionKit, for the launch-time install + foreground fallback)
        // and the memory-capped Background Assets downloader extension — so, like ShareKit, it
        // must stay free of heavy deps (no WhisperKit/CoreAI).
        .library(name: "BackgroundAssetsKit", targets: ["BackgroundAssetsKit"]),
        // The lean Live Activity kit: the recording/playback ActivityAttributes, the Live
        // Activity button intents (app-process trampolines), and the pure clock/level math.
        // Linked by BOTH the host app (via TranscriptionKit, which drives the activities) and
        // the memory-capped widget extension (which renders them) — so, like ShareKit, it must
        // stay free of heavy deps (no WhisperKit/CoreAI).
        .library(name: "GlanceKit", targets: ["GlanceKit"]),
        // The macOS-only feature kit: yt-dlp/ffmpeg URL ingest, ScreenCaptureKit
        // meeting capture, and the Mac window shell.
        .library(name: "TranscriptionMacKit", targets: ["TranscriptionMacKit"]),
        // Headless transcription CLI (macOS): URL or file → transcript on stdout.
        // Drives the same TranscriptionKit/MacKit pipeline the app uses.
        .executable(name: "transcribe-cli", targets: ["transcribe-cli"])
    ],
    dependencies: [
        // WhisperKit (on-device ASR) + SpeakerKit (the diarizer cross-check
        // baseline). MIT. The monorepo formerly known as argmaxinc/WhisperKit.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        // FCTFoundation (sibling checkout, ../FCTFoundation) — the shared spine. Granular
        // products only: FCTEntities for the Spotlight donation mechanism, FCTComponentsUI
        // for the shared confidence text affordance.
        .package(path: "../FCTFoundation")
    ],
    targets: [
        .target(
            name: "ShareKit",
            path: "Sources/ShareKit"
        ),
        .target(
            name: "BackgroundAssetsKit",
            dependencies: ["ShareKit"],
            path: "Sources/BackgroundAssetsKit",
            resources: [.process("Resources")]
        ),
        .target(
            name: "GlanceKit",
            path: "Sources/GlanceKit"
        ),
        .target(
            name: "TranscriptionKit",
            dependencies: [
                "ShareKit",
                "BackgroundAssetsKit",
                "GlanceKit",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "FCTEntities", package: "FCTFoundation"),
                .product(name: "FCTComponentsUI", package: "FCTFoundation"),
                // The on-device intelligence spine: the app-parameterized SemanticAssistant
                // (Siri-Q&A flagship) + GuidedExtractor/PromptSafety (the FM extraction substrate).
                .product(name: "FCTIntelligence", package: "FCTFoundation"),
                // Name → contact resolution (speaker mapping, mention matching, Siri name
                // resolution) — the pure matcher + the CNContactStore-backed provider.
                .product(name: "FCTContacts", package: "FCTFoundation"),
                // CloudKit sync-status monitor + the first-launch import bootstrap gate (the
                // companion UX depends on the user seeing sync state, not a jarring empty feed).
                .product(name: "FCTCloudKit", package: "FCTFoundation"),
                .product(name: "FCTSync", package: "FCTFoundation"),
                // The generic Live Activity lifecycle + system now-playing coordinator the
                // playback/recording activity managers drive.
                .product(name: "FCTGlanceables", package: "FCTFoundation")
            ],
            path: "Sources/TranscriptionKit",
            linkerSettings: [
                // The Sortformer diarizer runs on the raw Core AI system framework (macOS 27).
                // iOS-device linking is added by the app target (Lane C); the code is
                // `#if canImport(CoreAI)`-guarded so the iOS simulator build (no CoreAI) still compiles.
                .linkedFramework("CoreAI", .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "TranscriptionMacKit",
            dependencies: ["TranscriptionKit"],
            path: "Sources/TranscriptionMacKit"
        ),
        .executableTarget(
            name: "transcribe-cli",
            dependencies: ["TranscriptionMacKit"],
            path: "Sources/TranscribeCLI"
        ),
        .testTarget(
            name: "TranscriptionKitTests",
            dependencies: [
                "TranscriptionKit",
                "ShareKit",
                "BackgroundAssetsKit",
                "GlanceKit",
                .product(name: "FCTEntities", package: "FCTFoundation"),
                .product(name: "FCTIntelligence", package: "FCTFoundation"),
                .product(name: "FCTContacts", package: "FCTFoundation"),
                .product(name: "FCTComponentsUI", package: "FCTFoundation")
            ],
            path: "Tests/TranscriptionKitTests",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TranscriptionMacKitTests",
            dependencies: ["TranscriptionMacKit"],
            path: "Tests/TranscriptionMacKitTests"
        )
    ]
)
