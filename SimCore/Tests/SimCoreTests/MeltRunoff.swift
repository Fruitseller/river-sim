import XCTest
@testable import SimCore

/// Wächter + Messreihe zu **Schmelzwasser speist den Abfluss** (Issue #36):
/// `Terrain.updateRunoffWeight` / `Terrain.flowWeight`, Kalibrier-Logbuch bei
/// `SimConfig.meltRunoffEnabled` ff., Messreihen
/// `docs/melt-runoff-measurements.md`.
///
/// Die Abnahmekriterien des Tickets und ihre Wächter hier:
/// 1. Abfluss unter schneereichen Einzugsgebieten messbar erhöht →
///    `testMeltRunoffFavorsSnowFedCatchments`, gepoolt über Seeds in
///    `testMeltRunoffIsSeedRobustDiagnostic`
/// 2. Renormierung vs. Zusatzwasser gemessen entschieden →
///    `testMeltRunoffMeasurementDiagnostic` (beide Arme + der verworfene
///    Einlagerungs-Arm), Erhaltung in `testNormalizedMeltKeepsTheDrainageTotal`
/// 3. beide Netze und die Tropfen-Starts folgen derselben Regel →
///    `testBothNetworksSeedFromTheSameWeight`, `testMeltShiftsDropletSpawns`
/// 4. abgeschaltet bit-identisch → `testDisabledMeltRunoffIsBitIdentical` (Aus-Arm
///    UND schneefreie Welt), `testWithoutClimateThereIsNoRunoffWeight`,
///    `testUnweightedFlowIgnoresTheMelt` (der Cross-Worktree-Beleg gegen
///    `origin/main` steht in `docs/melt-runoff-measurements.md` §F)
/// 5. bestehende Wächter bleiben grün → `testEndorheicMechanicsSurviveMeltRunoff`
///    (#11 inselweit) und `Lithology.testSlopeBreakSurvivesMeltRunoff` (#12);
///    was dabei umgepinnt werden musste und warum: Messreihe §I
///
/// Dazu die Reichweite des Features (`testSnowyIslandScanDiagnostic`: nur alpine
/// Inseln haben überhaupt Schmelze), der Deckel des Beitrags
/// (`testMeltContributionIsCappedAtTheLocalRain` und, für die Kombination aus
/// Einlagerung und Renormierung,
/// `testMeltContributionStaysCappedWithSolidWithholding`) und die Kosten
/// (`testRunoffWeightCostDiagnostic`).
final class MeltRunoff: XCTestCase {

    // MARK: - Konfigurationen der vier Arme

    /// `aus` = Stand vor #36 (nur Regen), `A` = Renormierung (Produktion),
    /// `B` = Zusatzwasser (Σ steigt), `C` = massenkonsistente Einlagerung
    /// (verworfen, s. `SimConfig.meltRunoffWithholdSolid`).
    enum Arm: String, CaseIterable {
        case off = "aus", renorm = "A-renorm", extra = "B-zusatz", withhold = "C-einlag"
    }

    private func cfg(n: Int, arm: Arm) -> SimConfig {
        var c = SimConfig()
        c.n = n
        switch arm {
        case .off:      c.meltRunoffEnabled = false
        case .renorm:   break
        case .extra:    c.meltRunoffNormalized = false
        case .withhold: c.meltRunoffWithholdSolid = 1.0
        }
        return c
    }

    private func run(_ t: Terrain, to years: Double, dt: Double = 1000) {
        while t.years < years - 1e-6 { t.step(dtYears: dt) }
    }

    // MARK: - Kennzahlen

    /// Zahl der Zellen, die über `receiver` in `k` entwässern (inkl. `k`), und
    /// dieselbe topologische Summe über ein beliebiges Feld. Kahn über die
    /// Eingangsgrade — nach `hf` sortiert wäre die Reihenfolge auf Seespiegel-
    /// Flächen willkürlich (dieselbe Begründung wie in `RainWeightedFlow`).
    private func upstream(_ t: Terrain, of field: [Double]) -> (cells: [Double], sum: [Double]) {
        let cnt = t.cfg.count
        var cells = [Double](repeating: 1, count: cnt)
        var sum = field
        var indeg = [Int](repeating: 0, count: cnt)
        for k in 0..<cnt where t.receiver[k] >= 0 { indeg[Int(t.receiver[k])] += 1 }
        var queue = (0..<cnt).filter { indeg[$0] == 0 }
        var head = 0
        while head < queue.count {
            let k = queue[head]; head += 1
            let r = t.receiver[k]
            guard r >= 0 else { continue }
            cells[Int(r)] += cells[k]
            sum[Int(r)] += sum[k]
            indeg[Int(r)] -= 1
            if indeg[Int(r)] == 0 { queue.append(Int(r)) }
        }
        return (cells, sum)
    }

