import XCTest
@testable import SimCore

/// Wächter für die Fluss-Dynamik (Multi-Flow-Drainage → Braiding-Fundament).
/// Misst objektiv, dass `areaMFD` (a) deterministisch ist, (b) jede Zelle
/// mindestens sich selbst trägt, (c) die Kanalkarte STABILER macht als das
/// D8-Netz (= weniger „Springen") und (d) strukturell Aufspaltungen zulässt,
/// die D8 prinzipiell nicht darstellen kann. Kalibriert bei n≤200 für Tempo.
final class RiverDynamicsTests: XCTestCase {

    private func cfg(n: Int) -> SimConfig { var c = SimConfig(); c.n = n; return c }

    /// Kanalzellen: Land mit Einzugsgebiet ≥ `creek` Zellen. (Der Renderer nutzt
    /// braidMinCells=120; das Default 30 hier hält die älteren MFD-Metriken stabil.)
    private func channelSet(_ t: Terrain, area: [Double], creek: Double = 30) -> Set<Int> {
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        var s = Set<Int>()
        for k in 0..<t.cfg.count where t.hf[k] > t.cfg.sea && t.h[k] > t.cfg.sea {
            if area[k] / cellArea >= creek { s.insert(k) }
        }
        return s
    }

    private func jaccard(_ a: Set<Int>, _ b: Set<Int>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let u = a.union(b).count
        return u == 0 ? 1 : Double(a.intersection(b).count) / Double(u)
    }

    /// Gleicher Seed → bit-identisches MFD-Feld, auch nach Simulation.
    func testMFDDeterminism() {
        let a = Terrain(config: cfg(n: 96), seed: 4242)
        let b = Terrain(config: cfg(n: 96), seed: 4242)
        for _ in 0..<5 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertEqual(a.areaMFD, b.areaMFD, "areaMFD muss deterministisch sein")
    }

    /// Jede Landzelle trägt mindestens ihre eigene Fläche (untere Schranke).
    func testMFDCarriesSelf() {
        let t = Terrain(config: cfg(n: 96), seed: 777)
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        for k in 0..<t.cfg.count where t.hf[k] > t.cfg.sea {
            XCTAssertGreaterThanOrEqual(t.areaMFD[k], cellArea - 1e-9,
                                        "areaMFD darf nie unter die eigene Zellfläche fallen")
        }
    }

    func testMFDMayUseASlowerRenderCadence() {
        var c = cfg(n: 64)
        c.mfdUpdateInterval = 2
        c.braidingEnabled = false
        let t = Terrain(config: c, seed: 777)
        let before = t.areaMFD

        // Der erste Schritt lässt das reine Render-/Braiding-Feld stehen;
        // D8/Seen werden trotzdem in jedem `step` neu berechnet.
        t.step(dtYears: 1)
        XCTAssertEqual(t.areaMFD, before)

        t.step(dtYears: 1)
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        for k in 0..<t.cfg.count where t.hf[k] > t.cfg.sea {
            XCTAssertGreaterThanOrEqual(t.areaMFD[k], cellArea - 1e-9)
        }
    }

    func testSpatialCutoffIndexMatchesReferenceOrder() {
        var reference = cfg(n: 32)
        reference.meanderSmooth = 0
        reference.meanderNodeSpacing = 1
        reference.meanderNeckDist = 2
        var indexed = reference
        indexed.meanderSpatialCutoffIndex = true
        let nodes = [
            MeanderNode(x: 0, z: 0), MeanderNode(x: 1, z: 0),
            MeanderNode(x: 2, z: 0), MeanderNode(x: 3, z: 0),
            MeanderNode(x: 4, z: 0), MeanderNode(x: 4, z: 1),
            MeanderNode(x: 3, z: 1), MeanderNode(x: 1, z: 1),
            MeanderNode(x: 0, z: 1),
        ]
        let channel = RiverChannel(nodes: nodes, discharge: [Double](repeating: 100, count: nodes.count))
        let a = MeanderState(); a.channels = [channel]
        let b = MeanderState(); b.channels = [channel]

        a.migrate(dt: 0, config: reference)
        b.migrate(dt: 0, config: indexed)

        XCTAssertEqual(b.channels[0].nodes, a.channels[0].nodes)
        XCTAssertEqual(b.channels[0].discharge, a.channels[0].discharge)
        XCTAssertEqual(b.oxbows, a.oxbows)
    }

