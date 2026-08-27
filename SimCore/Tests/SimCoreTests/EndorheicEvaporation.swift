import XCTest
@testable import SimCore

/// Wächter + Messreihe zum Becken-Wasserhaushalt (Issue #11): ein geschlossenes
/// Becken füllt sich nur so weit, wie sein ZUFLUSS die VERDUNSTUNG über der
/// Seefläche trägt (`Terrain.capEndorheicBasins`, Kalibrier-Logbuch bei
/// `SimConfig.endorheicEvapRatio`).
final class EndorheicEvaporation: XCTestCase {

    /// Produktionsphysik in Testauflösung (die reinen Performance-Schalter der
    /// Produktion sind verhaltensneutral, s. AGENTS.md).
    private func cfg(n: Int = 256, kappa: Double? = nil) -> SimConfig {
        var c = SimConfig()
        c.n = n
        if let kappa { c.endorheicEvapRatio = kappa }
        // Gesteinsfeld (Issue #12) AUSGEPINNT — dieselbe Doktrin wie κ=6 unten und
        // wie `meanderCfg()` in SimCoreTests: diese Wächter prüfen die MECHANIK des
        // Wasserhaushalts an EINEM konkreten Becken (dem größten von Seed 1337 bei
        // n=256), und welches Becken das ist, entscheidet die Lithologie-Lotterie
        // mit. GEMESSEN (n=256, κ=6, Seed 1337, 10×200 J., Lithologie an gegen aus):
        // * Salzpfanne IM GRÖSSTEN Becken 10 gegen 1098 Krustenzellen — mit
        //   Lithologie ist das größte gedeckelte Becken ein GESPEISTES, das gar
        //   nicht trockenfällt. INSELWEIT crusten dagegen 510 Zellen (davon 469
        //   voll, gegen 137 ohne Lithologie): die Playa-Bildung ist intakt, nur
        //   nicht mehr im „largestEndorheicBasin" dieses Terrains.
        // * Bilanz-Spiegel desselben Seeds: max Sprung τ=500 0.00429 gegen 0.00026
        //   ohne Lithologie (Wächter-Schwelle 0.002), bei τ=0 0.00703. Die
        //   Ratenbegrenzung wirkt also weiter (limitiert < instantan), aber das
        //   ZIEL wandert schneller: mit variablem Gestein kippen mehr Becken
        //   zwischen gedeckelt und offen, und ein Rollenwechsel setzt den Spiegel
        //   per Konstruktion instantan (s. `capEndorheicBasins`). Das ist eine
        //   bestehende Kante von #11, die die Lithologie nur häufiger trifft —
        //   notiert in docs/lithology-measurements.md §E.
        // Dass die #11-MECHANIK mit Lithologie intakt bleibt, ist eigens
        // abgesichert: `Lithology.testEndorheicMechanicsSurviveLithology`.
        c.lithologyEnabled = false
        // Höhenbänder (Issue #4) AUSGEPINNT — exakt derselbe Grund und dieselbe
        // Doktrin wie die Lithologie darüber: die perzentil-gekoppelte
        // Vegetations-Höhengrenze ist Produktions-KALIBRIERUNG, dieser Wächter
        // prüft die MECHANIK an EINEM konkreten Becken. GEMESSEN (n=256, κ=6,
        // Seed 1337, 10×200 J.): mit abgeleiteten Bändern trägt das größte
        // gedeckelte Becken 0 Krustenzellen — es ist wieder ein GESPEISTES, das
        // nicht trockenfällt. Inselweit crusten in derselben Konfiguration 284
        // Zellen (183 davon voll), die Playa-Bildung ist also intakt (Beleg:
        // `Lithology.testEndorheicMechanicsSurviveLithology`, das die Bänder
        // NICHT pinnt und über alle Seeds zählt). Mit `legacyAbsolute` läuft die
        // Vegetation exakt wie vor #4, das Becken ist wieder das alte.
        // Schmelzwasser (Issue #36) AUSGEPINNT — dritter Pin, gleiche Doktrin und
        // gleiches Muster wie die zwei darüber: Seed 1337 ist bei n=256 eine
        // ALPINE Insel, die Schmelze speist dort den Abfluss und verschiebt damit,
        // WELCHES Becken das größte gedeckelte ist. GEMESSEN (n=256, κ=6, Seed
        // 1337, 10×200 J., Schmelze an gegen aus): Salzpfanne im GRÖSSTEN Becken
        // 0 gegen 1098 Krustenzellen — mit Schmelze ist das größte gedeckelte
        // Becken wieder ein gespeistes, das nicht trockenfällt. Dass die
        // Playa-Bildung selbst intakt bleibt (inselweit, über mehrere Seeds), hält
        // `MeltRunoff.testEndorheicMechanicsSurviveMeltRunoff` fest — genau die
        // Rolle, die `Lithology.testEndorheicMechanicsSurviveLithology` für #12 hat.
        c.meltRunoffEnabled = false
        // Gletscher (Issue #35) AUSGEPINNT — vierter Pin, gleiche Doktrin. Seed
        // 1337 ist bei n=256 eine alpine Insel; unter dem Eis liegt der fluviale
        // Abtrag still (`Terrain.underIce` gatet Auslass-Inzision und Tropfen),
        // und damit brechen die SILLS dieses Beckens seltener durch. Genau diese
        // diskreten Ereignisse sind es aber, an denen die Gegenprobe hängt.
        // GEMESSEN (n=256, κ=6, Seed 1337, 200×20 J., Eis an gegen aus; 1603
        // vergletscherte Zellen):
        // * τ=500 (ratenbegrenzt): max Sprung 0.00675 gegen 0.00654 — die
        //   Ratenbegrenzung selbst bewegt sich um 3 %.
        // * τ=0 (Kontrollarm, instantan): 0.00493 gegen 0.00787 — der
        //   KONTROLLARM fällt mit Eis um 37 % und rutscht unter den
        //   ratenbegrenzten. `testBasinLevelIsRateLimited` kippt also an einem
        //   ruhiger gewordenen Vergleichsarm, nicht an einer schwächeren
        //   Ratenbegrenzung (die Sichtbarkeits-Schranke maxJump/Spanne bleibt
        //   mit 0.320 gegen 0.307 auf ihrem Niveau).
        // Dass die #11-MECHANIK mit Gletscher intakt bleibt, prüft der Pass an
        // seiner eigenen Stelle: `Glacier.testLongRunIceStaysBounded` hält das
        // Relief, und die inselweite Playa-Bildung hängt nicht am Eis.
        c.iceEnabled = false
        // WIE empfindlich diese Wächter sind, hat der erste Pin-Versuch gezeigt:
        // er notierte die Bänder als Abstand über `sea`, wodurch die Rampenbreite
        // 0.68 − 0.5 = 0.18000000000000005 statt 0.18 wurde. Diese EINE ulp auf
        // ~9 % der Landzellen genügte, um `testBasinLevelIsRateLimited`
        // (0.00319 gegen die 0.002-Schranke) und die Playa-Fläche (3 statt 1098
        // Zellen) zu kippen. Deshalb hält `HeightBands.legacyAbsolute` die
        // Rampenbreite als Literal — nicht als Differenz zweier Grenzen.
        c.heightBandsOverride = .legacyAbsolute
        return c
    }