    /// Schneedeckung je Zelle (0 über See) — die Klassifikation der Einzugsgebiete
    /// muss in ALLEN Armen dieselbe Größe lesen, sonst vergleicht die Messung
    /// zwei verschiedene Fragen. `snowCover` ist arm-unabhängig (das Schneefeld
    /// selbst koppelt nicht an die Gewichtung zurück).
    private func coverField(_ t: Terrain) -> [Double] {
        (0..<t.cfg.count).map { t.h[$0] > t.cfg.sea ? t.snowCover($0) : 0 }
    }

    /// Kennzahlen eines Zustands. `qSnowFed`/`qSnowFree` sind der Abfluss je
    /// Einzugsgebiets-ZELLE (`area[k] / (Zellen · cellArea)`, also der mittlere
    /// Abfluss ÜBER dem Einzugsgebiet von `k`) — getrennt nach mittlerer
    /// Schneedeckung des Einzugsgebiets. Die Normierung auf die Zellzahl macht
    /// den Vergleich unabhängig davon, dass Gebirgsflüsse größere Gebiete führen.
    struct Metrics {
        var channels = 0, landCells = 0
        var relief = 0.0, lakeFrac = 0.0
        var outletTotal = 0.0          // totalOutletArea() / Zellzahl → Erhaltung
        var meanWeight = 0.0, maxWeight = 0.0
        var snowFedCells = 0, snowFreeCells = 0
        var qSnowFed = 0.0, qSnowFree = 0.0
        var snowVisible = 0.0          // Landanteil mit Deckung > 0.05
    }

    /// Einzugsgebiete ab dieser Zellzahl gelten als „Lauf" (wie in
    /// `docs/river-baseline-metrics.md` und im Luv/Lee-Wächter von #10).
    private let minCatchment = 30.0
    /// Mittlere Schneedeckung des Einzugsgebiets, ab der es als schneegespeist gilt …
    private let snowFedThreshold = 0.05
    /// … und unter der es als schneefrei gilt (nicht 0, damit ein Streusel-Pixel
    /// im Oberlauf ein sonst schneefreies Gebiet nicht aus der Referenz nimmt).
    private let snowFreeThreshold = 0.002

    private func measure(_ t: Terrain) -> Metrics {
        let c = t.cfg
        let cellArea = c.cellSize * c.cellSize
        let cover = coverField(t)
        let up = upstream(t, of: cover)
        let w = t.flowWeight
        var m = Metrics()
        var wSum = 0.0, visible = 0
        for k in 0..<c.count {
            guard t.hf[k] > c.sea && t.h[k] > c.sea else { continue }
            m.landCells += 1
            if cover[k] > 0.05 { visible += 1 }
            let wk = w.isEmpty ? 1 : w[k]
            wSum += wk
            m.maxWeight = max(m.maxWeight, wk)
            if t.areaMFD[k] / cellArea >= c.renderMinCells { m.channels += 1 }
            guard up.cells[k] >= minCatchment else { continue }
            let q = t.area[k] / (up.cells[k] * cellArea)
            let s = up.sum[k] / up.cells[k]
            if s >= snowFedThreshold { m.snowFedCells += 1; m.qSnowFed += q }
            else if s <= snowFreeThreshold { m.snowFreeCells += 1; m.qSnowFree += q }
        }
        m.meanWeight = m.landCells == 0 ? 0 : wSum / Double(m.landCells)
        m.snowVisible = m.landCells == 0 ? 0 : Double(visible) / Double(m.landCells)
        m.relief = t.landRelief()
        m.lakeFrac = t.lakeStats(depth: 0.03).fraction
        m.outletTotal = t.totalOutletArea() / Double(c.count)
        if m.snowFedCells > 0 { m.qSnowFed /= Double(m.snowFedCells) }
        if m.snowFreeCells > 0 { m.qSnowFree /= Double(m.snowFreeCells) }
        return m
    }

    private func line(_ arm: Arm, _ seed: UInt32, _ years: Int, _ m: Metrics) -> String {
        String(format: """
            [#36] %@ Seed=%d Jahr=%d | Abfluss/Einzugszelle schneegespeist=%.4f (%d) \
            schneefrei=%.4f (%d) Verhältnis=%.4f | ΣAbfluss=%.4f | \
            Gewicht Mittel=%.4f max=%.3f | Kanalzellen=%d Relief=%.4f Seeanteil=%.4f \
            Schnee sichtbar=%.4f
            """,
            arm.rawValue, seed, years, m.qSnowFed, m.snowFedCells,
            m.qSnowFree, m.snowFreeCells,
            m.qSnowFree > 0 ? m.qSnowFed / m.qSnowFree : 0,
            m.outletTotal, m.meanWeight, m.maxWeight,
            m.channels, m.relief, m.lakeFrac, m.snowVisible)
    }

