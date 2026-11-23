import XCTest
@testable import SimCore

final class FlattenRegeneration: XCTestCase {

    private static let uiMaxRadius = 30.0
    private static let uiMaxStrength = 3.0

    private func flatCfg(n: Int = 96) -> SimConfig {
        var c = SimConfig()
        c.n = n; c.world = calibrationWorld
        c.rangeLandform = calibrationRangeLandform
        c.meanderBelt = calibrationMeanderBelt
        return c
    }

    @discardableResult
    private func flattenWholeMap(_ t: Terrain, target: Double, rounds: Int = 14) -> Double {
        let r = FlattenRegeneration.uiMaxRadius
        let stepCells = max(1.0, (r / t.cfg.cellSize) * 0.5)
        let last = Double(t.cfg.n - 1)
        for _ in 0..<rounds {
            var gz = 0.0
            while gz <= last + stepCells {
                var gx = 0.0
                while gx <= last + stepCells {
                    t.flatten(gx: min(gx, last), gz: min(gz, last), radiusWorld: r,
                              targetHeight: target,
                              strength: FlattenRegeneration.uiMaxStrength)
                    gx += stepCells
                }
                gz += stepCells
            }
        }
        t.computeFlow()
        t.snapWaterLevel()
        return t.landRelief()
    }

    private func flattenedTerrain(seed: UInt32 = 1337, n: Int = 96) -> Terrain {
        let c = flatCfg(n: n)
        let t = Terrain(config: c, seed: seed)
        flattenWholeMap(t, target: c.sea + 0.25)
        return t
    }

    private func forestFraction(_ t: Terrain) -> Double {
        var land = 0, forest = 0
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea {
            land += 1
            if t.veg[k] > 0.45 { forest += 1 }
        }
        return land == 0 ? 0 : Double(forest) / Double(land)
    }

    private func macroSlope(_ t: Terrain) -> Double {
        let n = t.cfg.n
        var sum = 0.0
        var cnt = 0
        for j in 2..<(n - 2) {
            for i in 2..<(n - 2) {
                let k = j * n + i
                guard t.h[k] > t.cfg.sea else { continue }
                sum += Terrain.macroSlope(t.h, k, n)
                cnt += 1
            }
        }
        return cnt == 0 ? 0 : sum / Double(cnt)
    }

    private func channelFraction(_ t: Terrain) -> Double {
        var land = 0, chan = 0
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea {
            land += 1
            if t.streamMap[k] >= 0.5 { chan += 1 }
        }
        return land == 0 ? 0 : Double(chan) / Double(land)
    }

    private func drainageFraction(_ t: Terrain, cells: Double = 30) -> Double {
        let minA = cells * t.cfg.cellSize * t.cfg.cellSize
        var land = 0, chan = 0
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea {
            land += 1
            if t.area[k] >= minA { chan += 1 }
        }
        return land == 0 ? 0 : Double(chan) / Double(land)
    }

    private func vegSpread(_ t: Terrain) -> Double {
        var s = 0.0, s2 = 0.0, cnt = 0.0
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea {
            s += t.veg[k]; s2 += t.veg[k] * t.veg[k]; cnt += 1
        }
        guard cnt > 0 else { return 0 }
        return max(0, s2 / cnt - (s / cnt) * (s / cnt)).squareRoot()
    }

    private func meanStream(_ t: Terrain) -> Double {
        var s = 0.0, cnt = 0.0
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea { s += t.streamMap[k]; cnt += 1 }
        return cnt == 0 ? 0 : s / cnt
    }

    private func interiorHeights(_ t: Terrain, margin: Int = 16) -> [Double] {
        let n = t.cfg.n
        var out: [Double] = []
        out.reserveCapacity((n - 2 * margin) * (n - 2 * margin))
        for j in margin..<(n - margin) {
            for i in margin..<(n - margin) { out.append(t.h[j * n + i]) }
        }
        return out
    }

    private func interiorForest(_ t: Terrain, margin: Int = 16) -> Double {
        let n = t.cfg.n
        var land = 0, forest = 0
        for j in margin..<(n - margin) {
            for i in margin..<(n - margin) {
                let k = j * n + i
                guard t.h[k] > t.cfg.sea else { continue }
                land += 1
                if t.veg[k] > 0.45 { forest += 1 }
            }
        }
        return land == 0 ? 0 : Double(forest) / Double(land)
    }