    /// TROCKENES Klima (κ hoch). Die Mechanik-Wächter brauchen ein sicher
    /// gedeckeltes Becken; das Produktions-κ ist bewusst am unteren Rand des
    /// physikalischen Bands kalibriert (Logbuch: `SimConfig.endorheicEvapRatio`),
    /// dort kippen je Seed nur einzelne Becken. Ein Wächter, der daran hängt,
    /// würde bei jeder Klima-Nachkalibrierung rot, ohne dass die MECHANIK kaputt
    /// ist — dieselbe Doktrin wie `meanderCfg()` in SimCoreTests.
    private func dryCfg(n: Int = 256) -> SimConfig { cfg(n: n, kappa: 6) }

    /// Alle verdunstungs-limitierten Becken als Komponenten-Listen
    /// (`endorheicBasin != .none`, 8er-Nachbarschaft — Wasserfläche UND
    /// trockener Boden gehören dazu). Jede Komponente hier ist per Konstruktion
    /// ein GEDECKELTES Becken: `capEndorheicBasins` setzt die Rollen nur dort,
    /// wo der Vollstand die Verdunstung nicht trägt (`full > inflow`) und das
    /// Becken über dem Rausch-Gate liegt — ein Becken, das seinen Vollstand
    /// hält, bleibt `.none`. Die Auswahl EINES Beckens daraus ist Sache des
    /// jeweiligen Wächters; welche Auswahl plattformstabil ist, steht dort.
    private func endorheicBasins(_ t: Terrain) -> [[Int]] {
        let n = t.cfg.n
        var seen = [Bool](repeating: false, count: t.cfg.count)
        var comps = [[Int]]()
        for s in 0..<t.cfg.count where t.endorheicBasin[s] != .none && !seen[s] {
            var stack = [s], comp = [Int]()
            seen[s] = true
            while let k = stack.popLast() {
                comp.append(k)
                let i = k % n, j = k / n
                for dj in -1...1 {
                    for di in -1...1 {
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                        let nb = nj * n + ni
                        if t.endorheicBasin[nb] != .none && !seen[nb] { seen[nb] = true; stack.append(nb) }
                    }
                }
            }
            comps.append(comp)
        }
        return comps
    }

    /// Größtes verdunstungs-limitiertes Becken — der Sonderfall „größte
    /// Komponente" von `endorheicBasins`. EINE Quelle für die
    /// Komponenten-Logik: die Nachbarschaftsregel stand hier zweimal, und die
    /// nächste Änderung daran hätte beide Kopien finden müssen.
    private func largestEndorheicBasin(_ t: Terrain) -> [Int] {
        endorheicBasins(t).max { $0.count < $1.count } ?? []
    }

    /// Verkrustete Playa-Zellen einer Zell-Liste: trockengefallener Beckenboden
    /// mit überwiegender Salzkruste — das, was das Rendering als helle Pfanne
    /// malt (`SimNode.terrainColorBytes`).
    private func playaCells(_ t: Terrain, _ cells: [Int]) -> [Int] {
        cells.filter { t.endorheicBasin[$0] == .dryBed && t.saltCrust[$0] > 0.5 }
    }

    /// Wasserfläche eines Beckens in Zellen (Rolle `.water`) — die Fläche, über
    /// die das Becken verdunstet.
    private func waterArea(_ t: Terrain, _ cells: [Int]) -> Int {
        cells.reduce(0) { $0 + (t.endorheicBasin[$1] == .water ? 1 : 0) }
    }

    /// Wasserkomponente (stehendes Wasser, 8er) um `start`.
    private func waterCells(_ t: Terrain, _ cells: [Int]) -> [Int] {
        cells.filter { t.hf[$0] - t.h[$0] > 0.001 }
    }

    // MARK: - Abnahme 1: Spiegel unter der Sill

    /// Ein verdunstungs-limitiertes Becken steht UNTER seiner Sill: es gibt
    /// trockengefallenen Beckenboden, der HÖHER liegt als die Wasserfläche, und
    /// dessen Gefälle (steilster Abstieg auf `h`, unabhängig von den
    /// Sim-Empfängern gerechnet) führt in den Restsee zurück — das Becken könnte
    /// also mehr Wasser halten, bekommt aber nicht genug.
    func testDryBasinLevelStaysBelowSill() {
        let t = Terrain(config: dryCfg(), seed: 1337)
        let basin = largestEndorheicBasin(t)
        XCTAssertGreaterThan(basin.count, 200, "kein nennenswertes abflussloses Becken")
        let water = waterCells(t, basin)
        XCTAssertGreaterThan(water.count, 0, "Becken ganz ohne Wasserfläche")
        let level = water.map { t.hf[$0] }.max()!
        let bed = basin.filter { t.endorheicBasin[$0] == .dryBed }
        XCTAssertGreaterThan(bed.count, 0, "kein trockengefallener Beckenboden")
        let bedTop = bed.map { t.h[$0] }.max()!
        XCTAssertGreaterThan(bedTop, level + 0.005,
            "Trockenboden liegt nicht über dem Spiegel — kein gedeckeltes Becken")
        // Der freigelegte Boden liegt INNEN: sein Abstieg (steilster Abstieg auf
        // `h`) verlässt das Becken nicht — er endet im Restsee oder in einer
        // Droplet-Mulde DARIN, jedenfalls nie im Meer. Das ist die Aussage
        // „Spiegel unter der Sill": läge er auf der Sill, hätte dieser Boden
        // Wasser; wäre die Sill durchgeschnitten, liefe er ins Meer.
        let n = t.cfg.n
        var reachedWater = 0, reachedSea = 0
        for start in bed.prefix(400) {
            var k = start
            var guardN = 0
            while guardN < 4 * n {
                guardN += 1
                if t.hf[k] - t.h[k] > 0.001 { reachedWater += 1; break }
                if t.h[k] <= t.cfg.sea { reachedSea += 1; break }
                let i = k % n, j = k / n
                var next = -1
                var bestSlope = 0.0
                for dj in -1...1 {
                    for di in -1...1 {
                        if di == 0 && dj == 0 { continue }
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                        let nb = nj * n + ni
                        let dist = (di != 0 && dj != 0) ? 2.0.squareRoot() : 1.0
                        let s = (t.h[k] - t.h[nb]) / dist
                        if s > bestSlope { bestSlope = s; next = nb }
                    }
                }
                if next < 0 { break }
                k = next
            }
        }
        let walked = min(400, bed.count)
        XCTAssertEqual(reachedSea, 0,
            "trockengefallener Boden entwässert ins Meer — das Becken ist offen, nicht gedeckelt")
        XCTAssertGreaterThan(Double(reachedWater), 0.4 * Double(walked),
            "der freigelegte Boden findet den Restsee nicht (\(reachedWater)/\(walked))")
    }

