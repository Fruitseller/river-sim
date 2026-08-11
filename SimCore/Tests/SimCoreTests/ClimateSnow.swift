import XCTest
@testable import SimCore

/// Wächter + Messreihe zur **Klima-Vertikalen** (Issue #33): Temperaturfeld aus
/// der Höhe und Schneedecke als Massenbilanz
/// (`Terrain.updateClimate`, Kalibrier-Logbuch bei `SimConfig.climateEnabled` ff.,
/// Modellherleitung `docs/research-climate-cryosphere.md`).
///
/// Die Abnahmekriterien des Tickets und ihre Wächter hier:
/// 1. deterministisch und dt-invariant → `testSnowBalanceIsDtInvariant`,
///    `testSnowBalanceIsDeterministic`
/// 2. Färbung und Waldgrenze lesen das Schneefeld →
///    `testSnowCoverIsTheSingleSourceForColouring`,
///    `HeightBandTests.testSnowZoneFollowsTheClimateNotAFixedLandFraction`
/// 3. abgeschaltet bit-identisch → `testDisabledClimateIsBitIdenticalPhysics`,
///    `testDisabledClimateFallsBackToThePercentileBands`
/// 4. Snapshot → `WorldSnapshotTests` (die Feldtabellen iterieren das Inventar)
final class ClimateSnow: XCTestCase {

    private func cfg(n: Int = 192) -> SimConfig {
        var c = SimConfig(); c.n = n; return c
    }

    /// Landanteile: Schnee-Rampe (Deckung > `snowBandCoverStart`), voll beschneit
    /// (≥ `snowBandCoverFull`) und „überhaupt sichtbar" (Deckung > 0.05).
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

    // MARK: - Messreihe (Diagnose, keine Zusicherung)

    /// **Sweep über `snowMeltPerKYear`** — der Regler, der die BREITE des
    /// Übergangs setzt. Druckt die Landanteile bei der Generierung und nach
    /// 20.000 Jahren. Rohdaten für `docs/climate-snow-measurements.md`.
    func testMeltRateSweepDiagnostic() {
        for c in [0.02, 0.06, 0.20] {
            var conf = cfg()
            conf.snowMeltPerKYear = c
            let t = Terrain(config: conf, seed: 1337)
            let f0 = fractions(t)
            let b0 = t.heightBands
            run(t, to: 20_000)
            let f1 = fractions(t)
            let b1 = t.heightBands
            // Saumbreite: Höhenspanne, über die der Vorrat von der Rampen- auf die
            // Sichtbarkeits-Schwelle fällt (Faktor 19), s. SimConfig.snowMeltPerKYear.
            print(String(format: "[#33] c=%.2f Saumbreite %.4f Einheiten | "
                         + "J0 sichtbar %.4f Rampe %.4f voll %.4f snowStart %.4f | "
                         + "J20k sichtbar %.4f Rampe %.4f voll %.4f snowStart %.4f maxH %.4f",
                         c, 18 / (c * conf.snowTurnoverYears * conf.climateLapseRate),
                         f0.visible, f0.ramp, f0.full, b0.snowStart,
                         f1.visible, f1.ramp, f1.full, b1.snowStart, t.maxHeight()))
        }
    }