    private func interiorMacroSlope(_ t: Terrain, margin: Int = 16) -> Double {
        let n = t.cfg.n
        var sum = 0.0, cnt = 0.0
        for j in margin..<(n - margin) {
            for i in margin..<(n - margin) {
                let k = j * n + i
                guard t.h[k] > t.cfg.sea else { continue }
                sum += Terrain.macroSlope(t.h, k, n)
                cnt += 1
            }
        }
        return cnt == 0 ? 0 : sum / cnt
    }

    private func interiorMix(_ t: Terrain, margin: Int = 16)
        -> (bare: Double, grass: Double, forest: Double, riparian: Double, water: Double) {
        let n = t.cfg.n
        var cnt = [0, 0, 0, 0]
        var water = 0, total = 0
        for j in margin..<(n - margin) {
            for i in margin..<(n - margin) {
                let k = j * n + i
                total += 1
                cnt[Int(t.vegClass[k])] += 1
                if t.hf[k] - t.h[k] > 0.02 { water += 1 }
            }
        }
        let d = Double(max(1, total))
        return (Double(cnt[0]) / d, Double(cnt[1]) / d, Double(cnt[2]) / d,
                Double(cnt[3]) / d, Double(water) / d)
    }

    private func interiorIncised(_ t: Terrain, depth: Double = 0.005, margin: Int = 16) -> Double {
        let n = t.cfg.n
        var cnt = 0.0, total = 0.0
        for j in margin..<(n - margin) {
            for i in margin..<(n - margin) {
                let k = j * n + i
                let ring = (t.h[k + 2] + t.h[k - 2] + t.h[k + 2 * n] + t.h[k - 2 * n]) * 0.25
                total += 1
                if ring - t.h[k] > depth { cnt += 1 }
            }
        }
        return total == 0 ? 0 : cnt / total
    }

    private func receiverStability(_ t: Terrain, years: Double = 250) -> Double {
        let before = t.snapshotReceivers()
        t.step(dtYears: years)
        return t.receiverAgreement(with: before)
    }

    private func innerRow(_ t: Terrain) -> String {
        let q = Terrain.landHeightQuantiles(heights: interiorHeights(t), sea: t.cfg.sea)
        let m = interiorMix(t)
        return String(format: "%7.0f | %8.5f | %8.5f | %8.5f | %6.1f%% | %5.1f %5.1f %5.1f %5.1f | %5.1f | %5.1f%%",
                      t.years, q.high, q.low, interiorMacroSlope(t), interiorForest(t) * 100,
                      m.bare * 100, m.grass * 100, m.forest * 100, m.riparian * 100,
                      m.water * 100, interiorIncised(t) * 100)
    }

    private static let innerHeader =
        "  Jahr | p95-Med. | Med.-p05 | Makro-S. |   Wald | kahl  Gras  Wald  Auw. | Wasser | Rinnen  (nur Innenfläche)"

    private func row(_ t: Terrain) -> String {
        String(format: "%7.0f | %8.4f | %8.5f | %8.5f | %8.5f | %6.1f%% | %6.2f%% | %6.2f%% | %6.4f | %6.4f",
               t.years, t.landRelief(), t.landReliefHigh(), t.landReliefLow(),
               macroSlope(t), forestFraction(t) * 100, channelFraction(t) * 100,
               drainageFraction(t) * 100, meanStream(t), vegSpread(t))
    }

    private static let header =
        "  Jahr |  max-min | p95-Med. | Med.-p05 | Makro-S. |   Wald |  Kanäle | Netz≥30 | Str.-Ø | veg-σ"

    func testFlattenMeasurementDiagnostic() throws {
        try skipUnlessMeasuring()
        let t = flattenedTerrain()
        print("== Issue #26: Einebnung auf sea+0.25, Seed 1337, n=96 ==")
        print(FlattenRegeneration.header)
        print(row(t))
        let marks = [3_000.0, 10_000.0, 50_000.0]
        for m in marks {
            while t.years < m { t.step(dtYears: 500) }
            print(row(t))
        }
        let ref = Terrain(config: flatCfg(), seed: 1337)
        print("== Kontrolle: unangetastetes Terrain, Seed 1337, n=96 ==")
        print(FlattenRegeneration.header)
        print(row(ref))
        for m in marks {
            while ref.years < m { ref.step(dtYears: 500) }
            print(row(ref))
        }
    }

