import XCTest
@testable import SimCore

/// Wächter + Messreihe zum **Gesteinsfeld** (Issue #12): räumlich variable
/// Erodierbarkeit und Hangdiffusivität aus einem deterministischen, seed-
/// abhängigen Lithologie-Feld (`Terrain.buildLithologyField` /
/// `Terrain.updateLithology`, Kalibrier-Logbuch bei `SimConfig.lithologyEnabled`).
///
/// Die Abnahmekriterien des Tickets und ihre Wächter hier:
/// 1. deterministisch je Seed → `testFieldIsDeterministicPerSeed`
/// 2. Erodierbarkeit UND Diffusivität lesen daraus → `testBothRatesReadTheField`
/// 3. Härtekontrast hält einen Hangknick ≥ 20k Jahre →
///    `testHardnessContrastHoldsSlopeBreak` (+ `testDiffusionContrastEffectIsMeasured`)
/// 4. kein Einebnen/Runaway, auch im weichsten Gestein →
///    `testSoftestRockDoesNotFlatten`
final class Lithology: XCTestCase {

    /// Produktionsphysik in Testauflösung (die reinen Performance-Schalter der
    /// Produktion sind verhaltensneutral, s. AGENTS.md).
    private func cfg(n: Int = 192) -> SimConfig {
        var c = SimConfig(); c.n = n; return c
    }

    /// REFERENZARM: das Feld wird gerechnet, wirkt aber auf keine Rate. Damit
    /// partitionieren beide Arme dieselben Zellen nach derselben Härte — der
    /// Unterschied kann nur aus der Wirkung kommen, nicht aus der Auswahl.
    private func uniformCfg(n: Int = 192) -> SimConfig {
        var c = cfg(n: n)
        c.lithContrast = 0
        c.lithDiffusionContrast = 0
        return c
    }

    // MARK: - Kennzahlen

    /// Makro-Steigung (±2 Zellen, wie Regen/Vegetation/Biom-Farbe sie lesen —
    /// die Per-Zell-Steigung wäre nach der Pre-Erosion überall „steil").
    private func macroSlope(_ t: Terrain, _ k: Int) -> Double {
        let n = t.cfg.n
        let i = k % n, j = k / n
        guard i > 1, i < n - 2, j > 1, j < n - 2 else { return 0 }
        return (abs(t.h[k + 2] - t.h[k - 2]) + abs(t.h[k + 2 * n] - t.h[k - 2 * n])) * 0.125
    }

    /// **Hangknick-Signal**: mittlere Makro-Steigung auf HARTEN gegen WEICHE
    /// Zellen — die geomorphologische Signatur eines lithologischen Knickpunkts
    /// (im Fließgleichgewicht S ∝ (U/K)^(1/n): hartes Gestein trägt die steile
    /// Stufe, weiches die flache Rampe). 1.0 = kein Zusammenhang.
    ///
    /// **Lokal gepaart** (Fenster von `window`² Zellen, Verhältnis je Fenster,
    /// gepoolt mit min(hart, weich) als Gewicht). Die Paarung ist nicht Kosmetik,
    /// sondern der Kern der Kennzahl: global gemittelt ist sie konfundiert und
    /// zeigt auch im REFERENZARM ein Signal (gemessen n=192, Seed 1337, 20k J.:
    /// 1.16 statt 1.00; die mittlere Abtragstiefe der „harten" gegen die
    /// „weichen" Zellen liegt dort sogar bei 5.4). Ursache ist die
    /// Provinz-Komponente: sie klumpt die Härteklassen räumlich, und die
    /// Erosionsrate der Insel schwankt zwischen Küste, Luv und Lee um mehr als
    /// den Härtekontrast. Innerhalb eines 16×16-Fensters sind Lage, Klima und
    /// Höhenband praktisch konstant, und über hart/weich entscheidet die Lage der
    /// Schichtebene (Fallen + Faltung) — genau der Kontakt, an dem ein
    /// lithologischer Hangknick sitzt.
    ///
    /// Gepoolt wird als GEOMETRISCHES Mittel der Fenster-Verhältnisse (Mittel der
    /// Logarithmen): das arithmetische Mittel von Quotienten ist nach oben
    /// verzerrt, wenn der Nenner klein werden kann (Fenster, in denen eine flache
    /// Ebene komplett in die weiche Klasse fällt) — gemessen hob das den
    /// Referenzarm allein durch diese Verzerrung auf 1.12. Das Log-Mittel ist
    /// symmetrisch: hart/weich getauscht liefert exakt den Kehrwert, reines
    /// Rauschen also 1.0.
    ///
    /// Gezählt wird nur trockenes Land (Seeböden haben per Konstruktion Steigung
    /// ≈ 0) und nur der Härte-Kern (|hard| > 0.33), damit die Kontaktzonen
    /// dazwischen das Signal nicht verwässern.
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

