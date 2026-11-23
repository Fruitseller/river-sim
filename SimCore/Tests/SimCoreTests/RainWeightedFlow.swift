import XCTest
@testable import SimCore

final class RainWeightedFlowTests: XCTestCase {

    private func cfg(n: Int, rainWeighted: Bool) -> SimConfig {
        var c = SimConfig()
        c.n = n; c.world = calibrationWorld
        c.rainWeightedFlow = rainWeighted
        c.iceEnabled = false
        return c
    }

    private func upstreamCells(_ t: Terrain) -> [Double] {
        let cnt = t.cfg.count
        var count = [Double](repeating: 1, count: cnt)
        var indeg = [Int](repeating: 0, count: cnt)
        for k in 0..<cnt where t.receiver[k] >= 0 { indeg[Int(t.receiver[k])] += 1 }
        var queue = (0..<cnt).filter { indeg[$0] == 0 }
        var head = 0, done = 0
        while head < queue.count {
            let k = queue[head]; head += 1; done += 1
            let r = t.receiver[k]
            guard r >= 0 else { continue }
            count[Int(r)] += count[k]
            indeg[Int(r)] -= 1
            if indeg[Int(r)] == 0 { queue.append(Int(r)) }
        }
        XCTAssertEqual(done, cnt, "Empfänger-Netz muss zyklenfrei sein")
        return count
    }

    func testRainWeightedFlowIsOnByDefault() {
        XCTAssertTrue(SimConfig().rainWeightedFlow,
                      "Der gewichtete Abfluss ist seit #10 die Produktions-Physik")
    }

    func testRainWeightIsNormalizedToLandMean() {
        for n in [96, 192, 320] {
            let t = Terrain(config: cfg(n: n, rainWeighted: true), seed: 1337)
            var wLand = 0.0, rawLand = 0.0, land = 0
            for k in 0..<t.cfg.count {
                if t.h[k] > t.cfg.sea {
                    wLand += t.rainWeight[k]; rawLand += t.rain[k]; land += 1
                } else {
                    XCTAssertEqual(t.rainWeight[k], 1.0,
                                   "über See muss das Gewicht neutral 1.0 sein")
                }
            }
            XCTAssertGreaterThan(land, 0)
            print(String(format: "[RAIN] n=%d Landmittel Gewicht=%.6f roh=%.4f",
                         n, wLand / Double(land), rawLand / Double(land)))
            XCTAssertEqual(wLand / Double(land), 1.0, accuracy: 1e-9,
                           "Σ Gewicht über Land muss = Zahl der Landzellen sein (n=\(n))")
        }
    }

    func testWeightedFlowKeepsDrainageTotal() {
        let t = Terrain(config: cfg(n: 128, rainWeighted: true), seed: 777)
        let total = Double(t.cfg.count)
        XCTAssertEqual(t.totalOutletArea(), total, accuracy: total * 1e-6,
                       "gewichtet darf die Entwässerungssumme nicht wegdriften")
    }

    func testWeightedSpawnsKeepTheLandBudget() {
        let t = Terrain(config: cfg(n: 128, rainWeighted: true), seed: 1337)
        let c = t.cfg
        var wLand = 0.0, wAll = 0.0
        for j in 0..<(c.n - 1) {
            for i in 0..<(c.n - 1) {
                let k = j * c.n + i
                wAll += t.rainWeight[k]
                if t.h[k] > c.sea { wLand += t.rainWeight[k] }
            }
        }
        let landShare = wLand / wAll
        let wMax = t.rainWeight.max() ?? 0
        var rnd = Mulberry32(seed: 4242)
        var onLand = 0
        let draws = 40_000
        for _ in 0..<draws {
            let s = Hydraulic.spawnPosition(&rnd, n: c.n, weight: t.rainWeight, weightMax: wMax)
            if t.h[Int(s.y) * c.n + Int(s.x)] > c.sea { onLand += 1 }
        }
        let share = Double(onLand) / Double(draws)
        print(String(format: "[RAIN] Starts auf Land=%.4f, erwartet (Gewichtsanteil)=%.4f",
                     share, landShare))
        XCTAssertEqual(share, landShare, accuracy: 0.01,
                       "gewichtete Starts dürfen den Land-Etat nicht verschieben")
        var wLandAll = 0.0, wAllCells = 0.0
        var landCells = 0
        for k in 0..<c.count {
            wAllCells += t.rainWeight[k]
            if t.h[k] > c.sea { wLandAll += t.rainWeight[k]; landCells += 1 }
        }
        XCTAssertEqual(wLandAll / wAllCells, Double(landCells) / Double(c.count), accuracy: 1e-9,
                       "der Land-Etat der Starts muss exakt der Zellanteil sein")
    }

