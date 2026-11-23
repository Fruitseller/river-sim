// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SimCore", targets: ["SimCore"]),
        .library(name: "SimRender", targets: ["SimRender"]),
        .executable(name: "simperf", targets: ["SimPerf"]),
    ],
    targets: [
        .target(name: "SimCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "SimRender", dependencies: ["SimCore"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "SimPerf", dependencies: ["SimCore"],
                         swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "SimCoreTests", dependencies: ["SimCore", "SimRender"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
