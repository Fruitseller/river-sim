import XCTest
@testable import SimCore

final class SimCoreTests: XCTestCase {

    private func makeConfig(n: Int = 96) -> SimConfig {
        var c = SimConfig()
        c.n = n; c.world = calibrationWorld
        return c
    }

    private func meanderCfg(n: Int = 96) -> SimConfig {
        var c = makeConfig(n: n)
        c.hydraulicEnabled = false
        c.meanderEnabled = true
        c.meanderMigration = 5.0e-5
        c.meanderNeckDist = 1.2
        c.meanderCohesion = 0
        c.meanderBelt = calibrationMeanderBelt
        c.upliftPer100y = 0.0015
        c.upliftDecayStartPer100y = 0
        c.upliftDecayFloorPer100y = 0
        c.lithologyEnabled = false
        return c
    }

    private func prodMeanderCfg(n: Int = 192) -> SimConfig {
        var c = SimConfig(); c.n = n; c.world = calibrationWorld
        c.meanderBelt = calibrationMeanderBelt
        c.deltaTrapFraction = calibrationDeltaTrapFraction

        c.pinIceBeforeAvalanche()
        return c
    }

    func testDeterminism() {
        let a = Terrain(config: makeConfig(), seed: 4242)
        let b = Terrain(config: makeConfig(), seed: 4242)
        XCTAssertEqual(a.fingerprint(), b.fingerprint(),
                       "Generierung muss deterministisch sein")
        for _ in 0..<10 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertEqual(a.fingerprint(), b.fingerprint(),
                       "Simulation muss deterministisch sein")
    }

    func testSeedsDiffer() {
        let a = Terrain(config: makeConfig(), seed: 1)
        let b = Terrain(config: makeConfig(), seed: 2)
        XCTAssertNotEqual(a.h, b.h)
    }

    func testDrainageAreaConservation() {
        let t = Terrain(config: makeConfig(), seed: 777)
        let outlet = t.totalOutletArea()
        let total = Double(t.cfg.count)
        XCTAssertEqual(outlet, total, accuracy: total * 1e-6,
                       "Summe der Senken-Einzugsgebiete muss = Gesamtzellzahl sein")
    }

    func testReliefStaysBounded() {
        let t = Terrain(config: makeConfig(), seed: 2024)
        let start = t.landRelief()
        XCTAssertGreaterThan(start, 0.1, "Startterrain muss Relief haben")
        var reliefs: [Double] = []
        for _ in 0..<8 {
            t.step(dtYears: 10000)
            reliefs.append(t.landRelief())
        }
        for r in reliefs {
            XCTAssertGreaterThan(r, 0.05, "Landschaft ebnet unrealistisch ein: \(reliefs)")
            XCTAssertLessThan(r, 2.0, "Relief läuft weg: \(reliefs)")
        }
        XCTAssertLessThanOrEqual(t.maxHeight(), 1.4)
        XCTAssertGreaterThanOrEqual(t.minHeight(), t.cfg.floor - 1e-9)
    }

    func testNoNaN() {
        let t = Terrain(config: makeConfig(n: 80), seed: 555)
        for _ in 0..<20 { t.step(dtYears: 5000) }
        for v in t.h { XCTAssertTrue(v.isFinite, "NaN/Inf im Höhenfeld") }
        for v in t.area { XCTAssertTrue(v.isFinite && v >= 0, "Ungültiges Einzugsgebiet") }
    }

    func testLongRunStable() {
        let t = Terrain(config: makeConfig(n: 80), seed: 33)
        for _ in 0..<400 { t.step(dtYears: 250) }
        XCTAssertTrue(t.h.allSatisfy { $0.isFinite })
        XCTAssertGreaterThan(t.landRelief(), 0.1)
        XCTAssertLessThan(t.landRelief(), 1.6)
    }

    func testLayerConsistency() {
        let t = Terrain(config: makeConfig(n: 80), seed: 9)
        for _ in 0..<5 { t.step(dtYears: 8000) }
        for k in 0..<t.cfg.count {
            XCTAssertEqual(t.h[k], t.rock[k] + t.sed[k], accuracy: 1e-9,
                           "h == rock + sed verletzt bei \(k)")
            XCTAssertGreaterThanOrEqual(t.sed[k], -1e-9, "negatives Sediment bei \(k)")
        }
    }

