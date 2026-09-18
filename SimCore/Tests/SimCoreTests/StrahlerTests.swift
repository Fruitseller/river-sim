import XCTest
@testable import SimCore

/// Wächter für die Strahler-Ordnung auf dem D8-Netz (Issue #31).
/// Abnahmepunkte:
///  - Kernel: Quelle=1, gleichrangige Zusammenflüsse erhöhen (+1), ungleichrangige
///    behalten den Maximalrang; Nicht-Netz-Zellen sind 0 und zählen nicht als Donor.
///  - Terrain-Integration: Ordnung ist stromabwärts monoton nicht-fallend entlang
///    `receiver` (innerhalb des Netzes) und deterministisch (gleicher Seed → bitgleich).
final class StrahlerTests: XCTestCase {

    // Handgebauter Wald: Indizes sind abstrakte Zellen, receiver[-1] = Senke.

    func testLinearChainIsOrderOne() {
        // 0 → 1 → 2 → 3 → Senke
        let receiver: [Int32] = [1, 2, 3, -1]
        let net = [Bool](repeating: true, count: 4)
        let o = Strahler.orders(receiver: receiver, isNetwork: net)
        XCTAssertEqual(o, [1, 1, 1, 1])
    }

    func testEqualOrderJunctionIncrements() {
        // Zwei Quellen (0,1) münden in 2; 2 → 3 → Senke.
        let receiver: [Int32] = [2, 2, 3, -1]
        let net = [Bool](repeating: true, count: 4)
        let o = Strahler.orders(receiver: receiver, isNetwork: net)
        XCTAssertEqual(o, [1, 1, 2, 2])
    }

    func testUnequalJunctionKeepsMax() {
        // Ordnung-2-Strang (0,1→2→3) bekommt einen Ordnung-1-Zufluss (4) bei 3:
        // bleibt 2. Erst der Zusammenfluss zweier 2er (5,6→3? nein) — hier nur Max-Erhalt.
        let receiver: [Int32] = [2, 2, 3, -1, 3]
        let net = [Bool](repeating: true, count: 5)
        let o = Strahler.orders(receiver: receiver, isNetwork: net)
        XCTAssertEqual(o[2], 2)
        XCTAssertEqual(o[4], 1)
        XCTAssertEqual(o[3], 2, "1er-Zufluss darf einen 2er nicht erhöhen")
    }

    func testTwoSecondOrdersMakeThird() {
        // Zwei getrennte 2er-Zusammenflüsse (0,1→4) und (2,3→5) münden beide in 6.
        let receiver: [Int32] = [4, 4, 5, 5, 6, 6, -1]
        let net = [Bool](repeating: true, count: 7)
        let o = Strahler.orders(receiver: receiver, isNetwork: net)
        XCTAssertEqual(o[4], 2)
        XCTAssertEqual(o[5], 2)
        XCTAssertEqual(o[6], 3)
    }

    func testNonNetworkCellsAreZeroAndDontFeed() {
        // 0 (kein Netz) → 1 (Netz): 1 ist Quelle (Ordnung 1), 0 bleibt 0.
        // 2,3 (kein Netz) → 4 (Netz) → 1: 4 ist Quelle, Junction 1 bleibt...
        // 4→1 und niemand sonst → 1 hat genau einen Netz-Donor → Ordnung 1.
        let receiver: [Int32] = [1, -1, 4, 4, 1]
        let net = [false, true, false, false, true]
        let o = Strahler.orders(receiver: receiver, isNetwork: net)
        XCTAssertEqual(o[0], 0)
        XCTAssertEqual(o[2], 0)
        XCTAssertEqual(o[3], 0)
        XCTAssertEqual(o[4], 1)
        XCTAssertEqual(o[1], 1, "einzelner Netz-Donor erhöht nicht")
    }

    // ---- Terrain-Integration ----

    private func cfg(n: Int) -> SimConfig {
        var c = SimConfig()
        c.n = n; c.world = calibrationWorld
        return c
    }

