import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter für das Kronendach (Issue #152).
///
/// WO Wald steht, rechnet `SimRender.ForestCanopyMask` auf der CPU; das ist
/// hier ausführbar geprüft:
///  - kein Wald über Rasterwasser, Seen und Flussbändern (auch nicht im
///    Filterabstand einer Zelle, den die lineare Textur verschmiert),
///  - kein Wald in Wänden, auf Schnee/Eis und im Ufersaum über dem Meer,
///  - gleiche Welt ergibt dieselbe Waldverteilung,
///  - Pinselstrich, Neugenerieren und Laden hinterlassen keinen veralteten Wald.
/// WIE er aussieht, rechnet der Terrain-Shader; davon ist headless nur die
/// STRUKTUR des Uniform-Wegs prüfbar (Muster `ReliefUniformsTests`).
final class CanopyTests: XCTestCase {

    private func aged(years: Double = 2000, seed: UInt32 = 1337) -> Terrain {
        agedWorld(renderConfig(n: 192), years: years, seed: seed)
    }

    /// Der Render-Takt aus `Main.gd`: Bänder, Wasserfeld, Schutz- und Waldmaske.
    @discardableResult
    private func refresh(_ render: RenderState, _ terrain: Terrain)
        -> (water: [UInt8], forest: [UInt8]) {
        render.buildRiverRibbons(terrain, hscale: 24, lift: 0.35)
        let water = render.waterFieldBytes(terrain, blend: 1.0)
        _ = render.protectMaskBytes(terrain)
        return (water, render.forestMaskBytes(terrain))
    }

    // MARK: - Wasser

    /// Kein Wald über sichtbaren Flüssen, Seen und Bändern, und auch nicht in
    /// der Nachbarzelle: der Shader liest die Maske linear gefiltert.
    func testNoForestOverRiversLakesOrBands() {
        let terrain = aged()
        let render = RenderState(geometryMode: true)
        let (water, forest) = refresh(render, terrain)
        let coverage = render.riverRibbonMesh.bandCoverage
        let n = terrain.cfg.n
        let river = byte01(WaterRender.protectRiverThreshold)
        let lake = byte01(WaterRender.protectLakeThreshold)

        var rivers = 0, lakes = 0, bands = 0
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                let isRiver = water[k * 4] >= river
                let isLake = water[k * 4 + 1] >= lake
                let isBand = coverage[k] >= WaterRender.protectBandThreshold
                guard isRiver || isLake || isBand else { continue }
                if isRiver { rivers += 1 }
                if isLake { lakes += 1 }
                if isBand { bands += 1 }
                for nj in max(0, j - 1)...min(n - 1, j + 1) {
                    for ni in max(0, i - 1)...min(n - 1, i + 1) {
                        XCTAssertEqual(forest[nj * n + ni], 0,
                                       "Wald an (\(ni), \(nj)) neben Wasser (\(i), \(j))")
                    }
                }
            }
        }
        XCTAssertGreaterThan(rivers, 0, "Testwelt braucht sichtbare Raster-Flüsse")
        XCTAssertGreaterThan(lakes, 0, "Testwelt braucht sichtbare Seen")
        XCTAssertGreaterThan(bands, 0, "Testwelt braucht Flussbänder")
        XCTAssertGreaterThan(forest.filter { $0 == 255 }.count, n * n / 20,
                             "Testwelt braucht geschlossenen Wald, sonst prüft der Test nichts")
    }

    // MARK: - Gelände

    /// Volle Vegetation überall; der Wald fehlt genau in der Wand, auf Schnee
    /// und im Ufersaum. Synthetisch, damit jede Schwelle allein wirkt.
    func testNoForestOnWallsSnowOrShore() {
        let n = 96
        let terrain = Terrain(config: renderConfig(n: n), seed: 1337)
        let sea = terrain.cfg.sea
        // Höhe je Zelle für eine Weltsteigung `s` in x-Richtung.
        let perCell = terrain.cfg.world / Double(n) / RenderContract.heightScale
        var state = terrain.state
        var surfaces = [UInt8](repeating: 0, count: n * n * 4)
        for j in 0..<n {
            for i in 0..<n {
                let k = j * n + i
                surfaces[k * 4] = 255
                switch i {
                case ..<24:  state.h[k] = sea + 0.2                                  // Ebene
                case ..<48:  state.h[k] = sea + 0.2 + Double(i - 24) * perCell * 2.5 // Wand
                case ..<72:  state.h[k] = sea + 0.2; surfaces[k * 4 + 2] = 255        // Schnee
                default:     state.h[k] = sea + CanopyRender.shoreLo * 0.5            // Ufersaum
                }
            }
        }
        terrain.restore(state)
        let forest = ForestCanopyMask.bytes(terrain, surfaces: surfaces,
                                            protect: [UInt8](repeating: 0, count: n * n),
                                            clump: [Float](repeating: 0, count: n * n))
        for j in 0..<n {
            for i in [4, 20] { XCTAssertEqual(forest[j * n + i], 255, "Ebene trägt Wald (\(i), \(j))") }
            for i in [30, 40, 60, 66, 80, 90] {
                XCTAssertEqual(forest[j * n + i], 0, "Wald an (\(i), \(j))")
            }
        }
    }

    // MARK: - Determinismus und Invalidierung

    func testSameWorldYieldsIdenticalForest() {
        let a = refresh(RenderState(geometryMode: true), aged(seed: 42)).forest
        let b = refresh(RenderState(geometryMode: true), aged(seed: 42)).forest
        XCTAssertEqual(a, b, "Gleiche Welt muss dieselbe Waldverteilung liefern")
    }

    /// Der Wald folgt beiden Quellen der Schutzmaske: einem Band-Bau ohne
    /// Terrain-Änderung dazwischen ebenso wie einem Wasser-Upload.
    func testForestFollowsTheProtectMask() {
        let terrain = aged()
        let render = RenderState(geometryMode: true)
        _ = render.waterFieldBytes(terrain, blend: 1.0)
        let withoutBands = render.forestMaskBytes(terrain)
        render.buildRiverRibbons(terrain, hscale: 24, lift: 0.35)
        let withBands = render.forestMaskBytes(terrain)
        XCTAssertNotEqual(withoutBands, withBands, "Band-Bau muss den Wald zurücknehmen")
        XCTAssertEqual(withBands,
                       ForestCanopyMask.bytes(terrain, surfaces: render.terrainSurfaceBytes(terrain),
                                              protect: render.protectMaskBytes(terrain),
                                              clump: ForestCanopyMask.clumpField(
                                                  n: terrain.cfg.n, world: terrain.cfg.world)))
    }

    /// Pinselstrich (über `BrushTool`, wie die Brücke): nach dem Render-Takt
    /// derselbe Wald wie in einem frischen Render-Zustand.
    func testBrushStrokeLeavesNoStaleForest() {
        let terrain = aged()
        let render = RenderState(geometryMode: true)
        let before = refresh(render, terrain).forest

        let n = Double(terrain.cfg.n)
        BrushTool.raise.apply(to: terrain, gx: n / 2, gz: n / 2,
                              radiusWorld: 25, strength: 40, target: 0)
        render.invalidate(terrain)
        terrain.recomputeFlowAfterEdit()
        render.invalidate(terrain)
        let after = refresh(render, terrain).forest

        XCTAssertNotEqual(before, after, "Pinselstrich muss den Wald verändern")
        XCTAssertEqual(after, refresh(RenderState(geometryMode: true), terrain).forest)
    }

    func testRegenerateLeavesNoStaleForest() {
        let terrain = aged()
        let render = RenderState(geometryMode: true)
        let before = refresh(render, terrain).forest

        terrain.generate(seed: 9999)
        terrain.computeFlow()
        render.invalidate(terrain, worldReplaced: true)
        let after = refresh(render, terrain).forest

        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after, refresh(RenderState(geometryMode: true), terrain).forest)
    }

    func testLoadLeavesNoStaleForest() throws {
        let saved = aged(seed: 4242)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("forest-mask-\(UUID().uuidString).rsworld").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try WorldSnapshot.write(saved, to: path)

        let render = RenderState(geometryMode: true)
        let before = refresh(render, aged()).forest
        let loaded = try WorldSnapshot.read(from: path)
        render.invalidate(loaded, worldReplaced: true)
        let after = refresh(render, loaded).forest

        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after, refresh(RenderState(geometryMode: true), loaded).forest)
    }

    // MARK: - Uniform-Weg (Struktur)

    func testEveryTableValueComesFromCanopyRender() {
        let mirror: [String: Double] = [
            "canopy_cell": CanopyRender.crownCell,
            "canopy_height": CanopyRender.canopyHeight,
            "canopy_lift_lo": CanopyRender.liftLo,
            "canopy_lift_hi": CanopyRender.liftHi,
            "canopy_crown_mid": CanopyRender.crownMid,
            "canopy_crown_spread": CanopyRender.crownSpread,
            "canopy_detail_lo": CanopyRender.detailFootprintLo,
            "canopy_detail_hi": CanopyRender.detailFootprintHi,
        ]
        XCTAssertEqual(CanopyUniforms.scalars.count, mirror.count,
                       "Tabellen-Eintrag ohne Spiegel-Zeile (oder umgekehrt)")
        for entry in CanopyUniforms.scalars {
            XCTAssertEqual(entry.value, mirror[entry.name],
                           "\(entry.name) trägt nicht seine CanopyRender-Konstante")
        }
    }

    /// Der Terrain-Shader deklariert jede Tabellen-Zahl default-frei, liest
    /// sie und deklariert keine `canopy_*`-Zahl an der Tabelle vorbei.
    func testTerrainShaderReadsExactlyTheTable() throws {
        let shader = try RepoSource.probe("game/shaders/terrain.gdshader")
        for entry in CanopyUniforms.scalars {
            assertContains(shader, "uniform float \(entry.name);",
                           hint: "\(entry.name) default-frei deklariert (Muster #92)")
            XCTAssertGreaterThanOrEqual(shader.count(ofIdentifier: entry.name), 2,
                                        "\(entry.name) wird deklariert, aber nie gelesen")
        }
        let declared = try shader.pairs(pattern: "uniform\\s+([A-Za-z0-9_]+)\\s+(canopy_[A-Za-z0-9_]+)")
        for (kind, name) in declared where kind == "float" {
            XCTAssertTrue(CanopyUniforms.scalars.contains { $0.name == name },
                          "terrain.gdshader deklariert \(name) an CanopyUniforms vorbei")
        }
        assertContains(shader, "uniform sampler2D forest_tex",
                       hint: "WO Wald steht, sagt allein die Waldmaske aus SimRender")
        assertContains(shader,
                       "VERTEX.y += calib_window(canopy_lift_lo, canopy_lift_hi, v_forest) * canopy_height;",
                       hint: "Das Dach ist angehoben (Schattenwurf der Waldkanten)")
    }

    func testBridgeAndMainCarryTheCanopy() throws {
        let bridge = try RepoSource.extensionSources()
        for needle in ["func canopyUniformNames", "func canopyUniformValues",
                       "CanopyUniforms.scalars", "func forestMaskBytes"] {
            assertContains(bridge, needle, hint: "Brücke marshallt Kronendach und Waldmaske")
        }
        XCTAssertFalse(bridge.contains("treeInstanceBuffer"),
                       "Instanzbäume sind seit #152 durch das Kronendach ersetzt")
        let main = try RepoSource.probe("game/scripts/Main.gd")
        for needle in ["canopyUniformNames()", "canopyUniformValues()", "forestMaskBytes()",
                       "static func canopy_calibration"] {
            assertContains(main, needle, hint: "Main.gd liest Kronendach und Waldmaske über die Brücke")
        }
    }
}
