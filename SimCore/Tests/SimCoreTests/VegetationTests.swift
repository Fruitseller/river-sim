import XCTest
@testable import SimCore

/// Tests der Vegetations-Stufen 2 (Veg-Typen + Ufer-Kohäsion) und 3 (Störung +
/// Sukzession). Neue Parameter werden HIER gepinnt bzw. explizit gesetzt —
/// die alten Test-Configs (meanderCfg etc.) bleiben unangetastet.
final class VegetationTests: XCTestCase {

    // MARK: - Stufe 2: Klassen

    /// Auwald (Klasse 3) entsteht auf dem Produktions-Pfad — und NUR flussnah,
    /// flach und nicht tief überflutet (die Ableitungs-Regeln halten).
    func testRiparianClassOnlyNearWater() {
        var c = SimConfig(); c.n = 192
        let t = Terrain(config: c, seed: 1337)
        for _ in 0..<10 { t.step(dtYears: 500) }
        let n = c.n
        let cellArea = c.cellSize * c.cellSize
        let minA = c.braidMinCells * cellArea
        var riparianCount = 0
        for j in 2..<(n - 2) {
            for i in 2..<(n - 2) {
                let k = j * n + i
                guard t.vegClass[k] == 3 else { continue }
                riparianCount += 1
                // flussnah: Wasser-Quelle (substanzieller Lauf oder stehendes
                // Wasser) im Dilatations-Umkreis (2 Ringe + 1 Toleranz).
                // Erwartung auf `area` (D8) umgestellt: die Quellmaske in
                // updateVegClass las früher `areaMFD`, womit das MFD-Netz über
                // vegClass → vegDamp in die Erosion floss — das verletzt die
                // Netz-Trennung aus AGENTS.md (MFD nur Render/Braiding). Der
                // Test spiegelt jetzt dieselbe D8-Quelle wie die Ableitung.
                var nearWater = false
                for dj in max(0, j - 3)...min(n - 1, j + 3) {
                    for di in max(0, i - 3)...min(n - 1, i + 3) {
                        let kk = dj * n + di
                        if t.hf[kk] > c.sea
                            && (t.area[kk] >= minA || t.hf[kk] - t.h[kk] > 0.015) {
                            nearWater = true
                        }
                    }
                }
                XCTAssertTrue(nearWater, "Auwald-Zelle (\(i),\(j)) ohne Wasser im Umkreis")
                // flach (Grob-Steigung wie in der Ableitung) + nicht tief geflutet
                let slope = (abs(t.h[k + 2] - t.h[k - 2]) + abs(t.h[k + 2 * n] - t.h[k - 2 * n])) * 0.125
                XCTAssertLessThan(slope * 40, 0.6, "Auwald auf steilem Hang (\(i),\(j))")
                XCTAssertLessThanOrEqual(t.hf[k] - t.h[k], 0.02, "Auwald unter Wasser (\(i),\(j))")
            }
        }
        XCTAssertGreaterThan(riparianCount, 0, "kein Auwald entstanden")
    }

