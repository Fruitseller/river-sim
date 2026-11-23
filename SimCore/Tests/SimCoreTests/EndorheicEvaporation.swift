import XCTest
@testable import SimCore

final class EndorheicEvaporation: XCTestCase {

    private func cfg(n: Int = 256, kappa: Double? = nil) -> SimConfig {
        var c = SimConfig()
        c.n = n; c.world = calibrationWorld
        c.rangeLandform = calibrationRangeLandform
        c.meanderBelt = calibrationMeanderBelt
        if let kappa { c.endorheicEvapRatio = kappa }
        c.lithologyEnabled = false
        c.meltRunoffEnabled = false
        c.iceEnabled = false
        c.heightBandsOverride = .legacyAbsolute
        c.channelDiffusionDamp = 1.0
        c.flowDepositDamp = 1.0
        return c
    }

    private func dryCfg(n: Int = 256) -> SimConfig { cfg(n: n, kappa: 6) }

    private func endorheicBasins(_ t: Terrain) -> [[Int]] {
        let n = t.cfg.n
        var seen = [Bool](repeating: false, count: t.cfg.count)
        var comps = [[Int]]()
        for s in 0..<t.cfg.count where t.endorheicBasin[s] != .none && !seen[s] {
            var stack = [s], comp = [Int]()
            seen[s] = true
            while let k = stack.popLast() {
                comp.append(k)
                let i = k % n, j = k / n
                for dj in -1...1 {
                    for di in -1...1 {
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                        let nb = nj * n + ni
                        if t.endorheicBasin[nb] != .none && !seen[nb] { seen[nb] = true; stack.append(nb) }
                    }
                }
            }
            comps.append(comp)
        }
        return comps
    }

    private func largestEndorheicBasin(_ t: Terrain) -> [Int] {
        endorheicBasins(t).max { $0.count < $1.count } ?? []
    }

    private func playaCells(_ t: Terrain, _ cells: [Int]) -> [Int] {
        cells.filter { t.endorheicBasin[$0] == .dryBed && t.saltCrust[$0] > 0.5 }
    }

    private func waterArea(_ t: Terrain, _ cells: [Int]) -> Int {
        cells.reduce(0) { $0 + (t.endorheicBasin[$1] == .water ? 1 : 0) }
    }

    private func waterCells(_ t: Terrain, _ cells: [Int]) -> [Int] {
        cells.filter { t.hf[$0] - t.h[$0] > 0.001 }
    }

    func testDryBasinLevelStaysBelowSill() {
        let t = Terrain(config: dryCfg(), seed: 1337)
        let basin = largestEndorheicBasin(t)
        XCTAssertGreaterThan(basin.count, 200, "kein nennenswertes abflussloses Becken")
        let water = waterCells(t, basin)
        XCTAssertGreaterThan(water.count, 0, "Becken ganz ohne Wasserfläche")
        let level = water.map { t.hf[$0] }.max()!
        let bed = basin.filter { t.endorheicBasin[$0] == .dryBed }
        XCTAssertGreaterThan(bed.count, 0, "kein trockengefallener Beckenboden")
        let bedTop = bed.map { t.h[$0] }.max()!
        XCTAssertGreaterThan(bedTop, level + 0.005,
            "Trockenboden liegt nicht über dem Spiegel — kein gedeckeltes Becken")
        let n = t.cfg.n
        var reachedWater = 0, reachedSea = 0
        for start in bed.prefix(400) {
            var k = start
            var guardN = 0
            while guardN < 4 * n {
                guardN += 1
                if t.hf[k] - t.h[k] > 0.001 { reachedWater += 1; break }
                if t.h[k] <= t.cfg.sea { reachedSea += 1; break }
                let i = k % n, j = k / n
                var next = -1
                var bestSlope = 0.0
                for dj in -1...1 {
                    for di in -1...1 {
                        if di == 0 && dj == 0 { continue }
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                        let nb = nj * n + ni
                        let dist = (di != 0 && dj != 0) ? 2.0.squareRoot() : 1.0
                        let s = (t.h[k] - t.h[nb]) / dist
                        if s > bestSlope { bestSlope = s; next = nb }
                    }
                }
                if next < 0 { break }
                k = next
            }
        }
        let walked = min(400, bed.count)
        XCTAssertEqual(reachedSea, 0,
            "trockengefallener Boden entwässert ins Meer — das Becken ist offen, nicht gedeckelt")
        XCTAssertGreaterThan(Double(reachedWater), 0.4 * Double(walked),
            "der freigelegte Boden findet den Restsee nicht (\(reachedWater)/\(walked))")
    }