    func testSculptRaisesAndPersists() {
        let t = Terrain(config: makeConfig(), seed: 4)
        let n = t.cfg.n
        let center = Double(n / 2)
        let before = t.h[Int(center) * n + Int(center)]
        for _ in 0..<200 {
            t.sculpt(gx: center, gz: center, radiusWorld: 12, dir: 1)
        }
        let after = t.h[Int(center) * n + Int(center)]
        XCTAssertGreaterThan(after, before + 0.2, "Anheben muss das Terrain erhöhen")
        t.computeFlow()
        for _ in 0..<3 { t.step(dtYears: 10000) }
        let peak = t.maxHeight()
        let peakArea = t.h[Int(center) * n + Int(center)]
        XCTAssertGreaterThan(peakArea, peak * 0.6,
                             "gesculptete Region muss nach Erosion prominent bleiben")
    }

    func testRiverStability() {
        let t = Terrain(config: makeConfig(), seed: 111)
        for _ in 0..<3 { t.step(dtYears: 5000) }
        let before = t.snapshotReceivers()
        t.step(dtYears: 100)
        let agreement = t.receiverAgreement(with: before)
        XCTAssertGreaterThan(agreement, 0.6,
                             "Entwässerung springt zu stark um: \(agreement)")
    }

    private func seededChannel() -> RiverChannel {
        var nodes: [MeanderNode] = []
        var dis: [Double] = []
        var x = 5.0
        while x <= 90 {
            nodes.append(MeanderNode(x: x, z: 48 + 1.5 * sin(x * 0.4)))
            dis.append(220)
            x += 1.5
        }
        return RiverChannel(nodes: nodes, discharge: dis)
    }

    private func kernelCfg() -> SimConfig {
        var c = makeConfig(); c.meanderMigration = 6.0e-6; return c
    }

    private func migratedState(steps: Int, dt: Double = 500) -> (MeanderState, SimConfig) {
        let cfg = kernelCfg()
        let s = MeanderState()
        s.channels = [seededChannel()]
        for _ in 0..<steps { s.migrate(dt: dt, config: cfg) }
        return (s, cfg)
    }

    func testMeanderDeterminism() {
        let (a, _) = migratedState(steps: 60)
        let (b, _) = migratedState(steps: 60)
        XCTAssertEqual(a.channels.count, b.channels.count)
        XCTAssertEqual(a.channels[0].nodes, b.channels[0].nodes,
                       "Mäander-Migration muss deterministisch sein")
        XCTAssertEqual(a.oxbows.count, b.oxbows.count)
    }

    func testMeanderSinuosityGrowsThenSaturates() {
        let cfg = kernelCfg()
        let s = MeanderState()
        s.channels = [seededChannel()]
        let s0 = s.channels[0].sinuosity
        for _ in 0..<40 { s.migrate(dt: 500, config: cfg) }
        let s40 = s.channels[0].sinuosity
        for _ in 0..<200 { s.migrate(dt: 500, config: cfg) }
        let s240 = s.channels[0].sinuosity
        XCTAssertGreaterThan(s40, s0 + 0.01, "Sinuosität muss zunächst wachsen: \(s0)→\(s40)")
        XCTAssertGreaterThan(s240, 1.0, "Lauf bleibt gewunden")
        XCTAssertLessThan(s240, 6.0, "Sinuosität läuft weg (keine Sättigung): \(s240)")
    }

    func testMeanderNoSelfIntersection() {
        let (s, cfg) = migratedState(steps: 300)
        let neck = cfg.meanderNeckDist
        let farSep = 2 * (max(4, Int((neck / cfg.meanderNodeSpacing) * 3) + 2))
        for ch in s.channels {
            let nodes = ch.nodes
            for i in 0..<nodes.count {
                var j = i + farSep
                while j < nodes.count {
                    XCTAssertGreaterThanOrEqual(dist(nodes[i], nodes[j]), neck * 0.999,
                        "Weiträumige Selbst-Durchdringung bei Knoten \(i),\(j)")
                    j += 1
                }
            }
        }
    }