    /// Auf dem Wasserlauf SELBST wächst kein Gehölz — weder Auwald (3) noch
    /// Wald (2). Sonst liegt eine Wurzel-Kohäsion (1.3 bzw. 1.1) auf dem
    /// Gerinne und panzert den Talboden; die stehen gebliebenen Knubbel im
    /// breiten MFD-Lauf hat `testBraidingBuildsBars` als „Inseln" gezählt
    /// (Braiding-Regression Aug 2026, s. updateVegClass). Bett = Gras heißt
    /// zugleich: dort gilt exakt die Vor-Merge-Dämpfung 1 − 0.6·veg.
    func testNoWoodlandOnTheChannelBed() {
        var c = SimConfig(); c.n = 192
        let t = Terrain(config: c, seed: 1337)
        for _ in 0..<10 { t.step(dtYears: 500) }
        let n = c.n
        let minA = c.braidMinCells * c.cellSize * c.cellSize
        var bed = 0
        for j in 2..<(n - 2) {
            for i in 2..<(n - 2) {
                let k = j * n + i
                // Bett = die Quellmaske aus updateVegClass (D8-Lauf oder
                // stehendes Wasser), nur über Meeresniveau.
                guard t.hf[k] > c.sea,
                      t.area[k] >= minA || t.hf[k] - t.h[k] > 0.02 else { continue }
                bed += 1
                XCTAssertLessThan(t.vegClass[k], 2,
                                  "Gehölz-Klasse \(t.vegClass[k]) auf Bett-Zelle (\(i),\(j))")
                // …und damit exakt die Alt-Dämpfung auf dem Gerinne.
                XCTAssertEqual(t.vegDamp(k), max(0, 1 - 0.6 * t.veg[k]), accuracy: 1e-15)
            }
        }
        XCTAssertGreaterThan(bed, 0, "keine Bett-Zelle gefunden — Test leer")
    }

    /// Alle bestehenden veg-Konsumenten bleiben mit Klassen {0, 1} (kahl/Gras)
    /// unverändert: typFactor(Gras) = 1.0 ⇒ vegDamp == (1 − 0.6·veg).
    func testGrassFactorMatchesLegacyDamping() {
        var c = SimConfig(); c.n = 96
        let t = Terrain(config: c, seed: 7)
        for k in 0..<c.count where t.vegClass[k] <= 1 {
            XCTAssertEqual(t.vegDamp(k), max(0, 1 - 0.6 * t.veg[k]), accuracy: 1e-15)
        }
    }

    // MARK: - Stufe 2: Ufer-Kohäsion

    private func sineChannel() -> RiverChannel {
        var nodes: [MeanderNode] = []
        var dis: [Double] = []
        for i in 0..<60 {
            nodes.append(MeanderNode(x: 10 + Double(i) * 1.2,
                                     z: 48 + 6 * sin(Double(i) * 0.35)))
            dis.append(200)
        }
        return RiverChannel(nodes: nodes, discharge: dis)
    }

    /// Migration mit voll bewachsenem Ufer-Streifen < ohne Bewuchs (gepinnte
    /// Test-Config: alte Migrations-Rate wie meanderCfg, Kohäsion 0.5).
    func testRiparianCohesionSlowsMigration() {
        var cfg = SimConfig(); cfg.n = 96
        cfg.meanderMigration = 5.0e-5
        cfg.meanderCohesion = 0.5
        func grownSinuosity(_ rip: @escaping (MeanderNode) -> Double) -> Double {
            let st = MeanderState()
            st.channels = [sineChannel()]
            for _ in 0..<20 { st.migrate(dt: 50, config: cfg, riparianAt: rip) }
            return st.channels[0].sinuosity
        }
        let bare = grownSinuosity { _ in 0 }
        let forested = grownSinuosity { _ in 1 }
        XCTAssertGreaterThan(bare, 1.0, "Referenzlauf müsste Schlingen aufbauen")
        XCTAssertLessThan(forested, bare, "bewaldetes Ufer muss langsamer migrieren")
        // Kohäsion 0.5 × riparian 1.0 halbiert die Rate — der Effekt muss
        // deutlich sein, nicht nur Rundungsrauschen.
        XCTAssertLessThan((forested - 1), (bare - 1) * 0.8)
    }

    /// Kohäsion 0 (gepinnter Alt-Zustand) ist ein exakter No-Op: gleiche
    /// Trajektorie wie ganz ohne riparianAt-Callback.
    func testCohesionZeroIsNoOp() {
        var cfg = SimConfig(); cfg.n = 96
        cfg.meanderMigration = 5.0e-5
        cfg.meanderCohesion = 0
        let a = MeanderState(); a.channels = [sineChannel()]
        let b = MeanderState(); b.channels = [sineChannel()]
        for _ in 0..<10 {
            a.migrate(dt: 50, config: cfg)
            b.migrate(dt: 50, config: cfg, riparianAt: { _ in 1 })
        }
        XCTAssertEqual(a.channels[0].nodes, b.channels[0].nodes)
    }

