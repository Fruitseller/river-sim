import XCTest
@testable import SimCore

final class Lithology: XCTestCase {

    private func cfg(n: Int = 192) -> SimConfig {
        var c = SimConfig(); c.n = n; c.world = calibrationWorld
        c.rangeLandform = calibrationRangeLandform
        c.meanderBelt = calibrationMeanderBelt
        c.iceFirnTemp = calibrationIceFirnTemp
        c.deltaTrapFraction = calibrationDeltaTrapFraction

        c.pinIceBeforeAvalanche()
        return c
    }

    private func uniformCfg(n: Int = 192) -> SimConfig {
        var c = cfg(n: n)
        c.lithContrast = 0
        c.lithDiffusionContrast = 0
        return c
    }

    private func macroSlope(_ t: Terrain, _ k: Int) -> Double {
        let n = t.cfg.n
        let i = k % n, j = k / n
        guard i > 1, i < n - 2, j > 1, j < n - 2 else { return 0 }
        return Terrain.macroSlope(t.h, k, n)
    }

    private func slopeBreakSignal(_ t: Terrain,
                                  window: Int = 16) -> (signal: Double, hardCells: Int, softCells: Int) {
        guard t.lithHardness.count == t.cfg.count else { return (1, 0, 0) }
        let n = t.cfg.n
        var nHard = 0, nSoft = 0
        var wsum = 0.0, acc = 0.0
        var j0 = 0
        while j0 < n {
            var i0 = 0
            while i0 < n {
                var sh = 0.0, ss = 0.0, ch = 0, cs = 0
                for j in j0..<min(n, j0 + window) {
                    for i in i0..<min(n, i0 + window) {
                        let k = j * n + i
                        guard t.h[k] > t.cfg.sea, t.hf[k] - t.h[k] < 0.01 else { continue }
                        let hard = t.lithHardness[k]
                        guard abs(hard) > 0.33 else { continue }
                        if hard > 0 { sh += macroSlope(t, k); ch += 1 }
                        else { ss += macroSlope(t, k); cs += 1 }
                    }
                }
                nHard += ch; nSoft += cs
                if ch >= 20 && cs >= 20 {
                    let mh = sh / Double(ch), ms = ss / Double(cs)
                    if mh > 1e-9 && ms > 1e-9 {
                        let w = Double(min(ch, cs))
                        acc += w * log(mh / ms); wsum += w
                    }
                }
                i0 += window
            }
            j0 += window
        }
        guard wsum > 0 else { return (1, nHard, nSoft) }
        return (exp(acc / wsum), nHard, nSoft)
    }

    private func lowering(_ t: Terrain, h0: [Double], hard0: [Double]) -> Double {
        var dHard = 0.0, dSoft = 0.0
        var nHard = 0, nSoft = 0
        for k in 0..<t.cfg.count where h0[k] > t.cfg.sea {
            let d = h0[k] - t.h[k]
            if hard0[k] > 0.33 { dHard += d; nHard += 1 }
            else if hard0[k] < -0.33 { dSoft += d; nSoft += 1 }
        }
        guard nHard > 100, nSoft > 100, dSoft > 0 else { return 1 }
        return (dHard / Double(nHard)) / (dSoft / Double(nSoft))
    }

    private func fractionInBasins(_ t: Terrain) -> Double {
        var wet = 0, land = 0
        for k in 0..<t.cfg.count where t.hf[k] > t.cfg.sea {
            land += 1
            if t.hf[k] - t.h[k] > 0.01 { wet += 1 }
        }
        return land == 0 ? 0 : Double(wet) / Double(land)
    }

    private func run(_ t: Terrain, to years: Double, dt: Double = 500) {
        while t.years < years { t.step(dtYears: dt) }
    }

