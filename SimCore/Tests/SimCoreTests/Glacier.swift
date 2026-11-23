import XCTest
@testable import SimCore

final class Glacier: XCTestCase {

    private func cfg(n: Int = 384) -> SimConfig {
        var c = SimConfig(); c.n = n; c.world = calibrationWorld
        c.rangeLandform = calibrationRangeLandform
        c.meanderBelt = calibrationMeanderBelt
        c.iceFirnTemp = calibrationIceFirnTemp
        c.deltaTrapFraction = calibrationDeltaTrapFraction

        c.pinIceBeforeAvalanche()
        return c
    }

    private func quietCfg(n: Int = 384) -> SimConfig {
        var c = cfg(n: n)
        c.hillDiffusion = 0
        c.meanderEnabled = false
        c.braidingEnabled = false
        c.puddleFillYears = 0
        c.waveRelax = 0
        return c
    }

    private func run(_ t: Terrain, to years: Double, dt: Double = 500) {
        while t.years < years { t.step(dtYears: dt) }
    }

    struct IceStats {
        var land = 0
        var glacier = 0
        var fraction = 0.0
        var maxThick = 0.0
        var meanThick = 0.0
        var lowest = 0.0
        var belowFirn = 0
        var reach = 0.0
        var anyIce = 0
        var rawMax = 0.0
        var maxH = 0.0

        var line: String {
            String(format: "Eis %5d (%.2f%%) | dick max %.4f mittel %.4f | roh %5d/%.4f | unter Firn %5d | Reichweite %.4f | maxH %.4f",
                   glacier, fraction * 100, maxThick, meanThick, anyIce, rawMax,
                   belowFirn, reach, maxH)
        }
    }

    static func firnLine(_ c: SimConfig) -> Double {
        c.sea + (c.climateSeaLevelTemp - c.iceFirnTemp) / c.climateLapseRate
    }

    static func iceStats(_ t: Terrain) -> IceStats {
        let c = t.cfg
        var s = IceStats()
        let firn = firnLine(c)
        var sum = 0.0
        var lowest = Double.infinity
        s.maxH = t.maxHeight()
        for k in 0..<c.count where t.h[k] > c.sea {
            s.land += 1
            guard t.ice.count == c.count else { continue }
            if t.ice[k] > 0 { s.anyIce += 1; s.rawMax = max(s.rawMax, t.ice[k]) }
            guard t.ice[k] > c.iceMinThickness else { continue }
            s.glacier += 1
            sum += t.ice[k]
            if t.ice[k] > s.maxThick { s.maxThick = t.ice[k] }
            if t.h[k] < lowest { lowest = t.h[k] }
            if t.h[k] < firn { s.belowFirn += 1 }
        }
        s.fraction = s.land == 0 ? 0 : Double(s.glacier) / Double(s.land)
        s.meanThick = s.glacier == 0 ? 0 : sum / Double(s.glacier)
        s.lowest = lowest.isFinite ? lowest : 0
        s.reach = lowest.isFinite ? firn - lowest : 0
        return s
    }

    static func shapeExponent(_ t: Terrain, at k: Int, halfWidth: Int = 6) -> Double? {
        let n = t.cfg.n
        let r = t.receiver[k]
        guard r >= 0, halfWidth >= 2 else { return nil }
        let i = k % n, j = k / n
        let ri = Int(r) % n, rj = Int(r) / n
        let alongX = abs(ri - i) >= abs(rj - j)
        let stepIdx = alongX ? n : 1
        let limit = alongX ? min(j, n - 1 - j) : min(i, n - 1 - i)
        guard limit >= halfWidth else { return nil }
        let h0 = t.h[k]
        let half = halfWidth / 2
        let dHalf = 0.5 * (t.h[k - half * stepIdx] + t.h[k + half * stepIdx]) - h0
        let dFull = 0.5 * (t.h[k - halfWidth * stepIdx] + t.h[k + halfWidth * stepIdx]) - h0
        guard dHalf > 1e-6, dFull > dHalf else { return nil }
        return log(dFull / dHalf) / log(Double(halfWidth) / Double(half))
    }

    static func glacierCells(_ t: Terrain) -> [Int] {
        guard t.ice.count == t.cfg.count else { return [] }
        var out: [Int] = []
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea && t.ice[k] > t.cfg.iceMinThickness {
            out.append(k)
        }
        return out
    }

    static func valleyShape(_ t: Terrain, cells: [Int],
                            halfWidth: Int = 6) -> (b: Double, count: Int) {
        var sum = 0.0, cnt = 0
        for k in cells {
            guard let r = shapeExponent(t, at: k, halfWidth: halfWidth) else { continue }
            sum += r; cnt += 1
        }
        return (cnt == 0 ? 0 : sum / Double(cnt), cnt)
    }

    static func pairedShape(_ a: Terrain, _ b: Terrain, cells: [Int],
                            halfWidth: Int = 6) -> (a: Double, b: Double, count: Int) {
        var sa = 0.0, sb = 0.0, cnt = 0
        for k in cells {
            guard let ra = shapeExponent(a, at: k, halfWidth: halfWidth),
                  let rb = shapeExponent(b, at: k, halfWidth: halfWidth) else { continue }
            sa += ra; sb += rb; cnt += 1
        }
        guard cnt > 0 else { return (0, 0, 0) }
        return (sa / Double(cnt), sb / Double(cnt), cnt)
    }

    func testIceGrowthSeriesDiagnostic() throws {
        try skipUnlessMeasuring()
        let c = cfg()
        let t = Terrain(config: c, seed: 1337)
        print("Firn-Grenze h = \(String(format: "%.4f", Glacier.firnLine(c))), maxH = \(String(format: "%.4f", t.maxHeight()))")
        for y in stride(from: 5_000.0, through: 50_000.0, by: 5_000.0) {
            run(t, to: y)
            print("  \(Int(t.years)) J.: \(Glacier.iceStats(t).line)")
        }
    }

