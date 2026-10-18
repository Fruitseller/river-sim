import XCTest
@testable import SimCore

/// Wächter + Messreihe zum **Gletscher-Pass** (Issue #35): Eisfluss, glaziale
/// Erosion, Moränen und die Stilllegung der fluvialen Abtragspfade unter dem Eis
/// (`Terrain.updateIce`, Kalibrier-Logbuch bei `SimConfig.iceEnabled` ff.,
/// Modellwahl `docs/research-climate-cryosphere.md` §4/§5).
///
/// Die Abnahmekriterien des Tickets und ihre Wächter hier:
/// 1. Zungen fließen talwärts → `testTongueReachesBelowTheFirnLine`
/// 2. V→U-Kennzahl entwickelt sich → `testGlaciatedValleysWidenTowardsU`,
///    Messreihe `testValleyShapeSeriesDiagnostic`
/// 3. Moränen entstehen, Schichtbuchhaltung bleibt grün →
///    `testMoraineBuildsAtTheTongue`, `testLayersStayConsistent`
/// 4. unter Eis kein fluvialer Abtrag → `testNoFluvialErosionUnderIce`
///    (isoliert), `testNoFluvialErosionUnderIceInProduction` (mit den
///    Bett-Pässen Mäander und Braiding) und
///    `testNoFluvialErosionUnderIceOnTheGridPath` (Nicht-Droplet-Zweig);
///    die Gegenrichtung — unter der Schwelle rührt das EIS nichts an —
///    `testThinIceNeitherFlowsNorGrinds`
/// 5. dt-invariant, deterministisch → `testIceIsFramerateIndependent`,
///    `testThickIceTransportIsStableForLargeSteps`, `testIceIsDeterministic`
/// 6. abgeschaltet bit-identisch → `testDisabledIceIsBitIdentical`,
///    `testIcelessWorldIsBitIdentical`
final class Glacier: XCTestCase {

    /// n = 384 ist die Arbeitsauflösung dieser Suite. Kleiner geht nicht: die
    /// Gletscher hängen an der GIPFELHÖHE (nur über der Firn-Grenze h = 0.5731
    /// entsteht Eis), und die erodiert bei kleinem n schneller weg — bei n = 192
    /// liegt `maxH` nach 40k Jahren bei 0.585, bei n = 640 noch bei 0.624
    /// (`docs/glacier-measurements.md` §A). n = 384 hält den Abstand zur
    /// Firn-Grenze über 50k Jahre und ist noch schnell genug für Wächter.
    private func cfg(n: Int = 384) -> SimConfig {
        var c = SimConfig(); c.n = n; c.world = calibrationWorld
        c.rangeLandform = calibrationRangeLandform  // Großform vor #174
        c.meanderBelt = calibrationMeanderBelt      // Mäander-Mechanik vor #174
        c.iceFirnTemp = calibrationIceFirnTemp      // Firn-Grenze 0.5731 der alten Großform
        c.deltaTrapFraction = calibrationDeltaTrapFraction  // ohne Delta-Schüttung, s. dort

        c.pinIceBeforeAvalanche()  // Stand vor dem Lawinen-Abgang
        return c
    }

    /// Konfiguration, in der AUSSER dem Eis nichts das Gelände anfasst — der
    /// Aufbau des Gate-Wächters. Uplift ist in der Produktion ohnehin 0
    /// (`upliftPer100y`), der Relief-Servo greift bei diesem Relief nicht, und
    /// `wavePass` arbeitet nur im Küstenband, während das Eis im Hochland sitzt.
    private func quietCfg(n: Int = 384) -> SimConfig {
        var c = cfg(n: n)
        c.hillDiffusion = 0
        c.meanderEnabled = false
        c.braidingEnabled = false
        c.puddleFillYears = 0
        // Küstenerosion aus — dieselbe Begründung wie `hillDiffusion = 0` gleich
        // darüber (s. `testNoFluvialErosionUnderIceInProduction`): `wavePass` ist
        // kein fluvialer Pass, läuft deshalb ungegatet und schiebt Material vom
        // NACHBARN auf die Eiszelle. Bis Issue #108 fiel das nie auf, weil kein
        // Arm ihn in der Küstenzone auslöste; mit dem Abfluss-Dämpfer der
        // Tropfen-Deposition (#108) liegt das Sediment ein Stück weiter
        // flussabwärts, und im Wellenband trafen 2 vergletscherte Zellen
        // (h − sea = 0.044/0.047 < `waveBand` 0.06, Δh 9e-6 und 2e-4). Gegenprobe
        // gemessen: mit `waveRelax = 0` sind es 0 Zellen, mit abgeschaltetem
        // Dämpfer ebenfalls 0 — der Wächter hat also den Wellenpass gemessen,
        // nicht das Gate.
        c.waveRelax = 0
        return c
    }

    private func run(_ t: Terrain, to years: Double, dt: Double = 500) {
        while t.years < years { t.step(dtYears: dt) }
    }

    // MARK: - Kennzahlen

    struct IceStats {
        var land = 0
        var glacier = 0          // Zellen über `iceMinThickness`
        var fraction = 0.0       // Anteil am Land
        var maxThick = 0.0
        var meanThick = 0.0      // über die vergletscherten Zellen
        var lowest = 0.0         // niedrigste Höhe mit Eis
        var belowFirn = 0        // vergletscherte Zellen unter der Firn-Grenze
        var reach = 0.0          // Firn-Grenze − niedrigste Eis-Höhe
        var anyIce = 0           // Zellen mit ice > 0 (auch unter der Schwelle)
        var rawMax = 0.0         // größte Eisdicke überhaupt
        var maxH = 0.0

        var line: String {
            String(format: "Eis %5d (%.2f%%) | dick max %.4f mittel %.4f | roh %5d/%.4f | unter Firn %5d | Reichweite %.4f | maxH %.4f",
                   glacier, fraction * 100, maxThick, meanThick, anyIce, rawMax,
                   belowFirn, reach, maxH)
        }
    }

    /// Höhe der Firn-Grenze des Eises aus der Kalibrier-Formel (`T = T₀ − Γ(h−sea)`
    /// bei `T = iceFirnTemp`) — oberhalb davon wandelt sich Firn zu Eis
    /// (`iceFirnColdSpan` rampt darunter).
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