    func testTerrainOrdersMonotoneDownstream() {
        let t = Terrain(config: cfg(n: 96), seed: 1234)
        for _ in 0..<3 { t.step(dtYears: 1000) }
        let minCells = 12.0
        let o = t.strahlerOrders(minCells: minCells)
        let cellArea = t.cfg.cellSize * t.cfg.cellSize
        var networkCells = 0
        for k in 0..<(t.cfg.n * t.cfg.n) {
            let inNet = t.area[k] / cellArea >= minCells && t.hf[k] > t.cfg.sea
            if !inNet {
                XCTAssertEqual(o[k], 0)
                continue
            }
            networkCells += 1
            XCTAssertGreaterThanOrEqual(o[k], 1)
            let r = Int(t.receiver[k])
            if r >= 0, o[r] >= 1 {
                XCTAssertGreaterThanOrEqual(o[r], o[k],
                    "Ordnung darf stromabwärts nicht fallen (k=\(k) → r=\(r))")
            }
        }
        XCTAssertGreaterThan(networkCells, 50, "Netz darf nicht leer sein")
        let maxOrder = o.max() ?? 0
        XCTAssertGreaterThanOrEqual(maxOrder, 2, "es muss echte Zusammenflüsse geben")
    }

    func testTerrainOrdersDeterministic() {
        let a = Terrain(config: cfg(n: 96), seed: 4242)
        let b = Terrain(config: cfg(n: 96), seed: 4242)
        for _ in 0..<3 { a.step(dtYears: 1000); b.step(dtYears: 1000) }
        XCTAssertEqual(a.strahlerOrders(minCells: 12), b.strahlerOrders(minCells: 12))
    }

    /// Empfänger-Indizes außerhalb des Gitters (r >= n oder r < -1) dürfen
    /// nicht zu Speicherzugriffsfehlern führen und werden wie Senken behandelt.
    func testOrdersWithOutOfBoundsReceivers() {
        // 0 zeigt auf 99 (außerhalb des Gitters), 1 zeigt auf 0, 2 zeigt auf -5 (ungültige negative Senke)
        let receiver: [Int32] = [99, 0, -5]
        let net = [true, true, true]
        let o = Strahler.orders(receiver: receiver, isNetwork: net)
        XCTAssertEqual(o.count, 3)
        XCTAssertEqual(o[0], 1, "Zelle 0 empfängt von Zelle 1 und entwässert nach außerhalb")
        XCTAssertEqual(o[1], 1, "Quelle mit Ordnung 1")
        XCTAssertEqual(o[2], 1, "Isolierte Zelle mit Ordnung 1")

        // Mismatch der Array-Längen liefert defensiv Nuller statt abzustürzen
        let mismatched = Strahler.orders(receiver: [0, 1], isNetwork: [true])
        XCTAssertEqual(mismatched, [0, 0])
    }

    /// Leeres Terrain sowie nicht-endliche oder nicht-positive Schwellen (NaN, <= 0)
    /// müssen sicher abgefangen werden.
    func testStrahlerOrdersWithEmptyTerrainAndNonFiniteOrNonPositiveMinCells() {
        let empty = Terrain(allocating: cfg(n: 0), seed: 1234)
        XCTAssertEqual(empty.strahlerOrders(minCells: 12), [], "Leeres Terrain muss leere Ordnungen liefern")

        let normal = Terrain(config: cfg(n: 96), seed: 1234)
        // Nicht-endliche oder nicht-positive minCells-Werte dürfen kein fehlerhaftes Vollnetz erzeugen
        let nanOrders = normal.strahlerOrders(minCells: .nan)
        XCTAssertEqual(nanOrders.count, 96 * 96)
        XCTAssertTrue(nanOrders.allSatisfy { $0 == 0 }, "NaN-Schwelle darf kein Netz ausweisen")

        let infOrders = normal.strahlerOrders(minCells: .infinity)
        XCTAssertTrue(infOrders.allSatisfy { $0 == 0 }, "Unendliche Schwelle darf kein Netz ausweisen")

        let zeroOrders = normal.strahlerOrders(minCells: 0)
        XCTAssertTrue(zeroOrders.allSatisfy { $0 == 0 }, "Null-Schwelle darf kein Netz ausweisen")

        let negOrders = normal.strahlerOrders(minCells: -10)
        XCTAssertTrue(negOrders.allSatisfy { $0 == 0 }, "Negative Schwelle darf kein Netz ausweisen")
    }
}
