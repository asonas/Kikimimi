// swift-tools-version: 6.0
// Lives at <repo>/core/Package.swift (same precedent as YoruMimizuku's `core/`).
// WhisperKit is a dependency of exactly one target (RecorderWhisper). Measured while designing: fetching and building
// WhisperKit 1.1.1 + swift-argument-parser (its only dependency without BUILD_ALL) took ~10 s of build time on this machine.
import PackageDescription

let package = Package(
    name: "RecorderKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RecorderCore", targets: ["RecorderCore"]),
        .library(name: "RecorderAudio", targets: ["RecorderAudio"]),
        .library(name: "RecorderWhisper", targets: ["RecorderWhisper"]),
        .library(name: "RecorderSummary", targets: ["RecorderSummary"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.1"),
    ],
    targets: [
        // Pure domain + storage + orchestration + ports. Foundation and Observation only.
        // An architecture test fails if its sources import AVFoundation, CoreAudio, ScreenCaptureKit, AppKit, SwiftUI or WhisperKit.
        .target(name: "RecorderCore"),
        .target(name: "RecorderSummary", dependencies: ["RecorderCore"]),
        // Hardware adapters: ScreenCaptureKit, AVAudioEngine, CoreAudio, CAF spool, AAC encode, TCC probes.
        .target(name: "RecorderAudio", dependencies: ["RecorderCore"]),
        // The only importer of WhisperKit. A future SpeechAnalyzer engine becomes a sibling target, not a branch in this one.
        .target(name: "RecorderWhisper", dependencies: [
            "RecorderCore",
            .product(name: "WhisperKit", package: "WhisperKit"),
        ]),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "RecorderSummaryTests", dependencies: ["RecorderSummary"]),
        .testTarget(name: "RecorderAudioTests", dependencies: ["RecorderAudio", "RecorderCore"]),
        .testTarget(name: "RecorderWhisperTests", dependencies: ["RecorderWhisper", "RecorderCore"],
                    exclude: ["generate-fixtures.sh"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