    func testBasinWaterAreaMatchesTheBudget() {
        var c = dryCfg()
        c.endorheicResponseYears = 0
        let t = Terrain(config: c, seed: 1337)
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let basin = largestEndorheicBasin(t)
        XCTAssertGreaterThan(basin.count, 200)
        func demand(_ k: Int) -> Double {
            let w = t.rainWeight.isEmpty ? 1 : t.rainWeight[k]
            let a = min(4.0, max(0.25, 1 + t.cfg.endorheicAridity * (1 - w)))
            return cellArea * t.cfg.endorheicEvapRatio * a
        }
        let inflow = basin.map { t.endorheicInflow[$0] }.max()!
        XCTAssertGreaterThan(inflow, 0, "kein Bilanz-Zufluss protokolliert")
        let water = basin.filter { t.endorheicBasin[$0] == .water }
        let spent = water.reduce(0.0) { $0 + demand($1) }
        XCTAssertLessThanOrEqual(spent, inflow * (1 + 1e-9),
            "Verdunstung über der Seefläche übersteigt den Zufluss")
        let dry = basin.filter { t.endorheicBasin[$0] == .dryBed }.sorted { t.h[$0] < t.h[$1] }
        if let next = dry.first {
            XCTAssertGreaterThan(spent + demand(next), inflow,
                "der Spiegel liegt unnötig tief — Budget nicht ausgeschöpft")
        }
    }

    func testWetAndDryClimateDifferBasinLevel() {
        func arm(_ kappa: Double) -> Terrain {
            var c = cfg(kappa: kappa)
            c.breachEnabled = false
            return Terrain(config: c, seed: 1337)
        }
        let wet = arm(0.5), dry = arm(6.0)
        let n = wet.cfg.n
        var seen = [Bool](repeating: false, count: wet.cfg.count)
        var ref = [Int]()
        for s in 0..<wet.cfg.count where !seen[s] && wet.hf[s] > wet.cfg.sea
                                         && wet.hf[s] - wet.h[s] > 0.03 {
            var stack = [s], comp = [Int]()
            seen[s] = true
            while let k = stack.popLast() {
                comp.append(k)
                let i = k % n, j = k / n
                for dj in -1...1 {
                    for di in -1...1 {
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                        let nb = nj * n + ni
                        if !seen[nb] && wet.hf[nb] > wet.cfg.sea && wet.hf[nb] - wet.h[nb] > 0.03 {
                            seen[nb] = true; stack.append(nb)
                        }
                    }
                }
            }
            if comp.count > ref.count { ref = comp }
        }
        XCTAssertGreaterThan(ref.count, 200, "kein Referenz-See im feuchten Arm")
        func level(_ t: Terrain) -> Double { ref.map { t.hf[$0] }.max()! }
        func volume(_ t: Terrain) -> Double { ref.reduce(0.0) { $0 + max(0, t.hf[$1] - t.h[$1]) } }
        print(String(format: "[KLIMA] Becken %d Zellen: feucht Spiegel %.4f Volumen %.3f · "
                             + "trocken Spiegel %.4f Volumen %.3f",
                     ref.count, level(wet), volume(wet), level(dry), volume(dry)))
        XCTAssertLessThan(level(dry), level(wet) - 0.01,
            "trockenes Klima hebt denselben Spiegel wie das feuchte")
        XCTAssertLessThan(volume(dry), 0.5 * volume(wet),
            "trockenes Klima hält fast dasselbe Wasservolumen")
        let basin = Set(largestEndorheicBasin(dry))
        XCTAssertGreaterThan(basin.count, 200, "trockener Arm hat kein abflussloses Becken")
        var escapes = 0
        for k in basin {
            let r = dry.receiver[k]
            if r >= 0 && !basin.contains(Int(r)) { escapes += 1 }
        }
        XCTAssertEqual(escapes, 0, "abflussloses Becken entwässert doch über die Sill")
        let wetOut = ref.contains { k in
            let r = wet.receiver[k]
            return r >= 0 && !ref.contains(Int(r))
        }
        XCTAssertTrue(wetOut, "feuchtes Becken hat auch keinen Abfluss — Vergleich ist blind")
    }

