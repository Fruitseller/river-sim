// swift-tools-version: 5.9
import PackageDescription

// GDExtension-Brücke: linkt den reinen Sim-Kern (SimCore) an SwiftGodot und
// erzeugt eine dynamische Library, die Godot als GDExtension lädt.
let package = Package(
    name: "RiverSimGD",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RiverSimGD", type: .dynamic, targets: ["RiverSimGD"]),
    ],
    dependencies: [
        .package(path: "../SimCore"),
        .package(url: "https://github.com/migueldeicaza/SwiftGodot", branch: "main"),
    ],
    targets: [
        .target(
            name: "RiverSimGD",
            dependencies: [
                .product(name: "SimCore", package: "SimCore"),
                "SwiftGodot",
            ]
        ),
    ]
)
