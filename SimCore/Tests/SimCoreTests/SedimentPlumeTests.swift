import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter für die Quellen der Sedimentfahnen (Issue #174, Paket C):
/// `SedimentPlume` und ihr Weg durch das Frame-Protokoll. Die Weichzeichnung
/// selbst ist Shader-Sache (`ocean.gdshader`), Uniform-Vertrag in
/// `WaterUniformsTests`.
final class SedimentPlumeTests: XCTestCase {

    /// Spalten `i < 6` Meer, rechts Land. In Zeile 10 läuft ein Fluss von
    /// Spalte 20 nach links ins Meer, mit `discharge` Zellen Einzugsgebiet an
    /// der Mündung und Höhen bis `peak`; in Zeile 20 ein zweiter, kleiner.
    private func riverWorld(discharge: Double, peak: Double, smallDischarge: Double = 500) -> Terrain {
        let config = renderConfig(n: 32)
        let n = config.n, sea = config.sea
        let cellArea = config.cellSize * config.cellSize
        let terrain = Terrain(allocating: config, seed: 1337)
        var state = terrain.state
        for k in 0..<(n * n) {
            let i = k % n
            state.h[k] = i < 6 ? sea - 0.03 : sea + 0.05
            state.receiver[k] = -1
            state.area[k] = 0
        }
        for (row, q, top) in [(10, discharge, peak), (20, smallDischarge, sea + 0.1)] {
            for i in 6...20 {
                let k = row * n + i
                state.h[k] = sea + 0.01 + (top - sea - 0.01) * Double(i - 6) / 14
                state.receiver[k] = Int32(k - 1)
                state.area[k] = q * cellArea * Double(21 - i) / 15
            }
        }
        state.waterLevel = state.h
        terrain.restore(state)
        return terrain
    }

    func testOneSourceCellPerLargeMouthOffshore() {
        let terrain = riverWorld(discharge: 40_000, peak: 0.65)
        let n = terrain.cfg.n
        let mouths = SedimentPlume.mouths(terrain)
        XCTAssertEqual(mouths.count, 1, "kleine Mündung unter plumeMinDischargeCells zählt nicht")
        let mouth = try! XCTUnwrap(mouths.first)
        XCTAssertEqual(mouth.landCell, 10 * n + 6)
        XCTAssertEqual(mouth.dischargeCells, 40_000, accuracy: 1e-6)
        XCTAssertEqual(mouth.relief, 0.65 - terrain.cfg.sea, accuracy: 1e-9,
                       "Relief = höchster Punkt des Einzugsgebiets über dem Meer")
        // In Fließrichtung bis zu plumeOffshoreCells ins Meer hinaus.
        XCTAssertEqual(mouth.sourceCell, 10 * n + 6 - WaterRender.plumeOffshoreCells)
        XCTAssertLessThanOrEqual(terrain.h[mouth.sourceCell], terrain.cfg.sea)

        let field = SedimentPlume.field(terrain)
        XCTAssertEqual(field.count, n * n)
        XCTAssertEqual(field.filter { $0 > 0 }.count, 1, "EINE Zelle je Mündung")
        XCTAssertEqual(Double(field[mouth.sourceCell]), SedimentPlume.strength(mouth), accuracy: 1e-6)
        XCTAssertEqual(field, SedimentPlume.field(terrain), "deterministisch")
    }

    func testStrengthGrowsWithDischargeAndLoad() {
        func strength(_ q: Double, _ relief: Double) -> Double {
            SedimentPlume.strength(.init(landCell: 0, sourceCell: 0, dischargeCells: q, relief: relief))
        }
        XCTAssertEqual(strength(WaterRender.plumeMinDischargeCells, 1), 0, accuracy: 1e-12,
                       "an der Schwelle setzt die Fahne weich ein, ohne Sprung")
        XCTAssertEqual(strength(WaterRender.plumeFullDischargeCells, WaterRender.plumeFullRelief), 1,
                       accuracy: 1e-12)
        XCTAssertGreaterThan(strength(20_000, 0.4), strength(5_000, 0.4), "mehr Abfluss, mehr Trübung")
        XCTAssertGreaterThan(strength(20_000, 0.4), strength(20_000, 0.1), "mehr Fracht, mehr Trübung")
        XCTAssertEqual(strength(WaterRender.plumeFullDischargeCells, 0), WaterRender.plumeReliefFloor,
                       accuracy: 1e-12, "auch ein flaches Einzugsgebiet trübt etwas")
    }

    func testRenderFrameCarriesThePlumeAndDropsItWithTheTerrain() throws {
        let terrain = riverWorld(discharge: 40_000, peak: 0.65)
        let render = RenderState(geometryMode: true)
        let overlays = try XCTUnwrap(render.frame(terrain, .settled, now: 0).overlays)
        XCTAssertEqual(overlays.plume, SedimentPlume.field(terrain))
        XCTAssertTrue(overlays.plume.contains { $0 > 0 })

        // Eine ANDERE Welt ohne Mündung: der Cache darf die alte Fahne nicht zeigen.
        let dry = riverWorld(discharge: 100, peak: 0.65)
        render.invalidate(dry, .replaced)
        let next = try XCTUnwrap(render.frame(dry, .settled, now: 10).overlays)
        XCTAssertFalse(next.plume.contains { $0 > 0 })
    }

    /// Die Fahne kommt mit den Overlays und blendet mit ihnen (#174): die
    /// Mip-Weichzeichnung allein glättete den Sprung nicht.
    func testPlumeFadesWithTheOverlays() throws {
        let ocean = try RepoSource.probe("game/shaders/ocean.gdshader")
        assertContains(ocean, "uniform sampler2D plume_prev_tex", hint: "Vorgängerstand der Fahne")
        assertContains(ocean, "mix(textureLod(plume_prev_tex, uv, lod).r, s, overlay_blend)",
                       hint: "plume_at mischt über die Overlay-Blende")
        XCTAssertEqual(ocean.count(of: "textureLod(plume_tex,"), 1,
                       "plume_tex nur in plume_at lesen")
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "overlay_fade.bind(ocean_mat)", hint: "Das Meer hängt an der Overlay-Blende")
        assertContains(main, "plume_prev_tex.update(previous)",
                       hint: "Der alte Stand wandert vor dem Upload nach plume_prev_tex")
    }
}