    func testMeanderResampleInvariant() {
        let (s, cfg) = migratedState(steps: 120)
        let sp = cfg.meanderNodeSpacing
        for ch in s.channels where ch.nodes.count >= 3 {
            var tight = 0, total = 0
            for i in 1..<ch.nodes.count {
                let d = dist(ch.nodes[i - 1], ch.nodes[i])
                total += 1
                if d < sp * 0.5 { tight += 1 }
                XCTAssertLessThan(d, sp * 2.0, "Knoten zu weit: \(d)")
            }
            XCTAssertLessThan(Double(tight) / Double(total), 0.1,
                              "zu viele dichte Knoten: \(tight)/\(total)")
            XCTAssertEqual(ch.nodes.count, ch.discharge.count, "Abfluss-Array inkonsistent")
        }
    }

    func testMeanderTerrainDeterminism() {
        let a = Terrain(config: meanderCfg(), seed: 2024)
        let b = Terrain(config: meanderCfg(), seed: 2024)
        for _ in 0..<20 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertEqual(a.meander.channels.count, b.meander.channels.count)
        for (ca, cb) in zip(a.meander.channels, b.meander.channels) {
            XCTAssertEqual(ca.nodes, cb.nodes, "Mäander-Läufe müssen deterministisch sein")
        }
        XCTAssertEqual(a.meander.oxbows.count, b.meander.oxbows.count)
    }

