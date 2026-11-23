// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RiverSimGD",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RiverSimGD", type: .dynamic, targets: ["RiverSimGD"]),
    ],
    dependencies: [
        .package(path: "../SimCore"),
        .package(url: "https://github.com/migueldeicaza/SwiftGodot", exact: "0.76.1"),
    ],
    targets: [
        .target(
            name: "RiverSimGD",
            dependencies: [
                .product(name: "SimCore", package: "SimCore"),
                .product(name: "SimRender", package: "SimCore"),
                "SwiftGodot",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