    /// KERN-METRIK gegen das „Springen": Über einen kleinen Zeitschritt bewegt sich
    /// die MFD-Kanalkarte WENIGER als die D8-Kanalkarte (stetige Gewichte statt
    /// argmax-Kippen). Baseline gemessen: D8 würfelt ~27% der Empfänger je Update.
    func testMFDReducesChannelJitter() {
        let t = Terrain(config: cfg(n: 200), seed: 1337)
        while t.years < 10_000 - 1e-6 { t.step(dtYears: 1000) }

        let d8Before = channelSet(t, area: t.area)
        let mfdBefore = channelSet(t, area: t.areaMFD)
        let recBefore = t.snapshotReceivers()
        t.step(dtYears: 100)
        let d8After = channelSet(t, area: t.area)
        let mfdAfter = channelSet(t, area: t.areaMFD)

        let d8J = jaccard(d8Before, d8After)      // 1 = unverändert, klein = springt
        let mfdJ = jaccard(mfdBefore, mfdAfter)
        let recChurn = 1 - t.receiverAgreement(with: recBefore)
        print(String(format: "[MFD] Kanal-Jaccard über +100 J.: D8=%.4f  MFD=%.4f  (D8-Empfänger-Churn=%.4f)",
                     d8J, mfdJ, recChurn))
        // MFD darf nicht instabiler sein als D8 (i. d. R. deutlich stabiler).
        XCTAssertGreaterThanOrEqual(mfdJ, d8J - 0.02,
                                    "MFD-Kanalkarte darf nicht stärker springen als D8")
    }

    /// WÄCHTER: Mäander im Produktions-Pfad bleibt über die Zeit STABIL (Sinuosität
    /// gedeckelt statt weglaufend — der frühere Fehlermodus war Sinu → 26) und bildet
    /// dynamisch Altarme. Ersetzt die geparkten Skips, jetzt auf dem sanften Terrain.
    func testMeanderProductionStable() {
        var c = SimConfig(); c.n = 256 // Produktions-Defaults (meanderEnabled/Migration/Deckel)
        let t = Terrain(config: c, seed: 1337)
        var everOxbow = false
        var maxSinuEver = 0.0
        var yr = 0
        while yr < 80_000 {
            t.step(dtYears: 1000); yr += 1000
            for ch in t.meander.channels { maxSinuEver = max(maxSinuEver, ch.sinuosity) }
            if !t.meander.oxbows.isEmpty { everOxbow = true }
            // Deckel wirkt in JEDEM Schritt: kein Lauf tangelt zum Knäuel.
            XCTAssertLessThan(maxSinuEver, 5.0, "Sinuosität läuft weg (Deckel wirkt nicht): \(maxSinuEver)")
        }
        XCTAssertTrue(everOxbow, "über 80k Jahre entstanden keine Altarme")
        XCTAssertLessThan(t.maxHeight(), 1.0, "Terrain-Runaway unter Mäander")
        XCTAssertGreaterThan(t.landRelief(), 0.30, "Terrain eingeebnet unter Mäander")
    }

    // MARK: - Mäander ↔ Droplet-Reconciliation

    /// Bett-Statistik der Mäander-Kanalzellen gegen die umgebende Aue:
    /// Referenzhöhe = Mittel der Nicht-Kanal-Landzellen im Ring (Chebyshev-Abstand 3,
    /// also außerhalb der Bank-Zone meanderBankWidth=1.6). `depth` = Ref − h → positiv
    /// heißt EINGETIEFT. `filled` = Anteil der Kanalzellen, die über ihrer Aue liegen
    /// (= zugeschüttetes/aufgeschüttetes Bett — der Reconciliation-Fehlermodus).
    private func bedStats(_ t: Terrain) -> (count: Int, depth: Double, filled: Double) {
        let n = t.cfg.n
        var sum = 0.0, cnt = 0, filled = 0
        for k in 0..<t.cfg.count where t.isChannel[k] && t.h[k] > t.cfg.sea {
            let i = k % n, j = k / n
            if i < 3 || i >= n - 3 || j < 3 || j >= n - 3 { continue }
            var refSum = 0.0, refN = 0
            for dj in -3...3 {
                for di in -3...3 {
                    if max(abs(di), abs(dj)) != 3 { continue }
                    let nb = (j + dj) * n + (i + di)
                    if t.isChannel[nb] || t.h[nb] <= t.cfg.sea { continue }
                    refSum += t.h[nb]; refN += 1
                }
            }
            if refN < 6 { continue }
            let d = refSum / Double(refN) - t.h[k]
            sum += d; cnt += 1
            if d < 0 { filled += 1 }
        }
        return (cnt, cnt == 0 ? 0 : sum / Double(cnt), cnt == 0 ? 0 : Double(filled) / Double(cnt))
    }

