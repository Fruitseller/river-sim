import XCTest

@testable import SimCore

enum ChannelIncision {
    struct Sample {
        var cells: Int
        var incision: Double
        var channelH: Double
        var neighbourH: Double
    }

    static func measure(_ t: Terrain) -> Sample {
        let n = t.cfg.n
        let cs = t.cfg.cellSize
        let cellArea = cs * cs
        var sum = 0.0, chSum = 0.0, nbSum = 0.0, count = 0
        for k in 0..<t.cfg.count {
            if t.h[k] <= t.cfg.sea { continue }
            if t.area[k] / cellArea < 1000 { continue }
            let r = Int(t.receiver[k])
            if r < 0 || r == k { continue }
            let qi = -((r / n) - (k / n))
            let qj = (r % n) - (k % n)
            let i = k % n, j = k / n
            var acc = 0.0, m = 0
            for s in [-3, -2, 2, 3] {
                let xi = i + qi * s, xj = j + qj * s
                if xi < 0 || xi >= n || xj < 0 || xj >= n { continue }
                acc += t.h[xj * n + xi]; m += 1
            }
            if m < 2 { continue }
            sum += acc / Double(m) - t.h[k]
            chSum += t.h[k]
            nbSum += acc / Double(m)
            count += 1
        }
        let d = Double(max(count, 1))
        return Sample(cells: count, incision: sum / d, channelH: chSum / d, neighbourH: nbSum / d)
    }

    static func productionConfig() -> SimConfig {
        SimConfig.production
    }

    static let settleYears = SimConfig.productionSettleYears
}

final class ChannelIncisionTests: XCTestCase {
    func testChannelCarveWorksWithoutOutletIncisionAndCanBeDisabled() {
        func valley(targetDepth: Double) -> Terrain {
            var c = SimConfig()
            c.n = 128
            c.world = SimConfig().cellSize * Double(c.n - 1)
            c.channelTargetDepth = targetDepth
            c.outletIncision = false
            c.hydraulicPerYear = 0
            c.hillDiffusion = 0
            c.waveRelax = 0
            c.meanderEnabled = false
            c.braidingEnabled = false
            c.basinFill = false
            c.puddleFillYears = 0
            c.iceEnabled = false
            c.upliftPer100y = 0
            c.upliftDecayStartPer100y = 0
            c.upliftDecayFloorPer100y = 0
            c.reliefServoPer100y = 0
            let t = Terrain(allocating: c, seed: 1337)
            var heights = [Double](repeating: 0, count: c.count)
            for j in 0..<c.n {
                for i in 0..<c.n {
                    let k = j * c.n + i
                    let h = c.sea + 0.1 + Double(c.n - 1 - j) * 0.002
                        + Double(abs(i - c.n / 2)) * 0.001
                    heights[k] = h
                }
            }
            t.setBedForTests(h: heights, sed: [Double](repeating: 0, count: c.count),
                             rock: heights, underIce: [])
            return t
        }
        let on = valley(targetDepth: SimConfig().channelTargetDepth)
        let off = valley(targetDepth: 0)
        let initial = off.h
        on.step(dtYears: 1000)
        off.step(dtYears: 1000)
        XCTAssertEqual(off.h, initial, "Abgeschalteter Bett-Pass verändert die Höhen")
        XCTAssertTrue(zip(on.h, initial).contains { $0 < $1 },
                      "Bett-Pass hängt noch an outletIncision")
        let carved = ChannelIncision.measure(on)
        let unchanged = ChannelIncision.measure(off)
        XCTAssertGreaterThan(carved.cells, 0, "Testtal hat keinen messbaren Lauf")
        XCTAssertEqual(carved.cells, unchanged.cells)
        XCTAssertGreaterThan(carved.incision, unchanged.incision,
                             "Bett-Pass vertieft das Querprofil nicht")
    }

