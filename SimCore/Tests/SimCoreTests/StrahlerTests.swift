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
        c.n = n
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
}
