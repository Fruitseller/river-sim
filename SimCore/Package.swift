// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SimCore", targets: ["SimCore"]),
        .library(name: "SimRender", targets: ["SimRender"]),
        // Mess-Harness (Issue #43) — s. docs/perf-measurements.md.
        .executable(name: "simperf", targets: ["SimPerf"]),
    ],
    targets: [
        // Sprachmodus je Target (Issue #201): die Paket-Default-Ebene
        // (`swiftLanguageModes`) gilt für alle Targets gleich; hier steht
        // der Umstieg aber Target für Target an. SimCore/SimRender/SimPerf/
        // SimCoreTests laufen im Swift-6-Modus mit strikter
        // Nebenläufigkeitsprüfung — die unsicheren Stellen sind dort als
        // `@unchecked Sendable`/`nonisolated(unsafe)` markiert und begründet.
        .target(name: "SimCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "SimRender", dependencies: ["SimCore"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "SimPerf", dependencies: ["SimCore"],
                         swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "SimCoreTests", dependencies: ["SimCore", "SimRender"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