    /// WÄCHTER Reconciliation (Mäander ↔ Droplet): Die `isChannel`-Maske wirkt im
    /// PRODUKTIONS-Pfad (hydraulicEnabled) — vorher kannte sie nur der Grid-Pfad
    /// (`transportLimited`), sodass die Tropfen das gecarvte Mäanderbett wieder
    /// zuschütteten. Vergleich gegen die ungedämpfte Referenz (channelDepositDamp
    /// = 1.0 = Zustand vor der Kopplung), gleicher Seed.
    /// Gemessen (n=256, seed 1337, 20k J.): Bett-Tiefe +0.0156 → +0.0222 (+43%),
    /// verlandete Betten 7.3% → 3.5%. Über 3 Seeds × 150k J. konsistent
    /// (Tiefe +25…+57%, Verlandung 13–15% → 7–10%), Relief/maxH unverändert.
    func testChannelBedSurvivesDroplets() {
        var cOn = SimConfig(); cOn.n = 256
        var cOff = cOn
        cOff.hydraulic.channelDepositDamp = 1.0 // = Zustand vor der Reconciliation
        let tOn = Terrain(config: cOn, seed: 1337)
        let tOff = Terrain(config: cOff, seed: 1337)
        // Über die Zeit gemittelt (Betten wandern, Einzel-Schnappschüsse rauschen).
        var dOn = 0.0, dOff = 0.0, fOn = 0.0, fOff = 0.0, samples = 0.0
        while tOn.years < 20_000 - 1e-6 {
            tOn.step(dtYears: 1000); tOff.step(dtYears: 1000)
            if Int(tOn.years) % 4000 != 0 { continue }
            let a = bedStats(tOn), b = bedStats(tOff)
            dOn += a.depth; fOn += a.filled
            dOff += b.depth; fOff += b.filled
            samples += 1
        }
        dOn /= samples; dOff /= samples; fOn /= samples; fOff /= samples
        print(String(format: "[RECON] Bett-Tiefe an=%+.5f aus=%+.5f | verlandete Betten an=%.1f%% aus=%.1f%%",
                     dOn, dOff, fOn * 100, fOff * 100))
        // 1) Das Bett ist überhaupt eingetieft (Referenzhöhe der Aue über dem Bett).
        XCTAssertGreaterThan(dOn, 0.015, "Mäanderbett ist nicht eingetieft — Tropfen füllen es zu")
        // 2) …und zwar deutlich tiefer als ohne die Kopplung (Marge zur Kalibrierung:
        //    gemessen ×1.43 hier, ×1.25…1.57 über 3 Seeds/150k).
        XCTAssertGreaterThan(dOn, dOff * 1.20, "Kanalmaske wirkt im Droplet-Pfad nicht")
        // 3) Deutlich weniger verlandete Betten als ohne Kopplung (gemessen ×0.48).
        XCTAssertLessThan(fOn, fOff * 0.75, "Kopplung verhindert das Zuschütten der Betten nicht")
        // Terrain bleibt gesund (dieselben Schwellen wie LongRunCollapse).
        XCTAssertLessThan(tOn.maxHeight(), 1.0, "Terrain-Runaway unter der Kanal-Dämpfung")
        XCTAssertGreaterThan(tOn.landRelief(), 0.30, "Terrain eingeebnet unter der Kanal-Dämpfung")
    }