    func testMeanderTerrainLongRunStable() {
        let cfg = prodMeanderCfg()
        let t = Terrain(config: cfg, seed: 33)
        let maxc = Double(cfg.n - 1)
        var maxSinu = 0.0, maxChannels = 0, badNodes = 0
        var lateSum = 0.0, lateCount = 0
        let steps = 200
        for s in 0..<steps {
            t.step(dtYears: 500)
            maxChannels = max(maxChannels, t.meander.channels.count)
            for ch in t.meander.channels {
                maxSinu = max(maxSinu, ch.sinuosity)
                if s >= steps - 40 { lateSum += ch.sinuosity; lateCount += 1 }
                for nd in ch.nodes where !(nd.x.isFinite && nd.z.isFinite
                    && nd.x >= 0 && nd.x <= maxc && nd.z >= 0 && nd.z <= maxc) { badNodes += 1 }
            }
        }
        XCTAssertEqual(badNodes, 0, "Knoten mit NaN/Inf oder außerhalb der Welt")
        XCTAssertGreaterThan(lateCount, 0, "am Ende existiert kein Lauf mehr")
        XCTAssertLessThan(maxSinu, 4.5, "Sinuosität läuft weg (Deckel wirkt nicht): \(maxSinu)")
        let lateMean = lateSum / Double(lateCount)
        XCTAssertGreaterThan(lateMean, 1.4, "Läufe mäandern nicht mehr: Mittel \(lateMean)")
        XCTAssertLessThan(maxChannels, 250, "Kanalzahl läuft weg: \(maxChannels)")
        let neck = cfg.meanderNeckDist
        let farSep = 2 * (max(4, Int((neck / cfg.meanderNodeSpacing) * 3) + 2))
        var minFar = Double.infinity
        for ch in t.meander.channels {
            let nodes = ch.nodes
            for i in 0..<nodes.count {
                var j = i + farSep
                while j < nodes.count { minFar = min(minFar, dist(nodes[i], nodes[j])); j += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(minFar, neck * 0.999,
                                    "weiträumige Selbst-Durchdringung: minFar \(minFar)")
        XCTAssertTrue(t.h.allSatisfy { $0.isFinite }, "NaN/Inf im Höhenfeld")
        XCTAssertGreaterThan(t.landRelief(), 0.30, "Terrain eingeebnet unter Mäander")
        XCTAssertLessThan(t.landRelief(), 0.80, "Relief läuft weg unter Mäander")
        XCTAssertLessThan(t.maxHeight(), 1.0, "Terrain-Runaway unter Mäander")
        XCTAssertGreaterThanOrEqual(t.minHeight(), cfg.floor - 1e-9)
    }

    func testMeanderCarvesChannel() {
        let cfg = meanderCfg()
        let t = Terrain(config: cfg, seed: 111)
        for _ in 0..<150 { t.step(dtYears: 500) }
        let n = cfg.n
        func hAt(_ x: Double, _ z: Double) -> Double {
            let i = min(max(Int(x.rounded()), 0), n - 1)
            let j = min(max(Int(z.rounded()), 0), n - 1)
            return t.h[j * n + i]
        }
        var chanSum = 0.0, bankSum = 0.0, cnt = 0
        for ch in t.meander.channels {
            let nd = ch.nodes
            for i in 1..<(nd.count - 1) {
                let a = nd[i - 1], c = nd[i + 1]
                let tx = c.x - a.x, tz = c.z - a.z
                let tl = (tx * tx + tz * tz).squareRoot()
                if tl < 1e-9 { continue }
                let px = -tz / tl, pz = tx / tl
                let hc = hAt(nd[i].x, nd[i].z)
                let hb = 0.5 * (hAt(nd[i].x + px * 3, nd[i].z + pz * 3)
                              + hAt(nd[i].x - px * 3, nd[i].z - pz * 3))
                chanSum += hc; bankSum += hb; cnt += 1
            }
        }
        XCTAssertGreaterThan(cnt, 0, "keine Kanalknoten")
        XCTAssertLessThan(chanSum / Double(cnt), bankSum / Double(cnt),
                          "Bett muss im Mittel unter der Aue liegen (Carve)")
    }

    func testMeanderOxbowLake() {
        let cfg = meanderCfg()
        let n = cfg.n
        let t = Terrain(config: cfg, seed: 111)
        func oxbowLakeCells() -> Int {
            var c = 0
            for loop in t.meander.oxbows {
                for nd in loop {
                    let i = min(max(Int(nd.x.rounded()), 0), n - 1)
                    let j = min(max(Int(nd.z.rounded()), 0), n - 1)
                    let k = j * n + i
                    if t.hf[k] - t.h[k] > 0.004 && t.hf[k] > cfg.sea { c += 1 }
                }
            }
            return c
        }
        var guardN = 0
        while t.meander.oxbows.isEmpty && guardN < 260 { t.step(dtYears: 500); guardN += 1 }
        XCTAssertFalse(t.meander.oxbows.isEmpty, "keine Altarme (river-history) entstanden")
        var maxLake = oxbowLakeCells()
        for _ in 0..<8 { t.step(dtYears: 500); maxLake = max(maxLake, oxbowLakeCells()) }
        XCTAssertGreaterThanOrEqual(maxLake, 1, "kein Altarm-See (hf>h) im Oxbow-Bereich")
    }

    func testMeanderOxbowAging() {
        let cfg = meanderCfg()
        let t = Terrain(config: cfg, seed: 111)
        var everSeen = false, maxCount = 0
        for _ in 0..<400 {
            t.step(dtYears: 500)
            if !t.meander.oxbows.isEmpty { everSeen = true }
            maxCount = max(maxCount, t.meander.oxbows.count)
            XCTAssertLessThan(t.meander.oxbows.count, 60, "Altarm-Liste wächst unbeschränkt")
            XCTAssertEqual(t.meander.oxbows.count, t.meander.oxbowAge.count)
            for age in t.meander.oxbowAge {
                XCTAssertLessThanOrEqual(age, cfg.oxbowMaxAge, "verlandeter Altarm nicht entfernt")
            }
        }
        XCTAssertTrue(everSeen, "über den ganzen Lauf ist nie ein Altarm entstanden")
        XCTAssertGreaterThan(maxCount, 0)
    }

    func testMeanderOxbowSiltsUp() {
        let cfg = prodMeanderCfg()
        let n = cfg.n
        let t = Terrain(config: cfg, seed: 33)
        func bedDeficit(_ cells: [Int]) -> Double {
            var s = 0.0
            for k in cells {
                var rim = t.h[k]
                for nb in [k - 1, k + 1, k - n, k + n] { rim = max(rim, t.h[nb]) }
                s += rim - t.h[k]
            }
            return cells.isEmpty ? 0 : s / Double(cells.count)
        }
        for _ in 0..<40 { t.step(dtYears: 500) }
        var cohort = Set<Int>()
        for _ in 0..<10 {
            t.step(dtYears: 500)
            for oi in t.meander.oxbows.indices where t.meander.oxbowAge[oi] == 0 {
                let loop = t.meander.oxbows[oi]
                guard loop.count >= 6 else { continue }
                for nd in loop[2..<(loop.count - 2)] {
                    let ci = min(max(Int(nd.x.rounded()), 1), n - 2)
                    let cj = min(max(Int(nd.z.rounded()), 1), n - 2)
                    cohort.insert(cj * n + ci)
                }
            }
        }
        let cells = cohort.sorted()
        XCTAssertGreaterThan(cells.count, 20,
                             "kaum frisch abgeschnürte Altarm-Betten: \(cells.count)")
        let d0 = bedDeficit(cells)
        XCTAssertGreaterThan(d0, 0.002, "frische Altarme sind nicht eingetieft: \(d0)")
        var ratios: [Double] = []
        for _ in 0..<4 {
            for _ in 0..<6 { t.step(dtYears: 500) }
            ratios.append(bedDeficit(cells) / d0)
        }
        let meanRatio = ratios.reduce(0, +) / Double(ratios.count)
        XCTAssertLessThan(meanRatio, 0.95,
                          "Altarm-Betten verlanden nicht: Defizit \(ratios) × d0=\(d0)")
        XCTAssertLessThan(ratios[ratios.count - 1], 0.90,
                          "Altarm-Verlandung konvergiert nicht: Defizit \(ratios) × d0=\(d0)")
        var peak = t.meander.oxbows.count
        while t.years < 80_000 - 1e-6 {
            t.step(dtYears: 500)
            peak = max(peak, t.meander.oxbows.count)
        }
        XCTAssertGreaterThan(peak, 20, "kaum Altarme über den Lauf: \(peak)")
        XCTAssertLessThan(Double(t.meander.oxbows.count), 0.7 * Double(peak),
                          "Altarm-Zahl geht nicht zurück: \(t.meander.oxbows.count) von Peak \(peak)")
    }

    func testMeanderTraceFromDrainage() {
        let t = Terrain(config: makeConfig(), seed: 111)
        for _ in 0..<4 { t.step(dtYears: 5000) }
        let channels = MeanderState.traceChannels(config: t.cfg, h: t.h, hf: t.hf,
                                                   area: t.area, receiver: t.receiver)
        XCTAssertFalse(channels.isEmpty, "Kein Hauptfluss aus der Entwässerung getract")
        for ch in channels {
            XCTAssertGreaterThanOrEqual(ch.nodes.count, 2)
            XCTAssertEqual(ch.nodes.count, ch.discharge.count)
            XCTAssertTrue(ch.discharge.allSatisfy { $0 > 0 }, "Abfluss muss positiv sein")
        }
    }

    func testSimConfigCellSizeHandlesDegenerateGridsAndNonFiniteWorlds() {
        var c = SimConfig()
        c.n = 720
        c.world = 112.4789
        XCTAssertEqual(c.cellSize, 112.4789 / 719.0)
        XCTAssertEqual(c.count, 720 * 720)

        c.n = 1
        XCTAssertEqual(c.cellSize, 0.0, "n = 1 darf nicht durch 0 teilen")
        XCTAssertEqual(c.count, 1, "n = 1 hat genau einen Gitterpunkt")
        c.n = 0
        XCTAssertEqual(c.cellSize, 0.0, "n = 0 darf keine negative Zellgröße liefern")
        XCTAssertEqual(c.count, 0, "n = 0 liefert 0 Gitterpunkte")
        c.n = -5
        XCTAssertEqual(c.cellSize, 0.0, "n < 0 muss defensiv 0 liefern")
        XCTAssertEqual(c.count, 0, "n < 0 muss defensiv 0 Gitterpunkte liefern")
        c.n = Int.min
        XCTAssertEqual(c.count, 0, "Int.min darf nicht überlaufen und liefert 0 Gitterpunkte")
        c.n = Int.max
        XCTAssertEqual(c.count, 0, "Überlauf bei n * n liefert defensiv 0 Gitterpunkte")

        c.n = 96
        c.world = 0.0
        XCTAssertEqual(c.cellSize, 0.0)
        c.world = -10.0
        XCTAssertEqual(c.cellSize, 0.0)
        c.world = Double.nan
        XCTAssertEqual(c.cellSize, 0.0)
        c.world = Double.infinity
        XCTAssertEqual(c.cellSize, 0.0)
        c.world = -Double.infinity
        XCTAssertEqual(c.cellSize, 0.0)
    }

    func testBrushOnSinglePointGridIsNoOp() {
        var c = SimConfig()
        c.n = 1
        XCTAssertEqual(c.cellSize, 0.0)
        let t = Terrain(allocating: c, seed: 1)
        let before = t.h
        t.flatten(gx: 0, gz: 0, radiusWorld: 0, targetHeight: 0.5)
        t.roughen(gx: 0, gz: 0, radiusWorld: 0)
        t.sculpt(gx: 0, gz: 0, radiusWorld: 0, dir: 1)
        XCTAssertEqual(t.h, before, "Pinsel ohne Schrittweite muss No-op sein")
    }

    func testFluvialIncisionWithoutCellSpacingDoesNotPoisonHeightsWithNaN() {
        var c = SimConfig()
        c.n = 16
        c.world = 0
        XCTAssertEqual(c.cellSize, 0.0)
        let t = Terrain(allocating: c, seed: 1337)
        var s = t.state
        for j in 0..<16 {
            for i in 0..<16 {
                let k = j * 16 + i
                s.h[k] = c.sea + 0.1 + Double(16 - 1 - j) * 0.02
                s.rock[k] = s.h[k]
                s.sed[k] = 0.0
            }
        }
        s.hf = s.h
        t.restore(s)

        t.step(dtYears: 100)
        XCTAssertTrue(t.h.allSatisfy { $0.isFinite },
                      "Höhen dürfen nach step() ohne Schrittweite keine NaNs/Infs enthalten")
        XCTAssertTrue(t.rock.allSatisfy { $0.isFinite },
                      "Fels darf nach step() ohne Schrittweite keine NaNs/Infs enthalten")
        XCTAssertTrue(t.sed.allSatisfy { $0.isFinite },
                      "Sediment darf nach step() ohne Schrittweite keine NaNs/Infs enthalten")

        for badWorld in [-10.0, Double.nan, Double.infinity] {
            var cBad = c
            cBad.world = badWorld
            XCTAssertEqual(cBad.cellSize, 0.0)
            let tBad = Terrain(allocating: cBad, seed: 1337)
            tBad.restore(s)
            tBad.step(dtYears: 100)
            XCTAssertTrue(tBad.h.allSatisfy { $0.isFinite },
                          "Ungültige Weltgröße \(badWorld) darf keine NaNs erzeugen")
        }
    }

    func testTransportLimitedWithoutCellSpacingDoesNotPoisonHeightsWithNaN() {
        var c = SimConfig()
        c.n = 16
        c.world = 0
        c.hydraulicEnabled = false
        XCTAssertEqual(c.cellSize, 0.0)
        let t = Terrain(allocating: c, seed: 1337)
        var s = t.state
        for j in 0..<16 {
            for i in 0..<16 {
                let k = j * 16 + i
                s.h[k] = c.sea + 0.1 + Double(16 - 1 - j) * 0.02
                s.rock[k] = s.h[k]
                s.sed[k] = 0.0
            }
        }
        s.hf = s.h
        t.restore(s)

        t.step(dtYears: 100)
        XCTAssertTrue(t.h.allSatisfy { $0.isFinite },
                      "transportLimited darf ohne Schrittweite keine NaNs/Infs erzeugen")
    }
}