    func testPeakHeightSeriesDiagnostic() throws {
        try skipUnlessMeasuring()
        for n in [192, 256, 384, 640] {
            var c = cfg(n: n); c.iceEnabled = false
            let t = Terrain(config: c, seed: 1337)
            var line = "n=\(n): "
            for y in stride(from: 0.0, through: 40_000.0, by: 10_000.0) {
                if y > 0 { run(t, to: y) }
                line += String(format: "%.0fk %.4f  ", y / 1000, t.maxHeight())
            }
            print(line + String(format: "(Firn-Grenze %.4f)", Glacier.firnLine(c)))
        }
    }

    func testIceParameterSweepDiagnostic() throws {
        try skipUnlessMeasuring()
        for (flow, melt, firn, ero) in [(3.0, 0.0010, 1e-4, 0.0),
                                        (3.0, 0.0010, 2e-4, 0.0),
                                        (3.0, 0.0004, 1e-4, 0.0),
                                        (3.0, 0.0020, 2e-4, 0.0),
                                        (1.0, 0.0010, 1e-4, 0.0),
                                        (6.0, 0.0010, 1e-4, 0.0)] {
            var c = cfg(n: 384)
            c.iceFlowK = flow; c.iceMeltPerKYear = melt
            c.iceFirnPerSnowYear = firn; c.iceErodeK = ero
            let t = Terrain(config: c, seed: 1337)
            run(t, to: 30_000)
            print(String(format: "flow %.2f melt %.4f firn %.0e ero %.0e → ", flow, melt, firn, ero)
                  + Glacier.iceStats(t).line)
        }
    }

    func testGlacialErosionSweepDiagnostic() throws {
        try skipUnlessMeasuring()
        for (firn, ero, swath) in [(1e-4, 3e-5, 2), (4e-4, 3e-5, 2), (1e-3, 3e-5, 2),
                                   (4e-4, 1e-4, 2), (4e-4, 3e-5, 0), (4e-4, 3e-5, 4)] {
            var c = cfg(n: 384)
            c.iceFlowK = 3.0; c.iceMeltPerKYear = 0.001; c.iceFirnPerSnowYear = firn
            c.iceErodeK = ero; c.iceErodeSwathRadius = swath
            var off = c; off.iceEnabled = false
            let t = Terrain(config: c, seed: 1337)
            let ref = Terrain(config: off, seed: 1337)
            run(t, to: 30_000); run(ref, to: 30_000)
            let cells = Glacier.glacierCells(t)
            for w in [4, 6, 10] {
                let p = Glacier.pairedShape(t, ref, cells: cells, halfWidth: w)
                print(String(format: "firn %.0e ero %.0e swath %d W %2d → Eis %5d | b %.3f gegen %.3f ohne Eis (n=%d)",
                             firn, ero, swath, w, cells.count, p.a, p.b, p.count))
            }
            print("   " + Glacier.iceStats(t).line)
        }
    }

    func testValleyShapeSeriesDiagnostic() throws {
        try skipUnlessMeasuring()
        for (turnover, ero) in [(1000.0, 1e-4), (1000.0, 3e-4), (4000.0, 1e-4)] {
            var c = cfg(n: 384)
            c.iceTurnoverYears = turnover; c.iceErodeK = ero
            var off = c; off.iceEnabled = false
            let t = Terrain(config: c, seed: 1337)
            let ref = Terrain(config: off, seed: 1337)
            let probe = Terrain(config: c, seed: 1337)
            while probe.years < 50_000 { probe.step(dtYears: 500) }
            let cells = Glacier.glacierCells(probe)
            print(String(format: "turnover %.0f ero %.0e (Zellen %d)", turnover, ero, cells.count))
            for y in stride(from: 0.0, through: 50_000.0, by: 10_000.0) {
                if y > 0 { run(t, to: y); run(ref, to: y) }
                let p = Glacier.pairedShape(t, ref, cells: cells)
                print(String(format: "   %2.0fk J.: b %.3f (Eis) gegen %.3f (ohne) → Δ %+.3f  n=%d",
                             y / 1000, p.a, p.b, p.a - p.b, p.count))
            }
            print("   " + Glacier.iceStats(t).line)
        }
    }

    func testGlacierProductionValleyDiagnostic() throws {
        try skipUnlessMeasuring()
        let env = ProcessInfo.processInfo.environment
        let seeds = (env["RS_SEEDS"] ?? "1337,20").split(separator: ",").compactMap { UInt32($0) }
        let checkpoints = (env["RS_YEARS"] ?? "10000,20000,30000").split(separator: ",").compactMap { Double($0) }
        let variants = (env["RS_VARIANTS"] ?? "base").split(separator: ";").map(String.init)
        let dt = Double(env["RS_DT"] ?? "") ?? 100
        for seed in seeds { for v in variants {
            let c = Glacier.variant(v, of: SimConfig.production)
            var off = c; off.iceEnabled = false
            let ice = Terrain(config: c, seed: seed, settleYears: SimConfig.productionSettleYears)
            let ref = Terrain(config: off, seed: seed, settleYears: SimConfig.productionSettleYears)
            for target in checkpoints {
                for t in [ice, ref] { while t.years < target - 1e-6 { t.step(dtYears: min(dt, target - t.years)) } }
                let cells = Glacier.glacierCells(ice)
                var row = String(format: "VUP s%d %@ %.0fk | Eiszellen %d", seed, v, target / 1000, cells.count)
                for w in [6, 10, 14] {
                    let p = Glacier.pairedShape(ice, ref, cells: cells, halfWidth: w)
                    row += String(format: " | W%d b %.3f / %.3f Δ %+.3f n %d", w, p.a, p.b, p.a - p.b, p.count)
                }
                print(row); flushStdout()
                let firn = Glacier.firnLine(c)
                let classes: [(String, (Int) -> Bool)] = [
                    ("unter Firn", { ice.h[$0] < firn }),
                    ("über Firn", { ice.h[$0] >= firn }),
                    ("Eis > 0,05", { ice.ice[$0] > 0.05 }),
                    ("Eis ≤ 0,05", { ice.ice[$0] <= 0.05 }),
                ]
                var split = String(format: "VUS s%d %@ %.0fk", seed, v, target / 1000)
                for (name, pred) in classes {
                    let sub = cells.filter(pred)
                    let p = Glacier.pairedShape(ice, ref, cells: sub, halfWidth: 10)
                    split += String(format: " | %@ W10 Δ %+.3f n %d (%d Zellen)", name, p.a - p.b, p.count, sub.count)
                }
                print(split); flushStdout()
            }
        } }
    }