    // MARK: - V→U-Kennzahl

    /// **V→U-Kennzahl eines Talquerprofils**: der Exponent `b` der Anpassung
    /// `Δh(x) ∝ x^b` quer zur Fließrichtung, aus zwei Stützstellen
    /// (`halfWidth/2` und `halfWidth`):
    ///
    ///     b = log₂( Δh(W) / Δh(W/2) )
    ///
    /// Ein **Kerbtal (V)** hat gerade Flanken, `Δh ∝ x` → **b = 1**. Ein
    /// **Trogtal (U)** ist in erster Näherung parabolisch, `Δh ∝ x²` → **b = 2**.
    /// Das ist die in der Glazialgeomorphologie übliche Kennzahl (Potenzgesetz-Fit
    /// des Querprofils); sie braucht keine absolute Skala und ist gegen die
    /// Talgröße invariant.
    ///
    /// Gemessen quer zur Fließrichtung (die Achse, entlang der das Wasser NICHT
    /// läuft), gemittelt über beide Flanken. `nil`, wenn die Zelle keine Mulde
    /// ist (eine der beiden Flanken steigt nicht) — dann gibt es kein Querprofil
    /// zu vermessen.
    ///
    /// VERWORFEN: das Breitenverhältnis `W(2d)/W(d)` (V = 2, U = √2). Es braucht
    /// eine absolute Tiefe `d` und einen Suchlauf bis dorthin; auf den steilen
    /// Oberläufen, in denen die Gletscher sitzen, fand er auf einer der beiden
    /// Seiten regelmäßig gar keinen Anstieg um `2d` → die Stichprobe brach auf
    /// n = 1…22 zusammen (`docs/glacier-measurements.md` §D).
    static func shapeExponent(_ t: Terrain, at k: Int, halfWidth: Int = 6) -> Double? {
        let n = t.cfg.n
        let r = t.receiver[k]
        guard r >= 0, halfWidth >= 2 else { return nil }
        let i = k % n, j = k / n
        let ri = Int(r) % n, rj = Int(r) / n
        // Quer zur Fließrichtung: die Achse, entlang der das Wasser NICHT läuft.
        let alongX = abs(ri - i) >= abs(rj - j)
        let stepIdx = alongX ? n : 1          // quer = y, wenn der Fluss in x läuft
        let limit = alongX ? min(j, n - 1 - j) : min(i, n - 1 - i)
        guard limit >= halfWidth else { return nil }
        let h0 = t.h[k]
        let half = halfWidth / 2
        let dHalf = 0.5 * (t.h[k - half * stepIdx] + t.h[k + half * stepIdx]) - h0
        let dFull = 0.5 * (t.h[k - halfWidth * stepIdx] + t.h[k + halfWidth * stepIdx]) - h0
        // Keine Mulde (oder ein Profil, das nach außen wieder abfällt): kein Tal.
        guard dHalf > 1e-6, dFull > dHalf else { return nil }
        return log(dFull / dHalf) / log(Double(halfWidth) / Double(half))
    }


    /// Indizes der vergletscherten Zellen (die Stichprobe der V→U-Messung).
    /// Bewusst OHNE Einzugsgebiets-Filter: Gletscher sitzen im Oberlauf, wo die
    /// Einzugsgebiete klein sind — ein `area`-Gate hätte die Stichprobe auf
    /// Einzelzellen zusammengestrichen (gemessen: n = 1). Die Auswahl der
    /// TALBÖDEN erledigt `shapeExponent` selbst: eine Zelle, die keine Mulde
    /// ist, liefert `nil`.
    static func glacierCells(_ t: Terrain) -> [Int] {
        guard t.ice.count == t.cfg.count else { return [] }
        var out: [Int] = []
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea && t.ice[k] > t.cfg.iceMinThickness {
            out.append(k)
        }
        return out
    }

    /// Mittlerer Formexponent über eine feste Zellen-Liste.
    static func valleyShape(_ t: Terrain, cells: [Int],
                            halfWidth: Int = 6) -> (b: Double, count: Int) {
        var sum = 0.0, cnt = 0
        for k in cells {
            guard let r = shapeExponent(t, at: k, halfWidth: halfWidth) else { continue }
            sum += r; cnt += 1
        }
        return (cnt == 0 ? 0 : sum / Double(cnt), cnt)
    }

    /// **Gepaarter** V→U-Vergleich zweier Läufe auf denselben Zellen: gewertet
    /// wird nur, wo BEIDE Arme ein auswertbares Profil haben. Ohne die Paarung
    /// vergleicht man zwei verschiedene Stichproben — der eisfreie Arm hat mehr
    /// gültige Profile, und schon dieser Unterschied verschiebt den Mittelwert
    /// (gemessen: derselbe Referenzarm kam je nach Auswahl auf 1.496 … 2.008).
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

    // MARK: - Messreihe (Diagnose, keine Zusicherung)

    /// Wachstum und Reichweite des Eises über die Zeit — die Rohdaten für
    /// `docs/glacier-measurements.md` §B.
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

    /// Wie hoch bleibt die Insel ÜBERHAUPT? Die Firn-Grenze liegt fix bei
    /// `h = 0.5731`; wo `maxH` darunter fällt, kann es per Konstruktion kein Eis
    /// geben. Ohne Gletscher gerechnet (Referenzarm).
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

    /// Sweep über die Regler, die Dicke, Reichweite und Abtrag setzen.
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

    /// Sweep über die glaziale Erosionsrate — bei fixierter Eis-Masse. Die
    /// V→U-Kennzahl wird auf DENSELBEN Talstücken auch im eisfreien Referenzarm
    /// gemessen: nur die Differenz zeigt, was das Eis geformt hat (die absolute
    /// Zahl hängt an Talgröße und Stichprobe).
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

