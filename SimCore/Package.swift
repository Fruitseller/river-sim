// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SimCore", targets: ["SimCore"]),
    ],
    targets: [
        .target(name: "SimCore"),
        .testTarget(name: "SimCoreTests", dependencies: ["SimCore"]),
    ]
)