    func testProductionGlaciersCarveTroughs() {
        var weighted = [Int: Double](), counts = [Int: Int]()
        var tongues = 0.0, tongueN = 0
        for seed: UInt32 in [1337, 20, 33] {
            let c = SimConfig.production
            var off = c; off.iceEnabled = false
            let ice = Terrain(config: c, seed: seed, settleYears: SimConfig.productionSettleYears)
            let ref = Terrain(config: off, seed: seed, settleYears: SimConfig.productionSettleYears)
            for t in [ice, ref] { while t.years < 20_000 - 1e-6 { t.step(dtYears: 1000) } }
            let cells = Glacier.glacierCells(ice)
            for w in [6, 10, 14] {
                let p = Glacier.pairedShape(ice, ref, cells: cells, halfWidth: w)
                weighted[w, default: 0] += (p.a - p.b) * Double(p.count); counts[w, default: 0] += p.count
            }
            let firn = Glacier.firnLine(c)
            let below = cells.filter { ice.h[$0] < firn }
            let p = Glacier.pairedShape(ice, ref, cells: below, halfWidth: 10)
            tongues += (p.a - p.b) * Double(p.count); tongueN += p.count
        }
        for w in [6, 10, 14] {
            let d = weighted[w]! / Double(max(1, counts[w]!))
            print(String(format: "[V→U Produktion] W%d gepoolt Δb %+.3f (n %d)", w, d, counts[w]!))
            XCTAssertGreaterThan(counts[w]!, 1000, "W\(w): zu wenige auswertbare Profile")
        }
        XCTAssertGreaterThan(weighted[10]! / Double(counts[10]!), 0.05, "W 10: Gletschertäler werden nicht U-förmiger")
        XCTAssertGreaterThan(weighted[6]! / Double(counts[6]!), 0.0, "W 6: Gletschertäler werden V-förmiger")
        XCTAssertGreaterThan(weighted[14]! / Double(counts[14]!), 0.0, "W 14: Gletschertäler werden V-förmiger")
        XCTAssertGreaterThan(tongues / Double(max(1, tongueN)), 0.05, "Zungen unter der Firn-Grenze schleifen keinen Trog")
    }

    func testMoraineBudgetDiagnostic() throws {
        try skipUnlessMeasuring()
        var none = quietCfg(n: 256); none.iceErodeK = 0; none.iceMoraineK = 0
        var eroOnly = quietCfg(n: 256); eroOnly.iceMoraineK = 0
        var morOnly = quietCfg(n: 256); morOnly.iceErodeK = 0
        let base = Terrain(config: none, seed: 1337)
        run(base, to: 20_000)
        for dt in [500.0, 5000.0] {
            let a = Terrain(allocating: none, seed: 1337); a.restore(base.state)
            let b = Terrain(allocating: eroOnly, seed: 1337); b.restore(base.state)
            let c = Terrain(allocating: morOnly, seed: 1337); c.restore(base.state)
            a.step(dtYears: dt); b.step(dtYears: dt); c.step(dtYears: dt)
            var erosion = 0.0, moraine = 0.0
            for k in 0..<none.count {
                erosion += a.h[k] - b.h[k]
                moraine += c.h[k] - a.h[k]
            }
            print(String(format: "dt %5.0f → glazialer Abtrag %.6f, Moräne %.6f (%.1f %%)",
                         dt, erosion, moraine,
                         erosion > 0 ? moraine / erosion * 100 : 0))
        }
    }

    func testIcePassCostDiagnostic() throws {
        try skipUnlessMeasuring()
        for n in [384, 640] {
            let on = cfg(n: n)
            var off = on; off.iceEnabled = false
            let warm = Terrain(config: on, seed: 1337)
            run(warm, to: 20_000)
            let state = warm.state
            for dt in [0.2, 500.0, 10_000.0] {
                let a = Terrain(allocating: on, seed: 1337); a.restore(state)
                let b = Terrain(allocating: off, seed: 1337); b.restore(state)
                let reps = dt < 1 ? 20 : 3
                var ta = 0.0, tb = 0.0
                for _ in 0..<reps {
                    var s = Date(); a.step(dtYears: dt); ta += Date().timeIntervalSince(s)
                    s = Date(); b.step(dtYears: dt); tb += Date().timeIntervalSince(s)
                }
                print(String(format: "n=%d dt=%.1f → Schritt mit Eis %.1f ms, ohne %.1f ms (Δ %.1f ms)",
                             n, dt, ta / Double(reps) * 1000, tb / Double(reps) * 1000,
                             (ta - tb) / Double(reps) * 1000))
            }
        }
    }

    func testTongueReachesBelowTheFirnLine() {
        let c = cfg()
        let t = Terrain(config: c, seed: 1337)
        let firn = Glacier.firnLine(c)
        XCTAssertEqual(t.ice.count, c.count, "Eisfeld fehlt")
        XCTAssertEqual(t.ice.max(), 0, "die Generierung soll eisfrei bleiben (s. iceEnabled)")

        run(t, to: 2_000)
        let early = Glacier.iceStats(t)
        run(t, to: 5_000)
        let peak = Glacier.iceStats(t)
        run(t, to: 30_000)
        let late = Glacier.iceStats(t)

        XCTAssertGreaterThan(peak.belowFirn, early.belowFirn,
                             "die Zunge wächst nicht: \(early.belowFirn) → \(peak.belowFirn)")
        XCTAssertGreaterThan(late.glacier, 200, "kaum Eis übrig")
        XCTAssertGreaterThan(late.belowFirn, 50,
                             "keine Zunge unter der Firn-Grenze \(firn) — das Eis fließt nicht")
        XCTAssertGreaterThan(late.reach, 0.02,
                             "Reichweite unter die Firn-Grenze zu klein: \(late.reach)")
        XCTAssertGreaterThan(late.maxThick, 0.02, "das Eis bleibt hauchdünn")
    }

