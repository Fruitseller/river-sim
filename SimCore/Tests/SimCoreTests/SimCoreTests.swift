import XCTest
@testable import SimCore

final class SimCoreTests: XCTestCase {

    private func makeConfig(n: Int = 96) -> SimConfig {
        var c = SimConfig()
        c.n = n; c.world = calibrationWorld
        return c
    }

    /// Config für die ISOLIERTEN Mäander-Kopplungstests: Mäander AN + Grid-Erosion
    /// (kein Droplet), alte Kalibrierung gepinnt. Prüft die Kopplungs-Mechanik
    /// (Carve, Altarm-See, Altern) ohne Droplet-Rauschen. Die LANGLAUF-Wächter
    /// laufen dagegen im Produktions-Pfad (s. prodMeanderCfg).
    private func meanderCfg(n: Int = 96) -> SimConfig {
        var c = makeConfig(n: n)
        c.hydraulicEnabled = false
        c.meanderEnabled = true
        // Diese Kopplungstests wurden gegen diese Werte kalibriert; Produktion nutzt
        // inzwischen andere (kleinere Migration/größerer Cutoff-Hals). Hier pinnen,
        // damit Test- und Produktions-Kalibrierung entkoppelt bleiben.
        c.meanderMigration = 5.0e-5
        c.meanderNeckDist = 1.2
        c.meanderCohesion = 0 // Stufe 2 (Ufer-Kohäsion) neutralisiert: diese Tests prüfen die reine Kopplungs-Mechanik
        // Mäander-Logik gegen KONSTANTE aktive Tektonik testen: die isolierte
        // Grid-Variante ohne Droplet braucht dauerhaften Relief-Nachschub für die
        // Altarm-Alterung. Die abklingende Produktions-Hebung (Issue #13) ist hier
        // bewusst AUS — diese Tests pinnen ihre alte Kalibrierung (s. AGENTS.md
        // „Drei Konfigurations-Ebenen"), sonst verschiebt jede Änderung an U₀/τ die
        // Kopplungs-Mechanik mit.
        c.upliftPer100y = 0.0015
        c.upliftDecayStartPer100y = 0
        c.upliftDecayFloorPer100y = 0
        // Uniformes Gestein (dieselbe Doktrin): diese Tests prüfen die Kopplung
        // Zentrumslinie ↔ Grid, nicht die Lithologie-Kalibrierung. Mit dem
        // Gesteinsfeld (Issue #12) läuft `transportLimited` auf räumlich variablem
        // kRock — die Härte des Streifens, in dem der Testlauf gerade liegt, würde
        // Carve-Tiefen und Altarm-Alterung mitverschieben. Das Gesteinsfeld hat
        // seine eigenen Wächter (`Lithology.swift`).
        c.lithologyEnabled = false
        return c
    }

    /// Config für die Mäander-LANGLAUF-Wächter: reine Produktions-Defaults, nur n
    /// gesenkt (n=192 statt 832 fürs Tempo; ~2.5 s je 100k Jahre in release).
    /// Bewusst NICHT `meanderCfg()`: dessen gepinnte Alt-Werte (Migration 5e-5,
    /// Hals 1.2, Grid-Erosion) sind seit `meanderEnabled = true` nicht mehr der
    /// Pfad, der real läuft — Langzeit-Stabilität muss auf dem echten Pfad
    /// (Droplet + Sinuositäts-Deckel + Hals 2.0) gemessen werden.
    private func prodMeanderCfg(n: Int = 192) -> SimConfig {
        var c = SimConfig(); c.n = n; c.world = calibrationWorld; return c
    }

    // MARK: - Determinismus

    /// Gleicher Seed → bit-identische Höhenfelder, auch nach Simulation.
    func testDeterminism() {
        let a = Terrain(config: makeConfig(), seed: 4242)
        let b = Terrain(config: makeConfig(), seed: 4242)
        XCTAssertEqual(a.h, b.h, "Generierung muss deterministisch sein")
        for _ in 0..<10 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertEqual(a.h, b.h, "Simulation muss deterministisch sein")
        XCTAssertEqual(a.receiver, b.receiver)
    }

