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
                var nearWater = false
                for dj in max(0, j - 3)...min(n - 1, j + 3) {
                    for di in max(0, i - 3)...min(n - 1, i + 3) {
                        let kk = dj * n + di
                        if t.hf[kk] > c.sea
                            && (t.areaMFD[kk] >= minA || t.hf[kk] - t.h[kk] > 0.015) {
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
}