    func testFlattenedPlateRegeneratesWithin3000Years() {
        for seed in [UInt32(1337), 4242, 777] {
            var off = flatCfg(); off.disturbanceEnabled = false
            let broken = Terrain(config: off, seed: seed)
            flattenWholeMap(broken, target: off.sea + 0.25)
            let fixed = flattenedTerrain(seed: seed)
            while broken.years < 3000 { broken.step(dtYears: 500) }
            while fixed.years < 3000 { fixed.step(dtYears: 500) }

            let qB = Terrain.landHeightQuantiles(heights: interiorHeights(broken), sea: off.sea)
            let qF = Terrain.landHeightQuantiles(heights: interiorHeights(fixed), sea: off.sea)
            let reliefB = qB.high + qB.low, reliefF = qF.high + qF.low
            let slopeB = interiorMacroSlope(broken), slopeF = interiorMacroSlope(fixed)
            let cutB = interiorIncised(broken), cutF = interiorIncised(fixed)

            XCTAssertGreaterThan(reliefF, 0.04,
                "Innenfläche bleibt flach (Seed \(seed)): p95−Median \(qF.high), Median−p05 \(qF.low)")
            XCTAssertGreaterThan(reliefF, reliefB * 3,
                "Regeneration bringt kaum mehr Relief als ohne Pfad (Seed \(seed)): \(reliefF) vs \(reliefB)")

            XCTAssertGreaterThan(slopeF, 0.002,
                "Keine Makro-Steigung auf der Innenfläche (Seed \(seed)): \(slopeF)")
            XCTAssertGreaterThan(slopeF, slopeB * 3,
                "Makro-Steigung kaum besser als ohne Pfad (Seed \(seed)): \(slopeF) vs \(slopeB)")

            XCTAssertGreaterThan(cutF, 0.08,
                "Keine Rinnen auf der Innenfläche (Seed \(seed)): \(cutF)")
            XCTAssertGreaterThan(cutF, cutB + 0.05,
                "Rinnen kaum mehr als ohne Pfad (Seed \(seed)): \(cutF) vs \(cutB)")
        }
    }

    func testSuccessionInsteadOfInstantForest() {
        let t = flattenedTerrain()
        XCTAssertLessThan(forestFraction(t), 0.05,
            "Eingeebnete Fläche übernimmt den alten Waldbestand (\(forestFraction(t)))")
        while t.years < 500 { t.step(dtYears: 250) }
        let earlyForest = interiorForest(t)
        XCTAssertLessThan(earlyForest, 0.5,
            "Nach 500 Jahren schon flächendeckend Wald (\(earlyForest)) — keine Sukzession")
        let earlyMix = interiorMix(t)
        XCTAssertGreaterThan(earlyMix.grass, 0.2,
            "Zwischenstadium Gras fehlt (\(earlyMix.grass))")
        while t.years < 3000 { t.step(dtYears: 250) }
        XCTAssertGreaterThan(interiorForest(t), 0.5,
            "Nach 3.000 Jahren wächst nichts nach (\(interiorForest(t)))")
        let mix = interiorMix(t)
        XCTAssertLessThan(mix.forest, 0.9,
            "Innenfläche ist flächendeckend derselbe Wald (\(mix.forest))")
    }

