import XCTest
@testable import SimCore

/// Wächter für den niederschlagsgewichteten Abfluss (Issue #9, scharf geschaltet
/// und kalibriert in Issue #10, `cfg.rainWeightedFlow`, Default AN).
///
/// Drei Fragen, getrennt geprüft:
/// 1. **AUS bleibt der Referenzarm.** Ausgeschaltet ist die Akkumulation exakt
///    „jede Zelle trägt ihre Fläche bei" (Zustand vor #9). Der Droplet-Sampler
///    zieht ohne Gewichtsfeld dieselben zwei Zufallszahlen wie vorher — ein
///    KONSTANTES Gewichtsfeld rechnet deshalb bit-identisch.
/// 2. **AN zeigt in die erwartete Richtung.** Der Wind kommt aus Westen
///    (`computeRain`), also trägt die Luvseite (West) bei GLEICH GROSSEM
///    Einzugsgebiet mehr Abfluss als die Lee-Seite (Ost), und die Tropfen starten
///    dichter im Luv.
/// 3. **AN verschiebt nur UM, es fügt nichts hinzu und nimmt nichts weg** — die
///    Kalibrier-Entscheidung aus #10: das Gewicht ist auf das Landmittel des
///    Regens normiert, über See neutral 1.0. Daraus folgen die drei Invarianten
///    in `testRainWeightIsNormalizedToLandMean`,
///    `testWeightedFlowKeepsDrainageTotal` und
///    `testWeightedSpawnsKeepTheLandBudget` — sie sind der Grund, warum kein
///    Zell-Gate und keine Erosionsrate nachgezogen werden musste.
///
/// Messreihe an/aus: `docs/rain-weighted-flow-measurements.md`
/// (erzeugt von `testRainWeightMeasurementDiagnostic`).
final class RainWeightedFlowTests: XCTestCase {

    private func cfg(n: Int, rainWeighted: Bool) -> SimConfig {
        var c = SimConfig()
        c.n = n
        c.rainWeightedFlow = rainWeighted
        return c
    }

    /// Ungewichtete D8-Referenz-Akkumulation auf DEMSELBEN Netz: Zahl der Zellen,
    /// die über `receiver` in `k` entwässern (inkl. der Zelle selbst).
    ///
    /// Topologisch über die Eingangsgrade (Kahn) statt über `hf`: das Empfänger-Netz
    /// ist ein Wald (jede Zelle hat höchstens einen Empfänger), auf flachen
    /// Seespiegel-Flächen sind die Füllhöhen aber GLEICH — nach `hf` sortiert wäre
    /// die Reihenfolge dort willkürlich und die Zählung zu klein.
    private func upstreamCells(_ t: Terrain) -> [Double] {
        let cnt = t.cfg.count
        var count = [Double](repeating: 1, count: cnt)
        var indeg = [Int](repeating: 0, count: cnt)
        for k in 0..<cnt where t.receiver[k] >= 0 { indeg[Int(t.receiver[k])] += 1 }
        var queue = (0..<cnt).filter { indeg[$0] == 0 }
        var head = 0, done = 0
        while head < queue.count {
            let k = queue[head]; head += 1; done += 1
            let r = t.receiver[k]
            guard r >= 0 else { continue }
            count[Int(r)] += count[k]
            indeg[Int(r)] -= 1
            if indeg[Int(r)] == 0 { queue.append(Int(r)) }
        }
        XCTAssertEqual(done, cnt, "Empfänger-Netz muss zyklenfrei sein")
        return count
    }

    // MARK: - 1) Ausgeschaltet = heutiges Verhalten

    func testRainWeightedFlowIsOnByDefault() {
        XCTAssertTrue(SimConfig().rainWeightedFlow,
                      "Der gewichtete Abfluss ist seit #10 die Produktions-Physik")
    }

    // MARK: - 1b) Die Normierung aus #10 (Basis der Rekalibrierung)

