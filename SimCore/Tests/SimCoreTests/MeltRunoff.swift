import XCTest
@testable import SimCore

final class MeltRunoff: XCTestCase {

    enum Arm: String, CaseIterable {
        case off = "aus", renorm = "A-renorm", extra = "B-zusatz", withhold = "C-einlag"
    }

    private func cfg(n: Int, arm: Arm) -> SimConfig {
        var c = SimConfig()
        c.n = n; c.world = calibrationWorld
        c.rangeLandform = calibrationRangeLandform
        switch arm {
        case .off:      c.meltRunoffEnabled = false
        case .renorm:   break
        case .extra:    c.meltRunoffNormalized = false
        case .withhold: c.meltRunoffWithholdSolid = 1.0
        }
        return c
    }

    private func run(_ t: Terrain, to years: Double, dt: Double = 1000) {
        while t.years < years - 1e-6 { t.step(dtYears: dt) }
    }

    private func upstream(_ t: Terrain, of field: [Double]) -> (cells: [Double], sum: [Double]) {
        let cnt = t.cfg.count
        var cells = [Double](repeating: 1, count: cnt)
        var sum = field
        var indeg = [Int](repeating: 0, count: cnt)
        for k in 0..<cnt where t.receiver[k] >= 0 { indeg[Int(t.receiver[k])] += 1 }
        var queue = (0..<cnt).filter { indeg[$0] == 0 }
        var head = 0
        while head < queue.count {
            let k = queue[head]; head += 1
            let r = t.receiver[k]
            guard r >= 0 else { continue }
            cells[Int(r)] += cells[k]
            sum[Int(r)] += sum[k]
            indeg[Int(r)] -= 1
            if indeg[Int(r)] == 0 { queue.append(Int(r)) }
        }
        return (cells, sum)
    }

    private func coverField(_ t: Terrain) -> [Double] {
        (0..<t.cfg.count).map { t.h[$0] > t.cfg.sea ? t.snowCover($0) : 0 }
    }

    struct Metrics {
        var channels = 0, landCells = 0
        var relief = 0.0, lakeFrac = 0.0
        var outletTotal = 0.0
        var meanWeight = 0.0, maxWeight = 0.0
        var snowFedCells = 0, snowFreeCells = 0
        var qSnowFed = 0.0, qSnowFree = 0.0
        var snowVisible = 0.0
    }

    private let minCatchment = 30.0
    private let snowFedThreshold = 0.05
    private let snowFreeThreshold = 0.002

    private func measure(_ t: Terrain) -> Metrics {
        let c = t.cfg
        let cellArea = c.cellSize * c.cellSize
        let cover = coverField(t)
        let up = upstream(t, of: cover)
        let w = t.flowWeight
        var m = Metrics()
        var wSum = 0.0, visible = 0
        for k in 0..<c.count {
            guard t.hf[k] > c.sea && t.h[k] > c.sea else { continue }
            m.landCells += 1
            if cover[k] > 0.05 { visible += 1 }
            let wk = w.isEmpty ? 1 : w[k]
            wSum += wk
            m.maxWeight = max(m.maxWeight, wk)
            if t.areaMFD[k] / cellArea >= c.renderMinCells { m.channels += 1 }
            guard up.cells[k] >= minCatchment else { continue }
            let q = t.area[k] / (up.cells[k] * cellArea)
            let s = up.sum[k] / up.cells[k]
            if s >= snowFedThreshold { m.snowFedCells += 1; m.qSnowFed += q }
            else if s <= snowFreeThreshold { m.snowFreeCells += 1; m.qSnowFree += q }
        }
        m.meanWeight = m.landCells == 0 ? 0 : wSum / Double(m.landCells)
        m.snowVisible = m.landCells == 0 ? 0 : Double(visible) / Double(m.landCells)
        m.relief = t.landRelief()
        m.lakeFrac = t.lakeStats(depth: 0.03).fraction
        m.outletTotal = t.totalOutletArea() / Double(c.count)
        if m.snowFedCells > 0 { m.qSnowFed /= Double(m.snowFedCells) }
        if m.snowFreeCells > 0 { m.qSnowFree /= Double(m.snowFreeCells) }
        return m
    }

