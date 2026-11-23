import XCTest
@testable import SimCore

final class ClimateSnow: XCTestCase {

    private func cfg(n: Int = 192) -> SimConfig {
        var c = SimConfig(); c.n = n; c.world = calibrationWorld
        c.rangeLandform = calibrationRangeLandform
        c.meanderBelt = calibrationMeanderBelt
        return c
    }

    private func fractions(_ t: Terrain) -> (visible: Double, ramp: Double, full: Double) {
        let c = t.cfg
        var land = 0, vis = 0, ramp = 0, full = 0
        for k in 0..<c.count where t.h[k] > c.sea {
            land += 1
            let cov = t.snowCover(k)
            if cov > 0.05 { vis += 1 }
            if cov > c.snowBandCoverStart { ramp += 1 }
            if cov >= c.snowBandCoverFull { full += 1 }
        }
        guard land > 0 else { return (0, 0, 0) }
        return (Double(vis) / Double(land), Double(ramp) / Double(land),
                Double(full) / Double(land))
    }

    private func run(_ t: Terrain, to years: Double, dt: Double = 500) {
        while t.years < years { t.step(dtYears: dt) }
    }

    func testMeltRateSweepDiagnostic() throws {
        try skipUnlessMeasuring()
        for c in [0.02, 0.06, 0.20] {
            var conf = cfg()
            conf.snowMeltPerKYear = c
            let t = Terrain(config: conf, seed: 1337)
            let f0 = fractions(t)
            let b0 = t.heightBands
            run(t, to: 20_000)
            let f1 = fractions(t)
            let b1 = t.heightBands
            print(String(format: "[#33] c=%.2f Saumbreite %.4f Einheiten | "
                         + "J0 sichtbar %.4f Rampe %.4f voll %.4f snowStart %.4f | "
                         + "J20k sichtbar %.4f Rampe %.4f voll %.4f snowStart %.4f maxH %.4f",
                         c, 18 / (c * conf.snowTurnoverYears * conf.climateLapseRate),
                         f0.visible, f0.ramp, f0.full, b0.snowStart,
                         f1.visible, f1.ramp, f1.full, b1.snowStart, t.maxHeight()))
        }
    }

    func testProductionResolutionDiagnostic() throws {
        try skipUnlessMeasuring()
        var c = SimConfig(); c.n = 832; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        for label in ["J0", "J10k", "J30k"] {
            if label != "J0" { run(t, to: label == "J10k" ? 10_000 : 30_000) }
            let f = fractions(t)
            let b = t.heightBands
            let land = (0..<c.count).filter { t.h[$0] > c.sea }
            let tMin = land.map { t.temperature[$0] }.min() ?? 0
            let sMax = land.map { t.snow[$0] }.max() ?? 0
            print(String(format: "[#33] n=832 %@ sichtbar %.4f Rampe %.4f voll %.4f | "
                         + "snowStart %.4f snowFull %.4f | maxH %.4f Tmin %.2f°C Smax %.3f",
                         label, f.visible, f.ramp, f.full, b.snowStart, b.snowFull,
                         t.maxHeight(), tMin, sMax))
        }
    }

    func testClimatePassCostDiagnostic() throws {
        try skipUnlessMeasuring()
        var c = SimConfig(); c.n = 832; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        let rounds = 200
        var clock = Date()
        for _ in 0..<rounds { t.updateClimate(dt: 100) }
        let climateMs = -clock.timeIntervalSinceNow * 1000 / Double(rounds)
        clock = Date()
        for _ in 0..<rounds { t.updateHeightBands() }
        let bandsMs = -clock.timeIntervalSinceNow * 1000 / Double(rounds)
        print(String(format: "[#33] n=832 je Schritt: updateClimate %.2f ms · "
                     + "updateHeightBands (inkl. Schnee-Zählpass) %.2f ms",
                     climateMs, bandsMs))
    }

    func testSnowBalanceIsDtInvariant() {
        let c = cfg(n: 128)
        let a = Terrain(config: c, seed: 1337)
        let b = Terrain(config: c, seed: 1337)
        XCTAssertEqual(a.snow, b.snow, "Testaufbau: Startzustände weichen ab")
        XCTAssertTrue(a.snow.contains { $0 > 0.01 }, "Testaufbau: keine Schneedecke")

        a.updateClimate(dt: 4000)
        for _ in 0..<400 { b.updateClimate(dt: 10) }

        var worst = 0.0
        for k in 0..<c.count { worst = max(worst, abs(a.snow[k] - b.snow[k])) }
        print(String(format: "[#33] dt-Invarianz Bilanz: größte Abweichung %.3e "
                     + "(Smax %.4f)", worst, a.snow.max() ?? 0))
        XCTAssertLessThan(worst, 1e-12,
            "Schneebilanz ist nicht dt-invariant (Abweichung \(worst))")
        XCTAssertEqual(a.temperature, b.temperature)
    }

