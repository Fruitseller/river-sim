import XCTest
@testable import SimCore

final class VegetationTests: XCTestCase {

    func testRiparianClassOnlyNearWater() {
        var c = SimConfig(); c.n = 192; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        for _ in 0..<10 { t.step(dtYears: 500) }
        let n = c.n
        let cellArea = c.cellSize * c.cellSize
        let minA = c.braidMinCells * cellArea
        var riparianCount = 0
        for j in 2..<(n - 2) {
            for i in 2..<(n - 2) {
                let k = j * n + i
                guard t.vegClass[k] == 3 else { continue }
                riparianCount += 1
                var nearWater = false
                for dj in max(0, j - 3)...min(n - 1, j + 3) {
                    for di in max(0, i - 3)...min(n - 1, i + 3) {
                        let kk = dj * n + di
                        if t.hf[kk] > c.sea
                            && (t.area[kk] >= minA || t.hf[kk] - t.h[kk] > 0.015) {
                            nearWater = true
                        }
                    }
                }
                XCTAssertTrue(nearWater, "Auwald-Zelle (\(i),\(j)) ohne Wasser im Umkreis")
                let slope = Terrain.macroSlope(t.h, k, n)
                XCTAssertLessThan(slope * 40, 0.6, "Auwald auf steilem Hang (\(i),\(j))")
                XCTAssertLessThanOrEqual(t.hf[k] - t.h[k], 0.02, "Auwald unter Wasser (\(i),\(j))")
            }
        }
        XCTAssertGreaterThan(riparianCount, 0, "kein Auwald entstanden")
    }

    func testNoWoodlandOnTheChannelBed() {
        var c = SimConfig(); c.n = 192; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        for _ in 0..<10 { t.step(dtYears: 500) }
        let n = c.n
        let minA = c.braidMinCells * c.cellSize * c.cellSize
        var bed = 0
        for j in 2..<(n - 2) {
            for i in 2..<(n - 2) {
                let k = j * n + i
                guard t.hf[k] > c.sea,
                      t.area[k] >= minA || t.hf[k] - t.h[k] > 0.02 else { continue }
                bed += 1
                XCTAssertLessThan(t.vegClass[k], 2,
                                  "Gehölz-Klasse \(t.vegClass[k]) auf Bett-Zelle (\(i),\(j))")
                XCTAssertEqual(t.vegDamp(k), max(0, 1 - 0.6 * t.veg[k]), accuracy: 1e-15)
            }
        }
        XCTAssertGreaterThan(bed, 0, "keine Bett-Zelle gefunden — Test leer")
    }