    // MARK: - Messreihe (print-only, Quelle von docs/melt-runoff-measurements.md)

    /// **Die Designentscheidung**: alle vier Arme über einen Lauf, ein Seed,
    /// mehrere Zeitmarken. Klein im Alltag (n = 192, 20.000 Jahre); die Tabellen
    /// im Dokument stammen aus demselben Test mit größerem Gitter/Horizont:
    ///
    ///     RS_MEAS_N=640 RS_MEAS_YEARS=50000 swift test -c release \
    ///       --package-path SimCore -Xswiftc -swift-version -Xswiftc 5 \
    ///       --filter testMeltRunoffMeasurementDiagnostic
    func testMeltRunoffMeasurementDiagnostic() {
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["RS_MEAS_N"] ?? "") ?? 192
        let years = Int(env["RS_MEAS_YEARS"] ?? "") ?? 20_000
        let seed = UInt32(env["RS_MEAS_SEED"] ?? "") ?? 1337
        let marks = [0, 5_000, 20_000, 50_000, 100_000].filter { $0 <= years }
        for arm in Arm.allCases {
            let t = Terrain(config: cfg(n: n, arm: arm), seed: seed)
            for mark in marks {
                run(t, to: Double(mark))
                print(line(arm, seed, mark, measure(t)))
            }
            XCTAssertGreaterThan(t.landRelief(), 0.10, "Terrain eingeebnet (\(arm.rawValue))")
        }
    }

    /// **Welche Inseln haben überhaupt Schnee?** Die Reichweite des Tickets ist
    /// keine Meinung, sondern messbar: nur Inseln, deren Kämme über die
    /// Schnee-Grenze reichen (`climateSeaLevelTemp`/`climateLapseRate`, bei
    /// Produktionswerten ab h ≈ 0.46), bekommen einen Schmelzbeitrag. Der Scan
    /// liefert die Seed-Auswahl für die Mehr-Seed-Messung — ein Mittel über
    /// zufällige Seeds wäre sonst ein Mittel über meist schneefreie Inseln und
    /// würde den Effekt kleinrechnen.
    func testSnowyIslandScanDiagnostic() {
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["RS_MEAS_N"] ?? "") ?? 192
        var snowy: [UInt32] = []
        // 1…40 als unvoreingenommene Stichprobe, dazu die Standard-Seeds der
        // übrigen Messreihen (1337/7/99/2024) — von denen sind drei schneefrei.
        for seed in (1...40).map(UInt32.init) + [1337, 99, 2024] {
            let t = Terrain(config: cfg(n: n, arm: .off), seed: seed)
            let m0 = measure(t), maxH0 = t.maxHeight()
            run(t, to: 20_000)
            let m = measure(t)
            if m.snowVisible > 0.001 { snowy.append(seed) }
            print(String(format: "[#36] Scan n=%d Seed=%d | maxH J0=%.4f J20k=%.4f | "
                                 + "Schnee sichtbar J0=%.4f J20k=%.4f | Läufe schneegespeist=%d",
                         n, seed, maxH0, t.maxHeight(),
                         m0.snowVisible, m.snowVisible, m.snowFedCells))
        }
        print("[#36] Scan: Inseln mit Schnee nach 20k J. = \(snowy)")
    }

    /// Mehr-Seed-Gegenprobe: die RICHTUNG (schneegespeist gegen schneefrei) muss
    /// über verschiedene Inselformen dieselbe sein, sonst misst man nur die
    /// Zufallslage der Gebirge. Gepoolt statt „Mittel der Verhältnisse" — kleine
    /// Inseln haben wenige schneegespeiste Läufe (dieselbe Begründung wie im
    /// Luv/Lee-Wächter von #10).
    func testMeltRunoffIsSeedRobustDiagnostic() {
        // ALPINE Seeds, ausgewählt mit `testSnowyIslandScanDiagnostic` (Kämme über
        // der Schnee-Grenze, ≥ 44 schneegespeiste Läufe nach 20k Jahren). Die
        // Standard-Seeds der übrigen Messreihen (7/99/2024) sind bei n=192 flache,
        // vollständig schneefreie Inseln — auf ihnen ist das Feature stumm (der
        // Scan zeigt das) und ein Mittel über sie würde nur Rauschen mitteln.
        let seeds: [UInt32] = [1337, 2, 6, 20, 33]
        var fed = [Arm: (q: Double, n: Int)](), free = [Arm: (q: Double, n: Int)]()
        var outlet = [Arm: Double]()
        for seed in seeds {
            for arm in Arm.allCases {
                let t = Terrain(config: cfg(n: 192, arm: arm), seed: seed)
                run(t, to: 20_000)
                let m = measure(t)
                fed[arm] = ((fed[arm]?.q ?? 0) + m.qSnowFed * Double(m.snowFedCells),
                            (fed[arm]?.n ?? 0) + m.snowFedCells)
                free[arm] = ((free[arm]?.q ?? 0) + m.qSnowFree * Double(m.snowFreeCells),
                             (free[arm]?.n ?? 0) + m.snowFreeCells)
                outlet[arm] = max(outlet[arm] ?? 0, m.outletTotal)
                print(line(arm, seed, 20_000, m))
            }
        }
        for arm in Arm.allCases {
            let f = fed[arm]!, g = free[arm]!
            let ratio = (f.q / Double(max(1, f.n))) / (g.q / Double(max(1, g.n)))
            print(String(format: "[#36] gepoolt %@ | schneegespeist/schneefrei=%.4f "
                                 + "(%d/%d Zellen) | ΣAbfluss max=%.4f",
                         arm.rawValue, ratio, f.n, g.n, outlet[arm]!))
        }
    }

    // MARK: - Abnahme 1: der Abfluss unter Schneegebieten steigt

    /// Kernnachweis: bei GLEICH GROSSEM Einzugsgebiet führt ein schneegespeister
    /// Lauf mehr Abfluss als ein schneefreier — und der Sprung kommt aus der
    /// Schmelze, nicht aus der Lage der Gebirge (der Aus-Arm ist die Gegenprobe
    /// auf demselben Seed).
    func testMeltRunoffFavorsSnowFedCatchments() {
        var ratios = [Arm: Double]()
        for arm in [Arm.off, .renorm] {
            let t = Terrain(config: cfg(n: 192, arm: arm), seed: 1337)
            run(t, to: 20_000)
            let m = measure(t)
            print(line(arm, 1337, 20_000, m))
            XCTAssertGreaterThan(m.snowFedCells, 20, "zu wenige schneegespeiste Läufe")
            XCTAssertGreaterThan(m.snowFreeCells, 20, "zu wenige schneefreie Läufe")
            ratios[arm] = m.qSnowFed / m.qSnowFree
        }
        XCTAssertGreaterThan(ratios[.renorm]!, ratios[.off]! * 1.02,
                             "Schmelzwasser muss den Abfluss schneegespeister "
                             + "Einzugsgebiete messbar heben")
    }

    // MARK: - Abnahme 2: Erhaltung / Normierungs-Arm

    /// Die Entwässerungs-Invariante hält im Produktions-Arm EXAKT: das Gewicht
    /// hat auf Land wieder das Mittel 1, über See 1.0 — Σ der Einzugsgebiete an
    /// allen Senken bleibt die Zellzahl. Das ist der Grund, warum kein in Zellen
    /// kalibriertes Gate nachgezogen werden musste.
    func testNormalizedMeltKeepsTheDrainageTotal() {
        let t = Terrain(config: cfg(n: 128, arm: .renorm), seed: 1337)
        let total = Double(t.cfg.count)
        for _ in 0..<5 {
            t.step(dtYears: 1000)
            XCTAssertFalse(t.runoffWeight.isEmpty, "Testaufbau: keine Schmelze im Spiel")
            XCTAssertEqual(t.totalOutletArea(), total, accuracy: total * 1e-6,
                           "die Renormierung darf die Entwässerungssumme nicht verschieben")
        }
        // Die Normierung selbst gilt für die Land/See-Aufteilung, die beim BAU des
        // Gewichts galt — die Erosion des Schritts verschiebt die Küstenlinie
        // danach um einzelne Zellen. Für die feldweise Prüfung wird das Gewicht
        // deshalb einmal frisch gebaut (`computeFlow` ruft `computeRain`); das ist
        // derselbe Aufruf, den der Sculpt-Pfad benutzt.
        t.computeFlow(dtYears: 0)
        var wLand = 0.0, land = 0
        for k in 0..<t.cfg.count {
            if t.h[k] > t.cfg.sea { wLand += t.runoffWeight[k]; land += 1 }
            else { XCTAssertEqual(t.runoffWeight[k], 1.0,
                                  "über See muss das Gewicht neutral 1.0 sein") }
        }
        XCTAssertEqual(wLand / Double(land), 1.0, accuracy: 1e-9,
                       "Σ Gewicht über Land muss = Zahl der Landzellen sein")
        XCTAssertEqual(t.totalOutletArea(), total, accuracy: total * 1e-6,
                       "die Renormierung darf die Entwässerungssumme nicht verschieben")
    }

    /// Der verworfene Arm zeigt genau das Gegenteil — und zwar messbar: als
    /// Zusatzwasser STEIGT die Entwässerungssumme über die Zellzahl. Der Wächter
    /// pinnt die Aussage „B ist der Arm, der die Kalibrier-Kaskade aufmacht".
    func testExtraWaterArmRaisesTheDrainageTotal() {
        let t = Terrain(config: cfg(n: 128, arm: .extra), seed: 1337)
        for _ in 0..<5 { t.step(dtYears: 1000) }
        let ratio = t.totalOutletArea() / Double(t.cfg.count)
        print(String(format: "[#36] Zusatzwasser-Arm: ΣAbfluss/Zellzahl=%.5f", ratio))
        XCTAssertGreaterThan(ratio, 1.0 + 1e-6,
                            "der Zusatzwasser-Arm muss die Summe anheben (sonst ist er sinnlos)")
    }

    // MARK: - Abnahme 3: eine Regel für alle drei Konsumenten

    /// Der D8-Akkumulator startet je Zelle EXAKT mit `cellArea · flowWeight[k]` —
    /// nachgerechnet über die topologische Summe des Gewichtsfelds. Damit ist
    /// belegt, dass `area` (Erosion) die Schmelze trägt.
    /// Für das MFD-Feld (Render/Braiding) gilt dieselbe Startwert-Regel; dort
    /// prüft `RiverDynamicsTests.testMFDCarriesSelf` die untere Schranke, weil
    /// MFD fraktional verteilt und deshalb keine Zellsumme ist.
    func testBothNetworksSeedFromTheSameWeight() {
        // Alpiner Seed: auf einer schneefreien Insel wäre das Feld leer und der
        // Test würde nur die Regen-Gewichtung von #10 nachprüfen.
        let t = Terrain(config: cfg(n: 192, arm: .renorm), seed: 1337)
        t.step(dtYears: 1000)
        XCTAssertFalse(t.runoffWeight.isEmpty, "Testaufbau: keine Schmelze im Spiel")
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let w = t.flowWeight
        let up = upstream(t, of: w)
        var maxRelErr = 0.0
        for k in 0..<t.cfg.count {
            let expect = up.sum[k] * cellArea
            maxRelErr = max(maxRelErr, abs(t.area[k] - expect) / max(1e-12, expect))
        }
        XCTAssertLessThan(maxRelErr, 1e-9,
                          "area muss die topologische Summe von flowWeight sein")
        // Gegenprobe: mit dem REINEN Regen-Gewicht ginge die Rechnung nicht auf.
        let upRain = upstream(t, of: t.rainWeight)
        var maxRelErrRain = 0.0
        for k in 0..<t.cfg.count where upRain.sum[k] > 0 {
            maxRelErrRain = max(maxRelErrRain,
                                abs(t.area[k] - upRain.sum[k] * cellArea) / (upRain.sum[k] * cellArea))
        }
        XCTAssertGreaterThan(maxRelErrRain, 1e-6,
                             "Testaufbau: Schmelz- und Regen-Gewicht unterscheiden sich nicht")
    }

    /// Dritter Konsument: die Tropfen-Startpunkte. Dieselbe
    /// Ablehnungs-Stichprobe, dasselbe Feld — also starten in schneegespeisten
    /// Zellen mehr Tropfen als mit dem reinen Regen-Gewicht.
    func testMeltShiftsDropletSpawns() {
        let t = Terrain(config: cfg(n: 128, arm: .renorm), seed: 1337)
        t.step(dtYears: 1000)
        let c = t.cfg
        // Zielzone: Zellen, deren Abfluss-Gewicht die Schmelze angehoben hat.
        var boosted = [Bool](repeating: false, count: c.count)
        for k in 0..<c.count where t.runoffWeight[k] > t.rainWeight[k] * 1.05 { boosted[k] = true }
        XCTAssertGreaterThan(boosted.filter { $0 }.count, 50, "Testaufbau: keine Schmelzzone")
        func share(_ weight: [Double]) -> Double {
            let wMax = weight.max() ?? 0
            var rnd = Mulberry32(seed: 4242)
            var hits = 0
            let draws = 200_000
            for _ in 0..<draws {
                let s = Hydraulic.spawnPosition(&rnd, n: c.n, weight: weight, weightMax: wMax)
                if boosted[Int(s.y) * c.n + Int(s.x)] { hits += 1 }
            }
            return Double(hits) / Double(draws)
        }
        let withMelt = share(t.runoffWeight), rainOnly = share(t.rainWeight)
        print(String(format: "[#36] Tropfen-Starts in der Schmelzzone: mit Schmelze=%.5f "
                             + "nur Regen=%.5f (×%.3f)",
                     withMelt, rainOnly, withMelt / rainOnly))
        XCTAssertGreaterThan(withMelt, rainOnly * 1.05,
                             "die Tropfen-Starts folgen der Schmelze nicht")
    }

    // MARK: - Abnahme 4: abgeschaltet ist bit-identisch

    /// Ausgeschaltet bleibt das Feld leer, `flowWeight` IST `rainWeight`, und
    /// beide Pfade rechnen bit-identisch zum Stand vor #36. Gegenprobe zum
    /// Cross-Worktree-Fingerabdruck in `docs/melt-runoff-measurements.md` §F:
    /// hier wird geprüft, dass der Aus-Arm dieselbe Welt liefert wie eine Welt,
    /// in der es (Klima aus) gar nichts zu schmelzen gibt.
    func testDisabledMeltRunoffIsBitIdentical() {
        var a = cfg(n: 96, arm: .off)
        a.climateEnabled = true
        var b = cfg(n: 96, arm: .renorm)
        b.snowAccumPerYear = 0            // Klima an, aber es fällt nie Schnee
        let ta = Terrain(config: a, seed: 1337), tb = Terrain(config: b, seed: 1337)
        for _ in 0..<4 { ta.step(dtYears: 1000); tb.step(dtYears: 1000) }
        XCTAssertTrue(ta.runoffWeight.isEmpty, "ausgeschaltet muss das Feld leer bleiben")
        XCTAssertTrue(tb.runoffWeight.isEmpty, "ohne Schnee muss das Feld leer bleiben")
        XCTAssertEqual(ta.h, tb.h, "ohne Schmelze müssen beide Wege dieselbe Welt liefern")
        XCTAssertEqual(ta.area, tb.area)
        XCTAssertEqual(ta.areaMFD, tb.areaMFD)
        XCTAssertEqual(ta.streamMap, tb.streamMap)
    }

    /// Ohne Klima (Muster #33) gibt es kein Schneefeld — also auch kein
    /// Schmelz-Gewicht, selbst wenn der Schalter an ist.
    func testWithoutClimateThereIsNoRunoffWeight() {
        var c = cfg(n: 96, arm: .renorm)
        c.climateEnabled = false
        let t = Terrain(config: c, seed: 1337)
        t.step(dtYears: 1000)
        XCTAssertTrue(t.snow.isEmpty && t.runoffWeight.isEmpty,
                      "ohne Klima darf kein Schmelz-Gewicht entstehen")
        XCTAssertEqual(t.flowWeight, t.rainWeight, "flowWeight muss zurückfallen")
    }

    /// Und ohne gewichteten Abfluss (`rainWeightedFlow` aus, Referenzarm von #9)
    /// bleibt die Akkumulation reine Zellfläche — die Schmelze darf diesen
    /// Schalter nicht hintergehen.
    func testUnweightedFlowIgnoresTheMelt() {
        var c = cfg(n: 96, arm: .renorm)
        c.rainWeightedFlow = false
        let t = Terrain(config: c, seed: 1337)
        t.step(dtYears: 1000)
        XCTAssertTrue(t.rainWeight.isEmpty && t.runoffWeight.isEmpty,
                      "ohne Regen-Gewichtung darf es kein Abfluss-Gewicht geben")
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let up = upstream(t, of: [Double](repeating: 1, count: t.cfg.count))
        var maxRelErr = 0.0
        for k in 0..<t.cfg.count {
            maxRelErr = max(maxRelErr, abs(t.area[k] - up.cells[k] * cellArea)
                                        / (up.cells[k] * cellArea))
        }
        XCTAssertLessThan(maxRelErr, 1e-9, "area muss reine Zellzahl bleiben")
    }

    /// Der Ernstfall, für den der Deckel existiert (s.
    /// `SimConfig.meltRunoffCapPerRain`): der Spieler trägt die schneereichste
    /// Kuppe ab, die Temperatur springt auf Tieflandwert, der Schneevorrat steht
    /// noch. Liefert das Terrain nach dem `SimNode.recomputeFlow`-Pfad und die
    /// abgetragene Zelle.
    private func sculptedSnowyPeak(_ arm: Arm) -> (t: Terrain, peak: Int) {
        let t = Terrain(config: cfg(n: 192, arm: arm), seed: 1337)
        t.step(dtYears: 1000)
        // Höchste beschneite Zelle suchen und großflächig auf Küstenniveau
        // einebnen — genau der Sculpt-Pfad aus dem Spiel.
        var peak = 0
        for k in 0..<t.cfg.count where t.snow[k] > t.snow[peak] { peak = k }
        XCTAssertGreaterThan(t.snow[peak], 0.1, "Testaufbau: keine tragfähige Schneedecke")
        let gx = Double(peak % t.cfg.n), gz = Double(peak / t.cfg.n)
        // Ein Strich zieht nur 18 % Richtung Ziel (s. `flatten`) — der Spieler
        // hält den Knopf, hier sind das 40 Striche.
        for _ in 0..<40 {
            t.flatten(gx: gx, gz: gz, radiusWorld: 0.1 * t.cfg.world,
                      targetHeight: t.cfg.sea + 0.05)
        }
        // `SimNode.recomputeFlow`-Pfad: Temperatur nachziehen (dt = 0 hält die
        // Bilanz), dann das Abflussfeld neu bestimmen.
        t.updateClimate(dt: 0)
        t.computeFlow(dtYears: 0)
        XCTAssertGreaterThan(t.temperature[peak], 5,
                             "Testaufbau: die Kuppe ist nicht im Warmen angekommen")
        XCTAssertGreaterThan(t.snow[peak], 0.1, "Testaufbau: der Vorrat ist schon weg")
        return (t, peak)
    }

    /// Größtes Verhältnis `runoffWeight/rainWeight` über Land — die Größe, die der
    /// Deckel beschränkt (die Tropfen-Stichprobe normiert auf das FELD-Maximum).
    private func maxWeightRatio(_ t: Terrain) -> Double {
        var maxRatio = 0.0
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea {
            maxRatio = max(maxRatio, t.runoffWeight[k] / t.rainWeight[k])
        }
        return maxRatio
    }

    /// Der Schmelzbeitrag ist auf `meltRunoffCapPerRain · rainWeight` gedeckelt —
    /// das Gewicht einer Zelle kann sich also höchstens verdoppeln. Geprüft am
    /// Sculpt-Ernstfall im Produktions-Arm.
    func testMeltContributionIsCappedAtTheLocalRain() {
        let (t, peak) = sculptedSnowyPeak(.renorm)
        let maxRatio = maxWeightRatio(t)
        print(String(format: "[#36] Deckel-Test: max runoffWeight/rainWeight=%.4f "
                             + "(ungedeckelt wäre der Schmelzterm ×%.0f des Regens)",
                     maxRatio,
                     t.cfg.snowMeltPerKYear * t.temperature[peak] * t.snow[peak]
                        / t.cfg.snowAccumPerYear / t.rain[peak]))
        XCTAssertLessThanOrEqual(maxRatio, 1 + t.cfg.meltRunoffCapPerRain + 1e-9,
                                 "der Schmelzbeitrag muss gedeckelt bleiben")
    }

    /// Derselbe Ernstfall MIT Einlagerung (`meltRunoffWithholdSolid = 1`, Arm C).
    /// Der Deckel muss auch in dieser Kombination halten: die Einlagerung senkt
    /// das Landmittel des rohen Gewichts unter das Regenmittel, die Renormierung
    /// hebt also alle Zellen an — ein am Roh-Wert gedeckelter Ausreißer läge nach
    /// der Normierung trotzdem über `(1 + Deckel)·rainWeight`. Deshalb greift der
    /// Deckel NACH der Normierung (s. `Terrain.updateRunoffWeight`).
    func testMeltContributionStaysCappedWithSolidWithholding() {
        let (t, _) = sculptedSnowyPeak(.withhold)
        XCTAssertGreaterThan(t.cfg.meltRunoffWithholdSolid, 0, "Testaufbau: keine Einlagerung")
        // Die Skew der Normierung wird an einer UNBERÜHRTEN Zelle abgelesen: warm
        // genug für reinen Flüssigniederschlag (keine Einlagerung) und ohne
        // Schneevorrat (keine Schmelze) — dort ist roh = rain, das Verhältnis
        // `runoffWeight/rainWeight` ist also exakt Regenmittel/Rohmittel. Liegt es
        // über 1, hebt die Renormierung alle Zellen an, und der Roh-Deckel allein
        // würde die Zusage `≤ (1 + Deckel)·rainWeight` verfehlen.
        var skew = 0.0
        for k in 0..<t.cfg.count
        where t.h[k] > t.cfg.sea && t.snow[k] == 0 && t.temperature[k] >= t.cfg.snowRainTemp {
            skew = t.runoffWeight[k] / t.rainWeight[k]
            break
        }
        let maxRatio = maxWeightRatio(t)
        print(String(format: "[#36] Deckel-Test mit Einlagerung: max runoffWeight/"
                             + "rainWeight=%.4f · Normierungs-Skew=%.4f", maxRatio, skew))
        XCTAssertGreaterThan(skew, 1.0,
                             "Testaufbau: keine unberührte Zelle gefunden oder die "
                             + "Einlagerung hebt den Normierungsfaktor nicht")
        XCTAssertLessThanOrEqual(maxRatio, 1 + t.cfg.meltRunoffCapPerRain + 1e-9,
                                 "der Deckel muss auch mit Einlagerung halten")
    }

    // MARK: - Rückwirkung auf bestehende Wächter

    /// **Der Becken-Wasserhaushalt (#11) übersteht die Schmelze** — dieselbe
    /// Rolle, die `Lithology.testEndorheicMechanicsSurviveLithology` für #12 hat,
    /// und aus demselben Grund: die #11-Wächter pinnen ihre Physik auf EIN
    /// konkretes Becken (das größte von Seed 1337 bei n=256), und die Schmelze
    /// verschiebt, welches Becken das ist (`EndorheicEvaporation.cfg`). Hier wird
    /// deshalb INSELWEIT und über mehrere Seeds gezählt: entstehen weiter
    /// Salzpfannen?
    func testEndorheicMechanicsSurviveMeltRunoff() {
        var c = SimConfig(); c.n = 256; c.endorheicEvapRatio = 6   // dryCfg von #11
        var ref = c; ref.meltRunoffEnabled = false                 // Arm der #11-Wächter

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
            print("[#36] Schmelze × #11 Seed \(seed) — an: Kruste>0.5 \(on.bed) / >0.9 "
                  + "\(on.crusted) / Becken \(on.basins); aus: \(off.bed) / \(off.crusted) "
                  + "/ \(off.basins)")
            if on.bed > 100 && on.crusted > 20 { playaOn += 1 }
            if off.bed > 100 && off.crusted > 20 { playaOff += 1 }
        }
        XCTAssertGreaterThan(playaOn, 0,
            "mit Schmelzwasser entsteht auf keinem Seed mehr eine Salzpfanne — #11 wäre kaputt")
        XCTAssertGreaterThanOrEqual(playaOn, playaOff,
            "Schmelzwasser kostet Salzpfannen-Seeds (an \(playaOn) gegen aus \(playaOff))")
    }

    // MARK: - Invarianten: Determinismus, dt, Kosten

    func testMeltRunoffIsDeterministic() {
        let a = Terrain(config: cfg(n: 96, arm: .renorm), seed: 4242)
        let b = Terrain(config: cfg(n: 96, arm: .renorm), seed: 4242)
        for _ in 0..<3 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertEqual(a.h, b.h, "Schmelz-Gewichtung muss deterministisch bleiben")
        XCTAssertEqual(a.runoffWeight, b.runoffWeight)
        XCTAssertEqual(a.area, b.area)
        XCTAssertEqual(a.areaMFD, b.areaMFD)
    }

    /// Das Gewichtsfeld ist eine reine Ableitung ohne eigenen Zustand: bei
    /// gleichem `h`/`rain`/`snow` hängt es NICHT an `dt`. Geprüft am direkten
    /// Aufruf (`computeFlow(dtYears:)` unterscheidet sich nur im Becken-Haushalt).
    func testRunoffWeightDoesNotDependOnDt() {
        let t = Terrain(config: cfg(n: 192, arm: .renorm), seed: 1337)
        t.step(dtYears: 1000)
        // Referenz auf EINGEFRORENEM Zustand: `computeFlow` rührt `h`, `rain`,
        // `temperature` und `snow` nicht an, nur den Becken-Wasserhaushalt (der
        // hängt an dt) — das Gewicht muss über alle dt gleich herauskommen.
        t.computeFlow(dtYears: 0)
        let ref = t.runoffWeight
        XCTAssertFalse(ref.isEmpty, "Testaufbau: keine Schmelze im Spiel")
        t.computeFlow(dtYears: 10_000)
        XCTAssertEqual(t.runoffWeight, ref, "das Gewicht darf nicht an dt hängen")
        t.computeFlow(dtYears: 1)
        XCTAssertEqual(t.runoffWeight, ref, "das Gewicht darf nicht an dt hängen")
    }

    /// Kosten des neuen Passes je `step()` in Produktionsauflösung — gemessen
    /// statt geschätzt (dieselbe Doktrin wie bei `updateHeightBands` und
    /// `updateClimate`). Er hängt an `computeRain`, läuft also einmal je Schritt.
    func testRunoffWeightCostDiagnostic() {
        var c = SimConfig(); c.n = 832
        let t = Terrain(config: c, seed: 1337)
        t.step(dtYears: 1000)
        let rounds = 100
        var clock = Date()
        for _ in 0..<rounds { t.computeRain() }
        let withMelt = -clock.timeIntervalSinceNow * 1000 / Double(rounds)
        var c2 = c; c2.meltRunoffEnabled = false
        let t2 = Terrain(config: c2, seed: 1337)
        t2.step(dtYears: 1000)
        clock = Date()
        for _ in 0..<rounds { t2.computeRain() }
        let rainOnly = -clock.timeIntervalSinceNow * 1000 / Double(rounds)
        clock = Date()
        for _ in 0..<10 { t.step(dtYears: 100) }
        let stepMs = -clock.timeIntervalSinceNow * 1000 / 10
        print(String(format: "[#36] n=832 computeRain je Schritt: mit Schmelze %.2f ms · "
                             + "ohne %.2f ms (Aufschlag %.2f ms) — ganzer step() %.1f ms",
                     withMelt, rainOnly, withMelt - rainOnly, stepMs))
    }
}