    /// Das Gewicht ist `rain / Landmittel(rain)` auf Land und 1.0 über See.
    /// Daraus folgt direkt: Σ Gewicht über Land = Zahl der Landzellen — der
    /// Gesamtabfluss ist derselbe wie ungewichtet, der Schalter verteilt nur um.
    /// Zusätzlich geprüft: das Landmittel des Gewichts ist AUFLÖSUNGSFREI 1.0,
    /// während das Landmittel des rohen `rain` mit n wegläuft (0.56 → 0.36) —
    /// genau der Grund, warum nicht das rohe Feld gewichtet.
    func testRainWeightIsNormalizedToLandMean() {
        for n in [96, 192, 320] {
            let t = Terrain(config: cfg(n: n, rainWeighted: true), seed: 1337)
            var wLand = 0.0, rawLand = 0.0, land = 0
            for k in 0..<t.cfg.count {
                if t.h[k] > t.cfg.sea {
                    wLand += t.rainWeight[k]; rawLand += t.rain[k]; land += 1
                } else {
                    XCTAssertEqual(t.rainWeight[k], 1.0,
                                   "über See muss das Gewicht neutral 1.0 sein")
                }
            }
            XCTAssertGreaterThan(land, 0)
            print(String(format: "[RAIN] n=%d Landmittel Gewicht=%.6f roh=%.4f",
                         n, wLand / Double(land), rawLand / Double(land)))
            XCTAssertEqual(wLand / Double(land), 1.0, accuracy: 1e-9,
                           "Σ Gewicht über Land muss = Zahl der Landzellen sein (n=\(n))")
        }
    }

    /// Die Entwässerungs-Invariante gilt EINGESCHALTET unverändert: Σ der
    /// Einzugsgebiete an allen Senken = Gesamtzellzahl. Das ist die eigentliche
    /// Aussage der Normierung — vor #10 (rohes Gewicht) fiel dieselbe Summe auf
    /// das Landmittel des Regens (gemessen 0.53 bei n=832) und riss damit jedes
    /// in Zellen kalibrierte Gate mit.
    func testWeightedFlowKeepsDrainageTotal() {
        let t = Terrain(config: cfg(n: 128, rainWeighted: true), seed: 777)
        let total = Double(t.cfg.count)
        XCTAssertEqual(t.totalOutletArea(), total, accuracy: total * 1e-6,
                       "gewichtet darf die Entwässerungssumme nicht wegdriften")
    }

    /// Der Tropfen-Etat auf LAND bleibt erhalten: über See trägt das Gewichtsfeld
    /// den neutralen Wert 1.0, also fällt derselbe Anteil der Startpunkte aufs
    /// Land wie bei gleichverteilten Starts. Das ist die Antwort auf #9 §D.3
    /// (rohes Gewicht verlor 21–28 % der Land-Tropfen an den Ozean, weil es über
    /// dem Meer am meisten regnet) — ohne die Tropfenzahl anzufassen.
    func testWeightedSpawnsKeepTheLandBudget() {
        let t = Terrain(config: cfg(n: 128, rainWeighted: true), seed: 1337)
        let c = t.cfg
        // Erwartungswert über GENAU den Bereich, aus dem `spawnPosition` zieht:
        // die Vorschläge sind gleichverteilt auf [0, n-1) × [0, n-1), die letzte
        // Zeile/Spalte wird also nie getroffen (Randeffekt der Zellzuordnung
        // `Int(py)*n + Int(px)`). Ohne diese Einschränkung verschiebt allein die
        // Küstenlage des Randes den Sollwert um ~0.007.
        var wLand = 0.0, wAll = 0.0
        for j in 0..<(c.n - 1) {
            for i in 0..<(c.n - 1) {
                let k = j * c.n + i
                wAll += t.rainWeight[k]
                if t.h[k] > c.sea { wLand += t.rainWeight[k] }
            }
        }
        let landShare = wLand / wAll
        let wMax = t.rainWeight.max() ?? 0
        var rnd = Mulberry32(seed: 4242)
        var onLand = 0
        let draws = 40_000
        for _ in 0..<draws {
            let s = Hydraulic.spawnPosition(&rnd, n: c.n, weight: t.rainWeight, weightMax: wMax)
            if t.h[Int(s.y) * c.n + Int(s.x)] > c.sea { onLand += 1 }
        }
        let share = Double(onLand) / Double(draws)
        print(String(format: "[RAIN] Starts auf Land=%.4f, erwartet (Gewichtsanteil)=%.4f",
                     share, landShare))
        // 3 σ der Stichprobe (p ≈ 0.7, N = 40000) sind ~0.007.
        XCTAssertEqual(share, landShare, accuracy: 0.01,
                       "gewichtete Starts dürfen den Land-Etat nicht verschieben")
        // Und über das GANZE Gitter gilt die Aussage exakt: der Gewichtsanteil
        // des Landes IST der Zellanteil des Landes (Gewicht über See = 1.0 = das
        // Landmittel). Über dem Ziehbereich oben stimmt das nur bis auf die
        // Randzeile/-spalte, deshalb hier getrennt geprüft.
        var wLandAll = 0.0, wAllCells = 0.0
        var landCells = 0
        for k in 0..<c.count {
            wAllCells += t.rainWeight[k]
            if t.h[k] > c.sea { wLandAll += t.rainWeight[k]; landCells += 1 }
        }
        XCTAssertEqual(wLandAll / wAllCells, Double(landCells) / Double(c.count), accuracy: 1e-9,
                       "der Land-Etat der Starts muss exakt der Zellanteil sein")
    }