    /// **V→U über die ZEIT** auf einem FESTEN Zellensatz (die Zellen, die am Ende
    /// vergletschert sind), im Eis-Arm gegen den eisfreien Referenzarm mit
    /// demselben Seed. Erst die Differenz der beiden Verläufe trennt das Eis von
    /// der allgemeinen Alterung. Rohdaten für `docs/glacier-measurements.md` §D.
    func testValleyShapeSeriesDiagnostic() throws {
        try skipUnlessMeasuring()
        for (turnover, ero) in [(1000.0, 1e-4), (1000.0, 3e-4), (4000.0, 1e-4)] {
            var c = cfg(n: 384)
            c.iceTurnoverYears = turnover; c.iceErodeK = ero
            var off = c; off.iceEnabled = false
            let t = Terrain(config: c, seed: 1337)
            let ref = Terrain(config: off, seed: 1337)
            // Zellensatz EINMAL am Ende festlegen und rückwärts anwenden: dieselben
            // Talstücke über alle Zeitpunkte (ein je Zeitpunkt neu bestimmter Satz
            // würde Formänderung und Auswahländerung vermischen).
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

    /// V→U in der PRODUKTION (Issue #174, Nachkalibrierung der Firn-Grenze,
    /// `docs/glacier-measurements.md` §L): `SimConfig.production` mit dem Einlauf
    /// der Brücke, Eis-Arm gegen eisfreien Arm mit demselben Seed, gepaart auf
    /// den am Ende vergletscherten Zellen. Der Pflichtwächter
    /// (`testGlaciatedValleysWidenTowardsU`) läuft auf der gepinnten alten Welt;
    /// diese Messung zeigt, dass die Produktions-Welt dieselbe Richtung geht.
    /// Produktionszellen sind kleiner (0,156 statt 0,34 Welteinheiten), deshalb
    /// mehrere Halbbreiten.
    ///
    ///     RS_MEASURE=1 RS_SEEDS=1337,20 RS_YEARS=10000,20000,30000 \
    ///         swift test … --filter testGlacierProductionValleyDiagnostic
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
                print(row); fflush(stdout)
                // Aufteilung der vergletscherten Zellen (Issue #174, §M): unter der
                // Firn-Grenze (Zungen, Talgletscher), darüber (Kare, Nährgebiet)
                // und nach Eisdicke — wo das V→U-Signal sitzt.
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
                print(split); fflush(stdout)
            }
        } }
    }

    /// **Wächter: die Talgletscher der PRODUKTION schleifen einen Trog** (Issue #174,
    /// `docs/glacier-measurements.md` §M). `testGlaciatedValleysWidenTowardsU`
    /// misst auf der gepinnten alten Welt; hier dieselbe Kennzahl (gepaarter
    /// Formexponent `b`, Eis-Arm gegen eisfreien Arm auf den am Ende vergletscherten
    /// Zellen) in der Produktion, gepoolt über drei Seeds, 20.000 Jahre, dt 1000.
    /// Mit dem Lawinen-Abgang und der alten Schleifspur (2 Zellen, auf die
    /// Zellgröße 0,34 geeicht, in der Produktion mit 0,156 nur die halbe Breite)
    /// war das Signal weg (Zellen unter der Firn-Grenze Δb −0,12 … 0,00 statt
    /// +0,2); mit 4 Zellen gemessen Δb W 6 / 10 / 14 gepoolt +0,05 / +0,14 / +0,06
    /// (Mac) bzw. +0,07 / +0,14 / +0,12 (Linux). Schranken weit darunter.
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

    /// Verhältnis **Moräne zu glazialem Abtrag**: wie viel von dem, was das Eis
    /// abträgt, legt es als Ausschmelz-Schutt wieder ab? Gemessen über EINEN
    /// Schritt aus DEMSELBEN Zustand in drei Armen (nichts / nur Abtrag / nur
    /// Moräne), damit die Differenzen genau die beiden Terme isolieren.
    /// Rohdaten für `docs/glacier-measurements.md` §F.
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

    /// Rechenzeit des Gletscher-Passes: Schrittzeit mit gegen ohne Eis, für den
    /// Frame-Fall (dt klein) und den `+10.000 Jahre`-Sprung. Rohdaten für
    /// `docs/glacier-measurements.md` §E.
    func testIcePassCostDiagnostic() throws {
        try skipUnlessMeasuring()
        for n in [384, 640] {
            let on = cfg(n: n)
            var off = on; off.iceEnabled = false
            // EINMAL Eis aufbauen und den Zustand danach je Messung
            // zurückspielen (Zustands-Inventar, Issue #8) — sonst kostet der
            // Vorlauf je Schrittweite erneut 20.000 Jahre.
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

    // MARK: - Abnahme 1: die Zunge fließt talwärts

    /// Es gibt Eis, es liegt UNTER der Firn-Grenze (also dort, wo es nicht
    /// entstehen kann — es muss hingeflossen sein), und die Zunge wächst über die
    /// Zeit. Das ist der Kern des Tickets: ohne Transport hätte das Eisfeld genau
    /// die Form seiner Massenbilanz und läge vollständig oberhalb der Grenze.
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

        // AUFBAU: die Zunge wächst in die Landschaft hinein.
        XCTAssertGreaterThan(peak.belowFirn, early.belowFirn,
                             "die Zunge wächst nicht: \(early.belowFirn) → \(peak.belowFirn)")
        // BESTAND: sie ist auch nach 30k Jahren da. Dass sie bis dahin wieder
        // schrumpft, ist kein Fehler, sondern die alternde Insel: `maxH` sinkt
        // (0.726 → 0.625 bei n = 384), das Nährgebiet über der Firn-Grenze wird
        // kleiner — und die glaziale Erosion sägt zusätzlich daran (Buzzsaw,
        // s. `SimConfig.iceErodeK`). Messreihe §B.
        XCTAssertGreaterThan(late.glacier, 200, "kaum Eis übrig")
        XCTAssertGreaterThan(late.belowFirn, 50,
                             "keine Zunge unter der Firn-Grenze \(firn) — das Eis fließt nicht")
        XCTAssertGreaterThan(late.reach, 0.02,
                             "Reichweite unter die Firn-Grenze zu klein: \(late.reach)")
        // Und das Eis liegt nicht nur als Hauch da: die Zunge ist mächtig.
        XCTAssertGreaterThan(late.maxThick, 0.02, "das Eis bleibt hauchdünn")
    }

    /// Ohne Transport (`iceFlowK = 0`) bleibt das Eis in seinem Nährgebiet: der
    /// Gegentest zu oben, der zeigt, dass die Reichweite AM FLIESSEN hängt und
    /// nicht an der Bilanz. Denn oberhalb der Firn-Grenze ist die Zufuhr exakt 0
    /// (`f_kalt = clamp(−T/span, 0, 1)`), das Eis dort unten kann also nur
    /// hingeflossen sein.
    func testWithoutFlowThereIsNoTongue() {
        // In BEIDEN Armen ohne glaziale Erosion: sonst senkt der Abtrag das Bett
        // unter schon liegendem Eis unter die Firn-Grenze, und der Wächter zählt
        // eine gesunkene Zelle als geflossenes Eis (gemessen: 180 solcher Zellen).
        var flowing = cfg(n: 256); flowing.iceErodeK = 0
        var still = flowing; still.iceFlowK = 0
        let a = Terrain(config: still, seed: 1337)
        let b = Terrain(config: flowing, seed: 1337)
        run(a, to: 10_000); run(b, to: 10_000)
        XCTAssertGreaterThan(a.ice.max() ?? 0, still.iceMinThickness, "Testaufbau: gar kein Eis")
        let stillBelow = Glacier.iceStats(a).belowFirn
        let flowBelow = Glacier.iceStats(b).belowFirn
        // Nicht exakt 0, und das ist kein Widerspruch: das BETT sinkt weiter
        // (Hangdiffusion und Hebung sind nicht gegatet, und am dünnen Saum unter
        // `iceMinThickness` auch die fluvialen Pässe), eine Zelle rutscht also
        // unter die Firn-Grenze, ohne dass Eis geflossen wäre — gemessen 63 von
        // 968. Kriterium ist deshalb der VERGLEICH, nicht die Null.
        XCTAssertGreaterThan(flowBelow, 5 * max(1, stillBelow),
                             "der Transport bringt kaum mehr Eis unter die Grenze: "
                             + "\(flowBelow) gegen \(stillBelow)")
    }

    // MARK: - Abnahme 2: V→U

    /// Die vergletscherten Talstücke sind nach 30k und 50k Jahren MESSBAR
    /// parabolischer (Formexponent `b` näher an 2) als DIESELBEN Talstücke im
    /// eisfreien Referenzlauf mit demselben Seed. Rohdaten und die Zeitreihe:
    /// `docs/glacier-measurements.md` §D.
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
            XCTAssertGreaterThan(p.a, p.b + 0.1,
                                 "V→U bleibt aus (\(years) J.): b \(p.a) gegen \(p.b) ohne Eis")
            print(String(format: "%.0fk J.: b %.3f (Eis) gegen %.3f (ohne) → Δ %+.3f  n=%d",
                         years / 1000, p.a, p.b, p.a - p.b, p.count))
        }
    }

    // MARK: - Abnahme 3: Moränen und Schichtbuchhaltung

    /// Der Ausschmelz-Schutt landet dort, wo das Eis SCHMILZT — also im
    /// Zehrgebiet und nicht unter dem Nährgebiet.
    ///
    /// Gemessen als Differenz zweier Arme über EINEN Schritt aus DEMSELBEN
    /// Zustand (der zweite Arm wird über das Zustands-Inventar aus dem ersten
    /// gefüllt). Zwei getrennt gelaufene Arme taugen dafür nicht: nach 30k Jahren
    /// sind sie überall auseinander, und die Differenz misst dann Chaos statt
    /// Moräne (gemessen: Summe über das Nährgebiet 1.02 statt 0).
    func testMoraineBuildsAtTheTongue() {
        var on = quietCfg(n: 256)
        on.iceErodeK = 0                 // isoliert: nur ablagern, nicht abtragen
        var off = on; off.iceMoraineK = 0
        let a = Terrain(config: on, seed: 1337)
        run(a, to: 20_000)
        let b = Terrain(allocating: off, seed: 1337)
        b.restore(a.state)
        let before = a.h
        // Die Temperatur VOR dem Schritt: `updateClimate` läuft am Schrittende
        // auf den dann FINALEN Höhen, eine Zelle kann also zwischen Moränen-Ablage
        // und Messung über die 0-°C-Grenze wandern (gemessen: 1.1e-4 „Schutt im
        // Nährgebiet", der in Wahrheit im Zehrgebiet lag).
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
        // Und der Schutt liegt als SEDIMENT auf, nicht als Fels.
        XCTAssertGreaterThan(a.sed.reduce(0, +), b.sed.reduce(0, +),
                             "die Moräne wurde nicht als Sediment gebucht")
    }

    /// `h == rock + sed` — die Schichtbuchhaltung, die BEIDE Eingriffe des
    /// Gletschers respektieren müssen (Abrasion nimmt erst Sediment, dann Fels;
    /// die Moräne legt Sediment auf).
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

    // MARK: - Abnahme 4: unter Eis kein fluvialer Abtrag

    /// Der Wächter ohne die konkurrierenden Bett-Pässe: hier arbeiten NUR
    /// Auslass-Inzision und Tropfen, die beiden Pfade, die `underIce` seit jeher
    /// gatet. Der Arm isoliert damit genau diese zwei.
    func testNoFluvialErosionUnderIce() {
        assertNoFluvialErosionUnderIce(quietCfg())
    }

    /// Derselbe Wächter mit den BETT-PÄSSEN DER PRODUKTION: `meanderEnabled`
    /// und `braidingEnabled` stehen wie in `SimConfig()` auf `true`. Nötig, weil
    /// `quietCfg()` beide abschaltet und der Wächter oben damit eine
    /// Konfiguration prüft, die es in Produktion nicht gibt: `meanderStamp`
    /// carvt sein Bett selbst und `braidPass` bewegt Bettmaterial — beide folgen
    /// denselben Tälern, in die die Zungen vorstoßen. Ungegatet bekam dasselbe
    /// Tal unter dem Eis weiter fluviale Kerb-Carves (gemessen 9 Zellen in EINEM
    /// Schritt: Bett-Carve 3, laterale Ufer 6, Braid-Fracht 1 —
    /// `docs/glacier-measurements.md` §I).
    ///
    /// Die Hangdiffusion bleibt dabei aus (`quietCfg`), und das ist der Punkt
    /// des Aufbaus: Bodenkriechen ist kein fluvialer Pass, trägt aber die
    /// Änderungen der NACHBARZELLEN auf die Eiszelle. Mit `hillDiffusion` an
    /// weichen 852 vergletscherte Zellen ab — davon 825 allein aus
    /// `outletErode`, das laut derselben Messreihe keine einzige Eiszelle
    /// anfasst (§I.1). Der Wächter würde dann die Diffusion messen statt das
    /// Gate.
    func testNoFluvialErosionUnderIceInProduction() {
        var c = quietCfg()
        c.meanderEnabled = true
        c.braidingEnabled = true
        assertNoFluvialErosionUnderIce(c)
    }

    /// Derselbe Wächter für den **Grid-Pfad** (`hydraulicEnabled = false`), den
    /// die isolierten Mäander- und Becken-Tests fahren: dort ersetzt
    /// `transportLimited` die Tropfen und bewegt Bettmaterial an eigenen
    /// Stellen (Delta am Meer, Ablagerung über Kapazität, Inzision darunter).
    /// Ungegatet bewegte er im Messlauf JEDE vergletscherte Zelle in EINEM
    /// Aufruf (651 von 651) — mehr als jeder andere Bett-Pass, weil er
    /// flächendeckend über `order` läuft statt entlang der Läufe. Mit Gate: 0,
    /// und das Eis hält doppelt so viel Fläche (1385 Zellen), weil ihm der
    /// Grid-Pfad 20k Jahre lang nicht mehr das Bett unter der Zunge abträgt
    /// (`docs/glacier-measurements.md` §I.2).
    ///
    /// Aufbau anders als bei den zwei Armen oben: der Grid-Pfad läuft in
    /// `step()` fest mit `diffusionPass` zusammen (kappa ist dort ein Default,
    /// kein Regler), und das Bodenkriechen würde die Änderungen der
    /// Nachbarzellen im SELBEN Schritt auf die Eiszelle tragen — der Vergleich
    /// zweier Arme über `step()` misst dann die Diffusion statt das Gate
    /// (§I.1). Deshalb: einen Zustand mit Eis auslaufen lassen und den Pass
    /// danach EINZELN aufrufen.
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

    /// Zwei Arme, die sich NUR im fluvialen Abtrag unterscheiden:
    /// * `gated` — Produktionspfad (die Gletscher-Maske gatet die fluvialen
    ///   Bett-Pässe),
    /// * `noFluvial` — dieselbe Config, aber jede fluviale Bett-RATE steht auf 0.
    ///   Bewusst über die Raten und nicht über die `…Enabled`-Schalter: so laufen
    ///   in beiden Armen dieselben Pässe mit derselben Reihenfolge, demselben
    ///   MFD-Takt und demselben Mäander-Zustand — der einzige Unterschied ist,
    ///   dass in `noFluvial` nichts davon `h` anfasst.
    /// Auf den vergletscherten Zellen müssen beide BIT-IDENTISCH sein: wenn das
    /// Gate hält, hat dort ohnehin kein fluvialer Pass gearbeitet. Zugleich muss
    /// es abseits des Eises einen Unterschied geben — sonst prüft der Test nichts.
    private func assertNoFluvialErosionUnderIce(_ base: SimConfig,
                                                file: StaticString = #filePath,
                                                line: UInt = #line) {
        var gated = base
        gated.iceErodeK = 0; gated.iceMoraineK = 0   // das Eis selbst darf `h` nicht anfassen
        var noFluvial = gated
        noFluvial.outletErode = 0
        noFluvial.hydraulicPerYear = 0
        // Mäander-Bett-Carve, laterale Ufer und Braid-Fracht (in `quietCfg()`
        // ohnehin aus, in Produktion die dritte und vierte Bett-Bewegung).
        // `braidCapacity = 0` legt `braidPass` still, OHNE `braidingEnabled` zu
        // kippen: die Fracht `qs` bleibt überall 0, also deponiert und scourt
        // nichts — und der MFD-Takt in `step()` bleibt derselbe wie im
        // Vergleichsarm.
        noFluvial.meanderCarve = 0
        noFluvial.meanderBankErode = 0
        noFluvial.braidCapacity = 0

        let a = Terrain(config: gated, seed: 1337)
        run(a, to: 20_000)
        // EIN Schritt aus DEMSELBEN Zustand: der Vergleichsarm wird über das
        // Zustands-Inventar (Issue #8) aus `a` gefüllt. Zwei getrennt gelaufene
        // Arme wären nach 20k Jahren überall auseinander und der Wächter
        // verglichen zwei Landschaften statt zwei Physiken.
        let b = Terrain(allocating: noFluvial, seed: 1337)
        b.restore(a.state)
        let before = a.h
        a.step(dtYears: 500)
        b.step(dtYears: 500)
        // Die MASKE DIESES SCHRITTS: `updateIce` läuft am Schrittanfang und baut
        // sie neu, und genau diese neue Maske haben die fluvialen Pässe
        // danach gesehen. Die Maske von VOR dem Schritt wäre veraltet — Zellen,
        // die das Eis in diesem Schritt verlassen hat, sind zu Recht wieder
        // fluvial (gemessen: 6 solche Zellen).
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
        // Dass sich `h` unter dem Eis trotzdem BEWEGT, ist kein Widerspruch: die
        // Hebung bzw. der Relief-Servo (`applyUplift`) greifen flächendeckend und
        // sind kein fluvialer Abtrag. Gemessen bewegen sie hier 4031 der
        // vergletscherten Zellen — in BEIDEN Armen gleich, deshalb bleibt die
        // Bit-Gleichheit oben die richtige Zusicherung.
        _ = before
    }

    /// **Eine Schwelle für alles**: unterhalb `iceMinThickness` fließt kein Eis
    /// und schleift auch keines — dieselbe Grenze, ab der `underIce` die
    /// fluvialen Pässe wieder zulässt. Ohne diese Kopplung arbeiteten am dünnen
    /// Saum BEIDE Erosionsgesetze gleichzeitig am selben Bett (PR-Review zu #35:
    /// `iceFlowSubStep` gatete den Ausstrom an `ice > 0` und die Abrasion an
    /// `i0 > 0`, während die fluvialen Gates erst über der Schwelle greifen).
    ///
    /// Geprüft als ÄQUIVALENZ zweier Arme über EINEN Schritt aus DEMSELBEN
    /// Zustand: eine Schwelle oberhalb der größten Eisdicke muss dasselbe
    /// liefern wie „Transport-Deckel 0 + `iceErodeK = 0`". Der Vergleichsarm
    /// stellt bewusst `iceFlowMoveFraction` auf 0 statt `iceFlowK` — Letzteres
    /// änderte über `totalK` auch die Zahl der Teilschritte, und die Bilanz
    /// relaxierte dann in anderen Häppchen (bit-gleich wäre sie nur in exakter
    /// Arithmetik).
    ///
    /// Die BILANZ läuft in beiden Armen weiter (Zufuhr, Schmelze, Moräne): ein
    /// Schneefeld muss über die Schwelle wachsen können, sonst entstünde nie
    /// ein Gletscher. Deshalb ist die Zusicherung „kein Transport, keine
    /// Abrasion" und nicht „das Eis ist eingefroren".
    func testThinIceNeitherFlowsNorGrinds() {
        var base = quietCfg(n: 256)
        base.hydraulicPerYear = 0     // nur das Eis darf `h` anfassen — sonst
        base.outletErode = 0          // misst der Vergleich den fluvialen Abtrag
        let t = Terrain(config: base, seed: 1337)
        run(t, to: 20_000)
        let thickest = t.ice.max() ?? 0
        XCTAssertGreaterThan(thickest, base.iceMinThickness, "Testaufbau: gar kein Eis")
        // Der dünne Saum ist in Produktion nicht leer — sonst prüfte der Wächter
        // eine Zone, die es gar nicht gibt.
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
        // Gegenprobe: mit der PRODUKTIONS-Schwelle tun Transport und Abrasion in
        // genau diesem Zustand sehr wohl etwas — der Vergleich oben ist also
        // keine Aussage über einen stillstehenden Gletscher.
        var active = 0
        for k in 0..<base.count where c.h[k].bitPattern != a.h[k].bitPattern { active += 1 }
        print("[SCHWELLE] geflossen \(iceDiff), geschliffen \(bedDiff), "
              + "über der Schwelle bewegt \(active)")
        XCTAssertGreaterThan(active, 100,
                             "Testaufbau: der Gletscher war auch über der Schwelle untätig")
    }

    // MARK: - Abnahme 5: dt-Invarianz und Determinismus

    /// Gleiche Simulationszeit, verschiedene Schrittweiten → dasselbe Eis UND
    /// derselbe Gletscherschliff. Aus EINEM Zustand (Jahr 5000, volle Physik)
    /// laufen 1000 Jahre einmal als ein Schritt (Sprung), als 10 × 100 und als
    /// 64 × 15,625 (Zeitraffer-Takt), auf drei Seeds.
    ///
    /// Warum Schrittpaare statt langer Läufe (der Wächter bis Issue #174): über
    /// 20.000 Jahre laufen zwei Schrittweiten auch ohne jeden Fehler
    /// auseinander (Tropfen-Splitting, `docs/dt-invariance-measurements.md` §5),
    /// und die Eismasse hängt an der Gipfelhöhe über der Firn-Grenze — sie
    /// verstärkt jede Abweichung im Relief. Der alte Wächter musste deshalb
    /// 15 % zulassen und lag auf seiner Welt zufällig in einem ruhigen Bereich,
    /// während die Produktion um Faktor 2,5 auseinanderlief. EIN Abschnitt aus
    /// demselben Zustand kann nicht chaotisch divergieren: was hier abweicht,
    /// ist Operator-Splitting im Eis-Pfad selbst, auf jedem Seed gleichsinnig.
    ///
    /// Und warum `cfg` statt `quietCfg`: zwei der drei Ursachen lagen in der
    /// Kopplung an den Rest des Schritts (die Pfützen-Verlandung füllte den
    /// Schliff wieder auf, die Temperatur stand auf dem Schrittanfang);
    /// `quietCfg` schaltet die Verlandung ab und hätte sie nie gesehen.
    ///
    /// Gemessen (`docs/glacier-measurements.md` §L, n = 256, Jahr 5000, Spanne
    /// über die drei Arme): vor dem Fix Absenkung 51–76 %, Masse 3,2–4,7 % —
    /// der Sprung schliff nur 25–50 % dessen, was der Zeitraffer schliff;
    /// danach Absenkung 2,0–3,7 %, Masse 0,5–1,7 %. Die Schranken liegen
    /// dazwischen.
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

    /// **Lawinen-Abgang erhält die Firn-Zufuhr** (Issue #174, §M): auf einer
    /// steilen Rampe mit ebenem Fuß, überall kalt genug für volle Umwandlung
    /// (gleiche Rate μ in jeder Zelle), liegt ohne Abgang die Zufuhr in der
    /// Rampe, mit Abgang am Fuß — die GESAMTE Eismasse bleibt gleich (kein Fluss,
    /// keine Erosion, keine Schmelze). Prüft damit Quelle −/Ziel + und die
    /// Zurücksetzung des Scratch zwischen den Aufrufen.
    func testAvalancheMovesFirnSupplyWithoutLosingIt() {
        func massSplit(_ hi: Double) -> (ramp: Double, foot: Double) {
            var c = cfg(n: 96)
            c.world = 0.156 * 95                       // Produktions-Zellgröße
            c.iceFlowK = 0; c.iceErodeK = 0; c.iceMoraineK = 0
            c.iceAvalancheSlopeLo = 1.0; c.iceAvalancheSlopeHi = hi
            var st = Terrain(config: c, seed: 1337).state
            let nn = c.n
            for j in 0..<nn { for i in 0..<nn {
                let k = j * nn + i
                let bed = c.sea + 0.9 - 0.0105 * Double(min(i, 30))   // Rampe i < 30 (Weltsteigung ≈ 1,6), dann eben; Fuß bei T ≈ −4 °C
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

    /// Schrittpaar in der PRODUKTION mit Lawinen-Abgang (der Wächter
    /// `testIceIsFramerateIndependent` läuft auf der alten Welt ohne Abgang):
    /// 1000 Jahre ab Jahr 5000 als 1 × 1000, 10 × 100 und 64 × 15,625.
    /// Gemessen (Jahr 5000 und 15.000, drei Seeds): Masse 0,5 … 0,8 %, Fläche
    /// 0,3 … 0,5 % (ohne Abgang Masse 0,5 … 1,3 %, Fläche 0,06 … 0,6 %;
    /// `docs/glacier-measurements.md` §M).
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

    /// Nach einem Weltwechsel müssen neue Firnquellen den Arbeitsbereich
    /// aufspannen. Alte Scratch-Raten dürfen am kleineren oder verschobenen
    /// Rand keinen Zufluss erzeugen. Vergleich gegen jeweils frische Puffer.
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

    /// Dickes Eis auf flachem Bett: der Fall, in dem der Transport bis Issue
    /// #174 instabil lief. Die Sub-Taktung richtete sich nur nach dem
    /// steilsten Oberflächen-Abfall; auf einer fast ebenen Eisplatte ist der
    /// klein, also lief EIN Teilschritt mit `kappa·I` weit über 1/4, und der
    /// Schachbrett-Modus der Oberfläche wuchs je Teilschritt um `|1 − 8·kappa·I|`.
    /// In der Produktion schliff das aufgeschaukelte Gefälle bei dt = 1000 im
    /// Mittel 0,065 unter dem Eis in einem Schritt (§L).
    ///
    /// Aufbau ohne Welt-Realisierung: n = 64, ebenes Bett über der Firn-Grenze,
    /// 1.0 Eis mit einem Schachbrett-Muster von ±0.001, keine Zufuhr, keine
    /// Erosion. 2000 Jahre als EIN Aufruf gegen 20 × 100: die Felder müssen
    /// übereinstimmen, und das Muster muss abklingen statt wachsen.
    func testThickIceTransportIsStableForLargeSteps() {
        var c = cfg(n: 64)
        c.iceErodeK = 0; c.iceMoraineK = 0
        var s = Terrain(config: c, seed: 1337).state
        let nn = c.n
        let bed = c.sea + 0.6                         // T = −4,6 °C: keine Schmelze
        func sign(_ k: Int) -> Double { ((k % nn) + (k / nn)) % 2 == 0 ? 1 : -1 }
        for k in 0..<c.count {
            s.h[k] = bed; s.rock[k] = bed; s.sed[k] = 0
            s.ice[k] = 1.0 + 0.001 * sign(k)
            s.snow[k] = 0
        }
        // Größte Abweichung vom Mittel: die Platte startet mit ±0.001 und muss
        // glatter werden, nicht rauer.
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

    /// Ein Arm des Schrittweiten-Vergleichs: `span` Jahre aus DEMSELBEN Zustand
    /// in Schritten à `dt`, danach Eismasse, vergletscherte Zellen und die
    /// mittlere Bett-Absenkung unter dem Eis des Ausgangszustands.
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

    /// Größte relative Abweichung einer Kennzahl über die Arme.
    static func spread(_ v: [Double]) -> Double {
        let lo = v.min()!, hi = v.max()!
        return (hi - lo) / max(abs(lo), abs(hi), 1e-12)
    }

    /// Schrittpaar-Messung: aus EINEM Zustand 1000 Jahre als 1 × 1000,
    /// 10 × 100 und 64 × 15,625 (Zeitraffer-Takt) — für die Wahl des Aufbaus
    /// von `testIceIsFramerateIndependent` (`docs/glacier-measurements.md` §L).
    ///
    ///     RS_MEASURE=1 RS_GRID=256 RS_SEED=1337,42,20 RS_START=5000 swift test …
    ///         --filter testIceStepPairDiagnostic
    ///
    /// `RS_GRID=prod` misst auf `SimConfig.production` mit Einlauf,
    /// `RS_VARIANTS="base;hill=0;uplift=0"` wiederholt die Arme mit Ablationen
    /// (nur die drei Arme, der Vorlauf bleibt Produktion).
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

    /// Config-Variante für die Ablationen der Schrittpaar-Messung:
    /// `hill=0,hyd=0` usw., `base` ist die unveränderte Config.
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

    /// Eismasse und -fläche in der PRODUKTION (`SimConfig.production` mit dem
    /// Einlauf der Brücke) über lange Läufe in verschiedenen Schrittweiten —
    /// die Tabelle in `docs/glacier-measurements.md` §L.
    ///
    ///     RS_MEASURE=1 RS_SEED=1337 RS_DTS=15,100,1000 RS_YEARS=20000,100000 \
    ///         swift test -c release --package-path SimCore \
    ///         -Xswiftc -swift-version -Xswiftc 5 --filter testIceDtSweepDiagnostic
    ///
    /// Die Läufe sind unabhängig und lassen sich je Seed/dt parallel starten.
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

    /// `dt = 0` (Sculpt-Pfad) darf die Eisbilanz nicht um ein ULP verschieben —
    /// dieselbe Zusicherung wie bei der Schneedecke.
    func testZeroStepLeavesIceUntouched() {
        let t = Terrain(config: cfg(n: 192), seed: 1337)
        run(t, to: 10_000)
        let before = t.ice
        t.updateIce(dt: 0)
        XCTAssertEqual(before, t.ice, "ein zeitloser Aufruf hat das Eisfeld verändert")
    }

    /// Gleicher Seed → bit-gleiches Eisfeld (die getestete Invariante des
    /// Projekts, hier für den parallelen Zwei-Phasen-Pass).
    func testIceIsDeterministic() {
        let a = Terrain(config: cfg(n: 256), seed: 1337)
        let b = Terrain(config: cfg(n: 256), seed: 1337)
        run(a, to: 20_000)
        // Andere Schritt-STÜCKELUNG darf nicht bit-gleich sein — das prüft
        // `testIceIsFramerateIndependent` mit Schranken. Hier dieselbe Taktung.
        run(b, to: 20_000)
        XCTAssertEqual(a.ice, b.ice, "Eisfeld nicht reproduzierbar")
        XCTAssertEqual(a.h, b.h, "Gelände nicht reproduzierbar")
        XCTAssertEqual(a.underIce, b.underIce, "Eismaske nicht reproduzierbar")
    }

    // MARK: - Abnahme 6: abgeschaltet bit-identisch

    /// `iceEnabled = false`: kein Eis, keine Maske — und damit fallen BEIDE Gates
    /// und der ganze Pass weg. Der Test prüft genau die Vorbedingungen dieser
    /// Bit-Identität (dass `underIce` leer bleibt, ist die Bedingung, unter der
    /// `outletIncision` und `Hydraulic.erode` ihre Gletscher-Zweige gar nicht
    /// erst betreten).
    func testDisabledIceIsBitIdentical() {
        var off = cfg(n: 192); off.iceEnabled = false
        let t = Terrain(config: off, seed: 1337)
        run(t, to: 20_000)
        XCTAssertTrue(t.underIce.isEmpty, "abgeschaltet ist die Eismaske nicht leer")
        XCTAssertEqual(t.ice.count, off.count, "das Eisfeld soll trotzdem existieren (#33)")
        XCTAssertEqual(t.ice.max(), 0, "abgeschaltet ist das Eisfeld nicht konstant 0")
    }

    /// Eine Welt, die NIE Eis bekommt (Meeresspiegel-Temperatur so hoch, dass
    /// keine Zelle unter 0 °C liegt), rechnet mit und ohne Gletscher-Pass
    /// BIT-IDENTISCH. Das ist der harte Aus-Wächter: er prüft den
    /// Schnell-Ausstieg des Passes an der scharfen Kante, an der er greift.
    func testIcelessWorldIsBitIdentical() {
        var warm = cfg(n: 192)
        warm.climateSeaLevelTemp = 40      // 0-°C-Isotherme weit über dem Gipfel
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

    /// Die Färbung hat EINE Quelle (dieselbe Doktrin wie `snowCoverage`):
    /// `SimRender.TerrainColorRenderer` ruft `Terrain.iceCoverage` über den
    /// rohen Puffer auf, statt die Formel ein zweites Mal hinzuschreiben.
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
        // Ohne Klima ist die Eis-Deckung exakt 0 → der Renderer malt nur Schnee.
        var off = c; off.climateEnabled = false
        let cold = Terrain(config: off, seed: 1337)
        XCTAssertEqual(cold.iceCover(0), 0, "ohne Klima ist die Eis-Deckung nicht 0")
    }

    // MARK: - Langzeit-Wächter

    /// Über sehr lange Läufe darf weder das Eis noch das Relief entgleisen —
    /// dieselbe Invariante wie `LongRunCollapse`, hier mit dem Gletscher an
    /// Bord. Der Deckel für das Eis ist die Konstruktion selbst
    /// (`iceFirnPerSnowYear · snow · iceTurnoverYears`, s. dort).
    func testLongRunIceStaysBounded() {
        let c = cfg(n: 192)
        let t = Terrain(config: c, seed: 1337)
        let bound = c.iceFirnPerSnowYear * c.iceTurnoverYears   // snow ≤ 1.0
        var seen = 0.0
        while t.years < 200_000 {
            t.step(dtYears: 2000)
            let maxIce = t.ice.max() ?? 0
            seen = max(seen, maxIce)
            XCTAssertLessThanOrEqual(maxIce, bound + 1e-9,
                                     "Eisdicke über der Konstruktions-Grenze bei \(t.years) J.")
            XCTAssertFalse(maxIce.isNaN, "NaN im Eisfeld bei \(t.years) J.")
        }
        // ZUSÄTZLICH empirisch: die Konstruktions-Grenze (4.0) ist so weit weg,
        // dass sie ein Entgleisen erst merkte, wenn das Eis das ganze Relief
        // überragt. Gemessen bleibt das Maximum unter 0.3 (§B) — 1.0 lässt
        // reichlich Luft für andere Seeds und fängt trotzdem jedes Weglaufen.
        XCTAssertLessThan(seen, 2.0, "Eisdicke läuft weg (max \(seen))")
        print(String(format: "200k Jahre, n=%d: größte Eisdicke %.4f", c.n, seen))
        XCTAssertLessThan(t.landReliefRobust(), 1.0, "Relief entgleist")
        var worst = 0.0
        for k in 0..<c.count { worst = max(worst, abs(t.h[k] - (t.rock[k] + t.sed[k]))) }
        XCTAssertLessThan(worst, 1e-9, "Schichtbuchhaltung nach 200k Jahren kaputt")
    }

    /// Regression: Schliff ohne Schrittweite (`cellSize == 0`, hier n = 3 mit
    /// `world = 0`). Ohne den `cs > 0`-Guard in `iceFlowSubStep` wurde das
    /// Gefälle `w / cs` unendlich und mit ihm die Schliff-Rate; das Bett fiel
    /// dann um den vollen Teilschritt-Deckel. Jetzt schleift das Eis nicht:
    /// das Bett ist bit-gleich zum Arm ganz ohne Erosion (`iceErodeK = 0`).
    /// Ein 1×1-Gitter erreicht den Pfad nicht — am gespiegelten Rand ist das
    /// Gefälle 0 und die Zelle eine Mulde —, deshalb n = 3. `iceEro` ist
    /// `private`; geprüft wird seine einzige Wirkung, das Bett.
    func testIceWithoutCellSpacingDoesNotGrind() {
        func bedAfterIce(erodeK: Double) -> [Double] {
            var c = SimConfig()
            c.n = 3; c.world = 0
            c.iceErodeK = erodeK
            XCTAssertEqual(c.cellSize, 0.0)
            let t = Terrain(allocating: c, seed: 1)
            var s = t.state
            // Gipfel mit Eis in der Mitte, Land ringsum, überall Frost (keine
            // Schmelze, also keine Moräne, die das Bett ebenfalls anfasst).
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