    func testUncappedRunIsBitIdenticalToDisabled() {
        var on = cfg(kappa: 0.5)
        var off = cfg(); off.endorheicEvaporation = false
        on.n = 160; on.world = calibrationWorld; off.n = 160
        let a = Terrain(config: on, seed: 1337)
        let b = Terrain(config: off, seed: 1337)
        for _ in 0..<5 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertFalse(a.endorheicBasin.contains { $0 != .none },
                       "κ=0.5 deckelt doch ein Becken — Referenzarm ungültig")
        XCTAssertEqual(a.h, b.h, "Höhenfeld weicht ab, obwohl kein Becken gedeckelt wurde")
        XCTAssertEqual(a.hf, b.hf, "Füllstand weicht ab")
        XCTAssertEqual(a.area, b.area, "D8-Abfluss weicht ab")
        XCTAssertEqual(a.areaMFD, b.areaMFD, "MFD-Abfluss weicht ab")
        XCTAssertEqual(a.veg, b.veg, "Vegetation weicht ab")
    }

    func testWellFedBasinIsUnchanged() {
        let t = Terrain(config: cfg(), seed: 2024)
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let n = t.cfg.n
        var seen = [Bool](repeating: false, count: t.cfg.count)
        var checked = 0
        for s in 0..<t.cfg.count where !seen[s] && t.hf[s] > t.cfg.sea && t.hf[s] > t.h[s] {
            let sill = t.hf[s]
            var stack = [s], comp = [Int]()
            var inflow = 0.0
            seen[s] = true
            while let k = stack.popLast() {
                comp.append(k)
                inflow = max(inflow, t.area[k])
                let i = k % n, j = k / n
                for dj in -1...1 {
                    for di in -1...1 {
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                        let nb = nj * n + ni
                        if !seen[nb] && t.hf[nb] == sill && t.hf[nb] > t.h[nb] {
                            seen[nb] = true; stack.append(nb)
                        }
                    }
                }
            }
            let ratio = inflow / cellArea / Double(comp.count)
            guard comp.count >= 100, ratio > 2 * t.cfg.endorheicEvapRatio else { continue }
            checked += 1
            for k in comp {
                XCTAssertEqual(t.endorheicBasin[k], .none,
                               "gut gespeistes Becken (Ratio \(ratio)) wurde gedeckelt")
            }
        }
        XCTAssertGreaterThan(checked, 0, "kein gut gespeistes Becken zum Prüfen gefunden")
    }