    /// Rückwärtskompatibilität: OHNE Maske (leeres Array) rechnet `Hydraulic.erode`
    /// bit-identisch wie vor der Reconciliation — die Kopplung ist opt-in.
    func testDropletUnchangedWithoutMask() {
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
                        channel: [Bool](repeating: false, count: c.count), track: &trk2)
        XCTAssertEqual(h, h2, "leere Maske und all-false-Maske müssen identisch rechnen")
    }

    /// DIAGNOSE (print-only): Wie flach sind die Reaches, in denen Flüsse laufen?
    /// Mäander/Braiding brauchen Kanalzellen mit Längsslope < meanderFlatSlope
    /// (0.02). Misst die Slope-Verteilung der Kanalzellen + größte zusammenhängende
    /// Flachfläche (Auen-Proxy). Kein Assert außer „Kanäle existieren".
    func testTerrainFlatnessDiagnostic() {
        let t = Terrain(config: cfg(n: 256), seed: 1337)
        while t.years < 15_000 - 1e-6 { t.step(dtYears: 1000) }
        let n = t.cfg.n, cs = t.cfg.cellSize
        let flat = 0.02 // meanderFlatSlope
        @inline(__always) func slope(_ k: Int) -> Double {
            let i = k % n, j = k / n
            if i == 0 || i == n - 1 || j == 0 || j == n - 1 { return .infinity }
            let gx = (t.h[k + 1] - t.h[k - 1]) / (2 * cs)
            let gz = (t.h[k + n] - t.h[k - n]) / (2 * cs)
            return (gx * gx + gz * gz).squareRoot()
        }
        let chan = channelSet(t, area: t.areaMFD)
        XCTAssertGreaterThan(chan.count, 0)
        var lt005 = 0, lt01 = 0, lt02 = 0, lt05 = 0
        for k in chan {
            let s = slope(k)
            if s < 0.005 { lt005 += 1 }
            if s < 0.01 { lt01 += 1 }
            if s < flat { lt02 += 1 }
            if s < 0.05 { lt05 += 1 }
        }
        let c = Double(chan.count)
        print(String(format: "[FLAT] Kanalzellen n=%d | slope<0.005: %.1f%%  <0.01: %.1f%%  <0.02: %.1f%%  <0.05: %.1f%%",
                     chan.count, 100*Double(lt005)/c, 100*Double(lt01)/c, 100*Double(lt02)/c, 100*Double(lt05)/c))
        // Größte zusammenhängende Flachfläche über LAND (Auen-Proxy, 4er-Nachbarschaft).
        var flatLand = [Bool](repeating: false, count: n * n)
        var flatCount = 0
        for k in 0..<(n * n) where t.hf[k] > t.cfg.sea && slope(k) < flat {
            flatLand[k] = true; flatCount += 1
        }
        var seen = [Bool](repeating: false, count: n * n)
        var largest = 0
        var stack = [Int]()
        for start in 0..<(n * n) where flatLand[start] && !seen[start] {
            stack.removeAll(keepingCapacity: true); stack.append(start); seen[start] = true
            var size = 0
            while let k = stack.popLast() {
                size += 1
                let i = k % n, j = k / n
                if i > 0 && flatLand[k-1] && !seen[k-1] { seen[k-1] = true; stack.append(k-1) }
                if i < n-1 && flatLand[k+1] && !seen[k+1] { seen[k+1] = true; stack.append(k+1) }
                if j > 0 && flatLand[k-n] && !seen[k-n] { seen[k-n] = true; stack.append(k-n) }
                if j < n-1 && flatLand[k+n] && !seen[k+n] { seen[k+n] = true; stack.append(k+n) }
            }
            largest = max(largest, size)
        }
        let land = t.landCellCount()
        print(String(format: "[FLAT] Flach-Land (slope<0.02): %d von %d Landzellen (%.1f%%), größte zusammenhängende Aue: %d Zellen",
                     flatCount, land, 100*Double(flatCount)/Double(max(1,land)), largest))
    }

    /// Braiding-Metriken auf dem aktuellen Zustand:
    /// - `islands`: kleine trockene Land-Komponenten, die KOMPLETT von Kanalzellen
    ///   umschlossen sind (4er-Flood-Fill, 8er-Rand) = Mittelbänke, um die sich der
    ///   Lauf teilt und wiedervereint — der sichtbare Braiding-Payoff.
    /// - `splits`: Kanalzellen, deren Abfluss sich auf ≥2 KANAL-Empfänger mit je
    ///   ≥20% Gewicht aufteilt (aktive Verzweigungen).
    private func braidMetrics(_ t: Terrain, creek: Double = 120) -> (islands: Int, splits: Int) {
        let n = t.cfg.n
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let chan = channelSet(t, area: t.areaMFD, creek: creek)
        // --- aktive Splits (p-Wahl kommt aus Terrain.mfdLocalExponent — dieselbe
        // Stelle wie Wasser- und Sediment-Routing, keine driftende Kopie) ---
        var splits = 0
        for k in chan {
            let i = k % n, j = k / n
            var raw = [Double](), tgt = [Int]()
            var sMax = 0.0
            for dj in -1...1 {
                for di in -1...1 {
                    if di == 0 && dj == 0 { continue }
                    let ni = i + di, nj = j + dj
                    if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                    let nb = nj * n + ni
                    let dist = (di != 0 && dj != 0) ? 2.0.squareRoot() : 1.0
                    let s = (t.hf[k] - t.hf[nb]) / dist
                    if s > 0 { raw.append(s); tgt.append(nb); sMax = max(sMax, s) }
                }
            }
            let p = t.mfdLocalExponent(k, sMax: sMax)
            var wsum = 0.0
            var w = [Double]()
            for s in raw { w.append(pow(s, p)); wsum += w.last! }
            guard wsum > 0 else { continue }
            var strong = 0
            for x in w.indices where w[x] / wsum >= 0.2 && chan.contains(tgt[x]) { strong += 1 }
            if strong >= 2 { splits += 1 }
        }
        // --- Inseln: trockene Komponenten, rundum Kanal ---
        var isChan = [Bool](repeating: false, count: n * n)
        for k in chan { isChan[k] = true }
        var seen = [Bool](repeating: false, count: n * n)
        var islands = 0
        var stack = [Int]()
        for start in 0..<(n * n) {
            if seen[start] || isChan[start] { continue }
            if t.hf[start] <= t.cfg.sea || t.h[start] <= t.cfg.sea { continue }
            // Trocken-Komponente per 8er-Flood-Fill wachsen lassen. Umschlossen =
            // jeder Nicht-Komponenten-Nachbar ist Kanal (Weltrand/Meer bricht das).
            stack.removeAll(keepingCapacity: true); stack.append(start); seen[start] = true
            var size = 0, enclosed = true
            while let k = stack.popLast() {
                size += 1
                if size > 60 { enclosed = false } // Bänke sind klein; große Flächen sind Ufer
                let i = k % n, j = k / n
                for dj in -1...1 {
                    for di in -1...1 {
                        if di == 0 && dj == 0 { continue }
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= n || nj < 0 || nj >= n { enclosed = false; continue }
                        let nb = nj * n + ni
                        if isChan[nb] { continue }
                        if t.hf[nb] <= t.cfg.sea || t.h[nb] <= t.cfg.sea { enclosed = false; continue }
                        if !seen[nb] { seen[nb] = true; stack.append(nb) }
                    }
                }
            }
            if enclosed { islands += 1 }
        }
        return (islands, splits)
    }

    /// WÄCHTER Braiding (Task 4): der Murray&Paola-Pass erzeugt auf dem
    /// Produktions-Pfad Verzweigungen und Mittelbänke — messbar MEHR als ohne ihn —
    /// und hält dabei das Terrain gesund (kein Runaway, kein Einebnen).
    func testBraidingBuildsBars() {
        var cOn = SimConfig(); cOn.n = 256
        var cOff = cOn; cOff.braidingEnabled = false
        let tOn = Terrain(config: cOn, seed: 1337)
        let tOff = Terrain(config: cOff, seed: 1337)
        // Bänke sind TRANSIENT (Arme bilden und schließen sich) — deshalb über die
        // Zeit gesammelt messen (alle 2k Jahre), nicht als Einzel-Schnappschuss.
        var sumIslOn = 0, sumIslOff = 0, maxSplitsOn = 0, maxSplitsOff = 0
        var prevIslOn = 0, everFormed = false, everClosed = false
        while tOn.years < 30_000 - 1e-6 {
            tOn.step(dtYears: 1000); tOff.step(dtYears: 1000)
            if Int(tOn.years) % 2000 == 0 {
                let mOn = braidMetrics(tOn), mOff = braidMetrics(tOff)
                sumIslOn += mOn.islands; sumIslOff += mOff.islands
                maxSplitsOn = max(maxSplitsOn, mOn.splits)
                maxSplitsOff = max(maxSplitsOff, mOff.splits)
                if mOn.islands > prevIslOn { everFormed = true }
                if mOn.islands < prevIslOn { everClosed = true }
                prevIslOn = mOn.islands
            }
        }
        print("[BRAID] an:  Insel-Summe=\(sumIslOn) Splits-Max=\(maxSplitsOn) gebildet=\(everFormed) geschlossen=\(everClosed)")
        print("[BRAID] aus: Insel-Summe=\(sumIslOff) Splits-Max=\(maxSplitsOff)")
        XCTAssertGreaterThan(sumIslOn, sumIslOff,
                             "Braiding-Pass muss Mittelbänke (umschlossene Inseln) bauen")
        XCTAssertGreaterThan(maxSplitsOn, maxSplitsOff,
                             "Braiding-Pass muss aktive Verzweigungen erzeugen")
        // Der eigentliche User-Wunsch: Arme bilden sich UND schließen sich wieder.
        XCTAssertTrue(everFormed && everClosed,
                      "Bänke müssen entstehen UND wieder verschwinden (transiente Dynamik)")
        // Terrain bleibt gesund (dieselben Schwellen wie LongRunCollapse).
        XCTAssertLessThan(tOn.maxHeight(), 1.0, "Terrain-Runaway unter Braiding")
        XCTAssertGreaterThan(tOn.landRelief(), 0.30, "Terrain eingeebnet unter Braiding")
    }

    /// WÄCHTER Becken-Entwässerung (nickmcd-Verhalten): die Generierung liefert
    /// Terrain, dessen Becken zum Meer entwässert sind — kleiner See-Anteil,
    /// kein Zentralbecken-Mega-See — und das unter Simulation entwässert BLEIBT.
    func testBasinsDrainToSea() {
        for seed: UInt32 in [1337, 42, 2024] {
            var c = SimConfig(); c.n = 256
            let t = Terrain(config: c, seed: seed)
            let s0 = t.lakeStats()
            var cOff = c; cOff.breachEnabled = false
            let tOff = Terrain(config: cOff, seed: seed)
            let sOff = tOff.lakeStats()
            var minDeepLargest = Int.max
            while t.years < 10_000 - 1e-6 {
                t.step(dtYears: 1000)
                minDeepLargest = min(minDeepLargest, t.lakeStats(depth: 0.03).largest)
                if ProcessInfo.processInfo.environment["RS_BREACH_DEBUG"] != nil {
                    let s = t.lakeStats()
                    let sd = t.lakeStats(depth: 0.03)
                    print(String(format: "[sim] seed %u J%.0f: frac=%.3f largest=%d | tief(>0.03): frac=%.3f largest=%d",
                                 seed, t.years, s.fraction, s.largest, sd.fraction, sd.largest))
                }
            }
            let s1 = t.lakeStats()
            let land = t.landCellCount()
            print(String(format: "[BREACH] seed %u: ohne %.1f%%/%d → t0 %.1f%%/%d → 10k %.1f%%/%d (Land %d)",
                         seed, sOff.fraction*100, sOff.largest,
                         s0.fraction*100, s0.largest, s1.fraction*100, s1.largest, land))
            // Frisch generiert: entwässert (gemessen 4–5%, ohne Breach 15–30%).
            XCTAssertLessThan(s0.fraction, 0.08, "Becken nicht entwässert (seed \(seed))")
            XCTAssertLessThan(Double(s0.largest), 0.03 * Double(land),
                              "Zentralbecken-See überlebt die Generierung (seed \(seed))")
            // …und BLEIBT unter Simulation im Griff: Seen dürfen sich füllen UND
            // leeren (gewolltes nickmcd-Verhalten — der tiefe See oszilliert) —
            // aber es darf kein PERMANENTER tiefer Mega-See entstehen. Deshalb
            // wird das MINIMUM über den Lauf geprüft: es beweist, dass jeder
            // große See zwischendurch wieder entwässert.
            XCTAssertLessThan(s1.fraction, 0.14, "Becken laufen wieder voll (seed \(seed))")
            XCTAssertLessThan(Double(minDeepLargest), 0.025 * Double(land),
                              "Tiefer See entwässert nie mehr (seed \(seed), min=\(minDeepLargest))")
        }
    }

    /// WÄCHTER Stream-Map (nickmcd): das GERENDERTE Flussnetz (Track-Maske ∩
    /// Abfluss ≥ creek — genau die Schnittmenge, die waterFieldBytes malt)
    /// (a) deckt nach der Generierung die großen Läufe ab (Recall: die Flüsse
    /// SIND getrackt, keine Lücken) und (b) PERSISTIERT über die Zeit
    /// (etablierte Läufe bleiben — Sharpening), statt jeden Schritt zu springen.
    func testStreamMapMarksAndPersists() {
        var c = SimConfig(); c.n = 256
        let t = Terrain(config: c, seed: 1337)
        func renderedSet() -> (set: Set<Int>, recall: Double) {
            let chan = channelSet(t, area: t.areaMFD, creek: 120)
            var s = Set<Int>()
            for k in chan where t.streamMap[k] > 0.2 { s.insert(k) }
            return (s, chan.isEmpty ? 0 : Double(s.count) / Double(chan.count))
        }
        func strongSmap() -> Set<Int> {
            var s = Set<Int>()
            for k in 0..<t.cfg.count where t.streamMap[k] > 0.2 && t.hf[k] > t.cfg.sea { s.insert(k) }
            return s
        }
        let r0 = renderedSet()
        let sm0 = strongSmap()
        XCTAssertGreaterThan(r0.set.count, 200, "gerendertes Flussnetz nach Spin-up leer")
        // KURZE Frist (+200 J.): die STREAM-MAP springt nicht (EWMA-Gedächtnis).
        // (Der areaMFD-Anteil des Renders flackert roh weiter — das glättet die
        // Render-EWMA in SimNode; hier wird die SimCore-Seite gesichert.)
        t.step(dtYears: 100); t.step(dtYears: 100)
        let jacShort = jaccard(sm0, strongSmap())
        // LANGE Frist (+2000 J.): Flüsse WANDERN (gewollte Dynamik), aber das
        // Netz bleibt verwandt statt komplett neu gewürfelt.
        t.step(dtYears: 1000); t.step(dtYears: 1000)
        let r1 = renderedSet()
        let jacLong = jaccard(r0.set, r1.set)
        print(String(format: "[SMAP] gerendert=%d Recall=%.2f→%.2f Jaccard +200J=%.2f +2kJ=%.2f",
                     r0.set.count, r0.recall, r1.recall, jacShort, jacLong))
        XCTAssertGreaterThan(r0.recall, 0.4,
                             "große Läufe sind nicht getrackt (Flüsse hätten Render-Lücken)")
        XCTAssertGreaterThan(r1.recall, 0.4,
                             "Tracking der großen Läufe zerfällt unter Simulation")
        XCTAssertGreaterThan(jacShort, 0.7,
                             "gerendertes Flussnetz SPRINGT auf kurzer Frist")
        XCTAssertGreaterThan(jacLong, 0.25,
                             "Flussnetz nach 2k Jahren ohne jede Verwandtschaft (reines Würfeln)")
    }

    /// STRUKTURELL: MFD lässt Zellen mit mehreren tieferen Nachbarn zu (Abfluss
    /// spaltet sich) — die Voraussetzung für Aufspalten+Wiedervereinen, die D8
    /// (genau ein Empfänger) prinzipiell fehlt. Muss > 0 sein.
    func testMFDAllowsSplits() {
        let t = Terrain(config: cfg(n: 200), seed: 1337)
        while t.years < 10_000 - 1e-6 { t.step(dtYears: 1000) }
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let n = t.cfg.n
        var splitCapable = 0 // Kanalzellen mit ≥2 tieferen Nachbarn (können sich teilen)
        let chan = channelSet(t, area: t.areaMFD)
        for k in chan {
            let i = k % n, j = k / n
            var lower = 0
            for dj in -1...1 {
                for di in -1...1 {
                    if di == 0 && dj == 0 { continue }
                    let ni = i + di, nj = j + dj
                    if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                    if t.hf[nj * n + ni] < t.hf[k] { lower += 1 }
                }
            }
            if lower >= 2 { splitCapable += 1 }
        }
        print(String(format: "[MFD] aufspalt-fähige Kanalzellen (≥2 tiefere Nachbarn): %d von %d Kanalzellen (cellArea=%.4f)",
                     splitCapable, chan.count, cellArea))
        XCTAssertGreaterThan(splitCapable, 0,
                             "MFD muss strukturell Aufspaltungen zulassen (D8 kann das nie)")
    }
}