    func testWithoutFlowThereIsNoTongue() {
        var flowing = cfg(n: 256); flowing.iceErodeK = 0
        var still = flowing; still.iceFlowK = 0
        let a = Terrain(config: still, seed: 1337)
        let b = Terrain(config: flowing, seed: 1337)
        run(a, to: 10_000); run(b, to: 10_000)
        XCTAssertGreaterThan(a.ice.max() ?? 0, still.iceMinThickness, "Testaufbau: gar kein Eis")
        let stillBelow = Glacier.iceStats(a).belowFirn
        let flowBelow = Glacier.iceStats(b).belowFirn
        XCTAssertGreaterThan(flowBelow, 5 * max(1, stillBelow),
                             "der Transport bringt kaum mehr Eis unter die Grenze: "
                             + "\(flowBelow) gegen \(stillBelow)")
    }

    func testGlaciatedValleysWidenTowardsU() {
        let c = cfg()
        var off = c; off.iceEnabled = false
        let ice = Terrain(config: c, seed: 1337)
        let ref = Terrain(config: off, seed: 1337)
        for years in [30_000.0, 50_000.0] {
            run(ice, to: years); run(ref, to: years)
            let cells = Glacier.glacierCells(ice)
            let p = Glacier.pairedShape(ice, ref, cells: cells)
            XCTAssertGreaterThan(p.count, 20, "Stichprobe zu klein (\(years) J.)")
            let bound = years <= 30_000 ? 0.1 : -0.15
            XCTAssertGreaterThan(p.a, p.b + bound,
                                 "V→U bleibt aus (\(years) J.): b \(p.a) gegen \(p.b) ohne Eis")
            print(String(format: "%.0fk J.: b %.3f (Eis) gegen %.3f (ohne) → Δ %+.3f  n=%d",
                         years / 1000, p.a, p.b, p.a - p.b, p.count))
        }
    }

    func testMoraineBuildsAtTheTongue() {
        var on = quietCfg(n: 256)
        on.iceErodeK = 0
        var off = on; off.iceMoraineK = 0
        let a = Terrain(config: on, seed: 1337)
        run(a, to: 20_000)
        let b = Terrain(allocating: off, seed: 1337)
        b.restore(a.state)
        let before = a.h
        let tempBefore = a.temperature
        a.step(dtYears: 500)
        b.step(dtYears: 500)

        var warm = 0.0, cold = 0.0, warmCells = 0, morainedCells = 0
        for k in 0..<on.count where before[k] > on.sea {
            let d = a.h[k] - b.h[k]
            if d != 0 { morainedCells += 1 }
            if tempBefore[k] > 0 {
                warm += d
                if a.ice[k] > on.iceMinThickness { warmCells += 1 }
            } else {
                cold += d
            }
        }
        XCTAssertGreaterThan(warmCells, 20, "Testaufbau: kein Eis im Zehrgebiet")
        XCTAssertGreaterThan(morainedCells, 20, "nirgends Moräne abgelegt")
        XCTAssertGreaterThan(warm, 0, "im Zehrgebiet entsteht keine Moräne")
        XCTAssertEqual(cold, 0, accuracy: 0,
                       "unter dem Nährgebiet (T ≤ 0) darf kein Schutt ausschmelzen")
        XCTAssertGreaterThan(a.sed.reduce(0, +), b.sed.reduce(0, +),
                             "die Moräne wurde nicht als Sediment gebucht")
    }

    func testLayersStayConsistent() {
        let c = cfg(n: 256)
        let t = Terrain(config: c, seed: 1337)
        run(t, to: 30_000)
        XCTAssertGreaterThan(Glacier.iceStats(t).glacier, 50, "Testaufbau: kein Eis")
        var worst = 0.0
        for k in 0..<c.count {
            worst = max(worst, abs(t.h[k] - (t.rock[k] + t.sed[k])))
            XCTAssertGreaterThanOrEqual(t.sed[k], -1e-12, "negatives Sediment, Zelle \(k)")
            XCTAssertGreaterThanOrEqual(t.ice[k], 0, "negative Eisdicke, Zelle \(k)")
        }
        XCTAssertLessThan(worst, 1e-9, "h weicht von rock+sed ab (max \(worst))")
    }

    func testNoFluvialErosionUnderIce() {
        assertNoFluvialErosionUnderIce(quietCfg())
    }

    func testNoFluvialErosionUnderIceInProduction() {
        var c = quietCfg()
        c.meanderEnabled = true
        c.braidingEnabled = true
        assertNoFluvialErosionUnderIce(c)
    }

    func testNoFluvialErosionUnderIceOnTheGridPath() {
        var c = quietCfg()
        c.hydraulicEnabled = false
        let t = Terrain(config: c, seed: 1337)
        run(t, to: 20_000)
        let mask = t.underIce
        XCTAssertEqual(mask.count, c.count, "keine Eismaske aufgebaut")
        let glaciated = (0..<c.count).filter { mask[$0] }
        XCTAssertGreaterThan(glaciated.count, 100, "Testaufbau: zu wenig Eis")

        let before = t.h
        t.transportLimitedForTests(dt: 500)
        var differsOnIce = 0, differsOffIce = 0
        for k in 0..<c.count where t.h[k].bitPattern != before[k].bitPattern {
            if mask[k] { differsOnIce += 1 } else { differsOffIce += 1 }
        }
        print("[GATE] Grid-Pfad: \(glaciated.count) Eiszellen, \(differsOnIce) davon bewegt, \(differsOffIce) eisfreie bewegt")
        XCTAssertEqual(differsOnIce, 0,
                       "\(differsOnIce) vergletscherte Zellen wurden von transportLimited verändert")
        XCTAssertGreaterThan(differsOffIce, 100,
                             "Testaufbau: der Grid-Pfad war nirgends aktiv")
    }