    func testBasinLevelIsRateLimited() {
        func run(_ tau: Double) -> (maxJump: Double, span: Double, moved: Double) {
            var c = dryCfg()
            c.endorheicResponseYears = tau
            let t = Terrain(config: c, seed: 1337)
            let basin = largestEndorheicBasin(t)
            XCTAssertGreaterThan(basin.count, 200, "kein abflussloses Becken (τ=\(tau))")
            let inv = 1.0 / Double(basin.count)
            func mean() -> Double { basin.reduce(0.0) { $0 + t.hf[$1] * inv } }
            var prev = mean()
            let first = prev
            var maxJump = 0.0, lo = prev, hi = prev
            for _ in 0..<200 {
                t.step(dtYears: 20)
                let m = mean()
                maxJump = max(maxJump, abs(m - prev))
                lo = min(lo, m); hi = max(hi, m)
                prev = m
            }
            return (maxJump, hi - lo, abs(prev - first))
        }
        let limited = run(500)
        print(String(format: "[RATE] τ=500: max Sprung %.5f Spanne %.5f (%.3f)",
                     limited.maxJump, limited.span, limited.maxJump / max(1e-9, limited.span)))
        XCTAssertGreaterThan(limited.span, 0.005,
            "Beckenspiegel wandert kaum — es gibt nichts zu begrenzen")
        XCTAssertLessThan(limited.maxJump, 0.6 * limited.span,
            "Beckenspiegel springt sichtbar (Ratenbegrenzung wirkt nicht)")
    }

    func testBasinLevelFollowsTargetRateLimited() {
        var base = dryCfg()
        base.endorheicResponseYears = 500
        let src = Terrain(config: base, seed: 1337)
        for _ in 0..<20 { src.step(dtYears: 20) }
        let basins = endorheicBasins(src)
        let basin = basins.max { waterArea(src, $0) < waterArea(src, $1) } ?? []
        XCTAssertGreaterThan(basin.count, 200, "kein abflussloses Becken")
        XCTAssertGreaterThan(waterArea(src, basin), 200,
                             "gewähltes Becken hat kaum Wasserfläche — die κ-Stufe"
                             + " hätte nichts, woran sie ziehen kann")
        let inv = 1.0 / Double(basin.count)
        let snapshot = src.state
        let start = basin.reduce(0.0) { $0 + src.hf[$1] * inv }

        func stepResponse(tau: Double) -> Double {
            var c = base
            c.endorheicResponseYears = tau
            c.endorheicEvapRatio = 12
            let t = Terrain(allocating: c, seed: 1337)
            t.restore(snapshot)
            t.step(dtYears: 20)
            return abs(basin.reduce(0.0) { $0 + t.hf[$1] * inv } - start)
        }
        let instant = stepResponse(tau: 0)
        let limited = stepResponse(tau: 500)
        print(String(format: "[STUFE] Becken %d Zellen (%d Wasser) · τ=0 %.5f · τ=500 %.5f (%.3f)",
                     basin.count, waterArea(src, basin), instant, limited,
                     limited / max(1e-9, instant)))
        XCTAssertGreaterThan(instant, 0.001,
            "das Ziel hat sich kaum verschoben — die Gegenprobe wäre leer")
        XCTAssertLessThan(limited, 0.25 * instant,
            "ratenbegrenzt folgt der Ziel-Stufe genauso schnell wie unbegrenzt")
    }

    func testBalanceLevelIsFramerateIndependent() {
        var c = dryCfg(n: 160)
        c.hydraulicEnabled = false
        c.meanderEnabled = false
        let fine = Terrain(config: c, seed: 1337)
        let coarse = Terrain(config: c, seed: 1337)
        let basin = largestEndorheicBasin(fine)
        guard basin.count >= 50 else {
            XCTFail("kein abflussloses Becken in dieser Konfiguration "
                    + "(\(basin.count) Zellen) — nichts zu vergleichen")
            return
        }
        for _ in 0..<50 { fine.step(dtYears: 20) }
        coarse.step(dtYears: 1000)
        let a = basin.reduce(0.0) { $0 + fine.hf[$1] } / Double(basin.count)
        let b = basin.reduce(0.0) { $0 + coarse.hf[$1] } / Double(basin.count)
        print(String(format: "[DT] Becken %d Zellen · 50×20 J. %.5f · 1×1000 J. %.5f",
                     basin.count, a, b))
        XCTAssertEqual(a, b, accuracy: 0.02,
                       "Bilanz-Spiegel hängt an der Schrittweite (\(a) vs \(b))")
    }