    func testGrassFactorMatchesLegacyDamping() {
        var c = SimConfig(); c.n = 96; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 7)
        for k in 0..<c.count where t.vegClass[k] <= 1 {
            XCTAssertEqual(t.vegDamp(k), max(0, 1 - 0.6 * t.veg[k]), accuracy: 1e-15)
        }
    }

    private func sineChannel() -> RiverChannel {
        var nodes: [MeanderNode] = []
        var dis: [Double] = []
        for i in 0..<60 {
            nodes.append(MeanderNode(x: 10 + Double(i) * 1.2,
                                     z: 48 + 6 * sin(Double(i) * 0.35)))
            dis.append(200)
        }
        return RiverChannel(nodes: nodes, discharge: dis)
    }

    func testRiparianCohesionSlowsMigration() {
        var cfg = SimConfig(); cfg.n = 96; cfg.world = calibrationWorld
        cfg.meanderMigration = 5.0e-5
        cfg.meanderCohesion = 0.5
        func grownSinuosity(_ rip: @escaping (MeanderNode) -> Double) -> Double {
            let st = MeanderState()
            st.channels = [sineChannel()]
            for _ in 0..<20 { st.migrate(dt: 50, config: cfg, riparianAt: rip) }
            return st.channels[0].sinuosity
        }
        let bare = grownSinuosity { _ in 0 }
        let forested = grownSinuosity { _ in 1 }
        XCTAssertGreaterThan(bare, 1.0, "Referenzlauf müsste Schlingen aufbauen")
        XCTAssertLessThan(forested, bare, "bewaldetes Ufer muss langsamer migrieren")
        XCTAssertLessThan((forested - 1), (bare - 1) * 0.8)
    }

    func testCohesionZeroIsNoOp() {
        var cfg = SimConfig(); cfg.n = 96; cfg.world = calibrationWorld
        cfg.meanderMigration = 5.0e-5
        cfg.meanderCohesion = 0
        let a = MeanderState(); a.channels = [sineChannel()]
        let b = MeanderState(); b.channels = [sineChannel()]
        for _ in 0..<10 {
            a.migrate(dt: 50, config: cfg)
            b.migrate(dt: 50, config: cfg, riparianAt: { _ in 1 })
        }
        XCTAssertEqual(a.channels[0].nodes, b.channels[0].nodes)
    }

    private func pickVegetatedCell(_ t: Terrain) -> Int {
        let n = t.cfg.n
        for j in 10..<(n - 10) {
            for i in 10..<(n - 10) {
                let k = j * n + i
                if t.veg[k] > 0.45 && t.h[k] > t.cfg.sea + 0.05 { return k }
            }
        }
        return -1
    }

    func testFloodKillClearsVegetation() {
        var c = SimConfig(); c.n = 96; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        let pick = pickVegetatedCell(t)
        XCTAssertGreaterThanOrEqual(pick, 0, "keine bewachsene Zelle gefunden — Test leer")
        let n = c.n
        let pi = pick % n, pj = pick / n
        let vBefore = t.veg[pick]
        for _ in 0..<40 {
            t.sculpt(gx: Double(pi), gz: Double(pj), radiusWorld: 5 * c.cellSize, dir: -1)
        }
        t.computeFlow()
        XCTAssertGreaterThan(t.hf[pick] - t.h[pick], c.vegFloodKillDepth,
                             "Senke pondet nicht — Test-Setup kaputt")
        t.updateVegetation(years: 3 * c.vegFloodKillYears)
        XCTAssertLessThan(t.veg[pick], vBefore * 0.1,
                          "Flood-Kill wirkt nicht (\(vBefore) → \(t.veg[pick]))")
    }

    func testRegrowthAfterKill() {
        var c = SimConfig(); c.n = 96; c.world = calibrationWorld
        c.disturbanceEnabled = false
        let t = Terrain(config: c, seed: 1337)
        let pick = pickVegetatedCell(t)
        XCTAssertGreaterThanOrEqual(pick, 0)
        let n = c.n
        let pi = pick % n, pj = pick / n
        let vBefore = t.veg[pick]
        let hBefore = t.h[pick]
        for _ in 0..<40 {
            t.sculpt(gx: Double(pi), gz: Double(pj), radiusWorld: 5 * c.cellSize, dir: -1)
        }
        t.computeFlow()
        t.updateVegetation(years: 3 * c.vegFloodKillYears)
        XCTAssertLessThan(t.veg[pick], 0.1)
        for _ in 0..<200 {
            t.flatten(gx: Double(pi), gz: Double(pj), radiusWorld: 6 * c.cellSize,
                      targetHeight: hBefore)
        }
        t.computeFlow()
        XCTAssertLessThanOrEqual(t.hf[pick] - t.h[pick], 0.015, "Senke pondet noch — Setup")
        for _ in 0..<6 { t.updateVegetation(years: 125) }
        XCTAssertGreaterThan(t.veg[pick], vBefore * 0.5,
                             "Regrünung zu langsam (\(vBefore) → \(t.veg[pick]))")
    }

    func testBareSitesStayBareDespiteSeeds() {
        var c = SimConfig(); c.n = 96; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        let n = c.n
        for _ in 0..<5 { t.updateVegetation(years: 250) }
        var checked = 0
        for j in 2..<(n - 2) {
            for i in 2..<(n - 2) {
                let k = j * n + i
                let v = t.h[k]
                let bands = t.heightBands
                var target = 0.0
                if v > c.sea + 0.005 && v < bands.vegNone && t.hf[k] - t.h[k] <= 0.015 {
                    target = Terrain.vegetationSuitability(
                        height: v, slope: Terrain.macroSlope(t.h, k, n),
                        rain: t.rain[k], bands: bands)
                }
                guard target < 0.01 else { continue }
                var seed = 0.0
                for dj in -2...2 {
                    for di in -2...2 { seed = max(seed, t.veg[(j + dj) * n + i + di]) }
                }
                guard seed > 0.3 else { continue }
                checked += 1
                XCTAssertLessThan(t.veg[k], 0.08, "Spontanwald auf kahlem Standort (\(i),\(j))")
            }
        }
        XCTAssertGreaterThan(checked, 0, "keine kahle Zelle mit Samen-Druck gefunden — Test leer")
    }

    func testMeanderStampKillsBedVegetation() {
        var c = SimConfig(); c.n = 96; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        for _ in 0..<6 { t.step(dtYears: 500) }
        t.step(dtYears: 1)
        var bed = 0
        for k in 0..<c.count where t.isChannel[k] {
            bed += 1
            XCTAssertLessThan(t.veg[k], 0.02, "Bett-Zelle \(k) behielt Vegetation")
        }
        XCTAssertGreaterThan(bed, 0, "keine Kanal-Zellen gestempelt — Test leer")
    }

    func testVegetationDeterminism() {
        var c = SimConfig(); c.n = 96; c.world = calibrationWorld
        let a = Terrain(config: c, seed: 99)
        let b = Terrain(config: c, seed: 99)
        for _ in 0..<8 { a.step(dtYears: 500); b.step(dtYears: 500) }
        XCTAssertEqual(a.h, b.h)
        XCTAssertEqual(a.veg, b.veg)
        XCTAssertEqual(a.vegClass, b.vegClass)
    }
}