    private func assertNoFluvialErosionUnderIce(_ base: SimConfig,
                                                file: StaticString = #filePath,
                                                line: UInt = #line) {
        var gated = base
        gated.iceErodeK = 0; gated.iceMoraineK = 0
        var noFluvial = gated
        noFluvial.outletErode = 0
        noFluvial.hydraulicPerYear = 0
        noFluvial.meanderCarve = 0
        noFluvial.meanderBankErode = 0
        noFluvial.braidCapacity = 0

        let a = Terrain(config: gated, seed: 1337)
        run(a, to: 20_000)
        let b = Terrain(allocating: noFluvial, seed: 1337)
        b.restore(a.state)
        let before = a.h
        a.step(dtYears: 500)
        b.step(dtYears: 500)
        let mask = a.underIce
        XCTAssertEqual(mask.count, gated.count, "keine Eismaske aufgebaut",
                       file: file, line: line)
        let glaciated = (0..<gated.count).filter { mask[$0] }
        XCTAssertGreaterThan(glaciated.count, 100, "Testaufbau: zu wenig Eis",
                             file: file, line: line)

        var differsOnIce = 0, differsOffIce = 0
        for k in 0..<gated.count {
            let same = a.h[k].bitPattern == b.h[k].bitPattern
            if mask[k] {
                if !same { differsOnIce += 1 }
            } else if !same {
                differsOffIce += 1
            }
        }
        XCTAssertEqual(differsOnIce, 0,
                       "\(differsOnIce) vergletscherte Zellen wurden fluvial verändert",
                       file: file, line: line)
        XCTAssertGreaterThan(differsOffIce, 100,
                             "Testaufbau: der fluviale Abtrag war nirgends aktiv",
                             file: file, line: line)
        _ = before
    }

    func testThinIceNeitherFlowsNorGrinds() {
        var base = quietCfg(n: 256)
        base.hydraulicPerYear = 0
        base.outletErode = 0
        let t = Terrain(config: base, seed: 1337)
        run(t, to: 20_000)
        let thickest = t.ice.max() ?? 0
        XCTAssertGreaterThan(thickest, base.iceMinThickness, "Testaufbau: gar kein Eis")
        let rim = (0..<base.count).filter { t.ice[$0] > 0 && t.ice[$0] <= base.iceMinThickness }
        print("[SAUM] \(rim.count) Zellen mit 0 < Eis ≤ iceMinThickness, dickstes Eis \(thickest)")
        XCTAssertGreaterThan(rim.count, 0, "kein Saum unter der Schwelle im Zustand")

        var raised = base; raised.iceMinThickness = 10 * thickest + 1
        var stilled = base; stilled.iceFlowMoveFraction = 0; stilled.iceErodeK = 0
        let a = Terrain(allocating: raised, seed: 1337);  a.restore(t.state)
        let b = Terrain(allocating: stilled, seed: 1337); b.restore(t.state)
        let c = Terrain(allocating: base, seed: 1337);    c.restore(t.state)
        a.step(dtYears: 500); b.step(dtYears: 500); c.step(dtYears: 500)

        var iceDiff = 0, bedDiff = 0
        for k in 0..<base.count {
            if a.ice[k].bitPattern != b.ice[k].bitPattern { iceDiff += 1 }
            if a.h[k].bitPattern != b.h[k].bitPattern { bedDiff += 1 }
        }
        XCTAssertEqual(iceDiff, 0, "\(iceDiff) Zellen: Eis unter der Schwelle ist geflossen")
        XCTAssertEqual(bedDiff, 0, "\(bedDiff) Zellen: Eis unter der Schwelle hat geschliffen")
        var active = 0
        for k in 0..<base.count where c.h[k].bitPattern != a.h[k].bitPattern { active += 1 }
        print("[SCHWELLE] geflossen \(iceDiff), geschliffen \(bedDiff), "
              + "über der Schwelle bewegt \(active)")
        XCTAssertGreaterThan(active, 100,
                             "Testaufbau: der Gletscher war auch über der Schwelle untätig")
    }

    func testIceIsFramerateIndependent() {
        for seed: UInt32 in [1337, 42, 20] {
            let src = Terrain(config: cfg(n: 256), seed: seed)
            run(src, to: 5_000)
            let arms = [1000.0, 100.0, 15.625].map {
                Glacier.iceArm(from: src, seed: seed, dt: $0, span: 1000)
            }
            for a in arms {
                print(String(format: "Seed %d, dt %7.3f → Eismasse %.4f, Zellen %d, Absenkung unter Eis %.6f",
                             seed, a.dt, a.mass, a.cells, a.lowering))
            }
            XCTAssertGreaterThan(arms.map(\.mass).min()!, 0, "Seed \(seed): kein Eis in einem der Arme")
            XCTAssertGreaterThan(arms.map(\.lowering).min()!, 0,
                                 "Seed \(seed): Testaufbau, das Eis schleift nicht")
            XCTAssertLessThan(Glacier.spread(arms.map(\.lowering)), 0.15,
                              "Seed \(seed): Gletscherschliff hängt an der Schrittweite: \(arms.map(\.lowering))")
            XCTAssertLessThan(Glacier.spread(arms.map(\.mass)), 0.03,
                              "Seed \(seed): Eismasse hängt an der Schrittweite: \(arms.map(\.mass))")
            XCTAssertLessThan(Glacier.spread(arms.map { Double($0.cells) }), 0.05,
                              "Seed \(seed): Eisfläche hängt an der Schrittweite: \(arms.map(\.cells))")
        }
    }

