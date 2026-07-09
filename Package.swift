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
        // The macOS-only feature kit: yt-dlp/ffmpeg URL ingest, ScreenCaptureKit
        // meeting capture, and the Mac window shell.
        .library(name: "TranscriptionMacKit", targets: ["TranscriptionMacKit"])
    ],
    dependencies: [
        // WhisperKit (on-device ASR) + SpeakerKit (the diarizer cross-check
        // baseline). MIT. The monorepo formerly known as argmaxinc/WhisperKit.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "TranscriptionKit",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift")
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
        .testTarget(
            name: "TranscriptionKitTests",
            dependencies: ["TranscriptionKit"],
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