    func testDriedBedIsRenderedAsPlaya() {
        let t = Terrain(config: dryCfg(), seed: 1337)
        for _ in 0..<10 { t.step(dtYears: 200) }
        let basins = endorheicBasins(t)
        XCTAssertFalse(basins.isEmpty, "kein abflussloses Becken")
        let basin = basins.max { playaCells(t, $0).count < playaCells(t, $1).count } ?? []
        let bed = playaCells(t, basin)
        XCTAssertGreaterThan(bed.count, 100, "keine Salzpfanne entstanden")
        for k in bed {
            XCTAssertLessThan(t.hf[k] - t.h[k], 0.005, "Playa-Zelle führt noch Wasser")
            XCTAssertLessThan(t.waterLevel[k] - t.h[k], 0.03,
                              "Darstellungs-Seespiegel malt die Playa weiter blau")
        }
        let crusted = bed.filter { t.saltCrust[$0] > 0.9 }
        XCTAssertGreaterThan(crusted.count, 20, "keine voll verkrustete Pfannenfläche")
        for k in crusted { XCTAssertLessThan(t.veg[k], 0.2, "Salzpfanne begrünt") }
        let submerged = basin.filter { t.endorheicBasin[$0] == .water }
        XCTAssertGreaterThan(submerged.count, 20,
                             "kein Restsee im Pfannen-Becken — die Abnahme"
                             + " „Kruste baut sich unter Wasser ab\" hätte nichts"
                             + " zu vergleichen")
        let crustWet = submerged.isEmpty ? 0
            : submerged.reduce(0.0) { $0 + t.saltCrust[$1] } / Double(submerged.count)
        let crustDry = bed.reduce(0.0) { $0 + t.saltCrust[$1] } / Double(bed.count)
        print(String(format: "[KRUSTE] Becken %d Zellen · Pfanne %d (%d voll) ·"
                     + " Restsee %d · Kruste nass %.4f gegen trocken %.4f",
                     basin.count, bed.count, crusted.count, submerged.count,
                     crustWet, crustDry))
        XCTAssertLessThan(crustWet, 0.6 * crustDry,
                          "Salzkruste unter Wasser so stark wie auf der Pfanne")
    }

    func testEndorheicIsDeterministic() {
        let a = Terrain(config: cfg(n: 160), seed: 4242)
        let b = Terrain(config: cfg(n: 160), seed: 4242)
        for _ in 0..<5 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertEqual(a.endorheicBasin, b.endorheicBasin)
        XCTAssertEqual(a.saltCrust, b.saltCrust)
        XCTAssertEqual(a.hf, b.hf)
    }

    func testEvapRatioMeasurementDiagnostic() throws {
        try skipUnlessMeasuring()
        for kappa: Double in [0, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0] {
            for seed: UInt32 in [1337, 42, 2024] {
                var c = cfg(kappa: kappa)
                if kappa == 0 { c.endorheicEvaporation = false }
                let t = Terrain(config: c, seed: seed)
                func line(_ tag: String) -> String {
                    let any = t.lakeStats(), vis = t.lakeStats(depth: 0.03)
                    let e = t.endorheicStats()
                    let salt = t.saltCrust.reduce(0) { $0 + ($1 > 0.5 ? 1 : 0) }
                    return String(format: "%@ See %.2f%%/%d sichtbar %.2f%% | Becken %d (W %d, T %d) Salz %d",
                                  tag, any.fraction * 100, any.largest, vis.fraction * 100,
                                  e.basins, e.water, e.dryBed, salt)
                }
                let gen = line("gen")
                while t.years < 10_000 - 1e-6 { t.step(dtYears: 1000) }
                print(String(format: "[EVAP] κ=%.2f seed %u: %@ → %@ relief %.4f",
                             kappa, seed, gen, line("10k"), t.landReliefRobust()))
            }
        }
    }