    /// Der Spiegel ist der BILANZ-Stand, nicht irgendein Stand: die Verdunstung
    /// über der Wasserfläche schöpft den Zufluss aus (≤), und eine Zelle mehr
    /// Wasserfläche würde ihn überschreiten (>). Damit ist Abnahmekriterium 1
    /// nicht nur „unter der Sill", sondern quantitativ belegt.
    func testBasinWaterAreaMatchesTheBudget() {
        var c = dryCfg()
        c.endorheicResponseYears = 0 // Bilanz-Stand ohne Einschwingen prüfen
        let t = Terrain(config: c, seed: 1337)
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let basin = largestEndorheicBasin(t)
        XCTAssertGreaterThan(basin.count, 200)
        func demand(_ k: Int) -> Double {
            let w = t.rainWeight.isEmpty ? 1 : t.rainWeight[k]
            let a = min(4.0, max(0.25, 1 + t.cfg.endorheicAridity * (1 - w)))
            return cellArea * t.cfg.endorheicEvapRatio * a
        }
        // Zufluss aus dem Bilanz-Feld: im fertigen `area` steht er nicht mehr,
        // weil die Seefläche dort terminale Senke ist (s. endorheicInflow).
        let inflow = basin.map { t.endorheicInflow[$0] }.max()!
        XCTAssertGreaterThan(inflow, 0, "kein Bilanz-Zufluss protokolliert")
        // Wasserfläche = genau die Menge, über die die Bilanz verdunstet
        // (Becken-Rolle `.water`). Ein Tiefen-Filter wäre enger: der Deckel setzt hf =
        // level auch dort, wo das nur ein halber Millimeter ist.
        let water = basin.filter { t.endorheicBasin[$0] == .water }
        let spent = water.reduce(0.0) { $0 + demand($1) }
        XCTAssertLessThanOrEqual(spent, inflow * (1 + 1e-9),
            "Verdunstung über der Seefläche übersteigt den Zufluss")
        // Nächsthöhere Beckenzelle (erste trockene) würde das Budget reißen.
        let dry = basin.filter { t.endorheicBasin[$0] == .dryBed }.sorted { t.h[$0] < t.h[$1] }
        if let next = dry.first {
            XCTAssertGreaterThan(spent + demand(next), inflow,
                "der Spiegel liegt unnötig tief — Budget nicht ausgeschöpft")
        }
    }

    // MARK: - Abnahme 2: feuchtes vs. trockenes Klima

    /// Dasselbe Becken erreicht unter feuchtem und trockenem Klima
    /// unterschiedliche Spiegel, und im trockenen Fall entwässert es NICHT mehr
    /// über die Sill.
    ///
    /// Klima = κ: weil #10 den Abfluss auf sein Landmittel normiert, fällt die
    /// absolute Nässe aus `area` heraus — „feucht" ist ein kleines Verhältnis
    /// Verdunstung:Abflusshöhe, „trocken" ein großes (Herleitung:
    /// `SimConfig.endorheicEvaporation`). Beide Arme laufen auf demselben Seed
    /// ohne Breach-Spin-up, damit die Terrains identisch generiert werden.
    func testWetAndDryClimateDifferBasinLevel() {
        func arm(_ kappa: Double) -> Terrain {
            var c = cfg(kappa: kappa)
            c.breachEnabled = false // sonst hängt die Zahl der Spin-up-Runden am See-Anteil
            return Terrain(config: c, seed: 1337)
        }
        let wet = arm(0.5), dry = arm(6.0)
        // Referenz-Becken: die größte Wasserfläche des FEUCHTEN Arms.
        let n = wet.cfg.n
        var seen = [Bool](repeating: false, count: wet.cfg.count)
        var ref = [Int]()
        for s in 0..<wet.cfg.count where !seen[s] && wet.hf[s] > wet.cfg.sea
                                         && wet.hf[s] - wet.h[s] > 0.03 {
            var stack = [s], comp = [Int]()
            seen[s] = true
            while let k = stack.popLast() {
                comp.append(k)
                let i = k % n, j = k / n
                for dj in -1...1 {
                    for di in -1...1 {
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                        let nb = nj * n + ni
                        if !seen[nb] && wet.hf[nb] > wet.cfg.sea && wet.hf[nb] - wet.h[nb] > 0.03 {
                            seen[nb] = true; stack.append(nb)
                        }
                    }
                }
            }
            if comp.count > ref.count { ref = comp }
        }
        XCTAssertGreaterThan(ref.count, 200, "kein Referenz-See im feuchten Arm")
        func level(_ t: Terrain) -> Double { ref.map { t.hf[$0] }.max()! }
        func volume(_ t: Terrain) -> Double { ref.reduce(0.0) { $0 + max(0, t.hf[$1] - t.h[$1]) } }
        print(String(format: "[KLIMA] Becken %d Zellen: feucht Spiegel %.4f Volumen %.3f · "
                             + "trocken Spiegel %.4f Volumen %.3f",
                     ref.count, level(wet), volume(wet), level(dry), volume(dry)))
        XCTAssertLessThan(level(dry), level(wet) - 0.01,
            "trockenes Klima hebt denselben Spiegel wie das feuchte")
        XCTAssertLessThan(volume(dry), 0.5 * volume(wet),
            "trockenes Klima hält fast dasselbe Wasservolumen")
        // Trockener Arm: das Becken hat KEINEN Abfluss über die Sill — kein
        // Empfänger einer Beckenzelle liegt außerhalb des Beckens.
        let basin = Set(largestEndorheicBasin(dry))
        XCTAssertGreaterThan(basin.count, 200, "trockener Arm hat kein abflussloses Becken")
        var escapes = 0
        for k in basin {
            let r = dry.receiver[k]
            if r >= 0 && !basin.contains(Int(r)) { escapes += 1 }
        }
        XCTAssertEqual(escapes, 0, "abflussloses Becken entwässert doch über die Sill")
        // Gegenprobe: im feuchten Arm läuft dasselbe Becken über (die Sill
        // bekommt den Beckenabfluss) — sonst wäre die Aussage oben trivial.
        let wetOut = ref.contains { k in
            let r = wet.receiver[k]
            return r >= 0 && !ref.contains(Int(r))
        }
        XCTAssertTrue(wetOut, "feuchtes Becken hat auch keinen Abfluss — Vergleich ist blind")
    }