    private func line(_ arm: Arm, _ seed: UInt32, _ years: Int, _ m: Metrics) -> String {
        String(format: """
            [#36] %@ Seed=%d Jahr=%d | Abfluss/Einzugszelle schneegespeist=%.4f (%d) \
            schneefrei=%.4f (%d) Verhältnis=%.4f | ΣAbfluss=%.4f | \
            Gewicht Mittel=%.4f max=%.3f | Kanalzellen=%d Relief=%.4f Seeanteil=%.4f \
            Schnee sichtbar=%.4f
            """,
            arm.rawValue, seed, years, m.qSnowFed, m.snowFedCells,
            m.qSnowFree, m.snowFreeCells,
            m.qSnowFree > 0 ? m.qSnowFed / m.qSnowFree : 0,
            m.outletTotal, m.meanWeight, m.maxWeight,
            m.channels, m.relief, m.lakeFrac, m.snowVisible)
    }

    func testMeltRunoffMeasurementDiagnostic() throws {
        try skipUnlessMeasuring()
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["RS_MEAS_N"] ?? "") ?? 192
        let years = Int(env["RS_MEAS_YEARS"] ?? "") ?? 20_000
        let seed = UInt32(env["RS_MEAS_SEED"] ?? "") ?? 1337
        let marks = [0, 5_000, 20_000, 50_000, 100_000].filter { $0 <= years }
        for arm in Arm.allCases {
            let t = Terrain(config: cfg(n: n, arm: arm), seed: seed)
            for mark in marks {
                run(t, to: Double(mark))
                print(line(arm, seed, mark, measure(t)))
            }
            XCTAssertGreaterThan(t.landRelief(), 0.10, "Terrain eingeebnet (\(arm.rawValue))")
        }
    }

    func testSnowyIslandScanDiagnostic() throws {
        try skipUnlessMeasuring()
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["RS_MEAS_N"] ?? "") ?? 192
        var snowy: [UInt32] = []
        for seed in (1...40).map(UInt32.init) + [1337, 99, 2024] {
            let t = Terrain(config: cfg(n: n, arm: .off), seed: seed)
            let m0 = measure(t), maxH0 = t.maxHeight()
            run(t, to: 20_000)
            let m = measure(t)
            if m.snowVisible > 0.001 { snowy.append(seed) }
            print(String(format: "[#36] Scan n=%d Seed=%d | maxH J0=%.4f J20k=%.4f | "
                                 + "Schnee sichtbar J0=%.4f J20k=%.4f | Läufe schneegespeist=%d",
                         n, seed, maxH0, t.maxHeight(),
                         m0.snowVisible, m.snowVisible, m.snowFedCells))
        }
        print("[#36] Scan: Inseln mit Schnee nach 20k J. = \(snowy)")
    }

    func testMeltRunoffIsSeedRobustDiagnostic() throws {
        try skipUnlessMeasuring()
        let seeds: [UInt32] = [1337, 2, 6, 20, 33]
        var fed = [Arm: (q: Double, n: Int)](), free = [Arm: (q: Double, n: Int)]()
        var outlet = [Arm: Double]()
        for seed in seeds {
            for arm in Arm.allCases {
                let t = Terrain(config: cfg(n: 192, arm: arm), seed: seed)
                run(t, to: 20_000)
                let m = measure(t)
                fed[arm] = ((fed[arm]?.q ?? 0) + m.qSnowFed * Double(m.snowFedCells),
                            (fed[arm]?.n ?? 0) + m.snowFedCells)
                free[arm] = ((free[arm]?.q ?? 0) + m.qSnowFree * Double(m.snowFreeCells),
                             (free[arm]?.n ?? 0) + m.snowFreeCells)
                outlet[arm] = max(outlet[arm] ?? 0, m.outletTotal)
                print(line(arm, seed, 20_000, m))
            }
        }
        for arm in Arm.allCases {
            let f = fed[arm]!, g = free[arm]!
            let ratio = (f.q / Double(max(1, f.n))) / (g.q / Double(max(1, g.n)))
            print(String(format: "[#36] gepoolt %@ | schneegespeist/schneefrei=%.4f "
                                 + "(%d/%d Zellen) | ΣAbfluss max=%.4f",
                         arm.rawValue, ratio, f.n, g.n, outlet[arm]!))
        }
    }

    func testMeltRunoffFavorsSnowFedCatchments() {
        var ratios = [Arm: Double]()
        for arm in [Arm.off, .renorm] {
            let t = Terrain(config: cfg(n: 192, arm: arm), seed: 1337)
            run(t, to: 20_000)
            let m = measure(t)
            print(line(arm, 1337, 20_000, m))
            XCTAssertGreaterThan(m.snowFedCells, 20, "zu wenige schneegespeiste Läufe")
            XCTAssertGreaterThan(m.snowFreeCells, 20, "zu wenige schneefreie Läufe")
            ratios[arm] = m.qSnowFed / m.qSnowFree
        }
        XCTAssertGreaterThan(ratios[.renorm]!, ratios[.off]! * 1.02,
                             "Schmelzwasser muss den Abfluss schneegespeister "
                             + "Einzugsgebiete messbar heben")
    }

    func testNormalizedMeltKeepsTheDrainageTotal() {
        let t = Terrain(config: cfg(n: 128, arm: .renorm), seed: 1337)
        let total = Double(t.cfg.count)
        for _ in 0..<5 {
            t.step(dtYears: 1000)
            XCTAssertFalse(t.runoffWeight.isEmpty, "Testaufbau: keine Schmelze im Spiel")
            XCTAssertEqual(t.totalOutletArea(), total, accuracy: total * 1e-6,
                           "die Renormierung darf die Entwässerungssumme nicht verschieben")
        }
        t.computeFlow(dtYears: 0)
        var wLand = 0.0, land = 0
        for k in 0..<t.cfg.count {
            if t.h[k] > t.cfg.sea { wLand += t.runoffWeight[k]; land += 1 }
            else { XCTAssertEqual(t.runoffWeight[k], 1.0,
                                  "über See muss das Gewicht neutral 1.0 sein") }
        }
        XCTAssertEqual(wLand / Double(land), 1.0, accuracy: 1e-9,
                       "Σ Gewicht über Land muss = Zahl der Landzellen sein")
        XCTAssertEqual(t.totalOutletArea(), total, accuracy: total * 1e-6,
                       "die Renormierung darf die Entwässerungssumme nicht verschieben")
    }

    func testExtraWaterArmRaisesTheDrainageTotal() {
        let t = Terrain(config: cfg(n: 128, arm: .extra), seed: 1337)
        for _ in 0..<5 { t.step(dtYears: 1000) }
        let ratio = t.totalOutletArea() / Double(t.cfg.count)
        print(String(format: "[#36] Zusatzwasser-Arm: ΣAbfluss/Zellzahl=%.5f", ratio))
        XCTAssertGreaterThan(ratio, 1.0 + 1e-6,
                            "der Zusatzwasser-Arm muss die Summe anheben (sonst ist er sinnlos)")
    }

    func testBothNetworksSeedFromTheSameWeight() {
        let t = Terrain(config: cfg(n: 192, arm: .renorm), seed: 1337)
        t.step(dtYears: 1000)
        XCTAssertFalse(t.runoffWeight.isEmpty, "Testaufbau: keine Schmelze im Spiel")
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let w = t.flowWeight
        let up = upstream(t, of: w)
        var maxRelErr = 0.0
        for k in 0..<t.cfg.count {
            let expect = up.sum[k] * cellArea
            maxRelErr = max(maxRelErr, abs(t.area[k] - expect) / max(1e-12, expect))
        }
        XCTAssertLessThan(maxRelErr, 1e-9,
                          "area muss die topologische Summe von flowWeight sein")
        let upRain = upstream(t, of: t.rainWeight)
        var maxRelErrRain = 0.0
        for k in 0..<t.cfg.count where upRain.sum[k] > 0 {
            maxRelErrRain = max(maxRelErrRain,
                                abs(t.area[k] - upRain.sum[k] * cellArea) / (upRain.sum[k] * cellArea))
        }
        XCTAssertGreaterThan(maxRelErrRain, 1e-6,
                             "Testaufbau: Schmelz- und Regen-Gewicht unterscheiden sich nicht")
    }

    func testMeltShiftsDropletSpawns() {
        let t = Terrain(config: cfg(n: 128, arm: .renorm), seed: 1337)
        t.step(dtYears: 1000)
        let c = t.cfg
        var boosted = [Bool](repeating: false, count: c.count)
        for k in 0..<c.count where t.runoffWeight[k] > t.rainWeight[k] * 1.05 { boosted[k] = true }
        XCTAssertGreaterThan(boosted.filter { $0 }.count, 50, "Testaufbau: keine Schmelzzone")
        func share(_ weight: [Double]) -> Double {
            let wMax = weight.max() ?? 0
            var rnd = Mulberry32(seed: 4242)
            var hits = 0
            let draws = 200_000
            for _ in 0..<draws {
                let s = Hydraulic.spawnPosition(&rnd, n: c.n, weight: weight, weightMax: wMax)
                if boosted[Int(s.y) * c.n + Int(s.x)] { hits += 1 }
            }
            return Double(hits) / Double(draws)
        }
        let withMelt = share(t.runoffWeight), rainOnly = share(t.rainWeight)
        print(String(format: "[#36] Tropfen-Starts in der Schmelzzone: mit Schmelze=%.5f "
                             + "nur Regen=%.5f (×%.3f)",
                     withMelt, rainOnly, withMelt / rainOnly))
        XCTAssertGreaterThan(withMelt, rainOnly * 1.05,
                             "die Tropfen-Starts folgen der Schmelze nicht")
    }

    func testDisabledMeltRunoffIsBitIdentical() {
        var a = cfg(n: 96, arm: .off)
        a.climateEnabled = true; a.iceEnabled = false
        var b = cfg(n: 96, arm: .renorm)
        b.snowAccumPerYear = 0
        b.iceEnabled = false
        let ta = Terrain(config: a, seed: 1337), tb = Terrain(config: b, seed: 1337)
        for _ in 0..<4 { ta.step(dtYears: 1000); tb.step(dtYears: 1000) }
        XCTAssertTrue(ta.runoffWeight.isEmpty, "ausgeschaltet muss das Feld leer bleiben")
        XCTAssertTrue(tb.runoffWeight.isEmpty, "ohne Schnee muss das Feld leer bleiben")
        XCTAssertEqual(ta.h, tb.h, "ohne Schmelze müssen beide Wege dieselbe Welt liefern")
        XCTAssertEqual(ta.area, tb.area)
        XCTAssertEqual(ta.areaMFD, tb.areaMFD)
        XCTAssertEqual(ta.streamMap, tb.streamMap)
    }

    func testWithoutClimateThereIsNoRunoffWeight() {
        var c = cfg(n: 96, arm: .renorm)
        c.climateEnabled = false
        let t = Terrain(config: c, seed: 1337)
        t.step(dtYears: 1000)
        XCTAssertTrue(t.snow.isEmpty && t.runoffWeight.isEmpty,
                      "ohne Klima darf kein Schmelz-Gewicht entstehen")
        XCTAssertEqual(t.flowWeight, t.rainWeight, "flowWeight muss zurückfallen")
    }

    func testUnweightedFlowIgnoresTheMelt() {
        var c = cfg(n: 96, arm: .renorm)
        c.rainWeightedFlow = false
        let t = Terrain(config: c, seed: 1337)
        t.step(dtYears: 1000)
        XCTAssertTrue(t.rainWeight.isEmpty && t.runoffWeight.isEmpty,
                      "ohne Regen-Gewichtung darf es kein Abfluss-Gewicht geben")
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let up = upstream(t, of: [Double](repeating: 1, count: t.cfg.count))
        var maxRelErr = 0.0
        for k in 0..<t.cfg.count {
            maxRelErr = max(maxRelErr, abs(t.area[k] - up.cells[k] * cellArea)
                                        / (up.cells[k] * cellArea))
        }
        XCTAssertLessThan(maxRelErr, 1e-9, "area muss reine Zellzahl bleiben")
    }

    private func sculptedSnowyPeak(_ arm: Arm) -> (t: Terrain, peak: Int) {
        let t = Terrain(config: cfg(n: 192, arm: arm), seed: 1337)
        t.step(dtYears: 1000)
        var peak = 0
        for k in 0..<t.cfg.count where t.snow[k] > t.snow[peak] { peak = k }
        XCTAssertGreaterThan(t.snow[peak], 0.1, "Testaufbau: keine tragfähige Schneedecke")
        let gx = Double(peak % t.cfg.n), gz = Double(peak / t.cfg.n)
        for _ in 0..<40 {
            t.flatten(gx: gx, gz: gz, radiusWorld: 0.1 * t.cfg.world,
                      targetHeight: t.cfg.sea + 0.05)
        }
        t.updateClimate(dt: 0)
        t.computeFlow(dtYears: 0)
        XCTAssertGreaterThan(t.temperature[peak], 5,
                             "Testaufbau: die Kuppe ist nicht im Warmen angekommen")
        XCTAssertGreaterThan(t.snow[peak], 0.1, "Testaufbau: der Vorrat ist schon weg")
        return (t, peak)
    }

    private func maxWeightRatio(_ t: Terrain) -> Double {
        var maxRatio = 0.0
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea {
            maxRatio = max(maxRatio, t.runoffWeight[k] / t.rainWeight[k])
        }
        return maxRatio
    }

    func testMeltContributionIsCappedAtTheLocalRain() {
        let (t, peak) = sculptedSnowyPeak(.renorm)
        let maxRatio = maxWeightRatio(t)
        print(String(format: "[#36] Deckel-Test: max runoffWeight/rainWeight=%.4f "
                             + "(ungedeckelt wäre der Schmelzterm ×%.0f des Regens)",
                     maxRatio,
                     t.cfg.snowMeltPerKYear * t.temperature[peak] * t.snow[peak]
                        / t.cfg.snowAccumPerYear / t.rain[peak]))
        XCTAssertLessThanOrEqual(maxRatio, 1 + t.cfg.meltRunoffCapPerRain + 1e-9,
                                 "der Schmelzbeitrag muss gedeckelt bleiben")
    }

    func testMeltContributionStaysCappedWithSolidWithholding() {
        let (t, _) = sculptedSnowyPeak(.withhold)
        XCTAssertGreaterThan(t.cfg.meltRunoffWithholdSolid, 0, "Testaufbau: keine Einlagerung")
        var skew = 0.0
        for k in 0..<t.cfg.count
        where t.h[k] > t.cfg.sea && t.snow[k] == 0 && t.temperature[k] >= t.cfg.snowRainTemp {
            skew = t.runoffWeight[k] / t.rainWeight[k]
            break
        }
        let maxRatio = maxWeightRatio(t)
        print(String(format: "[#36] Deckel-Test mit Einlagerung: max runoffWeight/"
                             + "rainWeight=%.4f · Normierungs-Skew=%.4f", maxRatio, skew))
        XCTAssertGreaterThan(skew, 1.0,
                             "Testaufbau: keine unberührte Zelle gefunden oder die "
                             + "Einlagerung hebt den Normierungsfaktor nicht")
        XCTAssertLessThanOrEqual(maxRatio, 1 + t.cfg.meltRunoffCapPerRain + 1e-9,
                                 "der Deckel muss auch mit Einlagerung halten")
    }

    func testEndorheicMechanicsSurviveMeltRunoff() {
        var c = SimConfig(); c.n = 256; c.world = calibrationWorld; c.endorheicEvapRatio = 6
        c.rangeLandform = calibrationRangeLandform
        var ref = c; ref.meltRunoffEnabled = false

        func playa(_ config: SimConfig, _ seed: UInt32) -> (bed: Int, crusted: Int, basins: Int) {
            let t = Terrain(config: config, seed: seed)
            for _ in 0..<10 { t.step(dtYears: 200) }
            var bed = 0, crusted = 0
            for k in 0..<t.cfg.count where t.endorheicBasin[k] == .dryBed {
                if t.saltCrust[k] > 0.5 { bed += 1 }
                if t.saltCrust[k] > 0.9 { crusted += 1 }
            }
            return (bed, crusted, t.endorheicStats().basins)
        }

        var playaOn = 0, playaOff = 0
        for seed: UInt32 in [1337, 42, 2024, 7] {
            let on = playa(c, seed), off = playa(ref, seed)
            print("[#36] Schmelze × #11 Seed \(seed) — an: Kruste>0.5 \(on.bed) / >0.9 "
                  + "\(on.crusted) / Becken \(on.basins); aus: \(off.bed) / \(off.crusted) "
                  + "/ \(off.basins)")
            if on.bed > 100 && on.crusted > 20 { playaOn += 1 }
            if off.bed > 100 && off.crusted > 20 { playaOff += 1 }
        }
        XCTAssertGreaterThan(playaOn, 0,
            "mit Schmelzwasser entsteht auf keinem Seed mehr eine Salzpfanne — #11 wäre kaputt")
        XCTAssertGreaterThanOrEqual(playaOn, playaOff,
            "Schmelzwasser kostet Salzpfannen-Seeds (an \(playaOn) gegen aus \(playaOff))")
    }

    func testMeltRunoffIsDeterministic() {
        let a = Terrain(config: cfg(n: 96, arm: .renorm), seed: 4242)
        let b = Terrain(config: cfg(n: 96, arm: .renorm), seed: 4242)
        for _ in 0..<3 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertEqual(a.h, b.h, "Schmelz-Gewichtung muss deterministisch bleiben")
        XCTAssertEqual(a.runoffWeight, b.runoffWeight)
        XCTAssertEqual(a.area, b.area)
        XCTAssertEqual(a.areaMFD, b.areaMFD)
    }

    func testRunoffWeightDoesNotDependOnDt() {
        let t = Terrain(config: cfg(n: 192, arm: .renorm), seed: 1337)
        t.step(dtYears: 1000)
        t.computeFlow(dtYears: 0)
        let ref = t.runoffWeight
        XCTAssertFalse(ref.isEmpty, "Testaufbau: keine Schmelze im Spiel")
        t.computeFlow(dtYears: 10_000)
        XCTAssertEqual(t.runoffWeight, ref, "das Gewicht darf nicht an dt hängen")
        t.computeFlow(dtYears: 1)
        XCTAssertEqual(t.runoffWeight, ref, "das Gewicht darf nicht an dt hängen")
    }

    func testRunoffWeightCostDiagnostic() throws {
        try skipUnlessMeasuring()
        var c = SimConfig(); c.n = 832; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        t.step(dtYears: 1000)
        let rounds = 100
        var clock = Date()
        for _ in 0..<rounds { t.computeRain() }
        let withMelt = -clock.timeIntervalSinceNow * 1000 / Double(rounds)
        var c2 = c; c2.meltRunoffEnabled = false
        let t2 = Terrain(config: c2, seed: 1337)
        t2.step(dtYears: 1000)
        clock = Date()
        for _ in 0..<rounds { t2.computeRain() }
        let rainOnly = -clock.timeIntervalSinceNow * 1000 / Double(rounds)
        clock = Date()
        for _ in 0..<10 { t.step(dtYears: 100) }
        let stepMs = -clock.timeIntervalSinceNow * 1000 / 10
        print(String(format: "[#36] n=832 computeRain je Schritt: mit Schmelze %.2f ms · "
                             + "ohne %.2f ms (Aufschlag %.2f ms) — ganzer step() %.1f ms",
                     withMelt, rainOnly, withMelt - rainOnly, stepMs))
    }
}
