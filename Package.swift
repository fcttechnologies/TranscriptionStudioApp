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
            path: "Sources/TranscriptionKit"
        ),
        .target(
            name: "TranscriptionMacKit",
            dependencies: ["TranscriptionKit"],
            path: "Sources/TranscriptionMacKit"
        ),
        .testTarget(
            name: "TranscriptionKitTests",
            dependencies: ["TranscriptionKit"],
            path: "Tests/TranscriptionKitTests"
        ),
        .testTarget(
            name: "TranscriptionMacKitTests",
            dependencies: ["TranscriptionMacKit"],
            path: "Tests/TranscriptionMacKitTests"
        )
    ]
)