    // MARK: - Stufe 3: Flood-Kill

    /// Sucht eine dicht bewachsene Land-Zelle abseits des Rands.
    private func pickVegetatedCell(_ t: Terrain) -> Int {
        let n = t.cfg.n
        for j in 10..<(n - 10) {
            for i in 10..<(n - 10) {
                let k = j * n + i
                if t.veg[k] > 0.45 && t.h[k] > t.cfg.sea + 0.05 { return k }
            }
        }
        return -1
    }

    /// Tief überflutete Zellen verlieren ihre Vegetation mit τ_kill (~3τ bis
    /// praktisch kahl) — nicht mit der trägen 250a-Relaxation.
    func testFloodKillClearsVegetation() {
        var c = SimConfig(); c.n = 96
        let t = Terrain(config: c, seed: 1337)
        let pick = pickVegetatedCell(t)
        XCTAssertGreaterThanOrEqual(pick, 0, "keine bewachsene Zelle gefunden — Test leer")
        let n = c.n
        let pi = pick % n, pj = pick / n
        let vBefore = t.veg[pick]
        // Senke graben → Priority-Flood pondet sie → Flood-Kill-Regime.
        for _ in 0..<40 {
            t.sculpt(gx: Double(pi), gz: Double(pj), radiusWorld: 5 * c.cellSize, dir: -1)
        }
        t.computeFlow()
        XCTAssertGreaterThan(t.hf[pick] - t.h[pick], c.vegFloodKillDepth,
                             "Senke pondet nicht — Test-Setup kaputt")
        t.updateVegetation(years: 3 * c.vegFloodKillYears)
        XCTAssertLessThan(t.veg[pick], vBefore * 0.1,
                          "Flood-Kill wirkt nicht (\(vBefore) → \(t.veg[pick]))")
    }

    /// Nach dem Ende der Störung wächst die Fläche innerhalb ~3·τ wieder zu
    /// (Sukzession: Samen-Druck der intakten Nachbarn + Relaxation).
    func testRegrowthAfterKill() {
        var c = SimConfig(); c.n = 96
        // Isoliert die VEGETATIONS-Relaxation: der Störungs-/Regenerationspfad
        // (Issue #26) hält frisch umgegrabenen Boden bewusst über sein
        // Abklingfenster kahl und wird über `step()` abgebaut — dieser Test
        // ruft aber nur `updateVegetation` und würde sonst eine Störung messen,
        // die er nie beenden kann. Eigene Wächter: `FlattenRegeneration`.
        c.disturbanceEnabled = false
        let t = Terrain(config: c, seed: 1337)
        let pick = pickVegetatedCell(t)
        XCTAssertGreaterThanOrEqual(pick, 0)
        let n = c.n
        let pi = pick % n, pj = pick / n
        let vBefore = t.veg[pick]
        let hBefore = t.h[pick]
        for _ in 0..<40 {
            t.sculpt(gx: Double(pi), gz: Double(pj), radiusWorld: 5 * c.cellSize, dir: -1)
        }
        t.computeFlow()
        t.updateVegetation(years: 3 * c.vegFloodKillYears) // Störung: Fläche stirbt
        XCTAssertLessThan(t.veg[pick], 0.1)
        // Störung beenden: Senke wieder auf die alte Höhe ziehen.
        for _ in 0..<200 {
            t.flatten(gx: Double(pi), gz: Double(pj), radiusWorld: 6 * c.cellSize,
                      targetHeight: hBefore)
        }
        t.computeFlow()
        XCTAssertLessThanOrEqual(t.hf[pick] - t.h[pick], 0.015, "Senke pondet noch — Setup")
        // ~3τ in Teilschritten (f < 1, echte Relaxations-Dynamik statt Sprung).
        for _ in 0..<6 { t.updateVegetation(years: 125) }
        XCTAssertGreaterThan(t.veg[pick], vBefore * 0.5,
                             "Regrünung zu langsam (\(vBefore) → \(t.veg[pick]))")
    }

