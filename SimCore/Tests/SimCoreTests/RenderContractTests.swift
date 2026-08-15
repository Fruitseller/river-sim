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
        assertContains(main, "set_shader_parameter(\"hscale\", HSCALE)",
                       hint: "Shader-Uniform der Überhöhung == Main.gd HSCALE")
        let shader = try RepoSource.file("game/shaders/terrain.gdshader")
        assertContains(shader, "uniform float hscale = \(glsl(RenderContract.heightScale));",
                       hint: "Shader-Default der Überhöhung == RenderContract.heightScale")
        // Nicht nur die DEKLARATION pinnen, sondern jede ANWENDUNG: ein
        // zusätzlicher Faktor am Displacement (`* hscale * 1.08`) oder eine
        // eigene Konstante in den Normalen ließe den Vertrag grün und das
        // gerenderte Terrain trotzdem von `HSCALE` abweichen — genau die
        // Drift-Klasse, die #51 beendet. Die drei Zeilen sind alle Stellen, die
        // den Uniform lesen (Vertex-Höhe, Vertex-Normale, per-Pixel-Normale).
        for use in ["VERTEX.y = mix(hraw, hfv, lift) * hscale;",
                    "NORMAL = normalize(vec3(-(hR - hL) * hscale, 2.0 * sw, -(hD - hU) * hscale));",
                    "vec3 n_ws = normalize(vec3(-s_uv.x * hscale / world_size, 1.0,"
                        + " -s_uv.y * hscale / world_size));"] {
            assertContains(shader, use,
                           hint: "Überhöhung wird unskaliert angewandt (keine Zusatzfaktoren)")
        }
        // Und keine vierte, ungeprüfte Anwendung: die Zahl der `hscale`-Vorkommen
        // im Shader ist gepinnt — 1 Deklaration + 1 Vertex-Höhe + 2 Vertex-Normale
        // + 2 per-Pixel-Normale = 6, alle in den Zeilen oben abgedeckt.
        XCTAssertEqual(shader.components(separatedBy: "hscale").count - 1, 6,
                       "Neue oder entfernte `hscale`-Anwendung im Terrain-Shader —"
                       + " Liste der geprüften Stellen mitziehen")
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
        let simNode = try RepoSource.extensionSources()
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
