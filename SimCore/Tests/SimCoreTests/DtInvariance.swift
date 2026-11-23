import XCTest
@testable import SimCore

final class DtInvariance: XCTestCase {

    struct Metrics {
        var lakeFraction = 0.0
        var coastCells = 0.0
        var landRelief = 0.0
        var meanLand = 0.0

        static func += (l: inout Metrics, r: Metrics) {
            l.lakeFraction += r.lakeFraction; l.coastCells += r.coastCells
            l.landRelief += r.landRelief; l.meanLand += r.meanLand
        }
        static func / (l: Metrics, d: Double) -> Metrics {
            Metrics(lakeFraction: l.lakeFraction / d, coastCells: l.coastCells / d,
                    landRelief: l.landRelief / d, meanLand: l.meanLand / d)
        }
        var line: String {
            String(format: "lake %.4f | coast %6.0f | relief %.4f | meanLand %.4f",
                   lakeFraction, coastCells, landRelief, meanLand)
        }
    }

    static func coastCells(_ t: Terrain) -> Int {
        var c = 0
        for k in 0..<t.cfg.count where abs(t.h[k] - t.cfg.sea) <= t.cfg.waveBand { c += 1 }
        return c
    }

    static func metrics(_ t: Terrain) -> Metrics {
        t.computeFlow()
        var sum = 0.0, land = 0
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea { sum += t.h[k]; land += 1 }
        return Metrics(lakeFraction: t.lakeStats(depth: 0.01).fraction,
                       coastCells: Double(coastCells(t)),
                       landRelief: t.landReliefRobust(),
                       meanLand: land == 0 ? 0 : sum / Double(land))
    }

    static func run(seed: UInt32, n: Int = 192, years: Double = 20_000,
                    dt: Double, from: Double = 10_000, every: Double = 2_000,
                    configure: (inout SimConfig) -> Void = { _ in }) -> Metrics {
        var c = SimConfig(); c.n = n; c.world = calibrationWorld
        c.rangeLandform = calibrationRangeLandform
        configure(&c)
        let t = Terrain(config: c, seed: seed)
        var acc = Metrics(), samples = 0.0, next = from
        while t.years < years - 1e-9 {
            t.step(dtYears: min(dt, years - t.years))
            if t.years >= next - 1e-9 {
                next += every
                acc += metrics(t); samples += 1
            }
        }
        return acc / max(1, samples)
    }

    static func dev(_ a: Double, _ b: Double) -> Double {
        let m = max(abs(a), abs(b))
        return m < 1e-12 ? 0 : abs(a - b) / m
    }

    func testWaveErosionIsFramerateIndependent() {
        func waveOnly(dt: Double) -> (band: Int, mass: Double) {
            var c = SimConfig(); c.n = 96; c.world = calibrationWorld
            c.meanderEnabled = false; c.braidingEnabled = false
            c.outletIncision = false; c.puddleFillYears = 0; c.basinFill = false
            c.hydraulicPerYear = 0
            c.hillDiffusion = 0
            c.upliftPer100y = 0; c.upliftDecayStartPer100y = 0; c.upliftDecayFloorPer100y = 0
            c.reliefServoPer100y = 0
            let t = Terrain(config: c, seed: 1337)
            while t.years < 4000 - 1e-9 { t.step(dtYears: min(dt, 4000 - t.years)) }
            var mass = 0.0
            for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea { mass += t.h[k] - t.cfg.sea }
            return (DtInvariance.coastCells(t), mass)
        }
        let a = waveOnly(dt: 10), b = waveOnly(dt: 250), c = waveOnly(dt: 2000)
        print("Wave-only: \(a) | \(b) | \(c)")
        for (x, y) in [(a, b), (a, c), (b, c)] {
            XCTAssertLessThan(DtInvariance.dev(Double(x.band), Double(y.band)), 0.05,
                              "Küstenzone driftet mit der Schrittweite: \(x.band) vs \(y.band)")
            XCTAssertLessThan(DtInvariance.dev(x.mass, y.mass), 0.02,
                              "Landmasse driftet mit der Schrittweite: \(x.mass) vs \(y.mass)")
        }
    }