    func testBasinRatioMeasurementDiagnostic() throws {
        try skipUnlessMeasuring()
        let big = ProcessInfo.processInfo.environment["RS_EVAP_N"].flatMap { Int($0) }
        for seed: UInt32 in [1337, 42, 2024] {
            var c = cfg(n: big ?? 256); c.endorheicEvaporation = false
            if big != nil { c.enableProductionPerformance() }
            let t = Terrain(config: c, seed: seed)
            for target in (big != nil ? [0.0, 5000.0] : [0.0, 10_000.0]) {
                while t.years < target - 1e-6 { t.step(dtYears: 1000) }
                let cellArea = t.cfg.cellSize * t.cfg.cellSize
                var seen = [Bool](repeating: false, count: t.cfg.count)
                var basins: [(cells: Int, ratio: Double, depth: Double)] = []
                for s in 0..<t.cfg.count where !seen[s] && t.hf[s] > t.cfg.sea && t.hf[s] > t.h[s] {
                    let sill = t.hf[s]
                    var stack = [s]; seen[s] = true
                    var cells = 0, inflow = 0.0, maxDepth = 0.0
                    while let k = stack.popLast() {
                        cells += 1
                        inflow = max(inflow, t.area[k])
                        maxDepth = max(maxDepth, t.hf[k] - t.h[k])
                        let i = k % t.cfg.n, j = k / t.cfg.n
                        for dj in -1...1 {
                            for di in -1...1 {
                                let ni = i + di, nj = j + dj
                                if ni < 0 || ni >= t.cfg.n || nj < 0 || nj >= t.cfg.n { continue }
                                let nb = nj * t.cfg.n + ni
                                if !seen[nb] && t.hf[nb] == sill && t.hf[nb] > t.h[nb] {
                                    seen[nb] = true; stack.append(nb)
                                }
                            }
                        }
                    }
                    basins.append((cells, inflow / cellArea / Double(cells), maxDepth))
                }
                basins.sort { $0.cells > $1.cells }
                let top = basins.prefix(10).map {
                    String(format: "%d Z ratio %.2f tief %.3f", $0.cells, $0.ratio, $0.depth)
                }.joined(separator: " · ")
                let total = basins.reduce(0) { $0 + $1.cells }
                let hit = [0.75, 1.0, 1.25, 1.5, 2.0, 3.0].map { k -> String in
                    let c = basins.filter { $0.ratio < k }.reduce(0) { $0 + $1.cells }
                    return String(format: "κ%.2f→%.0f%%", k, 100 * Double(c) / Double(max(1, total)))
                }.joined(separator: " ")
                print("[RATIO] seed \(seed) J\(Int(target)) n=\(t.cfg.n): \(basins.count) Becken, "
                      + "\(total) Ponding-Zellen — \(top) | gedeckelte Fläche: \(hit)")
            }
        }
    }

    func testProductionResolutionMeasurementDiagnostic() throws {
        try skipUnlessMeasuring()
        for kappa: Double in [0, 1.0, 1.25, 1.5, 2.0, 3.0] {
            var c = cfg(n: 832, kappa: kappa)
            c.enableProductionPerformance()
            if kappa == 0 { c.endorheicEvaporation = false }
            let t = Terrain(config: c, seed: 1337)
            var log = ""
            for target in [0.0, 5000.0, 20000.0] {
                while t.years < target - 1e-6 { t.step(dtYears: 1000) }
                let s = t.lakeStats(), vis = t.lakeStats(depth: 0.03), e = t.endorheicStats()
                let salt = t.saltCrust.reduce(0) { $0 + ($1 > 0.5 ? 1 : 0) }
                log += String(format: " | J%.0fk See %.2f%%/%d sichtbar %.2f%% Becken %d (W %d, T %d) Salz %d",
                              target / 1000, s.fraction * 100, s.largest, vis.fraction * 100,
                              e.basins, e.water, e.dryBed, salt)
            }
            print("[EVAP832] κ=\(kappa)\(log) relief \(t.landReliefRobust())")
        }
    }
}