    // MARK: - Abnahme 3: gut gespeiste Becken unverändert

    /// Unter der niedrigsten in der Landschaft gemessenen Zufluss-Ratio (1.74,
    /// s. Config-Logbuch) greift der Pass NIRGENDS — und dann ist der Lauf
    /// BIT-IDENTISCH zum abgeschalteten Feature. Das belegt, dass der
    /// Wasserhaushalt ausschließlich über den Spiegel-Deckel wirkt und die
    /// angefassten Pässe (D8/MFD-Weitergabe, Auslass-Inzision,
    /// Pfützen-Verlandung, Vegetations-Ziel) ohne gedeckeltes Becken inert sind.
    func testUncappedRunIsBitIdenticalToDisabled() {
        var on = cfg(kappa: 0.5)
        var off = cfg(); off.endorheicEvaporation = false
        on.n = 160; off.n = 160
        let a = Terrain(config: on, seed: 1337)
        let b = Terrain(config: off, seed: 1337)
        for _ in 0..<5 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertFalse(a.endorheicBasin.contains { $0 != .none },
                       "κ=0.5 deckelt doch ein Becken — Referenzarm ungültig")
        XCTAssertEqual(a.h, b.h, "Höhenfeld weicht ab, obwohl kein Becken gedeckelt wurde")
        XCTAssertEqual(a.hf, b.hf, "Füllstand weicht ab")
        XCTAssertEqual(a.area, b.area, "D8-Abfluss weicht ab")
        XCTAssertEqual(a.areaMFD, b.areaMFD, "MFD-Abfluss weicht ab")
        XCTAssertEqual(a.veg, b.veg, "Vegetation weicht ab")
    }

    /// Ein gut gespeistes Becken (Zufluss-Ratio ≫ κ) bleibt unangetastet: seine
    /// Zellen tragen die Becken-Rolle `.none` und stehen weiter auf dem Sill-Niveau.
    func testWellFedBasinIsUnchanged() {
        let t = Terrain(config: cfg(), seed: 2024) // Produktions-κ: hier ist die Aussage relevant
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        let n = t.cfg.n
        var seen = [Bool](repeating: false, count: t.cfg.count)
        var checked = 0
        for s in 0..<t.cfg.count where !seen[s] && t.hf[s] > t.cfg.sea && t.hf[s] > t.h[s] {
            let sill = t.hf[s]
            var stack = [s], comp = [Int]()
            var inflow = 0.0
            seen[s] = true
            while let k = stack.popLast() {
                comp.append(k)
                inflow = max(inflow, t.area[k])
                let i = k % n, j = k / n
                for dj in -1...1 {
                    for di in -1...1 {
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                        let nb = nj * n + ni
                        if !seen[nb] && t.hf[nb] == sill && t.hf[nb] > t.h[nb] {
                            seen[nb] = true; stack.append(nb)
                        }
                    }
                }
            }
            // Ratio doppelt über κ → das Becken trägt seinen Vollstand mit Marge.
            let ratio = inflow / cellArea / Double(comp.count)
            guard comp.count >= 100, ratio > 2 * t.cfg.endorheicEvapRatio else { continue }
            checked += 1
            for k in comp {
                XCTAssertEqual(t.endorheicBasin[k], .none,
                               "gut gespeistes Becken (Ratio \(ratio)) wurde gedeckelt")
            }
        }
        XCTAssertGreaterThan(checked, 0, "kein gut gespeistes Becken zum Prüfen gefunden")
    }

    // MARK: - Abnahme 4: ratenbegrenzt, kein Flackern