    func testRelaxationsTelescopeAcrossSubsteps() {
        for tau in [250.0, 800.0, 3000.0, 5500.0] {
            for total in [240.0, 2000.0, 10_000.0] {
                for parts in [1, 3, 24, 1000] {
                    let dt = total / Double(parts)
                    var rest = 1.0
                    for _ in 0..<parts { rest *= 1 - (1 - exp(-dt / tau)) }
                    XCTAssertEqual(1 - rest, 1 - exp(-total / tau), accuracy: 1e-9,
                                   "τ=\(tau), \(total) J. in \(parts) Teilschritten")
                }
            }
        }
    }

    func testDropletCountIsARate() {
        var c = SimConfig(); c.n = 64; c.world = calibrationWorld
        let expected = 1000.0 * c.hydraulicPerYear * Double(c.n * c.n) / (640.0 * 640.0)
        for dt in [0.2, 1.0, 50.0, 1000.0] {
            let t = Terrain(config: c, seed: 1337)
            var drops = 0, elapsed = 0.0
            while elapsed < 1000 - 1e-9 {
                let step = min(dt, 1000 - elapsed)
                drops += t.dropletCount(dtYears: step)
                elapsed += step
            }
            XCTAssertLessThanOrEqual(abs(Double(drops) - expected), 1.0,
                                     "dt \(dt): \(drops) Tropfen statt \(expected)")
        }
    }

    func testDropletStreamIsChunkingInvariant() {
        var c = SimConfig(); c.n = 96; c.world = calibrationWorld
        let ref = Terrain(config: c, seed: 1337)
        let p = c.hydraulic

        func run(total: Int, chunk: Int) -> ([Double], [Double]) {
            var h = ref.h, rock = ref.rock, sed = ref.sed
            var track = [Double](repeating: 0, count: c.count)
            var done = 0
            while done < total {
                let k = min(chunk, total - done)
                Hydraulic.erode(h: &h, rock: &rock, sed: &sed, n: c.n, count: k,
                                seed: 1337, floor: c.floor, p: p,
                                seaLevel: nil, firstDrop: UInt64(done),
                                hf: ref.hf, receiver: ref.receiver,
                                stream: ref.streamMap,
                                flowWeight: ref.flowWeight,
                                erodibility: ref.lithErodeK,
                                track: &track)
                done += k
            }
            return (h, track)
        }

        let single = run(total: 120, chunk: 120)
        for chunk in [1, 7, 40] {
            let split = run(total: 120, chunk: chunk)
            XCTAssertEqual(split.0, single.0, "Höhenfeld hängt an der Chargengröße \(chunk)")
            XCTAssertEqual(split.1, single.1, "Besuchszählung hängt an der Chargengröße \(chunk)")
        }
        var h2 = ref.h, rock2 = ref.rock, sed2 = ref.sed
        var track2 = [Double](repeating: 0, count: c.count)
        Hydraulic.erode(h: &h2, rock: &rock2, sed: &sed2, n: c.n, count: 120,
                        seed: 1337, floor: c.floor, p: p,
                        seaLevel: nil, firstDrop: 1,
                        hf: ref.hf, receiver: ref.receiver, stream: ref.streamMap,
                        flowWeight: ref.flowWeight, erodibility: ref.lithErodeK,
                        track: &track2)
        XCTAssertNotEqual(h2, single.0, "verschobener Tropfen-Strom liefert dasselbe Feld?")
    }

    func testStepCapsAreRates() {
        let t = Terrain(config: { var c = SimConfig(); c.n = 32; c.world = calibrationWorld; return c }(), seed: 1)
        for dt in [1e-6, 1.0, 20.0, 250.0, 500.0] {
            XCTAssertEqual(t.stepCapFractionForTests(dt), 0.5, accuracy: 1e-12, "dt \(dt)")
        }
        XCTAssertEqual(t.stepCapFractionForTests(1000), 0.75, accuracy: 1e-9)
        XCTAssertEqual(t.stepCapFractionForTests(2000), 0.9375, accuracy: 1e-9)
        for parts in [2, 4, 8] {
            let total = 500.0 * Double(parts)
            var rest = 1.0
            for _ in 0..<parts { rest *= 1 - t.stepCapFractionForTests(500) }
            XCTAssertEqual(1 - rest, t.stepCapFractionForTests(total), accuracy: 1e-9,
                           "\(total) J. gegen \(parts)×500 J.")
        }
        XCTAssertLessThanOrEqual(t.stepCapFractionForTests(1e6), 1.0)
        XCTAssertLessThan(t.stepCapFractionForTests(1000), 1.0)
    }

