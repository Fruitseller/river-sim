import XCTest

@testable import SimCore
@testable import SimRender

final class SedimentPlumeTests: XCTestCase {

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

    func testPlumeHugsTheCoastInANarrowBand() {
        let terrain = openCoastWorld()
        let n = terrain.cfg.n
        let field = SedimentPlume.field(terrain)
        let band = Int(WaterRender.plumeBandCells.rounded(.down))
        var widest = 0
        for j in 0..<n {
            var offshore = 0
            for i in 0..<60 where field[j * n + i] > 0 { offshore = max(offshore, 60 - i) }
            XCTAssertLessThanOrEqual(offshore, band, "Zeile \(j): Fahne über das Küstenband hinaus")
            widest = max(widest, offshore)
        }
        XCTAssertGreaterThanOrEqual(widest, band - 1, "das Band wird auch genutzt")
        for j in 0..<n { for i in 0..<(60 - band - 1) {
            XCTAssertEqual(field[j * n + i], 0, "offenes Meer bleibt klar: (\(i), \(j))")
        } }
    }

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

        let dry = riverWorld(discharge: 100, peak: 0.65)
        render.invalidate(dry, .replaced)
        let next = try XCTUnwrap(render.frame(dry, .settled, now: 10).overlays)
        XCTAssertFalse(next.plume.contains { $0 > 0 })
    }
}