    /// Der Bilanz-Spiegel folgt ratenbegrenzt: über 200 Schritte à 20 Jahren
    /// bleibt der größte Sprung des mittleren Beckenspiegels weit unter der
    /// Spanne, um die er insgesamt wandern kann. Die Gegenprobe ohne
    /// Ratenbegrenzung steht als eigene Stufenantwort daneben, s. unten.
    /// Der größte Sprung wird RELATIV ZUR SPANNE gemessen (Issue #2): „weit
    /// unter der Spanne, um die er wandern kann" ist die Aussage dieses
    /// Wächters. Die frühere absolute Schranke (0.002) hing am Absolutwert
    /// EINES diskreten Ereignisses — eine Sill bricht, der Priority-Flood
    /// pegelt das Becken um, und weil die Becken-Hypsometrie flach ist, wandern
    /// dabei hunderte Zellen zwischen Wasser und Trockenfall (gemessen
    /// 1319 → 1908 Zellen in EINEM Schritt). Jede Änderung an der
    /// Zeitintegration würfelt diesen Wert neu.
    ///
    /// Die beiden Zusicherungen tragen deshalb unterschiedlich viel:
    /// - Die **Gegenprobe** gegen den unbegrenzten Arm ist das eigentliche
    ///   Signal. Sie lief früher als ZWEITER 200-Schritt-Lauf mit τ=0 und
    ///   verglich die beiden maximalen Sprünge (`main` 0.00325 gegen 0.00612,
    ///   danach 0.00748 gegen 0.00929). Dieser Vergleich ist AUFGEGEBEN: die
    ///   zwei Arme durchlaufen verschiedene Landschaften (der Spiegel wirkt
    ///   über `hf` auf Abfluss und Erosion zurück), und in beiden ist der
    ///   größte Sprung nicht die EWMA, sondern ein diskretes Ereignis —
    ///   Sill-Durchbruch, Becken-Teilung, Rollenwechsel —, das per Konstruktion
    ///   instantan ist (s. `capEndorheicBasins`: der Vorstand wird auf
    ///   `[h, sill]` geklemmt, bevor relaxiert wird). Welcher Arm dabei den
    ///   größeren Ausschlag erwischt, ist Lotterie: auf diesem Repo-Stand
    ///   springt der RATENBEGRENZTE Arm auf macOS mit 0.00878 weiter als der
    ///   Kontrollarm mit 0.00761 (auf Linux ist es umgekehrt, CI war grün;
    ///   dasselbe Becken zählt dort 2313 statt 2813 Zellen) —
    ///   dieselbe Kante, die das Kalibrier-Logbuch oben schon für den
    ///   Gletscher-Pin notiert („der KONTROLLARM fällt mit Eis um 37 % und
    ///   rutscht unter den ratenbegrenzten"). Ein Wächter, der an einem
    ///   libm-Unterschied kippt, prüft nicht mehr die Mechanik.
    ///   Die Gegenprobe steht deshalb jetzt als **Stufenantwort** daneben
    ///   (`testBasinLevelFollowsTargetRateLimited`): beide Arme starten aus
    ///   DEMSELBEN Zustand, bekommen DIESELBE Ziel-Verschiebung und werden über
    ///   EINEN Schritt verglichen. Das ist genau die Größe, um die es geht (λ),
    ///   ohne diskrete Ereignisse im Weg.
    /// - Die **Sichtbarkeits-Schranke** bleibt hier und ist bimodal, weil das
    ///   Becken je nach Störung in dem einen oder anderen Regime landet:
    ///   gemessen 0.217 … 0.388 über die Depositions-Varianten von #2
    ///   (`main` 0.227), auf diesem Stand 0.307 unter Linux und 0.409 unter
    ///   macOS. Sie fängt ab, dass der Spiegel die
    ///   volle Spanne in einem Schritt durchläuft (das wäre ~1.0); weil ihr
    ///   Maximum aus den diskreten Ereignissen oben kommt und nicht aus der
    ///   Ratenbegrenzung, steht die Schranke auf 0.6 statt auf den früheren
    ///   0.45, die über der macOS-Messung nur 9 % Luft hatten.
    func testBasinLevelIsRateLimited() {
        func run(_ tau: Double) -> (maxJump: Double, span: Double, moved: Double) {
            var c = dryCfg()
            c.endorheicResponseYears = tau
            let t = Terrain(config: c, seed: 1337)
            // Ein Becken fixieren, das schon bei der Generierung gedeckelt ist.
            let basin = largestEndorheicBasin(t)
            XCTAssertGreaterThan(basin.count, 200, "kein abflussloses Becken (τ=\(tau))")
            let inv = 1.0 / Double(basin.count)
            func mean() -> Double { basin.reduce(0.0) { $0 + t.hf[$1] * inv } }
            var prev = mean()
            let first = prev
            var maxJump = 0.0, lo = prev, hi = prev
            for _ in 0..<200 {
                t.step(dtYears: 20)
                let m = mean()
                maxJump = max(maxJump, abs(m - prev))
                lo = min(lo, m); hi = max(hi, m)
                prev = m
            }
            return (maxJump, hi - lo, abs(prev - first))
        }
        let limited = run(500)
        print(String(format: "[RATE] τ=500: max Sprung %.5f Spanne %.5f (%.3f)",
                     limited.maxJump, limited.span, limited.maxJump / max(1e-9, limited.span)))
        XCTAssertGreaterThan(limited.span, 0.005,
            "Beckenspiegel wandert kaum — es gibt nichts zu begrenzen")
        XCTAssertLessThan(limited.maxJump, 0.6 * limited.span,
            "Beckenspiegel springt sichtbar (Ratenbegrenzung wirkt nicht)")
    }

    /// Gegenprobe zur Ratenbegrenzung als STUFENANTWORT — der Teil von
    /// `testBasinLevelIsRateLimited`, der früher als zweiter Langlauf mit τ=0
    /// daneben stand (Begründung des Umbaus dort).
    ///
    /// Aufbau: einen Zustand einschwingen, ihn als `TerrainState` festhalten und
    /// daraus ZWEI Terrains laden (derselbe Weg, den `WorldSnapshot.decode`
    /// geht: `init(allocating:)` + `restore`). Beide starten damit
    /// bit-identisch. Dann bekommen beide dieselbe Ziel-Verschiebung — κ von 6
    /// auf 12, ein trockeneres Klima, also mehr Verdunstung pro Seefläche und
    /// ein tieferer Zielstand — und laufen EINEN Schritt à 20 Jahren.
    ///
    /// Erwartung: der unbegrenzte Arm (τ=0) legt die ganze Strecke zum neuen
    /// Ziel in diesem einen Schritt zurück, der begrenzte nur den EWMA-Anteil
    /// λ = 1 − e^(−20/500) = 0.039. GEMESSEN (n=256, Seed 1337, 20×20 J.
    /// Vorlauf): macOS 0.00264 gegen 0.00012, Verhältnis 0.045 (2813 Zellen,
    /// 1024 davon Wasser) · Linux 0.00285 gegen 0.00013, Verhältnis 0.047
    /// (2313 Zellen, 941 Wasser). Das ist NICHT dasselbe Becken, und genau das
    /// ist der Punkt: die Stufenantwort liest auf beiden Plattformen praktisch
    /// denselben Wert, weil sie λ direkt misst statt es aus den Sprüngen zweier
    /// auseinanderlaufender Läufe zu erschließen. Die Zeile des jeweiligen
    /// Laufs steht als `[STUFE]` im Log.
    /// Das ist λ plus die Eigen-Drift des Ziels innerhalb des Schritts — und
    /// anders als der alte Langlauf-Vergleich liest die Stufenantwort auf
    /// beiden Plattformen praktisch denselben Wert, obwohl es nicht dasselbe
    /// Becken ist. Ohne die κ-Stufe (Kontrolle) bewegt sich der unbegrenzte Arm
    /// 0.00128, weil der eingeschwungene Zustand seinem Ziel ohnehin nachläuft;
    /// die Stufe verdoppelt das Signal und macht die Ursache benennbar.
    ///
    /// Warum eine Stufe im Klima und keine im Gelände: Sill-Eingriffe (Kerbe in
    /// die Schwelle) verschieben nicht das Ziel, sondern den DECKEL, und der
    /// klemmt per Konstruktion instantan — beide Arme sprängen gleich weit.
    func testBasinLevelFollowsTargetRateLimited() {
        var base = dryCfg()
        base.endorheicResponseYears = 500
        let src = Terrain(config: base, seed: 1337)
        for _ in 0..<20 { src.step(dtYears: 20) }
        // Ausgewählt wird das Becken mit der GRÖSSTEN WASSERFLÄCHE, nicht das
        // größte Becken: die Wasserfläche ist es, die verdunstet, also genau
        // die Größe, an der die κ-Stufe zieht (Ziel = höchster Stand, dessen
        // Seefläche der Zufluss noch trägt). Das größte Becken wäre wieder die
        // Auswahl, deren ulp-Anfälligkeit dieser Commit im Playa-Wächter
        // beseitigt — GEMESSEN kippt sie zwischen den Plattformen tatsächlich
        // (2313 Zellen unter Linux gegen 2813 unter macOS). Anders als dort
        // wäre die Folge hier kein stilles Grün, sondern Rot: ein Becken ohne
        // nennenswerte Wasserfläche antwortet kaum auf κ, und genau das prüft
        // die Vakuitäts-Zusicherung `instant > 0.001` unten. Trotzdem ist die
        // sachliche Auswahl die richtige — sie macht den Wächter unabhängig
        // davon, welches Becken gerade das größte ist.
        let basins = endorheicBasins(src)
        let basin = basins.max { waterArea(src, $0) < waterArea(src, $1) } ?? []
        XCTAssertGreaterThan(basin.count, 200, "kein abflussloses Becken")
        // Jede Komponente ist per Konstruktion gedeckelt (s. `endorheicBasins`);
        // die Wasserfläche ist die zusätzliche Voraussetzung dieses Wächters und
        // steht deshalb als Zusicherung da, nicht als Filter. Die gemessenen
        // Zahlen stehen in der `[STUFE]`-Zeile (s. Doc-Kommentar).
        XCTAssertGreaterThan(waterArea(src, basin), 200,
                             "gewähltes Becken hat kaum Wasserfläche — die κ-Stufe"
                             + " hätte nichts, woran sie ziehen kann")
        let inv = 1.0 / Double(basin.count)
        let snapshot = src.state
        let start = basin.reduce(0.0) { $0 + src.hf[$1] * inv }

        /// Ein Schritt aus dem festgehaltenen Zustand, mit verschobenem Ziel.
        func stepResponse(tau: Double) -> Double {
            var c = base
            c.endorheicResponseYears = tau
            c.endorheicEvapRatio = 12 // Ziel-Stufe: trockeneres Klima
            let t = Terrain(allocating: c, seed: 1337)
            t.restore(snapshot)
            t.step(dtYears: 20)
            return abs(basin.reduce(0.0) { $0 + t.hf[$1] * inv } - start)
        }
        let instant = stepResponse(tau: 0)
        let limited = stepResponse(tau: 500)
        print(String(format: "[STUFE] Becken %d Zellen (%d Wasser) · τ=0 %.5f · τ=500 %.5f (%.3f)",
                     basin.count, waterArea(src, basin), instant, limited,
                     limited / max(1e-9, instant)))
        XCTAssertGreaterThan(instant, 0.001,
            "das Ziel hat sich kaum verschoben — die Gegenprobe wäre leer")
        XCTAssertLessThan(limited, 0.25 * instant,
            "ratenbegrenzt folgt der Ziel-Stufe genauso schnell wie unbegrenzt")
    }