    /// Ausgeschaltet trägt jede Zelle EXAKT ihre Zellfläche bei — `area` ist also
    /// die reine Zellzahl des Einzugsgebiets, unabhängig vom Regen.
    func testUnweightedAccumulationIsPureCellArea() {
        let t = Terrain(config: cfg(n: 96, rainWeighted: false), seed: 4242)
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let cells = upstreamCells(t)
        var maxRelErr = 0.0
        for k in 0..<t.cfg.count {
            let expect = cells[k] * cellArea
            maxRelErr = max(maxRelErr, abs(t.area[k] - expect) / expect)
        }
        XCTAssertLessThan(maxRelErr, 1e-9,
                          "ohne Schalter muss area == Zellzahl × cellArea sein")
    }

    /// Ein KONSTANTES Gewichtsfeld darf am Droplet-Pfad nichts ändern: die
    /// Ablehnungs-Stichprobe nimmt Maximal-Gewichte ohne Ziehung an, der
    /// Zufallsstrom bleibt also derselbe. Damit ist belegt, dass der Sampler die
    /// Startpunkte nur UMVERTEILT und den Pfad nicht anfasst.
    func testUniformRainWeightIsBitIdentical() {
        var c = SimConfig(); c.n = 96
        let t = Terrain(config: c, seed: 99)
        var h = t.h, rock = t.rock, sed = t.sed
        var h2 = h, rock2 = rock, sed2 = sed
        var trk = [Double](repeating: 0, count: c.count)
        var trk2 = trk
        Hydraulic.erode(h: &h, rock: &rock, sed: &sed, n: c.n, count: 2000, seed: 7,
                        floor: c.floor, p: c.hydraulic, track: &trk)
        Hydraulic.erode(h: &h2, rock: &rock2, sed: &sed2, n: c.n, count: 2000, seed: 7,
                        floor: c.floor, p: c.hydraulic,
                        rainWeight: [Double](repeating: 0.42, count: c.count), track: &trk2)
        XCTAssertEqual(h, h2, "konstanter Regen darf die Tropfen nicht verschieben")
        XCTAssertEqual(trk, trk2, "konstanter Regen darf die Tracks nicht verschieben")
    }

    // MARK: - 2) Eingeschaltet: Luv trägt mehr Abfluss als Lee

