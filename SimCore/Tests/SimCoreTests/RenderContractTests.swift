import XCTest
@testable import SimCore

/// Wächter für `RenderContract` (Issue #51): die Zahlen, die Godot-Schicht,
/// GDExtension und Shader gemeinsam annehmen müssen.
///
/// Warum hier und warum als Textvergleich: `game/scripts/Main.gd` und die
/// Shader sind headless nicht ausführbar, ihr Quelltext aber lesbar (s.
/// `RepoSource`). Genau in dieser Lücke ist die Drift entstanden, die dieser
/// Vertrag beendet — der Shader-Default von `hscale` stand auf 26.0, während
/// `Main.gd` mit 24.0 rechnete.
final class RenderContractTests: XCTestCase {

    func testHeightScaleIsTheSameInEveryLayer() throws {
        XCTAssertEqual(RenderContract.heightScale, 24.0)
        let main = try RepoSource.file("game/scripts/Main.gd")
        assertContains(main, "const HSCALE := \(glsl(RenderContract.heightScale))",
                       hint: "Mesh-Überhöhung == RenderContract.heightScale")
        let shader = try RepoSource.file("game/shaders/terrain.gdshader")
        assertContains(shader, "uniform float hscale = \(glsl(RenderContract.heightScale));",
                       hint: "Shader-Default der Überhöhung == RenderContract.heightScale")
    }

    func testRiverLiftIsTheSameInEveryLayer() throws {
        XCTAssertEqual(RenderContract.riverLift, 0.35)
        let main = try RepoSource.file("game/scripts/Main.gd")
        assertContains(main, "const RIVER_LIFT := \(glsl(RenderContract.riverLift))",
                       hint: "Band-Anhebung == RenderContract.riverLift")
        // Über Wasser gilt der Land-Lift NICHT — die beiden Wasser-Versätze
        // müssen deutlich kleiner bleiben, sonst wäre die Sonderbehandlung
        // wirkungslos (das Band schwebte als Platte über der Fläche).
        XCTAssertLessThan(WaterRender.ribbonLakeSurfaceLift, RenderContract.riverLift)
        XCTAssertLessThan(abs(WaterRender.ribbonSeaSurfaceSink), RenderContract.riverLift)
    }

    func testDefaultSeedIsTheSameInEveryLayer() throws {
        XCTAssertEqual(RenderContract.defaultSeed, 1337)
        let main = try RepoSource.file("game/scripts/Main.gd")
        assertContains(main, "var sim_seed := \(RenderContract.defaultSeed)",
                       hint: "Start-Seed der Anzeige == RenderContract.defaultSeed")
        let simNode = try RepoSource.file("Extension/Sources/RiverSimGD/SimNode.swift")
        assertContains(simNode, "seed: RenderContract.defaultSeed",
                       hint: "Erstes Terrain der GDExtension == RenderContract.defaultSeed")
    }

    /// Der Default des `Terrain`-Initialisierers ist die dritte Kopie derselben
    /// Zahl — und die einzige, die sich hier AUSFÜHREN lässt: gleicher Seed →
    /// bit-gleiches Feld (Determinismus-Invariante des Projekts).
    func testTerrainDefaultSeedMatchesTheContract() {
        var cfg = SimConfig()
        cfg.n = 96
        let implicitSeed = Terrain(config: cfg)
        let explicitSeed = Terrain(config: cfg, seed: RenderContract.defaultSeed)
        XCTAssertEqual(implicitSeed.h, explicitSeed.h,
                       "Terrain-Default-Seed weicht von RenderContract.defaultSeed ab")
    }
}