    /// Verschiedene Seeds → verschiedene Terrains.
    func testSeedsDiffer() {
        let a = Terrain(config: makeConfig(), seed: 1)
        let b = Terrain(config: makeConfig(), seed: 2)
        XCTAssertNotEqual(a.h, b.h)
    }

    // MARK: - Entwässerungs-Invariante

    /// Die Summe der Einzugsgebiete an allen Land-Auslässen muss der Landfläche
    /// entsprechen — jede Zelle trägt genau ihre eigene Fläche bei.
    func testDrainageAreaConservation() {
        let t = Terrain(config: makeConfig(), seed: 777)
        let outlet = t.totalOutletArea()
        let total = Double(t.cfg.count)
        XCTAssertEqual(outlet, total, accuracy: total * 1e-6,
                       "Summe der Senken-Einzugsgebiete muss = Gesamtzellzahl sein")
    }

    // MARK: - Beschränktes Relief / Fließgleichgewicht

    /// Über viele Zeitsprünge darf das Relief weder weglaufen (→ ∞) noch
    /// einebnen (→ 0). Ersetzt die Masse-Erhaltung des Droplet-Prototyps.
    func testReliefStaysBounded() {
        let t = Terrain(config: makeConfig(), seed: 2024)
        let start = t.landRelief()
        XCTAssertGreaterThan(start, 0.1, "Startterrain muss Relief haben")
        var reliefs: [Double] = []
        for _ in 0..<8 {
            t.step(dtYears: 10000)
            reliefs.append(t.landRelief())
        }
        for r in reliefs {
            XCTAssertGreaterThan(r, 0.05, "Landschaft ebnet unrealistisch ein: \(reliefs)")
            XCTAssertLessThan(r, 2.0, "Relief läuft weg: \(reliefs)")
        }
        // Höhen bleiben in physikalisch sinnvollen Grenzen.
        XCTAssertLessThanOrEqual(t.maxHeight(), 1.4)
        XCTAssertGreaterThanOrEqual(t.minHeight(), t.cfg.floor - 1e-9)
    }

    /// Kein NaN/Inf über lange Läufe (numerische Stabilität des Solvers).
    func testNoNaN() {
        let t = Terrain(config: makeConfig(n: 80), seed: 555)
        for _ in 0..<20 { t.step(dtYears: 5000) }
        for v in t.h { XCTAssertTrue(v.isFinite, "NaN/Inf im Höhenfeld") }
        for v in t.area { XCTAssertTrue(v.isFinite && v >= 0, "Ungültiges Einzugsgebiet") }
    }

    /// Über sehr lange Zeiträume (wie im Zeitraffer: viele gedeckelte Schritte)
    /// bleibt die Landschaft stabil und beschränkt — kein Weglaufen, kein NaN.
    func testLongRunStable() {
        let t = Terrain(config: makeConfig(n: 80), seed: 33)
        for _ in 0..<400 { t.step(dtYears: 250) } // 100k Jahre in realistischen Schritten
        XCTAssertTrue(t.h.allSatisfy { $0.isFinite })
        XCTAssertGreaterThan(t.landRelief(), 0.1)
        XCTAssertLessThan(t.landRelief(), 1.6)
    }

    // MARK: - Konsistenz der Schichten

    /// h muss stets rock + sed entsprechen; Sediment nie negativ.
    func testLayerConsistency() {
        let t = Terrain(config: makeConfig(n: 80), seed: 9)
        for _ in 0..<5 { t.step(dtYears: 8000) }
        for k in 0..<t.cfg.count {
            XCTAssertEqual(t.h[k], t.rock[k] + t.sed[k], accuracy: 1e-9,
                           "h == rock + sed verletzt bei \(k)")
            XCTAssertGreaterThanOrEqual(t.sed[k], -1e-9, "negatives Sediment bei \(k)")
        }
    }

