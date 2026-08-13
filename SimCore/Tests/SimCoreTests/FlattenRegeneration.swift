import XCTest
@testable import SimCore

/// Wächter für Issue #26: **großflächige Einebnung** darf keine dauerhafte
/// Waldtapete hinterlassen. Der Report zeigte eine über Zehntausende Jahre
/// uniforme, dicht bewaldete Platte ohne neues Entwässerungsnetz.
///
/// Alle Läufe hier gehen über die ECHTE Pinsel-API (`Terrain.flatten`) mit den
/// UI-Grenzwerten (Radius 30 Welteinheiten = `radius_slider.max_value` in
/// `Main.gd`, Stärke 3) — kein direktes Beschreiben von `h`, sonst prüft der
/// Test einen Pfad, den der Spieler nie auslöst.
///
/// Messreihen (vorher/nachher): `docs/flatten-regeneration-measurements.md`.
final class FlattenRegeneration: XCTestCase {

    // MARK: - Aufbau

    /// UI-Maximalradius des Pinsels in WELT-Einheiten (`Main.gd`, radius_slider).
    private static let uiMaxRadius = 30.0
    /// UI-Maximalstärke des Pinsels (`Main.gd`, Stärke-Slider).
    private static let uiMaxStrength = 3.0

    /// Produktionsdefaults, nur `n` gesenkt (Laufzeit) — `world` bleibt, damit
    /// der Pinselradius in Welteinheiten dieselbe Bedeutung hat wie im Spiel.
    private func flatCfg(n: Int = 96) -> SimConfig {
        var c = SimConfig()
        c.n = n
        return c
    }

