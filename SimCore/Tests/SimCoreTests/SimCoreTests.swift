import XCTest
@testable import SimCore

final class SimCoreTests: XCTestCase {

    private func makeConfig(n: Int = 96) -> SimConfig {
        var c = SimConfig()
        c.n = n
        return c
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

    /// Große Zeitschritte müssen stabil sein (Vorteil des impliziten Solvers):
    /// ein 100k-Sprung darf nicht explodieren.
    func testLargeTimestepStable() {
        let t = Terrain(config: makeConfig(n: 80), seed: 33)
        t.step(dtYears: 100000)
        XCTAssertTrue(t.h.allSatisfy { $0.isFinite })
        XCTAssertLessThan(t.landRelief(), 2.0)
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
}