    func testUnweightedAccumulationIsPureCellArea() {
        let t = Terrain(config: cfg(n: 96, rainWeighted: false), seed: 4242)
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let cells = upstreamCells(t)
        var maxRelErr = 0.0
        for k in 0..<t.cfg.count {
            let expect = cells[k] * cellArea
            maxRelErr = max(maxRelErr, abs(t.area[k] - expect) / expect)
        }
        XCTAssertLessThan(maxRelErr, 1e-9,
                          "ohne Schalter muss area == Zellzahl × cellArea sein")
    }

    func testUniformRainWeightIsBitIdentical() {
        var c = SimConfig(); c.n = 96; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 99)
        var h = t.h, rock = t.rock, sed = t.sed
        var h2 = h, rock2 = rock, sed2 = sed
        var trk = [Double](repeating: 0, count: c.count)
        var trk2 = trk
        Hydraulic.erode(h: &h, rock: &rock, sed: &sed, n: c.n, count: 2000, seed: 7,
                        floor: c.floor, p: c.hydraulic, track: &trk)
        Hydraulic.erode(h: &h2, rock: &rock2, sed: &sed2, n: c.n, count: 2000, seed: 7,
                        floor: c.floor, p: c.hydraulic,
                        flowWeight: [Double](repeating: 0.42, count: c.count), track: &trk2)
        XCTAssertEqual(h, h2, "konstanter Regen darf die Tropfen nicht verschieben")
        XCTAssertEqual(trk, trk2, "konstanter Regen darf die Tracks nicht verschieben")
    }

    func testRainWeightedFlowFavorsLuv() {
        let t = Terrain(config: cfg(n: 128, rainWeighted: true), seed: 1337)
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let cells = upstreamCells(t)
        let n = t.cfg.n
        var luv = 0.0, luvN = 0.0, lee = 0.0, leeN = 0.0
        for k in 0..<t.cfg.count where t.hf[k] > t.cfg.sea {
            guard cells[k] >= 30 else { continue }
            let perCell = t.area[k] / (cells[k] * cellArea)
            let i = k % n
            if i < n / 2 { luv += perCell; luvN += 1 } else { lee += perCell; leeN += 1 }
        }
        XCTAssertGreaterThan(luvN, 0); XCTAssertGreaterThan(leeN, 0)
        luv /= luvN; lee /= leeN
        print(String(format: "[RAIN] Abfluss je Einzugsgebiets-Zelle: Luv=%.4f Lee=%.4f (×%.2f)",
                     luv, lee, luv / lee))
        XCTAssertGreaterThan(luv, lee * 1.10,
                             "Luv muss bei gleichem Einzugsgebiet spürbar mehr Abfluss tragen")
        let flat = Terrain(config: cfg(n: 128, rainWeighted: false), seed: 1337)
        let flatCells = upstreamCells(flat)
        for k in 0..<flat.cfg.count where flat.hf[k] > flat.cfg.sea && flatCells[k] >= 30 {
            XCTAssertEqual(flat.area[k] / (flatCells[k] * cellArea), 1.0, accuracy: 1e-9)
        }
    }

    func testRainWeightedMFDFavorsLuv() {
        let t = Terrain(config: cfg(n: 128, rainWeighted: true), seed: 1337)
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let n = t.cfg.n
        let cells = upstreamCells(t)
        var luv = 0.0, luvN = 0.0, lee = 0.0, leeN = 0.0
        for k in 0..<t.cfg.count where t.hf[k] > t.cfg.sea {
            guard cells[k] >= 30 else { continue }
            let perCell = t.areaMFD[k] / (cells[k] * cellArea)
            let i = k % n
            if i < n / 2 { luv += perCell; luvN += 1 } else { lee += perCell; leeN += 1 }
        }
        luv /= luvN; lee /= leeN
        print(String(format: "[RAIN] areaMFD je D8-Einzugsgebiets-Zelle: Luv=%.4f Lee=%.4f (×%.2f)",
                     luv, lee, luv / lee))
        XCTAssertGreaterThan(luv, lee * 1.10, "auch das MFD-Feld muss dem Regen folgen")
    }

    func testRainWeightedSpawnsFollowRain() {
        let n = 64
        var w = [Double](repeating: 0.5, count: n * n)
        for j in 0..<n { for i in 0..<(n / 2) { w[j * n + i] = 1.0 } }
        var rnd = Mulberry32(seed: 12345)
        var west = 0, east = 0
        for _ in 0..<20000 {
            let s = Hydraulic.spawnPosition(&rnd, n: n, weight: w, weightMax: 1.0)
            if Int(s.x) < n / 2 { west += 1 } else { east += 1 }
        }
        let ratio = Double(west) / Double(east)
        print(String(format: "[RAIN] Tropfen-Starts West/Ost = %d/%d (×%.2f)", west, east, ratio))
        XCTAssertGreaterThan(ratio, 1.85, "Startpunkte folgen dem Regen nicht (erwartet ≈ 2.0)")
        XCTAssertLessThan(ratio, 2.15, "Startpunkte übergewichten den Regen")
        var rnd2 = Mulberry32(seed: 12345)
        var uw = 0, ue = 0
        for _ in 0..<20000 {
            let s = Hydraulic.spawnPosition(&rnd2, n: n, weight: [], weightMax: 0)
            if Int(s.x) < n / 2 { uw += 1 } else { ue += 1 }
        }
        XCTAssertEqual(Double(uw) / Double(ue), 1.0, accuracy: 0.06,
                       "ohne Gewicht müssen die Starts gleichverteilt bleiben")
    }

    func testRainWeightedFlowIsDeterministic() {
        let a = Terrain(config: cfg(n: 96, rainWeighted: true), seed: 4242)
        let b = Terrain(config: cfg(n: 96, rainWeighted: true), seed: 4242)
        for _ in 0..<3 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertEqual(a.h, b.h, "gewichteter Abfluss muss deterministisch bleiben")
        XCTAssertEqual(a.area, b.area)
        XCTAssertEqual(a.areaMFD, b.areaMFD)
    }

    func testRainWeightMeasurementDiagnostic() throws {
        try skipUnlessMeasuring()
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["RS_MEAS_N"] ?? "") ?? 192
        let years = Int(env["RS_MEAS_YEARS"] ?? "") ?? 20_000
        let marks = [0, 5_000, 20_000, 50_000, 100_000].filter { $0 <= years }
        for on in [false, true] {
            let t = Terrain(config: cfg(n: n, rainWeighted: on), seed: 1337)
            for mark in marks {
                while t.years < Double(mark) - 1e-6 { t.step(dtYears: 1000) }
                let m = measure(t)
                print(String(format: """
                    [RAINMEAS] gewichtet=%@ Jahr=%d | Kanalzellen=%d \
                    Dichte Luv=%.4f Lee=%.4f (Luv/Lee=%.2f) | Relief=%.4f \
                    reliefRobust=%.4f | Seeanteil=%.4f größterSee=%d | \
                    Regen Land=%.3f Meer=%.3f
                    """,
                    on ? "an " : "aus", mark, m.channels, m.dLuv, m.dLee,
                    m.dLee > 0 ? m.dLuv / m.dLee : 0, m.relief, m.reliefRobust,
                    m.lakeFrac, m.largestLake, m.rainLand, m.rainSea)
                    + String(format: " | Landanteil Zellen=%.4f gewichtete Starts=%.4f",
                             m.landShare, m.spawnLandShare))
            }
            XCTAssertGreaterThan(t.landRelief(), 0.10, "Terrain eingeebnet (gewichtet=\(on))")
        }
    }

    func testRainWeightLuvLeeIsSeedRobustDiagnostic() throws {
        try skipUnlessMeasuring()
        var chLuv = [false: 0, true: 0], chLee = [false: 0, true: 0]
        var lLuv = [false: 0, true: 0], lLee = [false: 0, true: 0]
        for seed in [UInt32(1337), 7, 99, 2024, 555, 42] {
            for on in [false, true] {
                let t = Terrain(config: cfg(n: 192, rainWeighted: on), seed: seed)
                while t.years < 20_000 - 1e-6 { t.step(dtYears: 1000) }
                let m = measure(t)
                chLuv[on]! += m.chLuv; chLee[on]! += m.chLee
                lLuv[on]! += m.landLuv; lLee[on]! += m.landLee
                print(String(format: "[RAINSEED] Seed=%d gewichtet=%@ | Kanalzellen=%d " +
                                     "Dichte Luv=%.4f Lee=%.4f Luv/Lee=%.3f",
                             seed, on ? "an " : "aus", m.channels, m.dLuv, m.dLee,
                             m.dLee > 0 ? m.dLuv / m.dLee : 0))
            }
        }
        func pooled(_ on: Bool) -> Double {
            (Double(chLuv[on]!) / Double(lLuv[on]!)) / (Double(chLee[on]!) / Double(lLee[on]!))
        }
        let rOff = pooled(false), rOn = pooled(true)
        print(String(format: "[RAINSEED] gepoolte Drainagedichte Luv/Lee: aus=%.3f an=%.3f (×%.2f)",
                     rOff, rOn, rOn / rOff))
        XCTAssertGreaterThan(rOn, rOff * 1.05,
                             "gewichteter Abfluss muss die Drainagedichte Richtung Luv verschieben")
    }

    private struct Metrics {
        var channels = 0
        var chLuv = 0, chLee = 0, landLuv = 0, landLee = 0
        var dLuv = 0.0, dLee = 0.0
        var relief = 0.0, reliefRobust = 0.0
        var lakeFrac = 0.0, largestLake = 0
        var rainLand = 0.0, rainSea = 0.0
        var landShare = 0.0
        var spawnLandShare = 0.0
    }

    private func measure(_ t: Terrain) -> Metrics {
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let creek = t.cfg.renderMinCells
        let n = t.cfg.n
        var m = Metrics()
        var landLuv = 0, landLee = 0, chLuv = 0, chLee = 0
        var rainLandSum = 0.0, rainSeaSum = 0.0, seaCells = 0
        for k in 0..<t.cfg.count {
            let west = (k % n) < n / 2
            if t.hf[k] > t.cfg.sea && t.h[k] > t.cfg.sea {
                if west { landLuv += 1 } else { landLee += 1 }
                rainLandSum += t.rain[k]
                if t.areaMFD[k] / cellArea >= creek {
                    m.channels += 1
                    if west { chLuv += 1 } else { chLee += 1 }
                }
            } else {
                rainSeaSum += t.rain[k]; seaCells += 1
            }
        }
        m.chLuv = chLuv; m.chLee = chLee; m.landLuv = landLuv; m.landLee = landLee
        m.dLuv = landLuv == 0 ? 0 : Double(chLuv) / Double(landLuv)
        m.dLee = landLee == 0 ? 0 : Double(chLee) / Double(landLee)
        m.relief = t.landRelief()
        m.reliefRobust = t.landReliefRobust()
        let lake = t.lakeStats(depth: 0.03)
        m.lakeFrac = lake.fraction; m.largestLake = lake.largest
        m.rainLand = rainLandSum / Double(max(1, landLuv + landLee))
        m.rainSea = rainSeaSum / Double(max(1, seaCells))
        m.landShare = Double(landLuv + landLee) / Double(t.cfg.count)
        m.spawnLandShare = rainLandSum / max(1e-9, rainLandSum + rainSeaSum)
        return m
    }
}