    func testFieldIsDeterministicPerSeed() {
        let c = cfg(n: 128)
        let a = Terrain(config: c, seed: 1337)
        let b = Terrain(config: c, seed: 1337)
        let other = Terrain(config: c, seed: 7)

        XCTAssertEqual(a.lithHardness.count, c.count, "Gesteinsfeld fehlt")
        XCTAssertEqual(a.lithHardness, b.lithHardness, "gleicher Seed → unterschiedliches Feld")
        XCTAssertEqual(a.lithErodeK, b.lithErodeK, "Erodierbarkeit nicht reproduzierbar")
        XCTAssertNotEqual(a.lithHardness, other.lithHardness, "Feld hängt nicht am Seed")

        let hi = a.lithHardness.max()!, lo = a.lithHardness.min()!
        XCTAssertGreaterThan(hi, 0.6, "kein hartes Gestein im Feld")
        XCTAssertLessThan(lo, -0.6, "kein weiches Gestein im Feld")
        let mean = a.lithHardness.reduce(0, +) / Double(c.count)
        XCTAssertLessThan(abs(mean), 0.15, "Härte im Mittel verschoben (\(mean)) — globale Rate driftet")

        run(a, to: 3000); run(b, to: 3000)
        XCTAssertEqual(a.h, b.h, "Lauf mit Gesteinsfeld nicht bit-identisch reproduzierbar")
        XCTAssertEqual(a.lithHardness, b.lithHardness, "Feld-Fortschreibung nicht deterministisch")
    }

    func testZeroContrastIsBitIdenticalToDisabled() {
        var off = cfg(n: 128); off.lithologyEnabled = false
        let a = Terrain(config: off, seed: 1337)
        let b = Terrain(config: uniformCfg(n: 128), seed: 1337)
        XCTAssertEqual(a.h, b.h, "Nullkontrast weicht schon bei der Generierung ab")
        run(a, to: 3000); run(b, to: 3000)
        XCTAssertEqual(a.h, b.h, "Nullkontrast ist nicht bit-identisch zum Aus-Zustand")
        XCTAssertEqual(a.rock, b.rock, "Fels/Sediment-Bilanz weicht ab")
    }

    func testBothRatesReadTheField() {
        let base = uniformCfg(n: 128)

        var erodeOnly = base; erodeOnly.lithContrast = 0.6
        let ref1 = Terrain(config: base, seed: 1337)
        let ero = Terrain(config: erodeOnly, seed: 1337)
        run(ref1, to: 2000); run(ero, to: 2000)
        XCTAssertNotEqual(ref1.h, ero.h, "Erodierbarkeit liest das Gesteinsfeld nicht")

        var diffOnly = base; diffOnly.lithDiffusionContrast = 0.45
        let ref2 = Terrain(config: base, seed: 1337)
        let dif = Terrain(config: diffOnly, seed: 1337)
        run(ref2, to: 2000); run(dif, to: 2000)
        XCTAssertNotEqual(ref2.h, dif.h, "Hangdiffusivität liest das Gesteinsfeld nicht")
    }

    func testHardnessContrastHoldsSlopeBreak() {
        var onCfg = cfg(); onCfg.meltRunoffEnabled = false; onCfg.iceEnabled = false
        var offCfg = uniformCfg(); offCfg.meltRunoffEnabled = false; offCfg.iceEnabled = false
        let on = Terrain(config: onCfg, seed: 1337)
        let off = Terrain(config: offCfg, seed: 1337)
        let s0On = slopeBreakSignal(on).signal
        let s0Off = slopeBreakSignal(off).signal
        let h0On = on.h, hard0On = on.lithHardness
        let h0Off = off.h, hard0Off = off.lithHardness

        run(on, to: 20_000); run(off, to: 20_000)
        let sOn = slopeBreakSignal(on)
        let sOff = slopeBreakSignal(off)
        print("[#12] Hangknick-Signal n=\(on.cfg.n) Seed 1337 — an: J0 \(s0On) → J20k \(sOn.signal) "
              + "(hart \(sOn.hardCells) / weich \(sOn.softCells) Zellen); "
              + "aus: J0 \(s0Off) → J20k \(sOff.signal)")
        print("[#12] Abtragstiefe hart/weich über 20k — an: \(lowering(on, h0: h0On, hard0: hard0On)), "
              + "aus: \(lowering(off, h0: h0Off, hard0: hard0Off))")

        XCTAssertGreaterThan(sOn.signal, 1.10,
            "kein Hangknick nach 20k Jahren (Signal \(sOn.signal)) — Härtekontrast wirkungslos")
        XCTAssertGreaterThan(sOn.signal, sOff.signal + 0.06,
            "Signal steckt im Referenzarm (an \(sOn.signal) gegen aus \(sOff.signal))")
        XCTAssertLessThan(abs(sOff.signal - 1), 0.08,
            "Referenzarm zeigt selbst ein Signal (\(sOff.signal)) — die Kennzahl misst nicht die Wirkung")
    }