    func testDisturbedCellsDropInheritedStateAndStayLocal() {
        let c = flatCfg()
        let t = Terrain(config: c, seed: 1337)
        let vegBefore = t.veg, streamBefore = t.streamMap
        let center = Double(c.n / 2)
        let r = FlattenRegeneration.uiMaxRadius
        for _ in 0..<6 {
            t.flatten(gx: center, gz: center, radiusWorld: r,
                      targetHeight: c.sea + 0.25, strength: FlattenRegeneration.uiMaxStrength)
        }
        let rCells = r / c.cellSize
        var inside = 0, cleared = 0, outsideTouched = 0
        for j in 0..<c.n {
            for i in 0..<c.n {
                let k = j * c.n + i
                let d = (Double(i) - center).magnitudeHypot(Double(j) - center)
                if t.disturb[k] >= 0.99 {
                    inside += 1
                    if t.veg[k] <= vegBefore[k] * 0.01 && t.streamMap[k] <= streamBefore[k] * 0.01 {
                        cleared += 1
                    }
                } else if d > rCells + 1 {
                    if t.disturb[k] != 0 || t.veg[k] != vegBefore[k]
                        || t.streamMap[k] != streamBefore[k] { outsideTouched += 1 }
                }
            }
        }
        XCTAssertGreaterThan(inside, 100, "Testaufbau: zu wenige stark gestörte Zellen")
        XCTAssertEqual(cleared, inside,
            "Stark gestörte Zellen behalten Vegetation/Stream-Gedächtnis (\(inside - cleared) von \(inside))")
        XCTAssertEqual(outsideTouched, 0,
            "Der Eingriff hat \(outsideTouched) Zellen AUSSERHALB des Pinsels verändert")
    }

    func testFlattenDropsOldMeanderState() {
        func meanSinuosity(_ t: Terrain) -> Double {
            let ch = t.meander.channels
            return ch.isEmpty ? 0 : ch.map { $0.sinuosity }.reduce(0, +) / Double(ch.count)
        }
        func aged(_ c: SimConfig) -> Terrain {
            let t = Terrain(config: c, seed: 1337)
            while t.years < 15_000 { t.step(dtYears: 500) }
            return t
        }

        var off = flatCfg(); off.disturbanceEnabled = false
        let kept = aged(off)
        let keptOxbows = kept.meander.oxbows.count
        XCTAssertGreaterThan(keptOxbows, 0, "Testaufbau: keine Altarme entstanden")
        flattenWholeMap(kept, target: off.sea + 0.25)
        kept.step(dtYears: 250)
        XCTAssertGreaterThanOrEqual(kept.meander.oxbows.count, keptOxbows,
            "Testaufbau: ohne Pfad müssten die Altarme unverändert weiterlaufen")

        let t = aged(flatCfg())
        let sinBefore = meanSinuosity(t)
        XCTAssertGreaterThan(t.meander.oxbows.count, 0, "Testaufbau: keine Altarme entstanden")
        XCTAssertGreaterThan(sinBefore, 1.4, "Testaufbau: Läufe haben keine Schlingen")
        flattenWholeMap(t, target: t.cfg.sea + 0.25)
        t.step(dtYears: 250)
        XCTAssertTrue(t.meander.oxbows.isEmpty,
            "Altarme der alten Topografie überleben die Einebnung (\(t.meander.oxbows.count))")
        XCTAssertLessThan(meanSinuosity(t), 1.4,
            "Mäanderschlingen der alten Topografie laufen weiter (Sinuosität \(meanSinuosity(t)))")
    }

    func testFlattenIsExactlyFlatImmediately() {
        let c = flatCfg()
        let t = Terrain(config: c, seed: 1337)
        let target = c.sea + 0.25
        flattenWholeMap(t, target: target)
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for v in interiorHeights(t) { lo = min(lo, v); hi = max(hi, v) }
        XCTAssertEqual(hi - lo, 0, accuracy: 1e-9,
            "Einebnen hinterlässt sofort Struktur (\(lo) … \(hi)) statt einer exakten Ebene")
        XCTAssertEqual(lo, target, accuracy: 1e-9, "Zielhöhe nicht erreicht")
    }

    func testUntouchedAgingIsBitIdentical() {
        var off = flatCfg(); off.disturbanceEnabled = false
        let a = Terrain(config: off, seed: 1337)
        let b = Terrain(config: flatCfg(), seed: 1337)
        while a.years < 3000 { a.step(dtYears: 500); b.step(dtYears: 500) }
        XCTAssertEqual(a.h, b.h, "Alterung ohne Eingriff ist nicht bit-identisch")
        XCTAssertEqual(a.veg, b.veg, "Vegetation ohne Eingriff ist nicht bit-identisch")
        XCTAssertEqual(a.streamMap, b.streamMap, "Stream-Map ohne Eingriff ist nicht bit-identisch")
    }