    /// Framerate-Unabhängigkeit (Projekt-Invariante): der ratenbegrenzte
    /// Bilanz-Spiegel ist eine EWMA in Sim-Zeit — Zeitraffer in 20-Jahres-
    /// Schritten und ein einzelner 1000-Jahres-Sprung müssen denselben Stand
    /// erreichen. Verglichen wird das Becken, nicht das ganze Feld (die
    /// Droplet-Erosion ist nicht schrittinvariant).
    func testBalanceLevelIsFramerateIndependent() {
        var c = dryCfg(n: 160)
        c.hydraulicEnabled = false // Droplets sind der schrittabhängige Teil
        c.meanderEnabled = false
        let fine = Terrain(config: c, seed: 1337)
        let coarse = Terrain(config: c, seed: 1337)
        let basin = largestEndorheicBasin(fine)
        // Kein SKIP, sondern eine ZUSICHERUNG. Hier stand `try? XCTSkipIf(…)` —
        // das `try?` verschluckte den geworfenen Skip, die Absicherung war also
        // wirkungslos: bei einem zu kleinen Becken lief der Vergleich einfach
        // weiter (bei 0 Zellen sogar auf NaN). Und ein Skip wäre auch der
        // falsche Ausgang: Seed, Auflösung und κ sind gepinnt (`dryCfg`), das
        // Becken ist damit keine Umgebungs-Eigenschaft, sondern Voraussetzung
        // dieses Wächters — verschwindet es, muss er ROT werden statt still
        // durchzulaufen (dieselbe Doktrin wie `MeasurementGate`: kein Wächter
        // schaltet sich unbemerkt selbst ab). Die Schranke ist dabei WEIT vom
        // Ist-Zustand entfernt und damit kein neues Pin: gemessen 765 Zellen
        // gegen die 50 der Schranke (n=160, κ=6, Seed 1337, s. `[DT]`-Zeile).
        guard basin.count >= 50 else {
            XCTFail("kein abflussloses Becken in dieser Konfiguration "
                    + "(\(basin.count) Zellen) — nichts zu vergleichen")
            return
        }
        for _ in 0..<50 { fine.step(dtYears: 20) }
        coarse.step(dtYears: 1000)
        let a = basin.reduce(0.0) { $0 + fine.hf[$1] } / Double(basin.count)
        let b = basin.reduce(0.0) { $0 + coarse.hf[$1] } / Double(basin.count)
        // Die EWMA selbst ist in Sim-Zeit exakt; NICHT spurgleich ist das ZIEL
        // (die Landschaft erodiert zwischen den Schritten weiter, und 50 kleine
        // Schritte folgen einem wandernden Ziel enger als ein großer). Geprüft
        // wird deshalb ein Band: kein Faktor-Unterschied wie bei einer
        // dt-abhängigen Rate (die 50 Schritte würden dann 50× so weit laufen).
        print(String(format: "[DT] Becken %d Zellen · 50×20 J. %.5f · 1×1000 J. %.5f",
                     basin.count, a, b))
        XCTAssertEqual(a, b, accuracy: 0.02,
                       "Bilanz-Spiegel hängt an der Schrittweite (\(a) vs \(b))")
    }

    // MARK: - Abnahme 5: trockengefallene Fläche ist als solche erkennbar