    /// Produktions-Kalibrierung in Produktionsauflösung: was die Verteilung
    /// wirklich macht, inklusive Temperatur-Spanne und dem Vergleich zum alten
    /// Perzentil-Schnee (1.5 % des Landes).
    func testProductionResolutionDiagnostic() {
        var c = SimConfig(); c.n = 832
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

    /// Kosten der beiden neuen Pässe je `step()` in Produktionsauflösung —
    /// gemessen statt geschätzt (dieselbe Doktrin wie bei `updateHeightBands`).
    /// `updateClimate` ist parallel und per-Zelle, `snowAreaFractions` (im
    /// Höhenband-Pass) ist ein sequenzieller Zählpass über alle Zellen.
    func testClimatePassCostDiagnostic() {
        var c = SimConfig(); c.n = 832
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

    // MARK: - Abnahme 1: deterministisch und dt-invariant

    /// **dt-Invarianz der Bilanz** (Abnahmekriterium: Zeitraffer == Zeitsprung).
    /// Die Relaxationsform `S* + (S−S*)e^(−μdt)` teleskopiert exakt, solange `a`
    /// und `μ` gleich bleiben — der Test fährt deshalb `updateClimate` direkt
    /// gegen ein eingefrorenes Höhenfeld: EIN Schritt à 4000 Jahre gegen 400 à 10.
    /// Enge Schranke, weil hier nichts anderes mitläuft (die
    /// Operator-Splitting-Drift des vollen `step()` ist eine andere Baustelle,
    /// s. `DtInvariance`).
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
        // Rein Gleitkomma-Rundung der 400 Teilschritte, keine Modell-Abweichung.
        XCTAssertLessThan(worst, 1e-12,
            "Schneebilanz ist nicht dt-invariant (Abweichung \(worst))")
        // Temperatur hängt gar nicht an dt.
        XCTAssertEqual(a.temperature, b.temperature)
    }

    /// **dt-Invarianz durch den VOLLEN Zeitschritt** — „Zeitraffer == Zeitsprung
    /// für dieselbe Simulationszeit", so wie das Abnahmekriterium es formuliert.
    /// Der Test darüber isoliert die Bilanz; dieser hier fährt dieselben 20.000
    /// Jahre in dt = 50 / 500 / 2000 durch `step()` und vergleicht die
    /// Schnee-Kennzahlen am Ende.
    ///
    /// Die Schranke ist hier notwendigerweise weiter als die 1e-12 oben, und zwar
    /// aus einem Grund, der NICHT im Klimapass liegt: das Terrain selbst driftet
    /// über die Schrittweite (Operator-Splitting des Tropfen-Passes, Klassen-Doku
    /// von `DtInvariance` — Relief-Spanne 9.8 %, Seeanteil 72 % über dieselben
    /// Schrittweiten). Der Schnee liest die Höhe, also erbt er diese Drift. Die
    /// Schranke von 20 % liegt auf dem Niveau der Relief-Schranke dort und fängt
    /// jede eigene dt-Abhängigkeit des Klimapasses ab.
    ///
    /// Gemessen (n=192, Seed 1337, 20k Jahre; mittlerer Vorrat über Land /
    /// Rampen-Anteil / `snowStart`):
    ///   dt   50 → 0.00247 / 0.0050 / 0.5702
    ///   dt  500 → 0.00265 / 0.0052 / 0.5697
    ///   dt 2000 → 0.00243 / 0.0050 / 0.5702
    /// Spanne 8.3 % bzw. 3.8 %; die Grenze bewegt sich um 0.0005, also eine
    /// Histogramm-Bin-Breite.
    func testSnowThroughFullStepsIsDtInvariant() {
        var conf = cfg(n: 192)
        // Wie in DtInvariance: die Zufalls-Hebung des Servos aus dem Vergleich
        // nehmen, damit nur die Pass-Drift übrig bleibt.
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
                XCTAssertLessThan(devMean, 0.20, "\(tag): Vorrat \(a.mean) vs \(b.mean)")
                XCTAssertLessThan(devFrac, 0.20, "\(tag): Rampe \(a.frac) vs \(b.frac)")
                // Die GRENZE ist eine Temperatur und darf gar nicht driften —
                // sie hängt nur an der Höhenverteilung, nicht an der Schrittzahl.
                XCTAssertEqual(a.start, b.start, accuracy: 0.01,
                               "\(tag): snowStart \(a.start) vs \(b.start)")
            }
        }
    }

    /// `dt = 0` ist ein exakter No-Op auf der Bilanz (der Sculpt-Pfad in
    /// `SimNode.recomputeFlow` verlässt sich darauf) — nur die Temperatur wird
    /// nachgezogen.
    func testZeroStepLeavesTheBalanceUntouched() {
        let t = Terrain(config: cfg(n: 96), seed: 7)
        let before = t.snow
        t.updateClimate(dt: 0)
        XCTAssertEqual(before, t.snow, "dt = 0 hat die Schneebilanz verändert")
    }

    /// Determinismus je Seed: zwei Läufe derselben Config sind bit-gleich, und die
    /// parallelisierte Zelle-für-Zelle-Rechnung ändert daran nichts.
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

    // MARK: - Modell: Temperatur und Bilanz tun, was draufsteht

    /// Die Temperatur ist die kalibrierte affine Höhenfunktion — und das Meer
    /// trägt überall den Meeresspiegel-Wert (Höhe geklemmt).
    func testTemperatureFollowsTheCalibratedLapseRate() {
        let c = cfg(n: 96)
        let t = Terrain(config: c, seed: 1337)
        for k in 0..<c.count {
            XCTAssertEqual(t.temperature[k], c.expectedTemperature(at: t.h[k]),
                           accuracy: 1e-12, "Zelle \(k)")
        }
        // Meer: exakt T₀, unabhängig von der Tiefe.
        let deep = (0..<c.count).first { t.h[$0] < c.sea - 0.05 }
        XCTAssertNotNil(deep, "Testaufbau: keine tiefe Meereszelle")
        XCTAssertEqual(t.temperature[deep!], c.climateSeaLevelTemp, accuracy: 1e-12)
        // Die 0-°C-Isotherme sitzt, wo die Kalibrierung sie hinlegt.
        XCTAssertEqual(c.sea + c.climateSeaLevelTemp / c.climateLapseRate, 0.5730,
                       accuracy: 1e-4)
    }

    /// Schnee liegt OBEN und nirgends unten: die kälteste Landzelle trägt mehr
    /// als die wärmste. Klingt trivial, ist aber die Zusicherung, dass
    /// Akkumulation und Ablation nicht vertauscht sind.
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

    /// **Massenbilanz statt Höhenschwelle**: bei GLEICHER Höhe trägt die feuchte
    /// Luvseite mehr Schnee als der Regenschatten. Genau das kann eine
    /// Höhenschwelle prinzipiell nicht — es ist der Beleg, dass die Akkumulation
    /// wirklich aus dem Niederschlag kommt.
    ///
    /// **Nach Höhe gepaart** (Bins von 0.005 Höheneinheiten, geometrisch gepoolt) —
    /// dieselbe Methode wie beim Hangknick-Signal in `Lithology`. Ohne Paarung wäre
    /// die Kennzahl konfundiert: der Vorrat fällt über das Band um mehr als eine
    /// Größenordnung, und nass/trocken sind nicht gleich über die Höhe verteilt.
    /// Das geometrische Mittel ist symmetrisch — nass/trocken getauscht liefert den
    /// Kehrwert, reines Rauschen also 1.0.
    func testAccumulationCarriesTheOrographicSignal() {
        let c = cfg(n: 256)
        let t = Terrain(config: c, seed: 1337)
        XCTAssertEqual(t.rainWeight.count, c.count, "Testaufbau: kein Regen-Gewicht")
        // Höhenband um die Frostgrenze: unten T = +1 °C, oben die Isotherme.
        let lo = c.sea + (c.climateSeaLevelTemp - 1.0) / c.climateLapseRate
        let binWidth = 0.005, bins = 12
        var acc = 0.0, wsum = 0.0, pairs = 0
        for b in 0..<bins {
            let a0 = lo + Double(b) * binWidth, a1 = a0 + binWidth
            var wet = 0.0, dry = 0.0
            var nWet = 0, nDry = 0
            for k in 0..<c.count where t.h[k] >= a0 && t.h[k] < a1 {
                // Regen-Gewicht (#10) hat per Konstruktion Landmittel exakt 1.0.
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

    // MARK: - Abnahme 3: abgeschaltet ist bit-identisch

    /// **Der Aus-Wächter.** Mit `climateEnabled = false` bleibt jedes Kryo-Feld
    /// LEER, und die gesamte übrige Physik läuft bit-identisch zum
    /// eingeschalteten Arm — das Klima koppelt in keinen Erosionspass und nicht in
    /// die Vegetation (bewusste Scope-Grenze, s. `SimConfig.climateEnabled`).
    ///
    /// **Seit Issue #36 mit EINER Ausnahme:** die Schmelze speist den Abfluss.
    /// Beide Arme laufen hier deshalb mit `meltRunoffEnabled = false` — die
    /// Aussage des Wächters ist unverändert „das Klima SELBST rührt die Physik
    /// nicht an", nur ist die Schmelz-Kopplung jetzt ein eigener, eigens
    /// abschaltbarer Weg mit eigenem Aus-Wächter
    /// (`MeltRunoff.testDisabledMeltRunoffIsBitIdentical`). Ohne diese Zeile
    /// vergleicht der Test zwei verschiedene Physiken.
    ///
    /// Verglichen wird ALLES außer den drei Kryo-Feldern und der Schneegrenze:
    /// beides ist per Konstruktion der Unterschied.
    func testDisabledClimateIsBitIdenticalPhysics() {
        var off = cfg(n: 128); off.climateEnabled = false; off.meltRunoffEnabled = false
        var on = cfg(n: 128); on.meltRunoffEnabled = false
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
        // …und die NICHT-Schnee-Bänder sind ebenfalls identisch: die Umstellung
        // rührt ausschließlich an snowStart/snowFull.
        XCTAssertEqual(a.heightBands.vegFull, b.heightBands.vegFull)
        XCTAssertEqual(a.heightBands.vegRamp, b.heightBands.vegRamp)
        XCTAssertEqual(a.heightBands.rockStart, b.heightBands.rockStart)
        XCTAssertEqual(a.heightBands.rockFull, b.heightBands.rockFull)
        XCTAssertEqual(a.heightBands.coniferLow, b.heightBands.coniferLow)
        XCTAssertEqual(a.heightBands.coniferHigh, b.heightBands.coniferHigh)
    }

    /// Abgeschaltet rechnet die Schneegrenze exakt wie vor #33: das Höhenband
    /// kommt aus `bandSnowPercentile`, und `snowCover` liefert genau
    /// `HeightBands.snowAmount` — der „Faktor 1.0"-Fall des Tickets.
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

    // MARK: - Abnahme 2: eine Quelle für die Färbung

    /// `snowCover` IST `Terrain.snowCoverage` auf dem Feld — dieselbe Funktion,
    /// die `SimNode.terrainColorBytes` über den rohen Puffer aufruft. Der Test
    /// pinnt beide Enden: die FORMEL (hier nachgebaut) und dass der
    /// Feld-Zugriffsweg dasselbe liefert. Damit bekommt die Färbung keine zweite
    /// Wahrheit (dieselbe Doktrin wie `vegetationSuitability` seit Issue #4).
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
    /// Erwartete Temperatur aus der Kalibrier-Formel — bewusst hier nachgebaut
    /// (nicht aus `Terrain` gezogen), damit der Wächter die FORMEL prüft.
    func expectedTemperature(at height: Double) -> Double {
        climateSeaLevelTemp - climateLapseRate * max(0, height - sea)
    }
}