    // MARK: - Fluss-Stabilität

    // MARK: - Sculpting

    /// Anheben erhöht das Terrain lokal; die Tektonik-Kopplung sorgt dafür, dass
    /// der Eingriff über lange Zeiträume erhalten bleibt (Prototyp-Invariante:
    /// gesculpteter Berg bleibt der höchste Punkt der Karte).
    func testSculptRaisesAndPersists() {
        let t = Terrain(config: makeConfig(), seed: 4)
        let n = t.cfg.n
        let center = Double(n / 2)
        let before = t.h[Int(center) * n + Int(center)]
        // Kräftig anheben.
        for _ in 0..<200 {
            t.sculpt(gx: center, gz: center, radiusWorld: 12, dir: 1)
        }
        let after = t.h[Int(center) * n + Int(center)]
        XCTAssertGreaterThan(after, before + 0.2, "Anheben muss das Terrain erhöhen")
        t.computeFlow()
        // Über lange Zeit erodieren lassen — Kopplung soll den Berg halten.
        for _ in 0..<3 { t.step(dtYears: 10000) }
        let peak = t.maxHeight()
        let peakArea = t.h[Int(center) * n + Int(center)]
        XCTAssertGreaterThan(peakArea, peak * 0.6,
                             "gesculptete Region muss nach Erosion prominent bleiben")
    }

    /// Zwischen aufeinanderfolgenden Schritten sollen die meisten Flusszellen
    /// ihren Lauf behalten (analog zur 71-%-Messung im Prototyp).
    func testRiverStability() {
        let t = Terrain(config: makeConfig(), seed: 111)
        for _ in 0..<3 { t.step(dtYears: 5000) } // einschwingen
        let before = t.snapshotReceivers()
        t.step(dtYears: 100)
        let agreement = t.receiverAgreement(with: before)
        XCTAssertGreaterThan(agreement, 0.6,
                             "Entwässerung springt zu stark um: \(agreement)")
    }

    // MARK: - Mäander-Migration (M1: entkoppelter Kernel)

    /// Ein leicht gewellter Startlauf als Saat (schnurgerade → keine Krümmung →
    /// keine Migration). Abfluss konstant hoch, damit Bewegung sichtbar wird.
    private func seededChannel() -> RiverChannel {
        var nodes: [MeanderNode] = []
        var dis: [Double] = []
        var x = 5.0
        while x <= 90 {
            nodes.append(MeanderNode(x: x, z: 48 + 1.5 * sin(x * 0.4)))
            dis.append(220)
            x += 1.5
        }
        return RiverChannel(nodes: nodes, discharge: dis)
    }

    /// Config für die Kernel-Geometrie-Tests: moderate Rate (der voll-mobile
    /// synthetische Lauf würde bei der Produktionsrate pathologisch verknäueln;
    /// im Terrain hält das Mobilitäts-Gate ihn zahm — s. testMeanderTerrain*).
    private func kernelCfg() -> SimConfig {
        var c = makeConfig(); c.meanderMigration = 6.0e-6; return c
    }

    private func migratedState(steps: Int, dt: Double = 500) -> (MeanderState, SimConfig) {
        let cfg = kernelCfg()
        let s = MeanderState()
        s.channels = [seededChannel()]
        for _ in 0..<steps { s.migrate(dt: dt, config: cfg) }
        return (s, cfg)
    }

    func testMeanderDeterminism() {
        let (a, _) = migratedState(steps: 60)
        let (b, _) = migratedState(steps: 60)
        XCTAssertEqual(a.channels.count, b.channels.count)
        XCTAssertEqual(a.channels[0].nodes, b.channels[0].nodes,
                       "Mäander-Migration muss deterministisch sein")
        XCTAssertEqual(a.oxbows.count, b.oxbows.count)
    }