    func testLeversKeepTheChannelIncised() {
        var sumOn = 0.0, sumOff = 0.0
        for seed in [UInt32(1337), 7, 99] {
            var cOn = SimConfig(); cOn.n = 256
            cOn.world = SimConfig().cellSize * Double(cOn.n - 1)
            cOn.rangeLandform = calibrationRangeLandform
            cOn.meanderBelt = calibrationMeanderBelt
            cOn.deltaTrapFraction = calibrationDeltaTrapFraction
            var cOff = cOn
            cOff.channelDiffusionDamp = 1.0
            cOff.flowDepositDamp = 1.0
            let tOn = Terrain(config: cOn, seed: seed)
            let tOff = Terrain(config: cOff, seed: seed)
            var on = 0.0, off = 0.0, samples = 0.0
            while tOn.years < 20_000 - 1e-6 {
                tOn.step(dtYears: 1000); tOff.step(dtYears: 1000)
                if Int(tOn.years) % 4000 != 0 { continue }
                on += ChannelIncision.measure(tOn).incision
                off += ChannelIncision.measure(tOff).incision
                samples += 1
            }
            on /= samples; off /= samples
            print(String(format: "[INCISION] Wächter n=256 seed=%d: an=%.5f aus=%.5f (×%.2f)",
                         seed, on, off, on / max(off, 1e-12)))
            sumOn += on; sumOff += off
            XCTAssertLessThan(tOn.maxHeight(), 1.0, "Terrain-Runaway unter den Kanal-Hebeln")
            XCTAssertGreaterThan(tOn.landRelief(), tOff.landRelief() * 0.9,
                                 "Terrain eingeebnet unter den Kanal-Hebeln")
        }
        XCTAssertGreaterThan(sumOn, 0, "Flussbetten liegen auf Umgebungsniveau (Issue #108)")
        XCTAssertGreaterThan(sumOn, sumOff * 1.20, "die Kanal-Hebel wirken nicht")
    }

    func testCrossIncisionOverTimeDiagnostic() throws {
        try skipUnlessMeasuring()
        let seed = UInt32(ProcessInfo.processInfo.environment["RS_SEED"].flatMap { UInt32($0) } ?? 1337)
        let years = Double(ProcessInfo.processInfo.environment["RS_YEARS"].flatMap { Double($0) } ?? 100_000)
        let t = Terrain(config: ChannelIncision.productionConfig(), seed: seed,
                        settleYears: ChannelIncision.settleYears)
        let scale = RenderContract.heightScale
        func line(_ label: String) {
            let s = ChannelIncision.measure(t)
            print(String(format: "[INCISION] seed=%d %@ zellen=%d quereinschnitt=%.5f welt_y=%.3f kanal_h=%.4f nachbar_h=%.4f",
                         seed, label, s.cells, s.incision, s.incision * scale, s.channelH, s.neighbourH))
        }
        line("jahr0")
        var stepped = 0.0
        while stepped < years - 1e-6 {
            t.step(dtYears: 1000)
            stepped += 1000
            if Int(stepped) % 25_000 == 0 { line(String(format: "jahr%dk", Int(stepped) / 1000)) }
        }
    }

    func testIncisionLeverSweepDiagnostic() throws {
        try skipUnlessMeasuring()
        let arms: [(String, Double, Double, Bool)] = [
            ("beide aus (= vor #108) ", 1.0, 1.0, false),
            ("nur Diffusions-Schutz  ", 0.15, 1.0, false),
            ("nur Depositions-Dämpfer", 1.0, 0.15, false),
            ("beide an (= Produktion)", 0.15, 0.15, false),
            ("+ Pfützen (geparkt)    ", 0.15, 0.15, true),
        ]
        for (label, diff, dep, puddle) in arms {
            var c = ChannelIncision.productionConfig()
            c.channelDiffusionDamp = diff
            c.flowDepositDamp = dep
            c.puddleFillSkipsFlowCells = puddle
            let t = Terrain(config: c, seed: 1337, settleYears: ChannelIncision.settleYears)
            var out: [String] = []
            func take(_ y: Int) {
                let s = ChannelIncision.measure(t)
                out.append(String(format: "%dk:%.3f", y / 1000, s.incision * RenderContract.heightScale))
            }
            take(0)
            var stepped = 0
            while stepped < 100_000 {
                t.step(dtYears: 1000); stepped += 1000
                if stepped % 25_000 == 0 { take(stepped) }
            }
            print(String(format: "[SWEEP] %@ welt_y %@ | grat=%.4f relief=%.3f maxH=%.3f",
                         label, out.joined(separator: " "), t.ridgeCurvature(),
                         t.landRelief(), t.maxHeight()))
        }
    }
}