    func testDrainageIsFramerateIndependentWithoutDroplets() {
        func arms(_ tweak: @escaping (inout SimConfig) -> Void) -> [(dt: Double, m: Metrics)] {
            [10.0, 240.0, 2000.0].map { dt in
                (dt, DtInvariance.run(seed: 1337, dt: dt) { c in
                    c.hydraulicPerYear = 0
                    c.meanderEnabled = false; c.braidingEnabled = false
                    c.hillDiffusion = 0; c.waveRelax = 0
                    c.upliftPer100y = 0; c.upliftDecayStartPer100y = 0
                    c.upliftDecayFloorPer100y = 0; c.reliefServoPer100y = 0
                    tweak(&c)
                })
            }
        }
        for (tag, run) in [("ohne Pfützen", arms { $0.puddleFillYears = 0 }),
                           ("ohne Kern-Gate", arms { $0.puddleLakeCoreCells = 1 << 28 })] {
            for a in run { print(String(format: "\(tag) dt %6.0f | ", a.dt) + a.m.line) }
            for a in run {
                for b in run where b.dt > a.dt {
                    XCTAssertLessThan(DtInvariance.dev(a.m.lakeFraction, b.m.lakeFraction), 0.10,
                                      "\(tag), dt \(Int(a.dt)) vs \(Int(b.dt)): Seeanteil "
                                      + "\(a.m.lakeFraction) vs \(b.m.lakeFraction)")
                }
            }
        }
    }

    func testSameTimeSameResultAcrossStepSizes() {
        let arms = [10.0, 240.0, 2000.0].map { (dt: $0, m: DtInvariance.run(seed: 1337, dt: $0)) }
        for a in arms { print(String(format: "dt %6.0f | ", a.dt) + a.m.line) }
        for a in arms {
            for b in arms where b.dt > a.dt {
                let tag = "dt \(Int(a.dt)) vs \(Int(b.dt))"
                XCTAssertLessThan(DtInvariance.dev(a.m.coastCells, b.m.coastCells), 0.10,
                                  "\(tag): Küstenzone \(a.m.coastCells) vs \(b.m.coastCells)")
                XCTAssertLessThan(DtInvariance.dev(a.m.landRelief, b.m.landRelief), 0.20,
                                  "\(tag): Relief \(a.m.landRelief) vs \(b.m.landRelief)")
                XCTAssertLessThan(DtInvariance.dev(a.m.meanLand, b.m.meanLand), 0.05,
                                  "\(tag): meanLand \(a.m.meanLand) vs \(b.m.meanLand)")
                XCTAssertLessThan(DtInvariance.dev(a.m.lakeFraction, b.m.lakeFraction), 0.90,
                                  "\(tag): Seeanteil \(a.m.lakeFraction) vs \(b.m.lakeFraction)")
            }
        }
    }

    func testPuddleGateProbeDiagnostic() throws {
        try skipUnlessMeasuring()
        let variants: [(String, (inout SimConfig) -> Void)] = [
            ("Pfütze aus     ", { $0.puddleFillYears = 0 }),
            ("Pfütze an      ", { _ in }),
            ("ohne Gates     ", { $0.puddleFillDepth = 10; $0.puddleLakeCoreCells = 1 << 28 }),
            ("ohne Tiefen-Gate", { $0.puddleFillDepth = 10 }),
            ("ohne Kern-Gate ", { $0.puddleLakeCoreCells = 1 << 28 }),
        ]
        for (name, apply) in variants {
            var line = name + "|"
            for dt in [10.0, 240.0, 2000.0] {
                let m = DtInvariance.run(seed: 1337, dt: dt) { c in
                    c.hydraulicPerYear = 0
                    c.meanderEnabled = false; c.braidingEnabled = false
                    c.hillDiffusion = 0; c.waveRelax = 0
                    c.upliftPer100y = 0; c.upliftDecayStartPer100y = 0
                    c.upliftDecayFloorPer100y = 0; c.reliefServoPer100y = 0
                    apply(&c)
                }
                line += String(format: "  dt %5.0f: lake %.4f", dt, m.lakeFraction)
            }
            print(line)
        }
    }