    func testAvalancheMovesFirnSupplyWithoutLosingIt() {
        func massSplit(_ hi: Double) -> (ramp: Double, foot: Double) {
            var c = cfg(n: 96)
            c.world = 0.156 * 95
            c.iceFlowK = 0; c.iceErodeK = 0; c.iceMoraineK = 0
            c.iceAvalancheSlopeLo = 1.0; c.iceAvalancheSlopeHi = hi
            var st = Terrain(config: c, seed: 1337).state
            let nn = c.n
            for j in 0..<nn { for i in 0..<nn {
                let k = j * nn + i
                let bed = c.sea + 0.9 - 0.0105 * Double(min(i, 30))
                st.h[k] = bed; st.rock[k] = bed; st.sed[k] = 0
                st.ice[k] = 0; st.snow[k] = 0.3
            } }
            let t = Terrain(allocating: c, seed: 1337); t.restore(st)
            for _ in 0..<5 { t.updateIce(dt: 200) }
            var ramp = 0.0, foot = 0.0
            for j in 8..<(nn - 8) { for i in 0..<nn {
                if i < 30 { ramp += t.ice[j * nn + i] } else { foot += t.ice[j * nn + i] }
            } }
            return (ramp, foot)
        }
        let off = massSplit(0), on = massSplit(1.6)
        XCTAssertGreaterThan(on.foot, 1.3 * off.foot, "der Firn geht nicht an den Hangfuß ab: \(on) gegen \(off)")
        XCTAssertLessThan(on.ramp, 0.5 * off.ramp, "die Rampe trägt weiter Firn: \(on) gegen \(off)")
        XCTAssertEqual(on.ramp + on.foot, off.ramp + off.foot, accuracy: 1e-6 * (off.ramp + off.foot),
                       "der Abgang verliert Zufuhr: \(on) gegen \(off)")
    }

    func testIceIsFramerateIndependentInProduction() {
        for seed: UInt32 in [1337, 20] {
            let src = Terrain(config: .production, seed: seed, settleYears: SimConfig.productionSettleYears)
            run(src, to: 5_000, dt: 1000)
            let arms = [1000.0, 100.0, 15.625].map { Glacier.iceArm(from: src, seed: seed, dt: $0, span: 1000) }
            XCTAssertGreaterThan(arms.map(\.mass).min()!, 5, "Seed \(seed): kaum Eis")
            XCTAssertLessThan(Glacier.spread(arms.map(\.mass)), 0.03,
                              "Seed \(seed): Eismasse hängt an der Schrittweite: \(arms.map(\.mass))")
            XCTAssertLessThan(Glacier.spread(arms.map { Double($0.cells) }), 0.07,
                              "Seed \(seed): Eisfläche hängt an der Schrittweite: \(arms.map(\.cells))")
        }
    }

    func testIceDomainFollowsNewFirnAndReplacedWorld() {
        let c = cfg(n: 64)
        var blank = Terrain(config: c, seed: 1337).state
        let bed = c.sea + 0.2
        for k in 0..<c.count {
            blank.h[k] = bed; blank.rock[k] = bed; blank.sed[k] = 0
            blank.ice[k] = 0; blank.snow[k] = 0; blank.temperature[k] = 5.8
        }
        let reused = Terrain(allocating: c, seed: 1337)
        for (i, j) in [(8, 8), (12, 8), (c.n - 3, c.n - 3), (c.n - 6, c.n - 3)] {
            var state = blank
            let k = j * c.n + i
            state.h[k] = c.sea + 0.65; state.rock[k] = state.h[k]
            state.snow[k] = 0.2; state.temperature[k] = -5.9
            reused.restore(state)
            let fresh = Terrain(allocating: c, seed: 1337); fresh.restore(state)
            for dt in [1000.0, 5000.0, 100.0] {
                reused.updateIce(dt: dt); fresh.updateIce(dt: dt)
                XCTAssertEqual(reused.ice, fresh.ice, "Alter Scratch nach Weltwechsel bei \(i),\(j)")
                XCTAssertEqual(reused.h, fresh.h)
                XCTAssertEqual(reused.sed, fresh.sed)
                XCTAssertEqual(reused.underIce, fresh.underIce)
            }
            XCTAssertGreaterThan(reused.ice[k], 0, "Die neue Firnquelle wurde übersprungen")
        }
    }

    func testThickIceTransportIsStableForLargeSteps() {
        var c = cfg(n: 64)
        c.iceErodeK = 0; c.iceMoraineK = 0
        var s = Terrain(config: c, seed: 1337).state
        let nn = c.n
        let bed = c.sea + 0.6
        func sign(_ k: Int) -> Double { ((k % nn) + (k / nn)) % 2 == 0 ? 1 : -1 }
        for k in 0..<c.count {
            s.h[k] = bed; s.rock[k] = bed; s.sed[k] = 0
            s.ice[k] = 1.0 + 0.001 * sign(k)
            s.snow[k] = 0
        }
        func roughness(_ t: Terrain) -> Double {
            let mean = t.ice.reduce(0, +) / Double(c.count)
            return t.ice.map { abs($0 - mean) }.max()!
        }
        let jump = Terrain(allocating: c, seed: 1337); jump.restore(s)
        let fine = Terrain(allocating: c, seed: 1337); fine.restore(s)
        jump.updateIce(dt: 2000)
        for _ in 0..<20 { fine.updateIce(dt: 100) }
        var worst = 0.0
        for k in 0..<c.count { worst = max(worst, abs(jump.ice[k] - fine.ice[k])) }
        print(String(format: "Schachbrett ±0.001 → Rauheit Sprung %.3e, 20 × 100 %.3e; größte Abweichung %.3e",
                     roughness(jump), roughness(fine), worst))
        XCTAssertLessThan(roughness(jump), 0.001, "Sprung: die Eisoberfläche schaukelt sich auf")
        XCTAssertLessThan(roughness(fine), 0.001, "20 × 100: die Eisoberfläche schaukelt sich auf")
        XCTAssertLessThan(worst, 1e-3, "Eisfeld hängt an der Schrittweite (max \(worst))")
    }

    struct IceArm { var dt: Double; var mass: Double; var cells: Int; var lowering: Double }