    /// Die trockengefallene Fläche trägt (a) KEIN Wasser mehr — der
    /// Darstellungs-Seespiegel läuft auf die Geländehöhe zurück, das
    /// Wasser-Overlay malt dort also nichts — und (b) eine Salzkruste, aus der
    /// das Rendering die helle Playa baut (SimNode.terrainColorBytes). Der
    /// Bewuchs bleibt aus (Salzpfannen sind kahl).
    ///
    /// Geprüft wird das Becken mit der GRÖSSTEN Pfanne, nicht das größte Becken.
    /// Grund: welches Becken das größte ist, entscheidet sich zwischen den zwei
    /// Kandidaten dieses Seeds an wenigen Prozent Fläche (gemessen 2079 gegen
    /// 1836 Zellen), und nur der zweite fällt trocken — das größte ist ein
    /// GESPEISTES. Diese Reihenfolge kippt bereits an einer ulp: das
    /// Kalibrier-Logbuch oben notiert es für Lithologie, Höhenbänder, Schmelze
    /// und Eis, auf macOS kippt sie gegenüber Linux allein an der System-libm
    /// (plattformübergreifende Bit-Gleichheit gilt in diesem Projekt nicht,
    /// s. AGENTS.md) — der Wächter war dort rot, während CI grün war, ohne dass
    /// an der Mechanik etwas fehlte (inselweit crusteten 577 Zellen, 535 davon
    /// voll). Die Pfanne des gewählten Beckens ist plattformabhängig
    /// unterschiedlich GROSS — 577 Zellen unter macOS, 172 unter Linux gegen
    /// die 100 der Schranke darunter. Die 100 stehen seit #11 und bleiben; wer
    /// sie das nächste Mal reißen sieht, prüft zuerst, ob die Schranke oder das
    /// Terrain gewandert ist (das Logbuch oben notiert für denselben Seed
    /// einmal 1098 Krustenzellen, das war vor den Sim-Runden seither). Die Auswahl über das Maximum ist trotzdem keine Selbstbestätigung:
    /// bricht die Playa-Bildung, ist das Maximum 0 und die Zusicherung darunter
    /// rot. Was sie NICHT aufgibt, ist die Lokalität — alle weiteren
    /// Zusicherungen (Wasser, Bewuchs, Kruste unter Wasser) vergleichen
    /// weiterhin innerhalb EINES Beckens.
    func testDriedBedIsRenderedAsPlaya() {
        let t = Terrain(config: dryCfg(), seed: 1337)
        for _ in 0..<10 { t.step(dtYears: 200) } // Kruste/Spiegel einschwingen
        let basins = endorheicBasins(t)
        XCTAssertFalse(basins.isEmpty, "kein abflussloses Becken")
        let basin = basins.max { playaCells(t, $0).count < playaCells(t, $1).count } ?? []
        let bed = playaCells(t, basin)
        XCTAssertGreaterThan(bed.count, 100, "keine Salzpfanne entstanden")
        for k in bed {
            // `hf` steht auf dem Beckenboden (Deckel setzt hf = h); die Droplets
            // graben danach im selben Schritt noch ein paar 1e-4 tiefer, deshalb
            // gegen die Render-Schwelle prüfen statt auf Gleichheit.
            XCTAssertLessThan(t.hf[k] - t.h[k], 0.005, "Playa-Zelle führt noch Wasser")
            XCTAssertLessThan(t.waterLevel[k] - t.h[k], 0.03,
                              "Darstellungs-Seespiegel malt die Playa weiter blau")
        }
        // Bewuchs: auf der voll verkrusteten Pfanne geht das Vegetations-Ziel auf
        // 0 (target × (1 − Kruste)), teilverkrustete Ränder dürfen grün bleiben.
        let crusted = bed.filter { t.saltCrust[$0] > 0.9 }
        XCTAssertGreaterThan(crusted.count, 20, "keine voll verkrustete Pfannenfläche")
        for k in crusted { XCTAssertLessThan(t.veg[k], 0.2, "Salzpfanne begrünt") }
        // Und die Kruste baut sich wieder ab, wenn Wasser zurückkommt: über der
        // Wasserfläche liegt sie deutlich unter der der Pfanne (die EWMA braucht
        // dafür ~3·400 Jahre, ein einzelner Schritt reicht nicht — deshalb der
        // Vergleich der Mittelwerte, nicht eine Schwelle je Zelle).
        //
        // Die Restwasserfläche ist eine ZUSICHERUNG, kein `if`. Hier stand
        // `if submerged.count > 20 { … }`: mit der Auswahl über die größte
        // Pfanne wählt der Wächter tendenziell das am stärksten ausgetrocknete
        // Becken, und ein Becken ohne Restsee hätte diese Abnahme still
        // übersprungen statt sie zu prüfen — dieselbe Doktrin wie bei
        // `testBalanceLevelIsFramerateIndependent` und `MeasurementGate`: kein
        // Wächter schaltet sich unbemerkt selbst ab. Dass die Pfanne NEBEN
        // einem Restsee liegt, ist zudem genau der Sachverhalt, den die Abnahme
        // braucht (trockene Pfanne gegen benetzten Boden IM SELBEN Becken).
        // GEMESSEN (s. die `[KRUSTE]`-Zeile jedes Laufs): 669 Wasserzellen
        // gegen 577 Pfannenzellen unter macOS, 1224 gegen 172 unter Linux —
        // beide Plattformen führen die Abnahme also wirklich aus, an
        // verschiedenen Becken.
        let submerged = basin.filter { t.endorheicBasin[$0] == .water }
        XCTAssertGreaterThan(submerged.count, 20,
                             "kein Restsee im Pfannen-Becken — die Abnahme"
                             + " „Kruste baut sich unter Wasser ab\" hätte nichts"
                             + " zu vergleichen")
        let crustWet = submerged.isEmpty ? 0
            : submerged.reduce(0.0) { $0 + t.saltCrust[$1] } / Double(submerged.count)
        let crustDry = bed.reduce(0.0) { $0 + t.saltCrust[$1] } / Double(bed.count)
        print(String(format: "[KRUSTE] Becken %d Zellen · Pfanne %d (%d voll) ·"
                     + " Restsee %d · Kruste nass %.4f gegen trocken %.4f",
                     basin.count, bed.count, crusted.count, submerged.count,
                     crustWet, crustDry))
        XCTAssertLessThan(crustWet, 0.6 * crustDry,
                          "Salzkruste unter Wasser so stark wie auf der Pfanne")
    }

    // MARK: - Determinismus

    func testEndorheicIsDeterministic() {
        let a = Terrain(config: cfg(n: 160), seed: 4242)
        let b = Terrain(config: cfg(n: 160), seed: 4242)
        for _ in 0..<5 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertEqual(a.endorheicBasin, b.endorheicBasin)
        XCTAssertEqual(a.saltCrust, b.saltCrust)
        XCTAssertEqual(a.hf, b.hf)
    }

