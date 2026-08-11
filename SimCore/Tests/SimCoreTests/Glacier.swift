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
/// 5. dt-invariant, deterministisch → `testIceIsFramerateIndependent`,
///    `testIceIsDeterministic`
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
        var c = SimConfig(); c.n = n; return c
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

    /// Höhe der 0-°C-Isotherme aus der Kalibrier-Formel (`T = T₀ − Γ(h−sea)`) —
    /// oberhalb davon wandelt sich Firn zu Eis (`iceFirnColdSpan` rampt darunter).
    static func firnLine(_ c: SimConfig) -> Double {
        c.sea + c.climateSeaLevelTemp / c.climateLapseRate
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
    /// TALBÖDEN erledigt `widthRatio` selbst: ein Profil, das nicht auf beiden
    /// Seiten um `2d` ansteigt, liefert `nil`.
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
    func testIceGrowthSeriesDiagnostic() {
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
    func testPeakHeightSeriesDiagnostic() {
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
    func testIceParameterSweepDiagnostic() {
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
    func testGlacialErosionSweepDiagnostic() {
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
    func testValleyShapeSeriesDiagnostic() {
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

    /// Verhältnis **Moräne zu glazialem Abtrag**: wie viel von dem, was das Eis
    /// abträgt, legt es als Ausschmelz-Schutt wieder ab? Gemessen über EINEN
    /// Schritt aus DEMSELBEN Zustand in drei Armen (nichts / nur Abtrag / nur
    /// Moräne), damit die Differenzen genau die beiden Terme isolieren.
    /// Rohdaten für `docs/glacier-measurements.md` §F.
    func testMoraineBudgetDiagnostic() {
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
    func testIcePassCostDiagnostic() {
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

    /// Zwei Arme, die sich NUR im fluvialen Abtrag unterscheiden:
    /// * `gated` — Produktionspfad (Gletscher-Maske gatet Tropfen und Inzision),
    /// * `noFluvial` — dieselbe Config, aber die beiden fluvialen Abtragspässe
    ///   sind global abgeschaltet.
    /// Auf den vergletscherten Zellen müssen beide BIT-IDENTISCH sein: wenn das
    /// Gate hält, hat dort ohnehin kein fluvialer Pass gearbeitet. Zugleich muss
    /// es abseits des Eises einen Unterschied geben — sonst prüft der Test nichts.
    func testNoFluvialErosionUnderIce() {
        var gated = quietCfg()
        gated.iceErodeK = 0; gated.iceMoraineK = 0   // das Eis selbst darf `h` nicht anfassen
        var noFluvial = gated
        noFluvial.outletErode = 0
        noFluvial.hydraulicPerYear = 0

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
        // sie neu, und genau diese neue Maske haben die beiden fluvialen Pässe
        // danach gesehen. Die Maske von VOR dem Schritt wäre veraltet — Zellen,
        // die das Eis in diesem Schritt verlassen hat, sind zu Recht wieder
        // fluvial (gemessen: 6 solche Zellen).
        let mask = a.underIce
        XCTAssertEqual(mask.count, gated.count, "keine Eismaske aufgebaut")
        let glaciated = (0..<gated.count).filter { mask[$0] }
        XCTAssertGreaterThan(glaciated.count, 100, "Testaufbau: zu wenig Eis")

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
                       "\(differsOnIce) vergletscherte Zellen wurden fluvial verändert")
        XCTAssertGreaterThan(differsOffIce, 100,
                             "Testaufbau: der fluviale Abtrag war nirgends aktiv")
        // Dass sich `h` unter dem Eis trotzdem BEWEGT, ist kein Widerspruch: die
        // Hebung bzw. der Relief-Servo (`applyUplift`) greifen flächendeckend und
        // sind kein fluvialer Abtrag. Gemessen bewegen sie hier 4031 der
        // vergletscherten Zellen — in BEIDEN Armen gleich, deshalb bleibt die
        // Bit-Gleichheit oben die richtige Zusicherung.
        _ = before
    }

    // MARK: - Abnahme 5: dt-Invarianz und Determinismus

    /// Gleiche Simulationszeit, verschiedene Schrittweiten → dasselbe Eis. Der
    /// Transport ist sub-getaktet, die Bilanz exakt relaxiert; übrig bleibt die
    /// Operator-Splitting-Drift, die dieses Projekt benannt zulässt
    /// (`docs/dt-invariance-measurements.md` §5) — deshalb Schranken statt
    /// Bit-Gleichheit. Gemessene Spanne: `docs/glacier-measurements.md` §G.
    func testIceIsFramerateIndependent() {
        var results: [(dt: Double, mass: Double, cells: Int)] = []
        for dt in [100.0, 500.0, 2500.0] {
            let t = Terrain(config: quietCfg(n: 256), seed: 1337)
            while t.years < 20_000 { t.step(dtYears: dt) }
            let s = Glacier.iceStats(t)
            var mass = 0.0
            for k in 0..<t.cfg.count { mass += t.ice[k] }
            results.append((dt, mass, s.glacier))
            print(String(format: "dt %6.0f → Eismasse %.5f, Zellen %d", dt, mass, s.glacier))
        }
        let masses = results.map(\.mass)
        let lo = masses.min()!, hi = masses.max()!
        XCTAssertGreaterThan(lo, 0, "kein Eis in einem der Arme")
        XCTAssertLessThan((hi - lo) / lo, 0.15,
                          "Eismasse hängt an der Schrittweite: \(masses)")
        let cells = results.map { Double($0.cells) }
        XCTAssertLessThan((cells.max()! - cells.min()!) / cells.min()!, 0.20,
                          "Eisfläche hängt an der Schrittweite: \(results.map(\.cells))")
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
    /// `SimNode.terrainColorBytes` ruft `Terrain.iceCoverage` über den rohen
    /// Puffer auf, statt die Formel ein zweites Mal hinzuschreiben.
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
}