    static func iceArm(from src: Terrain, seed: UInt32, dt: Double, span: Double,
                       config: SimConfig? = nil) -> IceArm {
        let c = config ?? src.cfg
        let t = Terrain(allocating: c, seed: seed); t.restore(src.state)
        let steps = Int((span / dt).rounded())
        for _ in 0..<steps { t.step(dtYears: dt) }
        var mass = 0.0, lowering = 0.0, under = 0
        for k in 0..<c.count {
            mass += t.ice[k]
            if src.ice[k] > c.iceMinThickness && src.h[k] > c.sea {
                lowering += src.h[k] - t.h[k]; under += 1
            }
        }
        return IceArm(dt: dt, mass: mass, cells: Glacier.iceStats(t).glacier,
                      lowering: under == 0 ? 0 : lowering / Double(under))
    }

    static func spread(_ v: [Double]) -> Double {
        let lo = v.min()!, hi = v.max()!
        return (hi - lo) / max(abs(lo), abs(hi), 1e-12)
    }

    func testIceStepPairDiagnostic() throws {
        try skipUnlessMeasuring()
        let env = ProcessInfo.processInfo.environment
        let seeds = env["RS_SEED"].map { $0.split(separator: ",").compactMap { UInt32($0) } }
            ?? [1337, 42, 20]
        let starts = env["RS_START"].map { $0.split(separator: ",").compactMap { Double($0) } }
            ?? [5_000]
        let grid = env["RS_GRID"] ?? "256"
        let variants = (env["RS_VARIANTS"] ?? "base").split(separator: ";").map(String.init)
        for seed in seeds {
            let src: Terrain
            if grid == "prod" {
                src = Terrain(config: .production, seed: seed, settleYears: SimConfig.productionSettleYears)
            } else {
                src = Terrain(config: cfg(n: Int(grid) ?? 256), seed: seed)
            }
            for start in starts {
                run(src, to: start)
                for variant in variants {
                    let c = Glacier.variant(variant, of: src.cfg)
                    let arms = [1000.0, 100.0, 15.625].map {
                        Glacier.iceArm(from: src, seed: seed, dt: $0, span: 1000, config: c)
                    }
                    for a in arms {
                        print(String(format: "[EIS-PAAR] n %@ s%d J%.0f %@ dt %7.3f | Eis %.4f | Zellen %d | Absenkung %.6f",
                                     grid, seed, start, variant, a.dt, a.mass, a.cells, a.lowering))
                    }
                    print(String(format: "[EIS-PAAR] n %@ s%d J%.0f %@ Spanne Masse %.2f %% Zellen %.2f %% Absenkung %.2f %%",
                                 grid, seed, start, variant, 100 * Glacier.spread(arms.map(\.mass)),
                                 100 * Glacier.spread(arms.map { Double($0.cells) }),
                                 100 * Glacier.spread(arms.map(\.lowering))))
                }
            }
        }
    }

    static func variant(_ spec: String, of base: SimConfig) -> SimConfig {
        var c = base
        for kv in spec.split(separator: ",") {
            let p = kv.split(separator: "=")
            guard p.count == 2, let v = Double(p[1]) else { continue }
            switch p[0] {
            case "hill": c.hillDiffusion = v
            case "hyd": c.hydraulicPerYear = v
            case "outlet": c.outletErode = v
            case "wave": c.waveRelax = v
            case "pond": c.puddleFillYears = v
            case "erode": c.iceErodeK = v
            case "moraine": c.iceMoraineK = v
            case "firn": c.iceFirnPerSnowYear = v
            case "turn": c.iceTurnoverYears = v
            case "melt": c.iceMeltPerKYear = v
            case "flow": c.iceFlowK = v
            case "temp": c.climateSeaLevelTemp = v
            case "ifirn": c.iceFirnTemp = v
            case "lapse": c.climateLapseRate = v
            case "ice": c.iceEnabled = v != 0
            case "avlo": c.iceAvalancheSlopeLo = v
            case "avhi": c.iceAvalancheSlopeHi = v
            case "avrun": c.iceAvalancheMaxRun = Int(v)
            case "avreach": c.iceAvalancheReach = Int(v)
            case "swath": c.iceErodeSwathRadius = Int(v)
            case "mexp": c.iceErodeFluxExp = v
            case "uplift":
                c.upliftDecayStartPer100y = v; c.upliftDecayFloorPer100y = v; c.reliefServoPer100y = v
            default: break
            }
        }
        return c
    }

