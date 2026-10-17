import XCTest
@testable import SimCore

/// Wächter der Delta-Schüttung (Issue #174, Abnahmepunkt 26): an einer
/// Flussmündung entstehen aus der Fracht Mündungsbarren — Sandinseln knapp
/// über dem Meer —, zwischen denen die Rinnen als Wasser frei bleiben.
/// Kennzahlen auf den Produktionswelten: `RiverDelta.swift`
/// (`testDeltaBudgetDiagnostic`), Messreihe
/// `docs/zielbild-measurements.md` § Delta.
///
/// Aufbau: ein Kerbtal (Land im Osten), das in der Mitte in eine Meeresrampe
/// mit dem Gefälle der gemessenen Küsten mündet (Meer im Westen). Das Flussnetz
/// kommt aus `computeFlow`, die Fracht wird vorgegeben — so prüft der Test
/// den Pass allein, ohne die Erosion davor.
final class DeltaTests: XCTestCase {

    private static let n = 160
    private static let coast = 60   // erste Meeresspalte von Osten aus: i < coast

    private func world(_ configure: (inout SimConfig) -> Void = { _ in }) -> Terrain {
        var cfg = SimConfig()
        cfg.n = Self.n
        cfg.world = Double(Self.n - 1) * SimConfig().cellSize   // Zellgröße wie Produktion
        configure(&cfg)
        let t = Terrain(allocating: cfg, seed: 1)
        let n = Self.n, sea = cfg.sea
        var h = [Double](repeating: 0, count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                // Land: Kerbtal mit Achse j = n/2 (Seitenhang steiler als das
                // Talgefälle, alles Wasser läuft zur Achse); Meer: Rampe.
                let x = Double(i - Self.coast), dj = abs(Double(j - n / 2))
                let z = x >= 0 ? sea + 0.0005 + 0.003 * x + 0.004 * dj
                               : max(sea - 0.0025 * -x, sea - 0.06)
                h[j * n + i] = z
            }
        }
        t.setBedForTests(h: h, sed: [Double](repeating: 0, count: n * n), rock: h, underIce: [])
        return t
    }

    /// Fracht eines Schritts an der großen Mündung des Tals: der Pass gibt
    /// jeder Mündung Einzugsgebiet × mittleren Abtrag je Landzelle, hier so
    /// gewählt, dass an der Mündung genau `load` ankommt.
    private func deposit(_ t: Terrain, load: Double) {
        t.deltaDepositForTests(yieldPerCell: load / mouth(t).discharge)
    }

    /// Die Mündung mit dem größten Einzugsgebiet (Landzelle mit Meeres-Empfänger).
    private func mouth(_ t: Terrain) -> DeltaMetrics.Mouth {
        let sea = t.cfg.sea
        var best = 0
        for k in 0..<t.cfg.count where t.hf[k] > sea {
            let r = Int(t.receiver[k])
            if r >= 0, t.hf[r] <= sea, t.area[k] > t.area[best] { best = k }
        }
        return DeltaMetrics.Mouth(cell: best, discharge: t.area[best] / (t.cfg.cellSize * t.cfg.cellSize),
                                  dir: (-1, 0), catchment: [])
    }

    /// Kernaussage: Mündungsbarren werden Inseln, die Rinnen bleiben Wasser —
    /// mindestens drei Distributäre mit Sandinseln dazwischen.
    func testMouthBarsBuildIslandsBetweenOpenDistributaries() {
        let t = world()
        for _ in 0..<40 {
            t.computeFlow()
            deposit(t, load: 0.6)
        }
        t.computeFlow()
        let m = mouth(t)
        XCTAssertGreaterThan(m.discharge, 2_000, "Testaufbau: das Tal sammelt keinen Fluss")
        let s = DeltaMetrics.shape(t, m)
        XCTAssertGreaterThanOrEqual(s.arms, 3, "weniger als drei Distributäre")
        XCTAssertGreaterThanOrEqual(s.islands, 1, "keine Sandinsel")
        XCTAssertGreaterThanOrEqual(s.islandCells, 20, "Inseln zu klein")
        // Inseln knapp über dem Meer: nie höher als der Barrenscheitel.
        let sea = t.cfg.sea
        let top = t.h.filter { $0 > sea }.count
        XCTAssertGreaterThan(top, 0)
        let n = Self.n
        var maxIsland = 0.0
        for j in 0..<n { for i in 0..<Self.coast where t.h[j * n + i] > sea {
            maxIsland = max(maxIsland, t.h[j * n + i] - sea)
        } }
        XCTAssertLessThanOrEqual(maxIsland, t.cfg.deltaTopset + 1e-12, "Delta-Insel über dem Scheitel")
        // Die Rinne direkt vor der Mündung bleibt offen.
        let mi = m.cell % n, mj = m.cell / n
        for i in (mi - 4)..<mi {
            XCTAssertLessThanOrEqual(t.h[mj * n + i], sea, "Mündungsrinne zugeschüttet bei i = \(i)")
        }
    }

    /// Ohne Fracht-Anteil ist der Pass aus und rührt das Gelände nicht an.
    func testZeroTrapFractionLeavesTheTerrainUntouched() {
        let t = world { $0.deltaTrapFraction = 0 }
        t.computeFlow()
        let before = t.h
        deposit(t, load: 0.6)
        XCTAssertEqual(t.h, before)
    }

    /// dt: dieselbe Fracht in halb so vielen, doppelt so großen Schritten
    /// liefert dieselbe Form (Barren sind geometrische Obergrenzen, die
    /// Füllreihenfolge ist fest).
    func testSameLoadInFewerStepsBuildsTheSameDelta() {
        func run(steps: Int, load: Double) -> (land: Int, deposit: Double) {
            let t = world()
            let before = t.h.reduce(0, +)
            for _ in 0..<steps {
                t.computeFlow()
                deposit(t, load: load)
            }
            return (t.h.filter { $0 > t.cfg.sea }.count, t.h.reduce(0, +) - before)
        }
        let fine = run(steps: 40, load: 0.3), coarse = run(steps: 20, load: 0.6)
        XCTAssertGreaterThan(fine.deposit, 0)
        XCTAssertEqual(Double(fine.land), Double(coarse.land), accuracy: 0.02 * Double(fine.land),
                       "Inselfläche hängt an der Schrittweite")
        XCTAssertEqual(fine.deposit, coarse.deposit, accuracy: 0.02 * fine.deposit,
                       "Ablagerung hängt an der Schrittweite")
    }
}