    func testSnowThroughFullStepsIsDtInvariant() {
        var conf = cfg(n: 192)
        conf.upliftDecayFloorPer100y = 0
        conf.reliefServoPer100y = 0
        var arms: [(dt: Double, mean: Double, frac: Double, start: Double)] = []
        for dt in [50.0, 500.0, 2000.0] {
            let t = Terrain(config: conf, seed: 1337)
            run(t, to: 20_000, dt: dt)
            var sum = 0.0
            var land = 0
            for k in 0..<conf.count where t.h[k] > conf.sea { sum += t.snow[k]; land += 1 }
            arms.append((dt, sum / Double(max(1, land)), fractions(t).ramp,
                         t.heightBands.snowStart))
        }
        for a in arms {
            print(String(format: "[#33] dt %6.0f: mittlerer Vorrat %.5f · Rampe %.4f "
                         + "· snowStart %.4f", a.dt, a.mean, a.frac, a.start))
        }
        for a in arms {
            for b in arms where b.dt > a.dt {
                let tag = "dt \(Int(a.dt)) vs \(Int(b.dt))"
                let devMean = abs(a.mean - b.mean) / max(abs(a.mean), abs(b.mean))
                let devFrac = abs(a.frac - b.frac) / max(abs(a.frac), abs(b.frac))
                XCTAssertLessThan(devMean, 0.30, "\(tag): Vorrat \(a.mean) vs \(b.mean)")
                XCTAssertLessThan(devFrac, 0.30, "\(tag): Rampe \(a.frac) vs \(b.frac)")
                XCTAssertEqual(a.start, b.start, accuracy: 0.01,
                               "\(tag): snowStart \(a.start) vs \(b.start)")
            }
        }
    }

    func testZeroStepLeavesTheBalanceUntouched() {
        let t = Terrain(config: cfg(n: 96), seed: 7)
        let before = t.snow
        t.updateClimate(dt: 0)
        XCTAssertEqual(before, t.snow, "dt = 0 hat die Schneebilanz verändert")
    }

    func testSnowBalanceIsDeterministic() {
        let c = cfg(n: 128)
        let a = Terrain(config: c, seed: 99)
        let b = Terrain(config: c, seed: 99)
        run(a, to: 3000); run(b, to: 3000)
        for k in 0..<c.count {
            XCTAssertEqual(a.snow[k].bitPattern, b.snow[k].bitPattern, "snow[\(k)]")
            XCTAssertEqual(a.temperature[k].bitPattern, b.temperature[k].bitPattern,
                           "temperature[\(k)]")
        }
    }

    func testTemperatureFollowsTheCalibratedLapseRate() {
        let c = cfg(n: 96)
        let t = Terrain(config: c, seed: 1337)
        for k in 0..<c.count {
            XCTAssertEqual(t.temperature[k], c.expectedTemperature(at: t.h[k]),
                           accuracy: 1e-12, "Zelle \(k)")
        }
        let deep = (0..<c.count).first { t.h[$0] < c.sea - 0.05 }
        XCTAssertNotNil(deep, "Testaufbau: keine tiefe Meereszelle")
        XCTAssertEqual(t.temperature[deep!], c.climateSeaLevelTemp, accuracy: 1e-12)
        XCTAssertEqual(c.sea + c.climateSeaLevelTemp / c.climateLapseRate, 0.5730,
                       accuracy: 1e-4)
    }

    func testSnowSitsOnTheColdEnd() {
        let c = cfg()
        let t = Terrain(config: c, seed: 1337)
        var warmest = -Double.greatestFiniteMagnitude, coldest = Double.greatestFiniteMagnitude
        var snowWarm = 0.0, snowCold = 0.0
        for k in 0..<c.count where t.h[k] > c.sea {
            if t.temperature[k] > warmest { warmest = t.temperature[k]; snowWarm = t.snow[k] }
            if t.temperature[k] < coldest { coldest = t.temperature[k]; snowCold = t.snow[k] }
        }
        XCTAssertGreaterThan(coldest, -1e9, "Testaufbau: kein Land")
        XCTAssertLessThan(snowWarm, 1e-6, "die wärmste Landzelle trägt Schnee")
        XCTAssertGreaterThan(snowCold, 0.05, "die kälteste Landzelle trägt keinen Schnee")
    }