    func testDtSpreadDiagnostic() throws {
        try skipUnlessMeasuring()
        for seed in [UInt32(1337), 4242] {
            for dt in [10.0, 240.0, 2000.0] {
                var c = SimConfig(); c.n = 192; c.world = calibrationWorld
                let t = Terrain(config: c, seed: seed)
                while t.years < 20_000 - 1e-9 { t.step(dtYears: min(dt, 20_000 - t.years)) }
                let stale = t.lakeStats(depth: 0.01).fraction
                let now = DtInvariance.metrics(t)
                let avg = DtInvariance.run(seed: seed, dt: dt)
                print(String(format: "seed %4d dt %6.0f | Ende: ", Int(seed), dt) + now.line
                      + String(format: " (hf veraltet: %.4f)", stale)
                      + " | Mittel: " + avg.line)
            }
        }
    }

    func testLakeTrajectoryDiagnostic() throws {
        try skipUnlessMeasuring()
        for dt in [250.0, 2000.0] {
            var c = SimConfig(); c.n = 192; c.world = calibrationWorld
            let t = Terrain(config: c, seed: 1337)
            print(String(format: "== dt %.0f ==", dt))
            var next = 1000.0
            while t.years < 20_000 - 1e-9 {
                t.step(dtYears: min(dt, 20_000 - t.years))
                guard t.years >= next - 1e-9 else { continue }
                next += 1000
                t.computeFlow()
                let s = t.lakeStats(depth: 0.01)
                print(String(format: "  %6.0f J. | lake %.4f | größter See %5d Zellen",
                             t.years, s.fraction, s.largest))
            }
        }
    }

    func testSplittingScalesWithDropRateDiagnostic() throws {
        try skipUnlessMeasuring()
        for rate in [0.0, 0.2, 2.0] {
            for dt in [10.0, 240.0, 2000.0] {
                let m = DtInvariance.run(seed: 1337, dt: dt) { c in
                    c.hydraulicPerYear = rate
                    c.meanderEnabled = false; c.braidingEnabled = false
                    c.puddleFillYears = 0; c.waveRelax = 0; c.hillDiffusion = 0
                    c.upliftPer100y = 0; c.upliftDecayStartPer100y = 0
                    c.upliftDecayFloorPer100y = 0; c.reliefServoPer100y = 0
                }
                print(String(format: "Tropfen/Jahr %.1f dt %6.0f | lake %.4f",
                             rate, dt, m.lakeFraction))
            }
        }
    }

    func testLakeAblationDiagnostic() throws {
        try skipUnlessMeasuring()
        let variants: [(String, (inout SimConfig) -> Void)] = [
            ("default         ", { _ in }),
            ("ohne Braiding   ", { $0.braidingEnabled = false }),
            ("ohne Mäander    ", { $0.meanderEnabled = false }),
            ("ohne Pfützenfüll", { $0.puddleFillYears = 0 }),
            ("ohne Droplets   ", { $0.hydraulicPerYear = 0 }),
        ]
        for (name, apply) in variants {
            var line = name + "|"
            for dt in [240.0, 2000.0] {
                var c = SimConfig(); c.n = 192; c.world = calibrationWorld; apply(&c)
                let t = Terrain(config: c, seed: 1337)
                while t.years < 20_000 - 1e-9 { t.step(dtYears: min(dt, 20_000 - t.years)) }
                t.computeFlow()
                let s = t.lakeStats(depth: 0.01)
                line += String(format: "  dt %4.0f: lake %.4f max %5d", dt, s.fraction, s.largest)
            }
            print(line)
        }
    }
}
