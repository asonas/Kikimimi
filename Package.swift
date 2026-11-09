// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InterviewRecorderSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "InterviewRecorderSpike"),
        .testTarget(name: "InterviewRecorderSpikeTests", dependencies: ["InterviewRecorderSpike"])
    ]
)