    /// Kernnachweis (Abnahmekriterium 4): bei GLEICH GROSSEM Einzugsgebiet trägt
    /// eine Luv-Zelle (West) mehr Abfluss als eine Lee-Zelle (Ost).
    ///
    /// Gemessen wird der Abfluss je Einzugsgebiets-ZELLE, `area[k] / (Zellen × cellArea)`
    /// — das ist genau der mittlere Niederschlag über dem Einzugsgebiet von `k`.
    /// Die Normierung auf die Zellzahl macht den Vergleich unabhängig davon, dass
    /// die West- und Osthälfte verschieden große Flüsse tragen.
    func testRainWeightedFlowFavorsLuv() {
        let t = Terrain(config: cfg(n: 128, rainWeighted: true), seed: 1337)
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let cells = upstreamCells(t)
        let n = t.cfg.n
        var luv = 0.0, luvN = 0.0, lee = 0.0, leeN = 0.0
        for k in 0..<t.cfg.count where t.hf[k] > t.cfg.sea {
            // Nur substanzielle Läufe (≥ 30 Zellen wie in docs/river-baseline-metrics.md):
            // Einzelzellen messen nur ihren eigenen Regen.
            guard cells[k] >= 30 else { continue }
            let perCell = t.area[k] / (cells[k] * cellArea)
            let i = k % n
            if i < n / 2 { luv += perCell; luvN += 1 } else { lee += perCell; leeN += 1 }
        }
        XCTAssertGreaterThan(luvN, 0); XCTAssertGreaterThan(leeN, 0)
        luv /= luvN; lee /= leeN
        print(String(format: "[RAIN] Abfluss je Einzugsgebiets-Zelle: Luv=%.4f Lee=%.4f (×%.2f)",
                     luv, lee, luv / lee))
        XCTAssertGreaterThan(luv, lee * 1.10,
                             "Luv muss bei gleichem Einzugsgebiet spürbar mehr Abfluss tragen")
        // Gegenprobe: ohne Schalter ist der Wert überall exakt 1 (reine Fläche),
        // die Richtung kommt also wirklich aus dem Regen.
        let flat = Terrain(config: cfg(n: 128, rainWeighted: false), seed: 1337)
        let flatCells = upstreamCells(flat)
        for k in 0..<flat.cfg.count where flat.hf[k] > flat.cfg.sea && flatCells[k] >= 30 {
            XCTAssertEqual(flat.area[k] / (flatCells[k] * cellArea), 1.0, accuracy: 1e-9)
        }
    }

    /// Dieselbe Richtung im MFD-Feld — die Gewichtung gilt für BEIDE Netze
    /// (die Rollentrennung bleibt: `area` erodiert, `areaMFD` rendert/braided).
    func testRainWeightedMFDFavorsLuv() {
        let t = Terrain(config: cfg(n: 128, rainWeighted: true), seed: 1337)
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let n = t.cfg.n
        // MFD verteilt fraktional; als „gleich großes Einzugsgebiet" dient hier das
        // D8-Zellmaß, das für beide Felder dieselbe Topologie beschreibt.
        let cells = upstreamCells(t)
        var luv = 0.0, luvN = 0.0, lee = 0.0, leeN = 0.0
        for k in 0..<t.cfg.count where t.hf[k] > t.cfg.sea {
            guard cells[k] >= 30 else { continue }
            let perCell = t.areaMFD[k] / (cells[k] * cellArea)
            let i = k % n
            if i < n / 2 { luv += perCell; luvN += 1 } else { lee += perCell; leeN += 1 }
        }
        luv /= luvN; lee /= leeN
        print(String(format: "[RAIN] areaMFD je D8-Einzugsgebiets-Zelle: Luv=%.4f Lee=%.4f (×%.2f)",
                     luv, lee, luv / lee))
        XCTAssertGreaterThan(luv, lee * 1.10, "auch das MFD-Feld muss dem Regen folgen")
    }

    /// Die Tropfen-Startpunkte folgen dem Niederschlag: bei doppeltem Gewicht
    /// starten (im Rahmen der Stichprobe) doppelt so viele Tropfen.
    func testRainWeightedSpawnsFollowRain() {
        let n = 64
        // West nass (1.0), Ost halb so nass (0.5) → erwartete Aufteilung 2:1.
        var w = [Double](repeating: 0.5, count: n * n)
        for j in 0..<n { for i in 0..<(n / 2) { w[j * n + i] = 1.0 } }
        var rnd = Mulberry32(seed: 12345)
        var west = 0, east = 0
        for _ in 0..<20000 {
            let s = Hydraulic.spawnPosition(&rnd, n: n, weight: w, weightMax: 1.0)
            if Int(s.x) < n / 2 { west += 1 } else { east += 1 }
        }
        let ratio = Double(west) / Double(east)
        print(String(format: "[RAIN] Tropfen-Starts West/Ost = %d/%d (×%.2f)", west, east, ratio))
        XCTAssertGreaterThan(ratio, 1.85, "Startpunkte folgen dem Regen nicht (erwartet ≈ 2.0)")
        XCTAssertLessThan(ratio, 2.15, "Startpunkte übergewichten den Regen")
        // Ohne Gewichtsfeld bleibt es gleichverteilt.
        var rnd2 = Mulberry32(seed: 12345)
        var uw = 0, ue = 0
        for _ in 0..<20000 {
            let s = Hydraulic.spawnPosition(&rnd2, n: n, weight: [], weightMax: 0)
            if Int(s.x) < n / 2 { uw += 1 } else { ue += 1 }
        }
        XCTAssertEqual(Double(uw) / Double(ue), 1.0, accuracy: 0.06,
                       "ohne Gewicht müssen die Starts gleichverteilt bleiben")
    }

