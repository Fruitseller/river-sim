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
        // SwiftGodot ist auf eine EXAKTE Upstream-Version gepinnt (Issue #49).
        // Vorher stand hier `branch: "main"`: jeder frische Klon und jeder
        // `swift package update` konnte damit eine andere Auflösung ziehen —
        // beim Codegen-lastigen SwiftGodot heißt das im besten Fall ~20 min
        // Voll-Neubau, im schlechtesten eine still geänderte Godot-API.
        // 0.76.1 ist genau die Revision, die bisher in Extension/Package.resolved
        // stand (be57caa3e81b9ac510bc7cc2e277003c706ab0a5 == Tag v0.76.1) — der
        // Pin ist also kein Versionswechsel, sondern friert den Ist-Stand ein.
        // Update-Verfahren (bewusster, eigener Commit): AGENTS.md, Abschnitt
        // „SwiftGodot-Pin".
        .package(url: "https://github.com/migueldeicaza/SwiftGodot", exact: "0.76.1"),
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