    /// Zweite, unabhängige Lesart derselben Physik: mittlere ABTRAGSTIEFE
    /// (h₀ − h) auf Zellen, die bei t₀ hart bzw. weich waren. < 1 heißt: das
    /// harte Gestein wurde weniger abgetragen. Diagnose-Kennzahl für die
    /// Messreihe (der Wächter hängt am Hangknick-Signal).
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

    // MARK: - Abnahme 1: Determinismus

    /// Gleicher Seed → gleiches Feld, anderer Seed → anderes Feld. Und: der
    /// gesamte Zeitschritt bleibt mit dem Feld bit-identisch reproduzierbar (die
    /// Ableitung läuft datenparallel über disjunkte Indexbereiche, s. AGENTS.md
    /// „Determinismus ist eine getestete Invariante").
    func testFieldIsDeterministicPerSeed() {
        let c = cfg(n: 128)
        let a = Terrain(config: c, seed: 1337)
        let b = Terrain(config: c, seed: 1337)
        let other = Terrain(config: c, seed: 7)

        XCTAssertEqual(a.lithHardness.count, c.count, "Gesteinsfeld fehlt")
        XCTAssertEqual(a.lithHardness, b.lithHardness, "gleicher Seed → unterschiedliches Feld")
        XCTAssertEqual(a.lithErodeK, b.lithErodeK, "Erodierbarkeit nicht reproduzierbar")
        XCTAssertNotEqual(a.lithHardness, other.lithHardness, "Feld hängt nicht am Seed")

        // Das Feld nutzt seine Spanne wirklich aus (sonst wäre alles ein
        // Einheitsgestein mit ±ε und die Wirkung wäre nicht messbar).
        let hi = a.lithHardness.max()!, lo = a.lithHardness.min()!
        XCTAssertGreaterThan(hi, 0.6, "kein hartes Gestein im Feld")
        XCTAssertLessThan(lo, -0.6, "kein weiches Gestein im Feld")
        // Mittelwert nahe 0 → K hat Mittel ≈ 1, die globale Rate bleibt kalibriert.
        let mean = a.lithHardness.reduce(0, +) / Double(c.count)
        XCTAssertLessThan(abs(mean), 0.15, "Härte im Mittel verschoben (\(mean)) — globale Rate driftet")

        run(a, to: 3000); run(b, to: 3000)
        XCTAssertEqual(a.h, b.h, "Lauf mit Gesteinsfeld nicht bit-identisch reproduzierbar")
        XCTAssertEqual(a.lithHardness, b.lithHardness, "Feld-Fortschreibung nicht deterministisch")
    }

    /// `lithContrast = 0` (Feld gerechnet, wirkungslos) muss BIT-IDENTISCH zum
    /// abgeschalteten Feature sein. Das ist die Grundlage aller A/B-Messungen:
    /// der Referenzarm darf sich nur durch die WIRKUNG unterscheiden, nicht durch
    /// eine veränderte Arithmetik (dieselbe Doktrin wie
    /// `RainWeightedFlow.testUniformRainWeightIsBitIdentical`).
    func testZeroContrastIsBitIdenticalToDisabled() {
        var off = cfg(n: 128); off.lithologyEnabled = false
        let a = Terrain(config: off, seed: 1337)
        let b = Terrain(config: uniformCfg(n: 128), seed: 1337)
        XCTAssertEqual(a.h, b.h, "Nullkontrast weicht schon bei der Generierung ab")
        run(a, to: 3000); run(b, to: 3000)
        XCTAssertEqual(a.h, b.h, "Nullkontrast ist nicht bit-identisch zum Aus-Zustand")
        XCTAssertEqual(a.rock, b.rock, "Fels/Sediment-Bilanz weicht ab")
    }

