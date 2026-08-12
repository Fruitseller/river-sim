// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SimCore", targets: ["SimCore"]),
        // Mess-Harness (Issue #43) — s. docs/perf-measurements.md.
        .executable(name: "simperf", targets: ["SimPerf"]),
    ],
    targets: [
        .target(name: "SimCore"),
        .executableTarget(name: "SimPerf", dependencies: ["SimCore"]),
        .testTarget(name: "SimCoreTests", dependencies: ["SimCore"]),
    ]
)