    func testRegenerationIsFramerateIndependent() {
        var c = flatCfg()
        c.iceEnabled = false
        c.upliftDecayStartPer100y = 0
        c.upliftDecayFloorPer100y = 0
        c.upliftPer100y = 0
        c.reliefServoPer100y = 0
        c.outletIncision = false
        c.basinFill = false
        c.puddleFillYears = 0
        c.braidingEnabled = false
        c.hillDiffusion = 0
        c.waveRelax = 0
        c.meanderEnabled = false
        c.hydraulic.erodeRate = 0
        c.hydraulic.depositRate = 0
        func run(_ dt: Double) -> [Double] {
            let t = Terrain(config: c, seed: 1337)
            flattenWholeMap(t, target: c.sea + 0.25)
            while t.years < 1000 - 1e-9 { t.step(dtYears: dt) }
            return t.h
        }
        let big = run(1000), small = run(50)
        var maxDiff = 0.0
        for k in 0..<big.count { maxDiff = max(maxDiff, abs(big[k] - small[k])) }
        XCTAssertLessThan(maxDiff, 1e-9,
            "Regeneration hängt an der Schrittweite (max. Abweichung \(maxDiff))")
    }

    func testRegenerationIsDeterministic() {
        let a = flattenedTerrain()
        let b = flattenedTerrain()
        while a.years < 2000 { a.step(dtYears: 500); b.step(dtYears: 500) }
        XCTAssertEqual(a.h, b.h, "Regenerierter Lauf ist nicht deterministisch")
        XCTAssertEqual(a.veg, b.veg, "Vegetation des regenerierten Laufs ist nicht deterministisch")
    }

    func testDisturbanceExpires() {
        let t = flattenedTerrain()
        XCTAssertGreaterThan(t.disturb.max() ?? 0, 0.9, "Testaufbau: keine Störung gebucht")
        while t.years < 15_000 { t.step(dtYears: 500) }
        XCTAssertEqual(t.disturb.max() ?? 0, 0,
            "Störungsfeld klingt nicht aus — der Pfad bliebe dauerhaft aktiv")
    }

    func testDisturbanceSweepDiagnostic() throws {
        try skipUnlessMeasuring()
        print("Pfad  seed |  " + FlattenRegeneration.innerHeader + " | Netzstabilität")
        for on in [false, true] {
            for seed in [1337, 4242, 777] {
                var c = flatCfg()
                c.disturbanceEnabled = on
                let t = Terrain(config: c, seed: UInt32(seed))
                flattenWholeMap(t, target: c.sea + 0.25)
                while t.years < 3000 { t.step(dtYears: 500) }
                let line = innerRow(t)
                let stab = receiverStability(t)
                print(String(format: "%@ %5d | ", on ? "an " : "aus", seed) + line
                      + String(format: " | %.3f", stab))
            }
        }
    }

    func testMeanderStateDiagnostic() throws {
        try skipUnlessMeasuring()
        for on in [false, true] {
            var c = flatCfg(); c.disturbanceEnabled = on
            let t = Terrain(config: c, seed: 1337)
            while t.years < 15000 { t.step(dtYears: 500) }
            let ox0 = t.meander.oxbows.count
            let sin0 = t.meander.channels.map { $0.sinuosity }.reduce(0, +)
                / Double(max(1, t.meander.channels.count))
            flattenWholeMap(t, target: c.sea + 0.25)
            t.step(dtYears: 250)
            let sin1 = t.meander.channels.map { $0.sinuosity }.reduce(0, +)
                / Double(max(1, t.meander.channels.count))
            print(String(format: "Pfad %@ | Altarme %d -> %d | Sinuosität %.3f -> %.3f | Läufe %d -> %d",
                         on ? "an " : "aus", ox0, t.meander.oxbows.count, sin0, sin1,
                         0, t.meander.channels.count))
        }
    }

    func testRegenerationTrajectoryDiagnostic() throws {
        try skipUnlessMeasuring()
        for seed in [1337, 4242] {
            let t = flattenedTerrain(seed: UInt32(seed))
            print("== Verlauf, Seed \(seed) ==")
            print(FlattenRegeneration.innerHeader)
            print(innerRow(t))
            for m in [500.0, 1000.0, 2000.0, 3000.0, 10_000.0] {
                while t.years < m { t.step(dtYears: 250) }
                print(innerRow(t))
            }
        }
    }
}