    /// Sinuosität wächst gegenüber dem geraden Start und läuft nicht weg
    /// (Cutoffs deckeln sie) — "wächst dann sättigt".
    func testMeanderSinuosityGrowsThenSaturates() {
        let cfg = kernelCfg()
        let s = MeanderState()
        s.channels = [seededChannel()]
        let s0 = s.channels[0].sinuosity
        for _ in 0..<40 { s.migrate(dt: 500, config: cfg) }
        let s40 = s.channels[0].sinuosity
        for _ in 0..<200 { s.migrate(dt: 500, config: cfg) }
        let s240 = s.channels[0].sinuosity
        XCTAssertGreaterThan(s40, s0 + 0.01, "Sinuosität muss zunächst wachsen: \(s0)→\(s40)")
        XCTAssertGreaterThan(s240, 1.0, "Lauf bleibt gewunden")
        XCTAssertLessThan(s240, 6.0, "Sinuosität läuft weg (keine Sättigung): \(s240)")
    }

    /// Nach Migration+Cutoffs dürfen sich keine nicht-benachbarten Knoten näher
    /// Keine *weiträumige* Selbst-Durchdringung: ein Lauf darf sich nicht über
    /// eine ferne Schleife hinweg selbst kreuzen. (Beinahe-Berührungen zwischen
    /// fast benachbarten Knoten sind kurzlebige Haarnadeln, die im nächsten
    /// Schritt abgeschnürt werden — das prüft der Cutoff-Mechanismus separat.)
    func testMeanderNoSelfIntersection() {
        let (s, cfg) = migratedState(steps: 300)
        let neck = cfg.meanderNeckDist
        let farSep = 2 * (max(4, Int((neck / cfg.meanderNodeSpacing) * 3) + 2))
        for ch in s.channels {
            let nodes = ch.nodes
            for i in 0..<nodes.count {
                var j = i + farSep
                while j < nodes.count {
                    XCTAssertGreaterThanOrEqual(dist(nodes[i], nodes[j]), neck * 0.999,
                        "Weiträumige Selbst-Durchdringung bei Knoten \(i),\(j)")
                    j += 1
                }
            }
        }
    }

    /// Der Resample hält die Knotenabstände überwiegend uniform: keiner über
    /// 2·spacing, und höchstens wenige unter 0.5·spacing (Sehne < Bogen an
    /// scharfen Bögen/Cutoff-Ecken, wird in Folgeschritten ausgerundet).
    func testMeanderResampleInvariant() {
        let (s, cfg) = migratedState(steps: 120)
        let sp = cfg.meanderNodeSpacing
        for ch in s.channels where ch.nodes.count >= 3 {
            var tight = 0, total = 0
            for i in 1..<ch.nodes.count {
                let d = dist(ch.nodes[i - 1], ch.nodes[i])
                total += 1
                if d < sp * 0.5 { tight += 1 }
                XCTAssertLessThan(d, sp * 2.0, "Knoten zu weit: \(d)")
            }
            XCTAssertLessThan(Double(tight) / Double(total), 0.1,
                              "zu viele dichte Knoten: \(tight)/\(total)")
            XCTAssertEqual(ch.nodes.count, ch.discharge.count, "Abfluss-Array inkonsistent")
        }
    }

    /// Mäander in Terrain integriert: gleicher Seed → identische Läufe, auch
    /// nach vielen step()s.
    func testMeanderTerrainDeterminism() {
        let a = Terrain(config: meanderCfg(), seed: 2024)
        let b = Terrain(config: meanderCfg(), seed: 2024)
        for _ in 0..<20 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertEqual(a.meander.channels.count, b.meander.channels.count)
        for (ca, cb) in zip(a.meander.channels, b.meander.channels) {
            XCTAssertEqual(ca.nodes, cb.nodes, "Mäander-Läufe müssen deterministisch sein")
        }
        XCTAssertEqual(a.meander.oxbows.count, b.meander.oxbows.count)
    }

