import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter für Strand und Felsküste (Issue #174, Paket C): `CoastMaterial`
/// und seine Gewichte im `TerrainColorRenderer` (Sand im A-Kanal der
/// Makrofarbe, Fels im G-Kanal der Materialgewichte).
final class CoastMaterialTests: XCTestCase {

    /// Kleine Welt: Spalten `i < shore` flaches Meer, rechts davon Land mit der Höhe
    /// `land(i)`.
    private func coastWorld(n: Int = 32, shore: Int = 8,
                            land: (Int) -> Double) -> Terrain {
        let config = renderConfig(n: n)
        let terrain = Terrain(allocating: config, seed: 1337)
        var state = terrain.state
        for j in 0..<n {
            for i in 0..<n {
                // Flacher Schelf: ein tiefer Absturz an der Wasserlinie läse
                // die Makro-Steigung (±2 Zellen) schon als Steilküste.
                state.h[j * n + i] = i < shore ? config.sea - 0.002 : land(i)
            }
        }
        state.waterLevel = state.h
        terrain.restore(state)
        return terrain
    }

    func testCalibrationWindowsFitTheWaveBandAndDoNotOverlap() {
        XCTAssertLessThanOrEqual(WaterRender.beachHeightHi, SimConfig().waveBand,
                                 "Strand nur, wo die Brandung (wavePass) arbeitet")
        XCTAssertLessThan(WaterRender.beachHeightLo, WaterRender.beachHeightHi)
        XCTAssertLessThan(WaterRender.beachSlopeLo, WaterRender.beachSlopeHi)
        XCTAssertLessThan(WaterRender.cliffCoastSlopeLo, WaterRender.cliffCoastSlopeHi)
        XCTAssertLessThanOrEqual(WaterRender.beachSlopeHi, WaterRender.cliffCoastSlopeLo,
                                 "eine Küstenzelle ist Strand ODER Fels")
        XCTAssertGreaterThanOrEqual(WaterRender.coastReachCells, 1)
    }

    func testSeaDistanceIsChebyshevAndCapped() {
        let terrain = coastWorld { _ in SimConfig().sea + 0.1 }
        let dist = CoastMaterial.seaDistance(terrain)
        let n = terrain.cfg.n, cap = UInt8(WaterRender.coastReachCells + 1)
        XCTAssertEqual(dist.count, n * n)
        for i in 0..<n {
            let expected = i < 8 ? 0 : min(Int(cap), i - 7)
            XCTAssertEqual(Int(dist[10 * n + i]), expected, "Spalte \(i)")
        }
    }

    func testFlatLowCoastBecomesSandAndLeavesTheInlandAlone() {
        let sea = SimConfig().sea
        let terrain = coastWorld { _ in sea + 0.004 }
        let buffers = TerrainColorRenderer.buffers(terrain)
        let n = terrain.cfg.n, j = 16
        for i in 8...(7 + WaterRender.coastReachCells) {
            let k = j * n + i
            XCTAssertEqual(buffers.colors[k * 4 + 3], 255, "Strand an Spalte \(i)")
            XCTAssertEqual(buffers.surfaces[k * 4], 0, "kein Bewuchs auf dem Strand")
        }
        let inland = j * n + 8 + WaterRender.coastReachCells + 2
        XCTAssertEqual(buffers.colors[inland * 4 + 3], 0, "Strand nur in Reichweite der Brandung")
        for k in 0..<(n * n) where terrain.h[k] <= sea {
            XCTAssertEqual(buffers.colors[k * 4 + 3], 0, "kein Sand unter Wasser")
        }
    }

    func testSteepCoastStaysRockWithoutSand() {
        let sea = SimConfig().sea
        // 0,02 je Zelle: macroSlope = 4 · 0,02 · 0,125 = 0,01 — steil für diese Küste.
        let terrain = coastWorld { i in sea + 0.02 * Double(i - 7) }
        let buffers = TerrainColorRenderer.buffers(terrain)
        let n = terrain.cfg.n
        let k = 16 * n + 9
        XCTAssertEqual(buffers.colors[k * 4 + 3], 0, "Felsküste trägt keinen Sand")
        XCTAssertGreaterThan(buffers.surfaces[k * 4 + 1], 200, "Felsküste ist Fels")
        let far = 16 * n + 20
        XCTAssertLessThan(buffers.surfaces[far * 4 + 1], buffers.surfaces[k * 4 + 1],
                          "derselbe Hang ohne Brandung bleibt beim allgemeinen Klippen-Gewicht")
    }

    func testCoastWeightsAreDeterministic() {
        let terrain = agedWorld(renderConfig(n: 96), years: 2000)
        let a = TerrainColorRenderer.buffers(terrain), b = TerrainColorRenderer.buffers(terrain)
        XCTAssertEqual(a.colors, b.colors)
        XCTAssertEqual(a.surfaces, b.surfaces)
        XCTAssertTrue(stride(from: 3, to: a.colors.count, by: 4).contains { a.colors[$0] > 128 },
                      "gealterte Welt ohne einen einzigen Strand")
    }
}