    func testSlopeBreakSurvivesMeltRunoff() {
        let on = Terrain(config: cfg(), seed: 1337)
        let off = Terrain(config: uniformCfg(), seed: 1337)
        XCTAssertTrue(on.cfg.meltRunoffEnabled, "Testaufbau: Schmelzwasser ist aus")
        XCTAssertTrue(on.cfg.iceEnabled, "Testaufbau: der Gletscher-Pass ist aus")
        run(on, to: 20_000); run(off, to: 20_000)
        let sOn = slopeBreakSignal(on).signal, sOff = slopeBreakSignal(off).signal
        let glaciated = on.underIce.isEmpty ? 0 : on.underIce.filter { $0 }.count
        print("[#12] Hangknick-Signal MIT Schmelze (#36) UND Eis (#35) — an: \(sOn), "
              + "aus: \(sOff), vergletscherte Zellen: \(glaciated)")
        XCTAssertGreaterThan(glaciated, 100,
            "Testaufbau: nur \(glaciated) vergletscherte Zellen — die Gegenprobe prüft kein Eis")
        XCTAssertGreaterThan(sOn, 1.10,
            "kein Hangknick unter Produktionsphysik (Signal \(sOn))")
        XCTAssertGreaterThan(sOn, sOff + 0.06,
            "Signal steckt im Referenzarm (an \(sOn) gegen aus \(sOff))")
    }

    func testDiffusionContrastEffectIsMeasured() {
        var noDiff = cfg(); noDiff.lithDiffusionContrast = 0
        let full = Terrain(config: cfg(), seed: 1337)
        let flat = Terrain(config: noDiff, seed: 1337)
        run(full, to: 20_000); run(flat, to: 20_000)
        let sFull = slopeBreakSignal(full).signal, sFlat = slopeBreakSignal(flat).signal
        print("[#12] Hangknick-Signal 20k — lithDiffusionContrast 0.45: \(sFull), 0: \(sFlat)")
        XCTAssertNotEqual(full.h, flat.h, "Diffusions-Kopplung ist wirkungslos verdrahtet")
        XCTAssertGreaterThan(sFull, 1.10, "Hangknick fehlt mit Diffusions-Kontrast (\(sFull))")
        XCTAssertGreaterThan(sFlat, 1.10,
            "Hangknick hängt doch am Diffusions-Kontrast (\(sFlat)) — Doku anpassen")
    }

    func testSoftestRockDoesNotFlatten() {
        var c = SimConfig(); c.n = 160; c.world = calibrationWorld; c.lithHardBias = -1
        let t = Terrain(config: c, seed: 1337)
        let maxH0 = t.maxHeight()
        let relief0 = t.landRelief()
        run(t, to: 100_000)
        print("[#12] weichstes Gestein n=160 Seed 1337 100k — Relief \(relief0) → \(t.landRelief()), "
              + "maxH \(maxH0) → \(t.maxHeight()), See-Anteil \(fractionInBasins(t)), "
              + "reliefRobust \(t.landReliefRobust())")
        XCTAssertLessThan(t.maxHeight(), maxH0 + 0.02,
            "Berge wachsen im weichsten Gestein (\(maxH0) → \(t.maxHeight()))")
        XCTAssertGreaterThan(t.landRelief(), 0.30,
            "weichstes Gestein ebnet ein (\(relief0) → \(t.landRelief()))")
        XCTAssertLessThan(fractionInBasins(t), 0.30,
            "See-Anteil wuchert im weichsten Gestein (\(fractionInBasins(t)))")
    }