    func testIceDtSweepDiagnostic() throws {
        try skipUnlessMeasuring()
        let env = ProcessInfo.processInfo.environment
        let seeds = env["RS_SEED"].map { $0.split(separator: ",").compactMap { UInt32($0) } }
            ?? [1337, 42, 20]
        let dts = env["RS_DTS"].map { $0.split(separator: ",").compactMap { Double($0) } }
            ?? [15, 100, 1000]
        let checkpoints = env["RS_YEARS"].map { $0.split(separator: ",").compactMap { Double($0) } }
            ?? [20_000, 100_000]
        var rows: [String] = []
        for seed in seeds {
            for dt in dts {
                let started = Date()
                let vc = Glacier.variant(env["RS_VARIANT"] ?? "base", of: SimConfig.production)
                let t = Terrain(config: vc, seed: seed, settleYears: SimConfig.productionSettleYears)
                let firn = Glacier.firnLine(vc)
                for target in checkpoints {
                    while t.years < target - 1e-6 { t.step(dtYears: min(dt, target - t.years)) }
                    let s = Glacier.iceStats(t)
                    var mass = 0.0
                    for k in 0..<t.cfg.count { mass += t.ice[k] }
                    let over = t.h.filter { $0 > firn }.count
                    let row = String(format: "| %d | %.0f | %.0f | %.2f | %d | %.4f | %.4f | %d | %.0f s |",
                                     seed, dt, t.years, mass, s.glacier, s.maxThick, s.maxH, over,
                                     Date().timeIntervalSince(started))
                    print("[EIS-DT] " + row)
                    rows.append(row)
                }
            }
        }
        print("\n=== EIS-DT ===")
        print("| Seed | dt | Jahr | Eismasse | Eiszellen | max. Dicke | maxH | Zellen über Firn | Zeit |")
        print("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        rows.forEach { print($0) }
        print("=== ENDE EIS-DT ===\n")
    }

    func testZeroStepLeavesIceUntouched() {
        let t = Terrain(config: cfg(n: 192), seed: 1337)
        run(t, to: 10_000)
        let before = t.ice
        t.updateIce(dt: 0)
        XCTAssertEqual(before, t.ice, "ein zeitloser Aufruf hat das Eisfeld verändert")
    }

    func testIceIsDeterministic() {
        let a = Terrain(config: cfg(n: 256), seed: 1337)
        let b = Terrain(config: cfg(n: 256), seed: 1337)
        run(a, to: 20_000)
        run(b, to: 20_000)
        XCTAssertEqual(a.ice, b.ice, "Eisfeld nicht reproduzierbar")
        XCTAssertEqual(a.h, b.h, "Gelände nicht reproduzierbar")
        XCTAssertEqual(a.underIce, b.underIce, "Eismaske nicht reproduzierbar")
    }

    func testDisabledIceIsBitIdentical() {
        var off = cfg(n: 192); off.iceEnabled = false
        let t = Terrain(config: off, seed: 1337)
        run(t, to: 20_000)
        XCTAssertTrue(t.underIce.isEmpty, "abgeschaltet ist die Eismaske nicht leer")
        XCTAssertEqual(t.ice.count, off.count, "das Eisfeld soll trotzdem existieren (#33)")
        XCTAssertEqual(t.ice.max(), 0, "abgeschaltet ist das Eisfeld nicht konstant 0")
    }

    func testIcelessWorldIsBitIdentical() {
        var warm = cfg(n: 192)
        warm.climateSeaLevelTemp = 40
        var noIce = warm; noIce.iceEnabled = false
        let a = Terrain(config: warm, seed: 1337)
        let b = Terrain(config: noIce, seed: 1337)
        run(a, to: 5_000); run(b, to: 5_000)
        XCTAssertEqual(a.ice.max(), 0, "Testaufbau: die warme Welt hat Eis")
        XCTAssertTrue(a.underIce.isEmpty, "ohne Eis muss die Maske leer bleiben")
        XCTAssertEqual(a.h, b.h, "h weicht ab")
        XCTAssertEqual(a.rock, b.rock, "rock weicht ab")
        XCTAssertEqual(a.sed, b.sed, "sed weicht ab")
        XCTAssertEqual(a.streamMap, b.streamMap, "streamMap weicht ab")
        XCTAssertEqual(a.area, b.area, "area weicht ab")
    }

    func testIceCoverIsTheSingleSourceForColouring() {
        let c = cfg(n: 192)
        let t = Terrain(config: c, seed: 1337)
        run(t, to: 10_000)
        var painted = 0
        for k in 0..<c.count {
            let expected = t.ice[k] / (t.ice[k] + c.iceCoverRef)
            XCTAssertEqual(Terrain.iceCoverage(thickness: t.ice[k], ref: c.iceCoverRef),
                           expected, accuracy: 0, "Formel, Zelle \(k)")
            XCTAssertEqual(t.iceCover(k), expected, accuracy: 0, "Feldzugriff, Zelle \(k)")
            if t.iceCover(k) > 0.5 { painted += 1 }
        }
        XCTAssertGreaterThan(painted, 20, "kein Eis, das sich vom Schnee abheben könnte")
        var off = c; off.climateEnabled = false
        let cold = Terrain(config: off, seed: 1337)
        XCTAssertEqual(cold.iceCover(0), 0, "ohne Klima ist die Eis-Deckung nicht 0")
    }

    func testLongRunIceStaysBounded() {
        let c = cfg(n: 192)
        let t = Terrain(config: c, seed: 1337)
        let bound = c.iceFirnPerSnowYear * c.iceTurnoverYears
        var seen = 0.0
        while t.years < 200_000 {
            t.step(dtYears: 2000)
            let maxIce = t.ice.max() ?? 0
            seen = max(seen, maxIce)
            XCTAssertLessThanOrEqual(maxIce, bound + 1e-9,
                                     "Eisdicke über der Konstruktions-Grenze bei \(t.years) J.")
            XCTAssertFalse(maxIce.isNaN, "NaN im Eisfeld bei \(t.years) J.")
        }
        XCTAssertLessThan(seen, 2.0, "Eisdicke läuft weg (max \(seen))")
        print(String(format: "200k Jahre, n=%d: größte Eisdicke %.4f", c.n, seen))
        XCTAssertLessThan(t.landReliefRobust(), 1.0, "Relief entgleist")
        var worst = 0.0
        for k in 0..<c.count { worst = max(worst, abs(t.h[k] - (t.rock[k] + t.sed[k]))) }
        XCTAssertLessThan(worst, 1e-9, "Schichtbuchhaltung nach 200k Jahren kaputt")
    }

    func testIceWithoutCellSpacingDoesNotGrind() {
        func bedAfterIce(erodeK: Double) -> [Double] {
            var c = SimConfig()
            c.n = 3; c.world = 0
            c.iceErodeK = erodeK
            XCTAssertEqual(c.cellSize, 0.0)
            let t = Terrain(allocating: c, seed: 1)
            var s = t.state
            s.h = [0.5, 0.5, 0.5, 0.5, 0.8, 0.5, 0.5, 0.5, 0.5]
            s.rock = s.h
            s.sed = .init(repeating: 0, count: 9)
            s.ice = [0, 0, 0, 0, 0.1, 0, 0, 0, 0]
            s.snow = .init(repeating: 0, count: 9)
            s.temperature = .init(repeating: -5, count: 9)
            t.restore(s)
            t.updateIce(dt: 100)
            return t.h
        }
        let ground = bedAfterIce(erodeK: 1e-4)
        XCTAssertTrue(ground.allSatisfy(\.isFinite), "nicht-endliches Bett: \(ground)")
        XCTAssertEqual(ground, bedAfterIce(erodeK: 0),
                       "Eis ohne Schrittweite hat geschliffen")
    }
}