    // MARK: - Messreihe (Kalibrierung)

    /// MESSREIHE: See-Anteil und Zahl/Fläche der verdunstungs-limitierten Becken
    /// über κ. Kein Assert — die Zahlen stehen im Config-Logbuch und in
    /// docs/endorheic-evaporation-measurements.md.
    func testEvapRatioMeasurementDiagnostic() throws {
        try skipUnlessMeasuring()
        for kappa: Double in [0, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0] {
            for seed: UInt32 in [1337, 42, 2024] {
                var c = cfg(kappa: kappa)
                if kappa == 0 { c.endorheicEvaporation = false }
                let t = Terrain(config: c, seed: seed)
                func line(_ tag: String) -> String {
                    let any = t.lakeStats(), vis = t.lakeStats(depth: 0.03)
                    let e = t.endorheicStats()
                    let salt = t.saltCrust.reduce(0) { $0 + ($1 > 0.5 ? 1 : 0) }
                    return String(format: "%@ See %.2f%%/%d sichtbar %.2f%% | Becken %d (W %d, T %d) Salz %d",
                                  tag, any.fraction * 100, any.largest, vis.fraction * 100,
                                  e.basins, e.water, e.dryBed, salt)
                }
                let gen = line("gen")
                while t.years < 10_000 - 1e-6 { t.step(dtYears: 1000) }
                print(String(format: "[EVAP] κ=%.2f seed %u: %@ → %@ relief %.4f",
                             kappa, seed, gen, line("10k"), t.landReliefRobust()))
            }
        }
    }

    /// MESSREIHE: das natürliche κ der Landschaft — je gefülltem Becken das
    /// Verhältnis ZUFLUSS zu SEEFLÄCHE (in Zellen; weil der Abfluss auf sein
    /// Landmittel normiert ist, IST das das Einzugsgebiet-zu-Seefläche-
    /// Verhältnis). Ein Becken wird gedeckelt, sobald κ über diesem Wert liegt.
    /// Gemessen mit ausgeschalteter Verdunstung, damit die Becken auf ihrem
    /// Vollstand stehen.
    func testBasinRatioMeasurementDiagnostic() throws {
        try skipUnlessMeasuring()
        let big = ProcessInfo.processInfo.environment["RS_EVAP_N"].flatMap { Int($0) }
        for seed: UInt32 in [1337, 42, 2024] {
            var c = cfg(n: big ?? 256); c.endorheicEvaporation = false
            if big != nil { c.hydraulicSkipWaterSpawns = true; c.meanderSpatialCutoffIndex = true }
            let t = Terrain(config: c, seed: seed)
            for target in (big != nil ? [0.0, 5000.0] : [0.0, 10_000.0]) {
                while t.years < target - 1e-6 { t.step(dtYears: 1000) }
                let cellArea = t.cfg.cellSize * t.cfg.cellSize
                var seen = [Bool](repeating: false, count: t.cfg.count)
                var basins: [(cells: Int, ratio: Double, depth: Double)] = []
                for s in 0..<t.cfg.count where !seen[s] && t.hf[s] > t.cfg.sea && t.hf[s] > t.h[s] {
                    let sill = t.hf[s]
                    var stack = [s]; seen[s] = true
                    var cells = 0, inflow = 0.0, maxDepth = 0.0
                    while let k = stack.popLast() {
                        cells += 1
                        inflow = max(inflow, t.area[k])
                        maxDepth = max(maxDepth, t.hf[k] - t.h[k])
                        let i = k % t.cfg.n, j = k / t.cfg.n
                        for dj in -1...1 {
                            for di in -1...1 {
                                let ni = i + di, nj = j + dj
                                if ni < 0 || ni >= t.cfg.n || nj < 0 || nj >= t.cfg.n { continue }
                                let nb = nj * t.cfg.n + ni
                                if !seen[nb] && t.hf[nb] == sill && t.hf[nb] > t.h[nb] {
                                    seen[nb] = true; stack.append(nb)
                                }
                            }
                        }
                    }
                    basins.append((cells, inflow / cellArea / Double(cells), maxDepth))
                }
                basins.sort { $0.cells > $1.cells }
                let top = basins.prefix(10).map {
                    String(format: "%d Z ratio %.2f tief %.3f", $0.cells, $0.ratio, $0.depth)
                }.joined(separator: " · ")
                // Anteil der Ponding-FLÄCHE, die bei gegebenem κ gedeckelt würde.
                let total = basins.reduce(0) { $0 + $1.cells }
                let hit = [0.75, 1.0, 1.25, 1.5, 2.0, 3.0].map { k -> String in
                    let c = basins.filter { $0.ratio < k }.reduce(0) { $0 + $1.cells }
                    return String(format: "κ%.2f→%.0f%%", k, 100 * Double(c) / Double(max(1, total)))
                }.joined(separator: " ")
                print("[RATIO] seed \(seed) J\(Int(target)) n=\(t.cfg.n): \(basins.count) Becken, "
                      + "\(total) Ponding-Zellen — \(top) | gedeckelte Fläche: \(hit)")
            }
        }
    }

    /// MESSREIHE: dasselbe in Produktionsauflösung (n=832) für einen Seed —
    /// die Becken-Größenverteilung hängt an der Auflösung.
    func testProductionResolutionMeasurementDiagnostic() throws {
        try skipUnlessMeasuring()
        for kappa: Double in [0, 1.0, 1.25, 1.5, 2.0, 3.0] {
            var c = cfg(n: 832, kappa: kappa)
            c.hydraulicSkipWaterSpawns = true
            c.meanderSpatialCutoffIndex = true
            if kappa == 0 { c.endorheicEvaporation = false }
            let t = Terrain(config: c, seed: 1337)
            var log = ""
            for target in [0.0, 5000.0, 20000.0] {
                while t.years < target - 1e-6 { t.step(dtYears: 1000) }
                let s = t.lakeStats(), vis = t.lakeStats(depth: 0.03), e = t.endorheicStats()
                let salt = t.saltCrust.reduce(0) { $0 + ($1 > 0.5 ? 1 : 0) }
                log += String(format: " | J%.0fk See %.2f%%/%d sichtbar %.2f%% Becken %d (W %d, T %d) Salz %d",
                              target / 1000, s.fraction * 100, s.largest, vis.fraction * 100,
                              e.basins, e.water, e.dryBed, salt)
            }
            print("[EVAP832] κ=\(kappa)\(log) relief \(t.landReliefRobust())")
        }
    }
}