    func testEndorheicMechanicsSurviveLithology() {
        var c = SimConfig(); c.n = 256; c.world = calibrationWorld; c.endorheicEvapRatio = 6
        c.rangeLandform = calibrationRangeLandform
        c.pinIceBeforeAvalanche()
        c.meanderBeltSillCutDepths = calibrationMeanderBeltSillCutDepths
        var ref = c; ref.lithologyEnabled = false

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
            print("[#12] Lithologie × #11 Seed \(seed) — an: Kruste>0.5 \(on.bed) / >0.9 \(on.crusted) "
                  + "/ Becken \(on.basins); aus: \(off.bed) / \(off.crusted) / \(off.basins)")
            if on.bed > 100 && on.crusted > 20 { playaOn += 1 }
            if off.bed > 100 && off.crusted > 20 { playaOff += 1 }
        }
        XCTAssertGreaterThan(playaOn, 0,
            "mit Lithologie entsteht auf keinem Seed mehr eine Salzpfanne — #11 wäre kaputt")
        XCTAssertGreaterThanOrEqual(playaOn, playaOff,
            "Lithologie kostet Salzpfannen-Seeds (an \(playaOn) gegen aus \(playaOff))")

        func levelWalk(tau: Double) -> (jump: Double, span: Double) {
            var rc = c; rc.endorheicResponseYears = tau
            let t = Terrain(config: rc, seed: 1337)
            var cells: [Int] = []
            for k in 0..<t.cfg.count where t.endorheicBasin[k] != .none { cells.append(k) }
            guard cells.count > 200 else { return (0, 1) }
            let inv = 1.0 / Double(cells.count)
            func mean() -> Double { cells.reduce(0.0) { $0 + t.hf[$1] * inv } }
            var prev = mean(), jump = 0.0, lo = prev, hi = prev
            for _ in 0..<200 {
                t.step(dtYears: 20)
                let m = mean()
                jump = max(jump, abs(m - prev))
                lo = min(lo, m); hi = max(hi, m); prev = m
            }
            return (jump, max(1e-9, hi - lo))
        }
        let limited = levelWalk(tau: 500)
        print(String(format: "[#12] Lithologie × #11 Ratenbegrenzung Seed 1337 — τ=500 "
                     + "max Sprung %.5f / Spanne %.5f = %.3f",
                     limited.jump, limited.span, limited.jump / limited.span))
        XCTAssertLessThan(limited.jump, 0.6 * limited.span,
            "Beckenspiegel springt mit Gesteinsfeld sichtbar "
            + "(\(limited.jump) gegen Spanne \(limited.span))")
    }

    func testHardestRockDoesNotRunAway() {
        var c = SimConfig(); c.n = 160; c.world = calibrationWorld; c.lithHardBias = 1
        let t = Terrain(config: c, seed: 1337)
        let maxH0 = t.maxHeight()
        run(t, to: 100_000)
        print("[#12] härtestes Gestein n=160 Seed 1337 100k — Relief \(t.landRelief()), "
              + "maxH \(maxH0) → \(t.maxHeight()), See-Anteil \(fractionInBasins(t))")
        XCTAssertLessThan(t.maxHeight(), maxH0 + 0.02,
            "Berge wachsen im härtesten Gestein (\(maxH0) → \(t.maxHeight()))")
        XCTAssertLessThan(fractionInBasins(t), 0.30,
            "See-Anteil wuchert im härtesten Gestein (\(fractionInBasins(t)))")
    }
}
