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
        .target(name: "SimCore"),
        .target(name: "SimRender", dependencies: ["SimCore"]),
        .executableTarget(name: "SimPerf", dependencies: ["SimCore"]),
        .testTarget(name: "SimCoreTests", dependencies: ["SimCore", "SimRender"]),
    ],
    // Swift-5-Sprachmodus: der Code ist Swift-5-Concurrency (u. a.
    // `Terrain.parallel` mit nicht-`Sendable`-Closures über rohe Zeiger).
    // Früher als `-Xswiftc -swift-version -Xswiftc 5` an jedem Aufruf, was
    // SwiftPM je Modul mit „language mode was overridden" quittierte.
    // Umstieg auf Swift 6: eigenes Issue.
    swiftLanguageModes: [.v5]
)