    /// Ebnet die GESAMTE Karte über die echte Pinsel-API auf `target` ein —
    /// gekachelte Striche mit UI-Maximalradius, so oft wiederholt, bis die
    /// Platte praktisch exakt flach ist (der Spieler zieht ebenso mehrfach
    /// über dieselbe Stelle). Deterministisch: feste Kachel-Reihenfolge.
    @discardableResult
    private func flattenWholeMap(_ t: Terrain, target: Double, rounds: Int = 14) -> Double {
        let r = FlattenRegeneration.uiMaxRadius
        let stepCells = max(1.0, (r / t.cfg.cellSize) * 0.5) // halbe Pinselbreite → Überlappung
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

    /// Frisches Terrain, danach die ganze Karte auf `sea + 0.25` gezogen —
    /// exakt der Repro-Aufbau aus Issue #26.
    private func flattenedTerrain(seed: UInt32 = 1337, n: Int = 96) -> Terrain {
        let c = flatCfg(n: n)
        let t = Terrain(config: c, seed: seed)
        flattenWholeMap(t, target: c.sea + 0.25)
        return t
    }

    // MARK: - Kennzahlen

    /// Anteil der Landzellen mit `veg > 0.45` (ab da malt der Renderer Wald und
    /// setzt Baum-Instanzen — die „Waldtapete" des Reports).
    private func forestFraction(_ t: Terrain) -> Double {
        var land = 0, forest = 0
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea {
            land += 1
            if t.veg[k] > 0.45 { forest += 1 }
        }
        return land == 0 ? 0 : Double(forest) / Double(land)
    }

    /// Mittlere MAKRO-Steigung über ±2 Zellen (`Terrain.macroSlope`, dieselbe
    /// Ableitung, die Vegetation und Biom-Farbe lesen) — misst die räumliche
    /// Differenzierung der Fläche unabhängig von der Rinnen-Textur.
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

    /// Anteil der Landzellen mit etabliertem Lauf (`streamMap ≥ 0.5`, also
    /// Besuchsrate über der Sättigungsreferenz) — objektives Maß für
    /// „es gibt wieder ein Entwässerungsnetz".
    private func channelFraction(_ t: Terrain) -> Double {
        var land = 0, chan = 0
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea {
            land += 1
            if t.streamMap[k] >= 0.5 { chan += 1 }
        }
        return land == 0 ? 0 : Double(chan) / Double(land)
    }

    /// Anteil der Landzellen im Trunk-Netz (D8-Einzugsgebiet ≥ `cells` Zellen).
    private func drainageFraction(_ t: Terrain, cells: Double = 30) -> Double {
        let minA = cells * t.cfg.cellSize * t.cfg.cellSize
        var land = 0, chan = 0
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea {
            land += 1
            if t.area[k] >= minA { chan += 1 }
        }
        return land == 0 ? 0 : Double(chan) / Double(land)
    }

    /// Streuung der Vegetationsdichte über Land (0 = flächendeckend identisch).
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

    /// Höhen des INNEREN Kartenausschnitts (Rand `margin` Zellen weggeschnitten).
    /// Der Weltrand ist Basisniveau Meer — dort schneidet die Inzision auch ohne
    /// jede Regeneration eine Schlucht (gemessen: max−min 0.21 nach 3.000 J. auf
    /// der unbehandelten Platte). Die Frage von Issue #26 ist aber, ob sich die
    /// FLÄCHE differenziert, nicht ihr Rand.
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

    /// Anteile der Innenfläche: Vegetationsklassen (kahl/Gras/Wald/Auwald) und
    /// Wasserflächen (`hf − h > 0.02`).
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

    /// Anteil der Innenfläche, der gegenüber seiner ±2-Umgebung EINGESCHNITTEN
    /// ist (Tiefenlinie ≥ `depth` unter dem Umgebungsmittel) — objektives Maß
    /// für „es gibt wieder Rinnen/Täler" ohne Rückgriff auf die Tropfen-Statistik
    /// (die bei n=96 unter der Sättigungsschwelle der Stream-Map bleibt).
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

    /// Stabilität des Entwässerungsnetzes: Anteil der Landzellen, die über
    /// `years` Jahre denselben Abfluss-Nachbarn behalten. Ein echtes Netz hält
    /// seinen Lauf; eine gefällelose Platte würfelt ihn je Schritt neu.
    private func receiverStability(_ t: Terrain, years: Double = 250) -> Double {
        let before = t.snapshotReceivers()
        t.step(dtYears: years)
        return t.receiverAgreement(with: before)
    }

    /// Innen-Zeile: Hoch-/Talseitenrelief, Makro-Steigung, Waldanteil und
    /// Flächen-Mix des inneren Ausschnitts.
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

    /// Eine Kennzahlen-Zeile für die Messreihen in `docs/`.
    private func row(_ t: Terrain) -> String {
        String(format: "%7.0f | %8.4f | %8.5f | %8.5f | %8.5f | %6.1f%% | %6.2f%% | %6.2f%% | %6.4f | %6.4f",
               t.years, t.landRelief(), t.landReliefHigh(), t.landReliefLow(),
               macroSlope(t), forestFraction(t) * 100, channelFraction(t) * 100,
               drainageFraction(t) * 100, meanStream(t), vegSpread(t))
    }

    private static let header =
        "  Jahr |  max-min | p95-Med. | Med.-p05 | Makro-S. |   Wald |  Kanäle | Netz≥30 | Str.-Ø | veg-σ"

    // MARK: - Repro / Messreihe

    /// **Repro-Messreihe** aus Issue #26 (Seed 1337, n=96, Karte auf `sea+0.25`).
    /// Prüft nichts, sondern druckt die Tabelle für `docs/` — der eigentliche
    /// Wächter ist `testFlattenedPlateRegeneratesWithin3000Years`.
    func testFlattenMeasurementDiagnostic() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RS_MEASURE"] != nil,
                          "Messreihe nur mit RS_MEASURE=1 (Laufzeit)")
        let t = flattenedTerrain()
        print("== Issue #26: Einebnung auf sea+0.25, Seed 1337, n=96 ==")
        print(FlattenRegeneration.header)
        print(row(t))
        let marks = [3_000.0, 10_000.0, 50_000.0]
        for m in marks {
            while t.years < m { t.step(dtYears: 500) }
            print(row(t))
        }
        // Kontrolle: dasselbe Terrain OHNE Eingriff — die Skala, an der
        // „differenzierte Landschaft" gemessen wird.
        let ref = Terrain(config: flatCfg(), seed: 1337)
        print("== Kontrolle: unangetastetes Terrain, Seed 1337, n=96 ==")
        print(FlattenRegeneration.header)
        print(row(ref))
        for m in marks {
            while ref.years < m { ref.step(dtYears: 500) }
            print(row(ref))
        }
    }

    // MARK: - Wächter

    /// **Hauptwächter (Issue #26)**: eine über die echte `flatten()`-API
    /// eingeebnete Karte entwickelt binnen 3.000 Jahren wieder eine
    /// differenzierte Landschaft — gemessen auf der INNENFLÄCHE, damit die
    /// Rand-Schlucht (Basisniveau Meer am Weltrand, entsteht auch ohne jede
    /// Regeneration) das Ergebnis nicht schönt.
    ///
    /// Gegenprobe im selben Test: derselbe Eingriff mit abgeschaltetem
    /// Regenerations-Pfad = der Zustand aus dem Report.
    /// Messreihe: `docs/flatten-regeneration-measurements.md`.
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

            // 1) Hoch- UND Talseitenrelief zusammen (Kriterium 6: beide Hälften
            //    getrennt gemessen — je nach Seed differenziert sich die Fläche
            //    nach oben oder nach unten, die Summe fängt beides).
            //    Gemessen 0.065 / 0.086 / 0.065 gegen 0.009 / 0.009 / 0.009.
            XCTAssertGreaterThan(reliefF, 0.04,
                "Innenfläche bleibt flach (Seed \(seed)): p95−Median \(qF.high), Median−p05 \(qF.low)")
            XCTAssertGreaterThan(reliefF, reliefB * 3,
                "Regeneration bringt kaum mehr Relief als ohne Pfad (Seed \(seed)): \(reliefF) vs \(reliefB)")

            // 2) Makro-Steigung — die Größe, die Vegetation und Biom-Farbe lesen.
            //    Gemessen 0.0055 / 0.0037 / 0.0033 gegen 0.0005.
            XCTAssertGreaterThan(slopeF, 0.002,
                "Keine Makro-Steigung auf der Innenfläche (Seed \(seed)): \(slopeF)")
            XCTAssertGreaterThan(slopeF, slopeB * 3,
                "Makro-Steigung kaum besser als ohne Pfad (Seed \(seed)): \(slopeF) vs \(slopeB)")

            // 3) Kanalbildung: Anteil der Zellen, die gegenüber ihrer Umgebung
            //    eingeschnitten sind. Gemessen 31 % / 16 % / 20 % gegen exakt 0 %.
            XCTAssertGreaterThan(cutF, 0.08,
                "Keine Rinnen auf der Innenfläche (Seed \(seed)): \(cutF)")
            XCTAssertGreaterThan(cutF, cutB + 0.05,
                "Rinnen kaum mehr als ohne Pfad (Seed \(seed)): \(cutF) vs \(cutB)")
        }
    }

    /// Sukzession statt Waldtapete: unmittelbar nach dem Eingriff ist die Fläche
    /// kahl, nach ~500 Jahren steht Gras, erst danach Wald — und die
    /// Vegetations-Klassen bleiben ein Mosaik statt einer Fläche.
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

    /// Kriterium 2: stark veränderte Zellen verlieren Vegetation und
    /// Stream-Map-Gedächtnis der ALTEN Topografie, unveränderte Bereiche nicht.
    /// (Die Baum-Instanzen des Frontends leiten sich aus `veg` ab — mit dem
    /// Bestand fällt auch die Baumplatzierung.)
    func testDisturbedCellsDropInheritedStateAndStayLocal() {
        let c = flatCfg()
        let t = Terrain(config: c, seed: 1337)
        let vegBefore = t.veg, streamBefore = t.streamMap
        // Ein Pinselabdruck in der Kartenmitte, mit UI-Maximalwerten.
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
                    // Voll gestörte Zelle: Bestand und Lauf-Gedächtnis der alten
                    // Landschaft müssen praktisch weg sein (der Reset ist
                    // anteilig, s. registerDisturbance).
                    inside += 1
                    if t.veg[k] <= vegBefore[k] * 0.01 && t.streamMap[k] <= streamBefore[k] * 0.01 {
                        cleared += 1
                    }
                } else if d > rCells + 1 {
                    // Außerhalb des Pinsels: KEIN Zustand darf sich geändert haben.
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

    /// Mäanderläufe und Altarme der alten Landschaft überleben eine
    /// großflächige Einebnung nicht — mit abgeschaltetem Pfad dagegen schon.
    func testFlattenDropsOldMeanderState() {
        func meanSinuosity(_ t: Terrain) -> Double {
            let ch = t.meander.channels
            return ch.isEmpty ? 0 : ch.map { $0.sinuosity }.reduce(0, +) / Double(ch.count)
        }
        /// Gealtertes Terrain: erst nach ein paar Jahrtausenden gibt es
        /// ausgeprägte Schlingen und Altarme, die man verlieren KANN.
        func aged(_ c: SimConfig) -> Terrain {
            let t = Terrain(config: c, seed: 1337)
            while t.years < 15_000 { t.step(dtYears: 500) }
            return t
        }

        // Gegenprobe: ohne Regenerations-Pfad schreibt die Sim den alten
        // Zustand über die frische Platte fort (gemessen: 14 → 14 Altarme,
        // Sinuosität 1.665 → 1.622).
        var off = flatCfg(); off.disturbanceEnabled = false
        let kept = aged(off)
        let keptOxbows = kept.meander.oxbows.count
        XCTAssertGreaterThan(keptOxbows, 0, "Testaufbau: keine Altarme entstanden")
        flattenWholeMap(kept, target: off.sea + 0.25)
        kept.step(dtYears: 250)
        XCTAssertEqual(kept.meander.oxbows.count, keptOxbows,
            "Testaufbau: ohne Pfad müssten die Altarme unverändert weiterlaufen")

        // Mit Pfad: Altarme weg, Läufe frisch aus der neuen Entwässerung
        // getrasst (gemessen: 14 → 0 Altarme, Sinuosität 1.665 → 1.274).
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

    /// Kriterium 3: der SOFORTeffekt des Werkzeugs wird nicht verrauscht — die
    /// frisch gezogene Fläche ist exakt flach (das Mikro-Relief wächst erst
    /// über die folgenden Jahrhunderte hinein).
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

    /// Kriterium 5: ohne Eingriff läuft die Alterung BIT-IDENTISCH zum Stand vor
    /// Issue #26 — der Regenerations-Pfad ist ausschließlich Eingriffs-Folge.
    func testUntouchedAgingIsBitIdentical() {
        var off = flatCfg(); off.disturbanceEnabled = false
        let a = Terrain(config: off, seed: 1337)
        let b = Terrain(config: flatCfg(), seed: 1337)
        while a.years < 3000 { a.step(dtYears: 500); b.step(dtYears: 500) }
        XCTAssertEqual(a.h, b.h, "Alterung ohne Eingriff ist nicht bit-identisch")
        XCTAssertEqual(a.veg, b.veg, "Vegetation ohne Eingriff ist nicht bit-identisch")
        XCTAssertEqual(a.streamMap, b.streamMap, "Stream-Map ohne Eingriff ist nicht bit-identisch")
    }

    /// Framerate-Invarianz: viele Mini-Schritte und ein großer Sprung tragen
    /// dieselbe Regeneration ein (Budget-Teleskopierung in
    /// `regenerateDisturbed`). Geprüft auf dem Gelände direkt nach dem
    /// Abklingfenster, bevor die chaotische Droplet-Erosion die Wege trennt.
    func testRegenerationIsFramerateIndependent() {
        // Alle anderen h-Pässe stillgelegt: der Test prüft die Teleskopierung
        // des Regenerations-Budgets, nicht die (chaotische) Erosion. Die
        // Tropfen sind PRO SCHRITT gezogen (`max(1, …)`), also selbst nicht
        // schrittweiten-invariant — sie müssen hier raus.
        var c = flatCfg()
        // Dazu gehört seit Issue #35 auch der Gletscher: die frisch gezogene
        // Ebene liegt zwar mit `sea + 0.25` weit unter der Firn-Grenze (0.5731),
        // aber `updateIce` läuft am SCHRITTANFANG auf dem Klima des vorigen
        // Schrittendes — im ersten Schritt also auf der Temperatur der noch
        // ungeebneten Gipfel. Dort entsteht einmalig Eis, das im zweiten Schritt
        // auf der warmen Platte ausschmilzt und seine Moräne ablegt. Die Menge
        // hängt an der Länge dieses EINEN Fensters, also an dt (gemessen: max.
        // Abweichung 0.0018 zwischen dt = 50 und dt = 1000). Das ist dieselbe
        // Operator-Splitting-Drift, wegen der auch `hillDiffusion` hier auf 0
        // steht — kein Fehler des Gletschers, aber nichts, was ein Wächter mit
        // 1e-9-Schranke messen kann. Der Gletscher hat seinen eigenen
        // Framerate-Wächter (`Glacier.testIceIsFramerateIndependent`, mit
        // Schranken statt Bit-Gleichheit).
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

    /// Determinismus: zwei identische Läufe über den Regenerations-Pfad sind
    /// bit-identisch (Wächter der Projekt-Invariante).
    func testRegenerationIsDeterministic() {
        let a = flattenedTerrain()
        let b = flattenedTerrain()
        while a.years < 2000 { a.step(dtYears: 500); b.step(dtYears: 500) }
        XCTAssertEqual(a.h, b.h, "Regenerierter Lauf ist nicht deterministisch")
        XCTAssertEqual(a.veg, b.veg, "Vegetation des regenerierten Laufs ist nicht deterministisch")
    }

    /// Die Störung ist ZEITLICH begrenzt: nach dem Abklingfenster ist das Feld
    /// wieder exakt 0 und die Fläche läuft unter normaler Physik weiter.
    func testDisturbanceExpires() {
        let t = flattenedTerrain()
        XCTAssertGreaterThan(t.disturb.max() ?? 0, 0.9, "Testaufbau: keine Störung gebucht")
        while t.years < 15_000 { t.step(dtYears: 500) }
        XCTAssertEqual(t.disturb.max() ?? 0, 0,
            "Störungsfeld klingt nicht aus — der Pfad bliebe dauerhaft aktiv")
    }

    /// Vorher/Nachher: Regenerations-Pfad aus gegen ein (beide Male derselbe
    /// Eingriff über die echte Pinsel-API).
    func testDisturbanceSweepDiagnostic() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RS_SWEEP"] != nil,
                          "Sweep nur mit RS_SWEEP=1")
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

    /// Mäander-Zustand vor/nach dem Eingriff (Kalibrierung des Wächters).
    func testMeanderStateDiagnostic() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RS_SWEEP"] != nil, "nur mit RS_SWEEP=1")
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

    /// Zeitverlauf der gewählten Kalibrierung (Innenfläche).
    func testRegenerationTrajectoryDiagnostic() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RS_SWEEP"] != nil,
                          "Verlauf nur mit RS_SWEEP=1")
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