    // MARK: - Stufe 3: kein Spontanwald

    /// Geografisch kahle Standorte (Ziel ≈ 0: steil/hoch/nass) bleiben kahl,
    /// auch wenn direkt daneben dichter Bewuchs steht — der Samen-Druck der
    /// Sukzession ist auf bewohnbare Standorte gegated.
    func testBareSitesStayBareDespiteSeeds() {
        var c = SimConfig(); c.n = 96
        let t = Terrain(config: c, seed: 1337)
        let n = c.n
        for _ in 0..<5 { t.updateVegetation(years: 250) }
        var checked = 0
        for j in 2..<(n - 2) {
            for i in 2..<(n - 2) {
                let k = j * n + i
                // geografisches Ziel nachrechnen (Formel aus updateVegetation)
                let v = t.h[k]
                var target = 0.0
                if v > c.sea + 0.005 && v < 0.68 && t.hf[k] - t.h[k] <= 0.015 {
                    let slope = (abs(t.h[k + 2] - t.h[k - 2]) + abs(t.h[k + 2 * n] - t.h[k - 2 * n])) * 0.125
                    target = max(0, 1 - slope * 40) * min(1, t.rain[k] * 1.3)
                           * (v < 0.5 ? 1 : max(0, 1 - (v - 0.5) / 0.18))
                }
                guard target < 0.01 else { continue }
                var seed = 0.0
                for dj in -2...2 {
                    for di in -2...2 { seed = max(seed, t.veg[(j + dj) * n + i + di]) }
                }
                guard seed > 0.3 else { continue }
                checked += 1
                XCTAssertLessThan(t.veg[k], 0.08, "Spontanwald auf kahlem Standort (\(i),\(j))")
            }
        }
        XCTAssertGreaterThan(checked, 0, "keine kahle Zelle mit Samen-Druck gefunden — Test leer")
    }

    // MARK: - Stufe 3: Ufer-Kill

    /// Frisch vom Mäander-Pass gestempelte Bett-Zellen verlieren ihre
    /// Vegetation komplett (Wurzel-Wegriss); der Mini-Schritt danach lässt der
    /// Regrünung keine Zeit (f ≈ 0.004) — veg muss dort ≈ 0 sein.
    func testMeanderStampKillsBedVegetation() {
        var c = SimConfig(); c.n = 96
        let t = Terrain(config: c, seed: 1337)
        for _ in 0..<6 { t.step(dtYears: 500) }
        t.step(dtYears: 1)
        var bed = 0
        for k in 0..<c.count where t.isChannel[k] {
            bed += 1
            XCTAssertLessThan(t.veg[k], 0.02, "Bett-Zelle \(k) behielt Vegetation")
        }
        XCTAssertGreaterThan(bed, 0, "keine Kanal-Zellen gestempelt — Test leer")
    }

    // MARK: - Stufe 3: Determinismus

    /// Gleicher Seed → bit-identische veg-/vegClass-Felder, auch nach
    /// Simulation (Dispersal-/Kill-Pässe sind parallel, aber disjunkt).
    func testVegetationDeterminism() {
        var c = SimConfig(); c.n = 96
        let a = Terrain(config: c, seed: 99)
        let b = Terrain(config: c, seed: 99)
        for _ in 0..<8 { a.step(dtYears: 500); b.step(dtYears: 500) }
        XCTAssertEqual(a.h, b.h)
        XCTAssertEqual(a.veg, b.veg)
        XCTAssertEqual(a.vegClass, b.vegClass)
    }
}
