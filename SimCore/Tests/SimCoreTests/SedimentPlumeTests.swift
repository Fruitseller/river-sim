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

    /// Weites Meer (Spalten `i < 60`), rechts flaches Land, senkrechte Küste.
    /// In Zeile 40 mündet ein großer Fluss, in Zeile 80 ein kleiner (unter
    /// `plumeMinDischargeCells`).
    private func openCoastWorld(discharge: Double = 40_000, peak: Double = 0.65) -> Terrain {
        let config = renderConfig(n: 96)
        let n = config.n, sea = config.sea
        let cellArea = config.cellSize * config.cellSize
        let terrain = Terrain(allocating: config, seed: 1337)
        var state = terrain.state
        for k in 0..<(n * n) {
            let i = k % n
            state.h[k] = i < 60 ? sea - 0.03 : sea + 0.05
            state.receiver[k] = -1
            state.area[k] = 0
        }
        for (row, q, top) in [(40, discharge, peak), (80, 500.0, sea + 0.1)] {
            for i in 60...90 {
                let k = row * n + i
                state.h[k] = sea + 0.01 + (top - sea - 0.01) * Double(i - 60) / 30
                state.receiver[k] = Int32(k - 1)
                state.area[k] = q * cellArea * Double(91 - i) / 31
            }
        }
        state.waterLevel = state.h
        terrain.restore(state)
        return terrain
    }

    func testPlumeStartsAtTheMouthAndNeverTouchesLand() throws {
        let terrain = openCoastWorld()
        let n = terrain.cfg.n
        let mouths = SedimentPlume.mouths(terrain)
        XCTAssertEqual(mouths.count, 1, "kleine Mündung unter plumeMinDischargeCells zählt nicht")
        let mouth = try XCTUnwrap(mouths.first)
        XCTAssertEqual(mouth.landCell, 40 * n + 60)
        XCTAssertEqual(mouth.seaCell, 40 * n + 59, "die Fahne beginnt auf der ersten Meereszelle")
        XCTAssertEqual(mouth.dischargeCells, 40_000, accuracy: 1e-6)
        XCTAssertEqual(mouth.relief, 0.65 - terrain.cfg.sea, accuracy: 1e-9,
                       "Relief = höchster Punkt des Einzugsgebiets über dem Meer")

        let field = SedimentPlume.field(terrain)
        XCTAssertEqual(field.count, n * n)
        XCTAssertEqual(Double(field[mouth.seaCell]), SedimentPlume.strength(mouth), accuracy: 1e-6,
                       "an der Mündung gilt die volle Stärke")
        XCTAssertEqual(field, SedimentPlume.field(terrain), "deterministisch")
        XCTAssertEqual(field.max() ?? 0, field[mouth.seaCell], "die Mündung ist die dichteste Stelle")
        for k in 0..<(n * n) {
            XCTAssertTrue(field[k] >= 0 && field[k].isFinite)
            if terrain.h[k] > terrain.cfg.sea { XCTAssertEqual(field[k], 0, "keine Fahne an Land") }
        }
    }

    /// Küstennah und schmal: der Streifen reicht höchstens `plumeBandCells` ins
    /// Meer; offenes Meer bleibt klar (der Rauchfächer des alten Shaders reichte
    /// bis zu 32 Zellen hinaus).
    func testPlumeHugsTheCoastInANarrowBand() {
        let terrain = openCoastWorld()
        let n = terrain.cfg.n
        let field = SedimentPlume.field(terrain)
        let band = Int(WaterRender.plumeBandCells.rounded(.down))
        var widest = 0
        for j in 0..<n {
            var offshore = 0   // größter Abstand zum Land (Zellen) einer Fahnenzelle in dieser Zeile
            for i in 0..<60 where field[j * n + i] > 0 { offshore = max(offshore, 60 - i) }
            XCTAssertLessThanOrEqual(offshore, band, "Zeile \(j): Fahne über das Küstenband hinaus")
            widest = max(widest, offshore)
        }
        XCTAssertGreaterThanOrEqual(widest, band - 1, "das Band wird auch genutzt")
        for j in 0..<n { for i in 0..<(60 - band - 1) {
            XCTAssertEqual(field[j * n + i], 0, "offenes Meer bleibt klar: (\(i), \(j))")
        } }
    }

    /// Klingt schnell ab und endet: ab `plumeCutoffDecays` Abklinglängen ist
    /// nichts mehr da; entlang der Küste nimmt die Dichte nicht zu.
    func testPlumeFadesQuicklyAndEnds() {
        let terrain = openCoastWorld()
        let n = terrain.cfg.n
        let field = SedimentPlume.field(terrain)
        let cutoff = WaterRender.plumeDecayCells * WaterRender.plumeCutoffDecays
        for k in 0..<(n * n) where field[k] > 0 {
            let dx = Double(k % n - 59), dz = Double(k / n - 40)
            XCTAssertLessThan((dx * dx + dz * dz).squareRoot(), cutoff, "Fahne über die Pfadlänge hinaus")
        }
        for direction in [1, -1] {
            var previous = Float.infinity
            for d in 0...30 {
                let value = field[(40 + direction * d) * n + 59]
                XCTAssertLessThanOrEqual(value, previous + 1e-6, "Dichte wächst entlang der Küste (d = \(d))")
                previous = value
            }
            XCTAssertLessThan(field[(40 + direction * 25) * n + 59],
                              0.5 * field[40 * n + 59], "nach 25 Zellen unter der halben Dichte")
        }
    }

    /// Die Fahne folgt der Küstenströmung: stromab (Welt-z, Zeilen +) reicht sie
    /// weiter als stromauf.
    func testPlumeReachesFurtherDownstream() {
        let terrain = openCoastWorld()
        let n = terrain.cfg.n
        let field = SedimentPlume.field(terrain)
        func reach(_ direction: Int) -> Int {
            var last = 0
            for d in 0..<40 where field[(40 + direction * d) * n + 59] > 0.02 { last = d }
            return last
        }
        XCTAssertGreaterThan(reach(1), reach(-1) + 5, "stromab weiter als stromauf")
    }

    /// Sichtbare Fläche (Anteil der Trübungsfarbe ≥ 10 %) einer vollen Fahne:
    /// der alte Fächer deckte rund 3000 Zellen (§F), hier bleibt es unter 600.
    func testVisiblePlumeAreaStaysSmall() {
        let field = SedimentPlume.field(openCoastWorld(discharge: 60_000, peak: 0.9))
        let visible = field.filter { Double($0) * WaterRender.oceanPlumeOpacity >= 0.1 }.count
        XCTAssertGreaterThan(visible, 40, "eine volle Fahne ist erkennbar")
        XCTAssertLessThan(visible, 600, "und kein Rauchfächer")
    }

    func testStrengthGrowsWithDischargeAndLoad() {
        func strength(_ q: Double, _ relief: Double) -> Double {
            SedimentPlume.strength(.init(landCell: 0, seaCell: 0, dischargeCells: q, relief: relief))
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
}