    /// Langlauf im Produktions-Pfad (100k Jahre): die Läufe MÄANDERN wirklich, der
    /// Sinuositäts-Deckel hält sie aber beschränkt (der alte Fehlermodus war
    /// Sinu → 16..26 = Knäuel), Knoten bleiben endlich und in der Welt, keine
    /// weiträumige Selbst-Durchdringung, Relief/Höhen bleiben plausibel.
    /// Gemessen (n=192, seed 33): maxSinu 3.74 (Deckel 3.0 + Overshoot), Sinu-Mittel
    /// der letzten 20k = 2.18, Kanäle max 93, 0 Durchdringungen (minFar 2.23 bei
    /// Hals 2.0), Relief 0.479, maxH 0.629. Kaputte Mechanik → rot: Deckel aus
    /// (meanderMaxSinuosity=∞) → maxSinu 16.5; Migration aus → Sinu-Mittel 1.04;
    /// `applyCutoffs` stillgelegt → minFar 0.08 (Lauf faltet sich auf sich selbst).
    func testMeanderTerrainLongRunStable() {
        let cfg = prodMeanderCfg()
        let t = Terrain(config: cfg, seed: 33)
        let maxc = Double(cfg.n - 1)
        var maxSinu = 0.0, maxChannels = 0, badNodes = 0
        var lateSum = 0.0, lateCount = 0
        let steps = 200 // × 500 = 100k Jahre
        for s in 0..<steps {
            t.step(dtYears: 500)
            maxChannels = max(maxChannels, t.meander.channels.count)
            for ch in t.meander.channels {
                maxSinu = max(maxSinu, ch.sinuosity)
                if s >= steps - 40 { lateSum += ch.sinuosity; lateCount += 1 } // letzte 20k J.
                // Asserts erst nach dem Lauf (pro Knoten × Schritt wäre zu langsam).
                for nd in ch.nodes where !(nd.x.isFinite && nd.z.isFinite
                    && nd.x >= 0 && nd.x <= maxc && nd.z >= 0 && nd.z <= maxc) { badNodes += 1 }
            }
        }
        XCTAssertEqual(badNodes, 0, "Knoten mit NaN/Inf oder außerhalb der Welt")
        XCTAssertGreaterThan(lateCount, 0, "am Ende existiert kein Lauf mehr")
        // Der Deckel greift: die Sinuosität bleibt in JEDEM Schritt beschränkt.
        // 4.5 = Deckel 3.0 + Luft für den Overshoot (Glättung/Cutoff greifen erst
        // im Folgeschritt) — ohne Deckel liefe sie auf 16+.
        XCTAssertLessThan(maxSinu, 4.5, "Sinuosität läuft weg (Deckel wirkt nicht): \(maxSinu)")
        // …aber die Läufe sind auch wirklich gewunden (sonst wäre der Deckel-Assert
        // trivial erfüllt: ohne Migration liegt das Mittel bei 1.04).
        let lateMean = lateSum / Double(lateCount)
        XCTAssertGreaterThan(lateMean, 1.4, "Läufe mäandern nicht mehr: Mittel \(lateMean)")
        XCTAssertLessThan(maxChannels, 250, "Kanalzahl läuft weg: \(maxChannels)")
        // Keine *weiträumige* Selbst-Durchdringung (Beinahe-Berührungen zwischen
        // fast benachbarten Knoten sind kurzlebige Haarnadeln, s. Kernel-Test).
        let neck = cfg.meanderNeckDist
        let farSep = 2 * (max(4, Int((neck / cfg.meanderNodeSpacing) * 3) + 2))
        var minFar = Double.infinity
        for ch in t.meander.channels {
            let nodes = ch.nodes
            for i in 0..<nodes.count {
                var j = i + farSep
                while j < nodes.count { minFar = min(minFar, dist(nodes[i], nodes[j])); j += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(minFar, neck * 0.999,
                                    "weiträumige Selbst-Durchdringung: minFar \(minFar)")
        // Masse/Relief bleiben plausibel — Mäander frisst das Terrain nicht auf.
        XCTAssertTrue(t.h.allSatisfy { $0.isFinite }, "NaN/Inf im Höhenfeld")
        XCTAssertGreaterThan(t.landRelief(), 0.30, "Terrain eingeebnet unter Mäander")
        XCTAssertLessThan(t.landRelief(), 0.80, "Relief läuft weg unter Mäander")
        XCTAssertLessThan(t.maxHeight(), 1.0, "Terrain-Runaway unter Mäander")
        XCTAssertGreaterThanOrEqual(t.minHeight(), cfg.floor - 1e-9)
    }

    // MARK: - Mäander-Kopplung ins Höhenfeld (M3)

    /// Der Kanal carvt sein eigenes Bett: Zellen unter der Zentrumslinie liegen
    /// im Mittel tiefer als die seitliche Aue.
    func testMeanderCarvesChannel() {
        let cfg = meanderCfg()
        let t = Terrain(config: cfg, seed: 111)
        for _ in 0..<150 { t.step(dtYears: 500) }
        let n = cfg.n
        func hAt(_ x: Double, _ z: Double) -> Double {
            let i = min(max(Int(x.rounded()), 0), n - 1)
            let j = min(max(Int(z.rounded()), 0), n - 1)
            return t.h[j * n + i]
        }
        var chanSum = 0.0, bankSum = 0.0, cnt = 0
        for ch in t.meander.channels {
            let nd = ch.nodes
            for i in 1..<(nd.count - 1) {
                let a = nd[i - 1], c = nd[i + 1]
                let tx = c.x - a.x, tz = c.z - a.z
                let tl = (tx * tx + tz * tz).squareRoot()
                if tl < 1e-9 { continue }
                let px = -tz / tl, pz = tx / tl // Normale
                let hc = hAt(nd[i].x, nd[i].z)
                let hb = 0.5 * (hAt(nd[i].x + px * 3, nd[i].z + pz * 3)
                              + hAt(nd[i].x - px * 3, nd[i].z - pz * 3))
                chanSum += hc; bankSum += hb; cnt += 1
            }
        }
        XCTAssertGreaterThan(cnt, 0, "keine Kanalknoten")
        XCTAssertLessThan(chanSum / Double(cnt), bankSum / Double(cnt),
                          "Bett muss im Mittel unter der Aue liegen (Carve)")
    }

    /// Nach längerem Lauf ist river-history vorhanden (abgeschnürte Schleifen) und
    /// mindestens ein Altarm hält Wasser (hf>h) — der Cutoff-Pfropf trennt die
    /// eingetiefte Schleife ab, die bestehende Seen-Logik füllt sie.
    func testMeanderOxbowLake() {
        let cfg = meanderCfg()
        let n = cfg.n
        let t = Terrain(config: cfg, seed: 111)
        func oxbowLakeCells() -> Int {
            var c = 0
            for loop in t.meander.oxbows {
                for nd in loop {
                    let i = min(max(Int(nd.x.rounded()), 0), n - 1)
                    let j = min(max(Int(nd.z.rounded()), 0), n - 1)
                    let k = j * n + i
                    if t.hf[k] - t.h[k] > 0.004 && t.hf[k] > cfg.sea { c += 1 }
                }
            }
            return c
        }
        // Bis zum ersten Altarm laufen (Timing hängt von der Migrations-Dynamik ab),
        // dann über ein kleines Fenster den maximalen Altarm-Seespiegel prüfen.
        var guardN = 0
        while t.meander.oxbows.isEmpty && guardN < 260 { t.step(dtYears: 500); guardN += 1 }
        XCTAssertFalse(t.meander.oxbows.isEmpty, "keine Altarme (river-history) entstanden")
        var maxLake = oxbowLakeCells()
        for _ in 0..<8 { t.step(dtYears: 500); maxLake = max(maxLake, oxbowLakeCells()) }
        XCTAssertGreaterThanOrEqual(maxLake, 1, "kein Altarm-See (hf>h) im Oxbow-Bereich")
    }

    /// Altarme verlanden und altern aus: die Liste bleibt beschränkt, kein
    /// Altarm überschreitet das Maximalalter, und die Betten steigen über die
    /// Zeit (Verlandung).
    func testMeanderOxbowAging() {
        let cfg = meanderCfg()
        let t = Terrain(config: cfg, seed: 111)
        var everSeen = false, maxCount = 0
        for _ in 0..<400 {
            t.step(dtYears: 500)
            if !t.meander.oxbows.isEmpty { everSeen = true }
            maxCount = max(maxCount, t.meander.oxbows.count)
            // Invarianten in jedem Schritt: Liste beschränkt, keiner überaltert.
            XCTAssertLessThan(t.meander.oxbows.count, 60, "Altarm-Liste wächst unbeschränkt")
            XCTAssertEqual(t.meander.oxbows.count, t.meander.oxbowAge.count)
            for age in t.meander.oxbowAge {
                XCTAssertLessThanOrEqual(age, cfg.oxbowMaxAge, "verlandeter Altarm nicht entfernt")
            }
        }
        XCTAssertTrue(everSeen, "über den ganzen Lauf ist nie ein Altarm entstanden")
        XCTAssertGreaterThan(maxCount, 0)
    }

    /// Verlandung im Produktions-Pfad: nach Cutoffs entstehen eingetiefte Altarm-
    /// Betten, und die füllen sich über die Zeit wieder zu (`fillOxbows`), bis sie
    /// ausaltern (`pruneOxbows` → die Altarm-Zahl geht vom Peak zurück).
    ///
    /// Metrik ist das **Bett-Defizit** (Tiefe unter dem höchsten 4er-Nachbarn) —
    /// genau die Größe, die `fillOxbows` abbaut, und immun gegen den Relief-Servo
    /// (der hebt Bett UND Uferrand). Die alte Metrik „h steigt absolut" ist unscharf
    /// geworden: sie liefert mit *und ohne* Verlandung ~0.82..0.90 (Servo/Deposition
    /// heben das Bett ohnehin) — gemessen, deshalb ersetzt.
    ///
    /// Gemessen (Produktions-Config, n=192, seed 33): 184 Kohorten-Zellen,
    /// d0 = 0.0073, Defizit-Mittel über die 4 Fenster = 0.76·d0; Altarm-Peak 203 →
    /// Ende 66 (0.33·Peak). Kaputte Mechanik → rot: Verlandung aus
    /// (oxbowFillYears=∞) → 1.19·d0; Ausaltern aus (oxbowMaxAge=∞) → 458/458 =
    /// 1.00·Peak; Cutoff aus (Hals 0 bzw. `applyCutoffs` stillgelegt) → 0 Zellen.
    func testMeanderOxbowSiltsUp() {
        let cfg = prodMeanderCfg()
        let n = cfg.n
        let t = Terrain(config: cfg, seed: 33)
        /// Mittlere Tiefe der Zellen unter ihrem höchsten 4er-Nachbarn.
        func bedDeficit(_ cells: [Int]) -> Double {
            var s = 0.0
            for k in cells {
                var rim = t.h[k]
                for nb in [k - 1, k + 1, k - n, k + n] { rim = max(rim, t.h[nb]) }
                s += rim - t.h[k]
            }
            return cells.isEmpty ? 0 : s / Double(cells.count)
        }
        for _ in 0..<40 { t.step(dtYears: 500) } // 20k Jahre einschwingen (graded state)
        // Kohorte: die Betten aller über 5k Jahre FRISCH abgeschnürten Schleifen.
        // Ohne die je zwei äußeren Knoten pro Ende — die verkorkt `plugOxbows`
        // ohnehin und sie liegen am noch aktiven Kanal.
        var cohort = Set<Int>()
        for _ in 0..<10 {
            t.step(dtYears: 500)
            for oi in t.meander.oxbows.indices where t.meander.oxbowAge[oi] == 0 {
                let loop = t.meander.oxbows[oi]
                guard loop.count >= 6 else { continue }
                for nd in loop[2..<(loop.count - 2)] {
                    let ci = min(max(Int(nd.x.rounded()), 1), n - 2)
                    let cj = min(max(Int(nd.z.rounded()), 1), n - 2)
                    cohort.insert(cj * n + ci)
                }
            }
        }
        let cells = cohort.sorted() // deterministische Summations-Reihenfolge
        XCTAssertGreaterThan(cells.count, 20,
                             "kaum frisch abgeschnürte Altarm-Betten: \(cells.count)")
        let d0 = bedDeficit(cells)
        XCTAssertGreaterThan(d0, 0.002, "frische Altarme sind nicht eingetieft: \(d0)")
        // Über 12k Jahre (unter oxbowMaxAge, die Kohorte lebt noch) muss das Defizit
        // deutlich schrumpfen. Mittel über 4 Fenster statt Einzelwert: einzelne
        // Zellen re-carvt ein zurückwandernder Lauf, das rauscht.
        var ratios: [Double] = []
        for _ in 0..<4 {
            for _ in 0..<6 { t.step(dtYears: 500) } // 3k Jahre je Fenster
            ratios.append(bedDeficit(cells) / d0)
        }
        // Mittel locker (chaos-robust: jede Mäander-Änderung würfelt die Kohorte
        // neu), dafür MUSS das letzte Fenster klar verlandet sein (Konvergenz).
        let meanRatio = ratios.reduce(0, +) / Double(ratios.count)
        XCTAssertLessThan(meanRatio, 0.95,
                          "Altarm-Betten verlanden nicht: Defizit \(ratios) × d0=\(d0)")
        XCTAssertLessThan(ratios[ratios.count - 1], 0.90,
                          "Altarm-Verlandung konvergiert nicht: Defizit \(ratios) × d0=\(d0)")
        // Und die Altarme altern aus: die Liste geht vom Peak wieder zurück.
        var peak = t.meander.oxbows.count
        while t.years < 80_000 - 1e-6 {
            t.step(dtYears: 500)
            peak = max(peak, t.meander.oxbows.count)
        }
        XCTAssertGreaterThan(peak, 20, "kaum Altarme über den Lauf: \(peak)")
        XCTAssertLessThan(Double(t.meander.oxbows.count), 0.7 * Double(peak),
                          "Altarm-Zahl geht nicht zurück: \(t.meander.oxbows.count) von Peak \(peak)")
    }

    /// Trace aus der echten D8-Entwässerung liefert plausible Läufe.
    func testMeanderTraceFromDrainage() {
        let t = Terrain(config: makeConfig(), seed: 111)
        for _ in 0..<4 { t.step(dtYears: 5000) }
        let channels = MeanderState.traceChannels(config: t.cfg, h: t.h, hf: t.hf,
                                                   area: t.area, receiver: t.receiver)
        XCTAssertFalse(channels.isEmpty, "Kein Hauptfluss aus der Entwässerung getract")
        for ch in channels {
            XCTAssertGreaterThanOrEqual(ch.nodes.count, 2)
            XCTAssertEqual(ch.nodes.count, ch.discharge.count)
            XCTAssertTrue(ch.discharge.allSatisfy { $0 > 0 }, "Abfluss muss positiv sein")
        }
    }
}