    // MARK: - Abnahme 2: beide Raten lesen das Feld

    /// Getrennter Nachweis für BEIDE Kopplungen: nur `lithContrast` verändert
    /// (Diffusion neutral) muss die Landschaft verschieben, und nur
    /// `lithDiffusionContrast` verändert (Erodierbarkeit neutral) ebenfalls.
    /// Damit hängt kein Kriterium an der Summe der beiden Wege.
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

    // MARK: - Abnahme 3: der Hangknick hält 20.000 Jahre

    /// Ein Härtekontrast baut einen Hangknick auf und HÄLT ihn über 20.000 Jahre,
    /// statt wegerodiert oder wegdiffundiert zu werden: die harten Bänke tragen
    /// messbar steilere Hänge als die weichen (Kennzahl `slopeBreakSignal`).
    ///
    /// Gegen den Referenzarm (Feld gerechnet, wirkungslos) gemessen — dort
    /// partitioniert dieselbe Härte dieselben Zellen und das Verhältnis bleibt
    /// bei 1: das Signal kommt also aus der WIRKUNG des Gesteins, nicht aus einer
    /// Korrelation zwischen Härtefeld und Topografie.
    func testHardnessContrastHoldsSlopeBreak() {
        let on = Terrain(config: cfg(), seed: 1337)
        let off = Terrain(config: uniformCfg(), seed: 1337)
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

    /// Was der DIFFUSIONS-Kontrast zum Hangknick beiträgt — gemessen, nicht
    /// behauptet: **nichts Messbares.** Der Knick kommt aus der fluvialen Rate;
    /// mit `lithDiffusionContrast = 0` ist das Signal bei 20k praktisch gleich
    /// (Zahlen im Log, s. docs/lithology-measurements.md §C). Die Kopplung bleibt
    /// trotzdem drin — sie ist Abnahmekriterium 2 des Tickets und physikalisch
    /// Standard (härteres Gestein liefert weniger Regolith, kriecht also weniger);
    /// dieser Wächter hält nur fest, dass der Knick NICHT an ihr hängt, damit
    /// niemand die Behauptung nachträglich in die Doku schreibt.
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

    // MARK: - Abnahme 4: kein Einebnen, auch im weichsten Gestein

    /// Derselbe Langlauf wie `LongRunCollapse`, aber mit `lithHardBias = −1`: die
    /// Härte ist damit auf der GANZEN Karte in die weiche Hälfte verschoben. Genau
    /// gerechnet: `hard` = Schichtwelle + Provinz − 1, geklemmt → `hard ∈ [−1, 0]`,
    /// also **K ≥ 1.0 überall** (bis 1.6 an den weichsten Stellen) und
    /// Diffusivität ≥ 1.0 (bis 1.45). Es gibt in diesem Arm also kein Gestein
    /// mehr, das langsamer erodiert als das Referenzgestein — der Härtekontrast
    /// bleibt, aber nur noch nach unten. Relief darf nicht einebnen, die Berge
    /// nicht wachsen, der See-Anteil nicht wuchern.
    func testSoftestRockDoesNotFlatten() {
        var c = SimConfig(); c.n = 160; c.lithHardBias = -1
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

    // MARK: - Rückwirkung auf bestehende Physik

    /// Die #11-Wächter (`EndorheicEvaporation`) pinnen das Gesteinsfeld AUS, weil
    /// sie die Mechanik an EINEM konkreten Becken prüfen und die Lithologie
    /// mitentscheidet, welches Becken das größte ist. Damit dieses Auspinnen keine
    /// echte Regression verdeckt, prüft dieser Wächter die #11-MECHANIK genau
    /// umgekehrt: **mit** Lithologie, über mehrere Seeds.
    ///
    /// Geprüft wird (a) es entstehen weiterhin Salzpfannen (trockengefallener
    /// Beckenboden mit Kruste) und (b) der Bilanz-Spiegel bleibt ratenbegrenzt —
    /// der ratenbegrenzte Arm springt weniger als der instantane. Die absolute
    /// Sprung-Schwelle (0.002) bleibt bewusst dem #11-Wächter auf uniformem
    /// Gestein: sie ist eine Eigenschaft des dort fixierten Beckens.
    func testEndorheicMechanicsSurviveLithology() {
        var c = SimConfig(); c.n = 256; c.endorheicEvapRatio = 6   // dryCfg von #11, Lithologie AN
        var ref = c; ref.lithologyEnabled = false                  // derselbe Arm wie der #11-Wächter

        /// Salzpfannen-Bilanz eines Seeds: (Krustenzellen > 0.5, > 0.9, Becken).
        func playa(_ config: SimConfig, _ seed: UInt32) -> (bed: Int, crusted: Int, basins: Int) {
            let t = Terrain(config: config, seed: seed)
            for _ in 0..<10 { t.step(dtYears: 200) }
            var bed = 0, crusted = 0
            for k in 0..<t.cfg.count where t.endorheicBasin[k] == 1 {
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

        // Ratenbegrenzung, gemessen wie in #11 (dort ist das Gesteinsfeld
        // ausgepinnt — deshalb steht die Messung hier überhaupt): der
        // Bilanz-Spiegel darf auch MIT Gestein nicht springen, sein größter
        // Einzelsprung bleibt also klar unter der Spanne, die er insgesamt
        // durchwandert.
        //
        // Der frühere Vergleich „ratenbegrenzt springt weniger als instantan"
        // ist GESTRICHEN, weil er nachweislich nicht die Ratenbegrenzung misst
        // (Issue #2, docs/dt-invariance-measurements.md §6):
        //   * Verglichen wurde der größte Einzelsprung ZWEIER UNABHÄNGIGER
        //     Läufe. Der kommt in beiden Armen von einem diskreten
        //     Gelände-Ereignis (eine Sill bricht, der Priority-Flood pegelt das
        //     Becken um; die flache Becken-Hypsometrie bewegt dabei hunderte
        //     Zellen Wasserfläche). Welcher Arm das größere Ereignis erwischt,
        //     ist Realisierungs-Glück — der Vergleich kippte in diesem Branch
        //     unter VIER voneinander unabhängigen, je einzeln verifizierten
        //     Änderungen.
        //   * Auf der Mechanik-Ebene ist die Erwartung sogar umgekehrt: über
        //     RUHIGE Schritte (Wasserfläche nahezu unverändert) bewegt sich der
        //     ratenbegrenzte Arm MEHR als der instantane — er relaxiert
        //     dauernd einem wandernden Ziel hinterher, während der Snap-Arm
        //     nach seinem Sprung stillsteht. Gemessen auf BEIDEN Ständen:
        //     `main` 0.00132 gegen 0.00056, dieser Branch 0.00046 gegen
        //     0.00027 (Mittel 0.000070/0.000041 bzw. 0.000094/0.000043).
        // Die Ratenbegrenzung selbst hat ihre eigenen, gepinnten Wächter in
        // `EndorheicEvaporation` (`testBasinLevelIsRateLimited`,
        // `testBalanceLevelIsFramerateIndependent`).
        func levelWalk(tau: Double) -> (jump: Double, span: Double) {
            var rc = c; rc.endorheicResponseYears = tau
            let t = Terrain(config: rc, seed: 1337)
            var cells: [Int] = []
            for k in 0..<t.cfg.count where t.endorheicBasin[k] != 0 { cells.append(k) }
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
        // Schranke aus der Messung beider Stände: `main` 0.00325/0.01577 = 0.206,
        // dieser Branch 0.01221/0.02574 = 0.474 — der Absolutwert hängt daran,
        // ob in den 200 Schritten eine Sill bricht. 0.6 fängt weiterhin ab, dass
        // der Spiegel seine Spanne in einem Schritt durchläuft (das wäre ~1.0).
        XCTAssertLessThan(limited.jump, 0.6 * limited.span,
            "Beckenspiegel springt mit Gesteinsfeld sichtbar "
            + "(\(limited.jump) gegen Spanne \(limited.span))")
    }

    /// Gegenprobe zur Weich-Grenze: mit Bias +1 liegt die Härte spiegelbildlich in
    /// der harten Hälfte (`hard ∈ [0, 1]` → **K ≤ 1.0 überall**, bis 0.4 an den
    /// härtesten Stellen). Die Landschaft darf dabei nicht in die andere Richtung
    /// weglaufen (unerodierbare Insel → Relief-Runaway, Becken entwässern nie).
    func testHardestRockDoesNotRunAway() {
        var c = SimConfig(); c.n = 160; c.lithHardBias = 1
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