    /// Determinismus bleibt auch eingeschaltet eine Invariante.
    func testRainWeightedFlowIsDeterministic() {
        let a = Terrain(config: cfg(n: 96, rainWeighted: true), seed: 4242)
        let b = Terrain(config: cfg(n: 96, rainWeighted: true), seed: 4242)
        for _ in 0..<3 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertEqual(a.h, b.h, "gewichteter Abfluss muss deterministisch bleiben")
        XCTAssertEqual(a.area, b.area)
        XCTAssertEqual(a.areaMFD, b.areaMFD)
    }

    // MARK: - Messung (print-only, Quelle von docs/rain-weighted-flow-measurements.md)

    /// Vergleichsmessung an/aus im Stil von `docs/river-baseline-metrics.md`:
    /// Kanalzellen, Drainagedichte Luv gegen Lee, Relief, See-Anteil.
    /// Kein Assert außer Grund-Gesundheit — die Zahlen stehen im Dokument.
    ///
    /// Läuft im Alltag klein (n = 192, 20k Jahre, ~1 s). Die Tabelle in
    /// `docs/rain-weighted-flow-measurements.md` stammt aus demselben Test mit
    /// größerem Gitter/Horizont:
    ///
    ///     RS_MEAS_N=640 RS_MEAS_YEARS=50000 swift test -c release \
    ///       --package-path SimCore -Xswiftc -swift-version -Xswiftc 5 \
    ///       --filter testRainWeightMeasurementDiagnostic
    func testRainWeightMeasurementDiagnostic() {
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["RS_MEAS_N"] ?? "") ?? 192
        let years = Int(env["RS_MEAS_YEARS"] ?? "") ?? 20_000
        let marks = [0, 5_000, 20_000, 50_000, 100_000].filter { $0 <= years }
        for on in [false, true] {
            let t = Terrain(config: cfg(n: n, rainWeighted: on), seed: 1337)
            for mark in marks {
                while t.years < Double(mark) - 1e-6 { t.step(dtYears: 1000) }
                let m = measure(t)
                print(String(format: """
                    [RAINMEAS] gewichtet=%@ Jahr=%d | Kanalzellen=%d \
                    Dichte Luv=%.4f Lee=%.4f (Luv/Lee=%.2f) | Relief=%.4f \
                    reliefRobust=%.4f | Seeanteil=%.4f größterSee=%d | \
                    Regen Land=%.3f Meer=%.3f
                    """,
                    on ? "an " : "aus", mark, m.channels, m.dLuv, m.dLee,
                    m.dLee > 0 ? m.dLuv / m.dLee : 0, m.relief, m.reliefRobust,
                    m.lakeFrac, m.largestLake, m.rainLand, m.rainSea)
                    + String(format: " | Landanteil Zellen=%.4f gewichtete Starts=%.4f",
                             m.landShare, m.spawnLandShare))
            }
            XCTAssertGreaterThan(t.landRelief(), 0.10, "Terrain eingeebnet (gewichtet=\(on))")
        }
    }

    /// Mehr-Seed-Gegenprobe zur Einzel-Seed-Messung oben: die Drainagedichte-
    /// Richtung (Luv/Lee) muss über verschiedene Inselformen dieselbe sein, sonst
    /// misst man nur die Zufallslage der Gebirge. Print-only bis auf den Vergleich
    /// der MITTLEREN Verhältnisse.
    func testRainWeightLuvLeeIsSeedRobustDiagnostic() {
        // GEPOOLT statt „Mittel der Verhältnisse": kleine, trockene Seeds haben
        // Hälften ganz ohne Kanalzellen (Seed 555: 47 bzw. 11 Kanalzellen auf der
        // ganzen Insel) — deren Einzel-Verhältnis ist 0 bzw. undefiniert und würde
        // ein Mittel dominieren. Gepoolt zählt jede Insel mit ihrem Gewicht.
        var chLuv = [false: 0, true: 0], chLee = [false: 0, true: 0]
        var lLuv = [false: 0, true: 0], lLee = [false: 0, true: 0]
        for seed in [UInt32(1337), 7, 99, 2024, 555, 42] {
            for on in [false, true] {
                let t = Terrain(config: cfg(n: 192, rainWeighted: on), seed: seed)
                while t.years < 20_000 - 1e-6 { t.step(dtYears: 1000) }
                let m = measure(t)
                chLuv[on]! += m.chLuv; chLee[on]! += m.chLee
                lLuv[on]! += m.landLuv; lLee[on]! += m.landLee
                print(String(format: "[RAINSEED] Seed=%d gewichtet=%@ | Kanalzellen=%d " +
                                     "Dichte Luv=%.4f Lee=%.4f Luv/Lee=%.3f",
                             seed, on ? "an " : "aus", m.channels, m.dLuv, m.dLee,
                             m.dLee > 0 ? m.dLuv / m.dLee : 0))
            }
        }
        func pooled(_ on: Bool) -> Double {
            (Double(chLuv[on]!) / Double(lLuv[on]!)) / (Double(chLee[on]!) / Double(lLee[on]!))
        }
        let rOff = pooled(false), rOn = pooled(true)
        print(String(format: "[RAINSEED] gepoolte Drainagedichte Luv/Lee: aus=%.3f an=%.3f (×%.2f)",
                     rOff, rOn, rOn / rOff))
        XCTAssertGreaterThan(rOn, rOff * 1.05,
                             "gewichteter Abfluss muss die Drainagedichte Richtung Luv verschieben")
    }

    private struct Metrics {
        var channels = 0
        var chLuv = 0, chLee = 0, landLuv = 0, landLee = 0
        var dLuv = 0.0, dLee = 0.0
        var relief = 0.0, reliefRobust = 0.0
        var lakeFrac = 0.0, largestLake = 0
        var rainLand = 0.0, rainSea = 0.0
        /// Anteil der Landzellen an allen Zellen …
        var landShare = 0.0
        /// … gegen den Anteil der Tropfen-STARTS, die auf Land fallen
        /// (= Σrain über Land / Σrain gesamt). Beide sind gleich, solange die
        /// Starts gleichverteilt sind; gewichtet sinkt der Land-Anteil, weil es
        /// über dem Meer am meisten regnet (relevant für
        /// `hydraulicSkipWaterSpawns` — s. Doku).
        var spawnLandShare = 0.0
    }

    /// Kanalzelle = Landzelle mit `areaMFD / cellArea ≥ renderMinCells` (die
    /// Render-Definition aus `SimNode.waterFieldBytes`). Drainagedichte = Anteil der
    /// Kanalzellen an den Landzellen der jeweiligen Hälfte (Luv = West = Wind-Seite).
    private func measure(_ t: Terrain) -> Metrics {
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let creek = t.cfg.renderMinCells
        let n = t.cfg.n
        var m = Metrics()
        var landLuv = 0, landLee = 0, chLuv = 0, chLee = 0
        var rainLandSum = 0.0, rainSeaSum = 0.0, seaCells = 0
        for k in 0..<t.cfg.count {
            let west = (k % n) < n / 2
            if t.hf[k] > t.cfg.sea && t.h[k] > t.cfg.sea {
                if west { landLuv += 1 } else { landLee += 1 }
                rainLandSum += t.rain[k]
                if t.areaMFD[k] / cellArea >= creek {
                    m.channels += 1
                    if west { chLuv += 1 } else { chLee += 1 }
                }
            } else {
                rainSeaSum += t.rain[k]; seaCells += 1
            }
        }
        m.chLuv = chLuv; m.chLee = chLee; m.landLuv = landLuv; m.landLee = landLee
        m.dLuv = landLuv == 0 ? 0 : Double(chLuv) / Double(landLuv)
        m.dLee = landLee == 0 ? 0 : Double(chLee) / Double(landLee)
        m.relief = t.landRelief()
        m.reliefRobust = t.landReliefRobust()
        let lake = t.lakeStats(depth: 0.03)
        m.lakeFrac = lake.fraction; m.largestLake = lake.largest
        m.rainLand = rainLandSum / Double(max(1, landLuv + landLee))
        m.rainSea = rainSeaSum / Double(max(1, seaCells))
        m.landShare = Double(landLuv + landLee) / Double(t.cfg.count)
        m.spawnLandShare = rainLandSum / max(1e-9, rainLandSum + rainSeaSum)
        return m
    }
}