    func testAccumulationCarriesTheOrographicSignal() {
        let c = cfg(n: 256)
        let t = Terrain(config: c, seed: 1337)
        XCTAssertEqual(t.rainWeight.count, c.count, "Testaufbau: kein Regen-Gewicht")
        let lo = c.sea + (c.climateSeaLevelTemp - 1.0) / c.climateLapseRate
        let binWidth = 0.005, bins = 12
        var acc = 0.0, wsum = 0.0, pairs = 0
        for b in 0..<bins {
            let a0 = lo + Double(b) * binWidth, a1 = a0 + binWidth
            var wet = 0.0, dry = 0.0
            var nWet = 0, nDry = 0
            for k in 0..<c.count where t.h[k] >= a0 && t.h[k] < a1 {
                if t.rainWeight[k] > 1.1 { wet += t.snow[k]; nWet += 1 }
                if t.rainWeight[k] < 0.9 { dry += t.snow[k]; nDry += 1 }
            }
            guard nWet >= 10, nDry >= 10 else { continue }
            let mWet = wet / Double(nWet), mDry = dry / Double(nDry)
            guard mWet > 1e-9, mDry > 1e-9 else { continue }
            let w = Double(min(nWet, nDry))
            acc += w * log(mWet / mDry); wsum += w
            pairs += 1
        }
        XCTAssertGreaterThanOrEqual(pairs, 4, "Testaufbau: zu wenige gepaarte Höhen-Bins")
        let signal = exp(acc / wsum)
        print(String(format: "[#33] Luv/Lee-Signal im Band %.3f…%.3f: %.3f (%d Bins)",
                     lo, lo + Double(bins) * binWidth, signal, pairs))
        XCTAssertGreaterThan(signal, 1.15,
            "die Akkumulation trägt kein Orographie-Signal (Verhältnis \(signal))")
    }

    func testDisabledClimateIsBitIdenticalPhysics() {
        var off = cfg(n: 128)
        off.climateEnabled = false; off.meltRunoffEnabled = false; off.iceEnabled = false
        var on = cfg(n: 128); on.meltRunoffEnabled = false; on.iceEnabled = false
        let a = Terrain(config: off, seed: 1337)
        let b = Terrain(config: on, seed: 1337)
        XCTAssertTrue(a.temperature.isEmpty && a.snow.isEmpty && a.ice.isEmpty,
                      "abgeschaltet sind die Kryo-Felder nicht leer")
        XCTAssertFalse(b.snow.isEmpty, "eingeschaltet ist das Schneefeld leer")

        for label in ["Generierung", "3000 Jahre"] {
            if label != "Generierung" { run(a, to: 3000); run(b, to: 3000) }
            XCTAssertEqual(a.h, b.h, "h weicht ab (\(label))")
            XCTAssertEqual(a.rock, b.rock, "rock weicht ab (\(label))")
            XCTAssertEqual(a.sed, b.sed, "sed weicht ab (\(label))")
            XCTAssertEqual(a.veg, b.veg, "veg weicht ab (\(label))")
            XCTAssertEqual(a.vegClass, b.vegClass, "vegClass weicht ab (\(label))")
            XCTAssertEqual(a.hf, b.hf, "hf weicht ab (\(label))")
            XCTAssertEqual(a.area, b.area, "area weicht ab (\(label))")
            XCTAssertEqual(a.streamMap, b.streamMap, "streamMap weicht ab (\(label))")
        }
        XCTAssertEqual(a.heightBands.vegFull, b.heightBands.vegFull)
        XCTAssertEqual(a.heightBands.vegRamp, b.heightBands.vegRamp)
        XCTAssertEqual(a.heightBands.rockStart, b.heightBands.rockStart)
        XCTAssertEqual(a.heightBands.rockFull, b.heightBands.rockFull)
        XCTAssertEqual(a.heightBands.coniferLow, b.heightBands.coniferLow)
        XCTAssertEqual(a.heightBands.coniferHigh, b.heightBands.coniferHigh)
    }

    func testDisabledClimateFallsBackToThePercentileBands() {
        var off = cfg(n: 128); off.climateEnabled = false
        let t = Terrain(config: off, seed: 1337)
        let reference = HeightBands.fromLandHeights(t.h, cfg: off)
        XCTAssertEqual(t.heightBands, reference,
                       "ohne Klima kommen die Bänder nicht mehr aus den Perzentilen")
        var checked = 0
        for k in 0..<off.count where t.h[k] > off.sea {
            XCTAssertEqual(t.snowCover(k), t.heightBands.snowAmount(t.h[k]),
                           "snowCover fällt nicht auf das Höhenband zurück")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 100, "Testaufbau: kein Land geprüft")
    }

    func testSnowCoverIsTheSingleSourceForColouring() {
        let c = cfg(n: 96)
        let t = Terrain(config: c, seed: 1337)
        for k in 0..<c.count {
            let expected = t.snow[k] / (t.snow[k] + c.snowCoverRef)
            XCTAssertEqual(Terrain.snowCoverage(swe: t.snow[k], ref: c.snowCoverRef),
                           expected, accuracy: 0, "Formel, Zelle \(k)")
            XCTAssertEqual(t.snowCover(k), expected, accuracy: 0, "Feldzugriff, Zelle \(k)")
        }
    }
}

private extension SimConfig {
    func expectedTemperature(at height: Double) -> Double {
        climateSeaLevelTemp - climateLapseRate * max(0, height - sea)
    }
}
