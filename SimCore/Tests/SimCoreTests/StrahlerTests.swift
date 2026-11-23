import XCTest
@testable import SimCore

final class StrahlerTests: XCTestCase {

    func testLinearChainIsOrderOne() {
        let receiver: [Int32] = [1, 2, 3, -1]
        let net = [Bool](repeating: true, count: 4)
        let o = Strahler.orders(receiver: receiver, isNetwork: net)
        XCTAssertEqual(o, [1, 1, 1, 1])
    }

    func testEqualOrderJunctionIncrements() {
        let receiver: [Int32] = [2, 2, 3, -1]
        let net = [Bool](repeating: true, count: 4)
        let o = Strahler.orders(receiver: receiver, isNetwork: net)
        XCTAssertEqual(o, [1, 1, 2, 2])
    }

    func testUnequalJunctionKeepsMax() {
        let receiver: [Int32] = [2, 2, 3, -1, 3]
        let net = [Bool](repeating: true, count: 5)
        let o = Strahler.orders(receiver: receiver, isNetwork: net)
        XCTAssertEqual(o[2], 2)
        XCTAssertEqual(o[4], 1)
        XCTAssertEqual(o[3], 2, "1er-Zufluss darf einen 2er nicht erhöhen")
    }

    func testTwoSecondOrdersMakeThird() {
        let receiver: [Int32] = [4, 4, 5, 5, 6, 6, -1]
        let net = [Bool](repeating: true, count: 7)
        let o = Strahler.orders(receiver: receiver, isNetwork: net)
        XCTAssertEqual(o[4], 2)
        XCTAssertEqual(o[5], 2)
        XCTAssertEqual(o[6], 3)
    }

    func testNonNetworkCellsAreZeroAndDontFeed() {
        let receiver: [Int32] = [1, -1, 4, 4, 1]
        let net = [false, true, false, false, true]
        let o = Strahler.orders(receiver: receiver, isNetwork: net)
        XCTAssertEqual(o[0], 0)
        XCTAssertEqual(o[2], 0)
        XCTAssertEqual(o[3], 0)
        XCTAssertEqual(o[4], 1)
        XCTAssertEqual(o[1], 1, "einzelner Netz-Donor erhöht nicht")
    }

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

    func testOrdersWithOutOfBoundsReceivers() {
        let receiver: [Int32] = [99, 0, -5]
        let net = [true, true, true]
        let o = Strahler.orders(receiver: receiver, isNetwork: net)
        XCTAssertEqual(o.count, 3)
        XCTAssertEqual(o[0], 1, "Zelle 0 empfängt von Zelle 1 und entwässert nach außerhalb")
        XCTAssertEqual(o[1], 1, "Quelle mit Ordnung 1")
        XCTAssertEqual(o[2], 1, "Isolierte Zelle mit Ordnung 1")

        let empty = Strahler.orders(receiver: [], isNetwork: [])
        XCTAssertEqual(empty, [])

        #if !DEBUG
        let mismatched = Strahler.orders(receiver: [0, 1], isNetwork: [true])
        XCTAssertEqual(mismatched, [0, 0])
        #endif
    }

    func testStrahlerOrdersWithEmptyTerrainAndNonFiniteOrNonPositiveMinCells() {
        let empty = Terrain(allocating: cfg(n: 0), seed: 1234)
        XCTAssertEqual(empty.strahlerOrders(minCells: 12), [], "Leeres Terrain muss leere Ordnungen liefern")

        let normal = Terrain(config: cfg(n: 96), seed: 1234)
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

    func testStrahlerOrdersWithoutCellSpacingReturnsZeroOrders() {
        var c = cfg(n: 96)
        c.world = 0
        XCTAssertEqual(c.cellSize, 0.0)
        let zeroWorld = Terrain(allocating: c, seed: 1234)
        var s = zeroWorld.state
        s.hf = [Double](repeating: c.sea + 0.1, count: c.count)
        s.area = [Double](repeating: 100.0, count: c.count)
        s.receiver = [Int32](repeating: -1, count: c.count)
        zeroWorld.restore(s)
        let zeroOrders = zeroWorld.strahlerOrders(minCells: 12)
        XCTAssertEqual(zeroOrders.count, 96 * 96)
        XCTAssertTrue(zeroOrders.allSatisfy { $0 == 0 },
                      "Terrain mit world = 0 darf kein Netz ausweisen")

        c.world = -10
        XCTAssertEqual(c.cellSize, 0.0)
        let negWorld = Terrain(allocating: c, seed: 1234)
        negWorld.restore(s)
        let negOrders = negWorld.strahlerOrders(minCells: 12)
        XCTAssertEqual(negOrders.count, 96 * 96)
        XCTAssertTrue(negOrders.allSatisfy { $0 == 0 },
                      "Terrain mit world < 0 darf kein Netz ausweisen")

        c.world = .nan
        XCTAssertEqual(c.cellSize, 0.0)
        let nanWorld = Terrain(allocating: c, seed: 1234)
        nanWorld.restore(s)
        let nanOrders = nanWorld.strahlerOrders(minCells: 12)
        XCTAssertEqual(nanOrders.count, 96 * 96)
        XCTAssertTrue(nanOrders.allSatisfy { $0 == 0 },
                      "Terrain mit nicht-endlicher world darf kein Netz ausweisen")

        var c1 = SimConfig()
        c1.n = 1
        XCTAssertEqual(c1.cellSize, 0.0)
        let singlePoint = Terrain(allocating: c1, seed: 1234)
        var s1 = singlePoint.state
        s1.hf = [c1.sea + 0.1]
        s1.area = [100.0]
        s1.receiver = [-1]
        singlePoint.restore(s1)
        let singleOrders = singlePoint.strahlerOrders(minCells: 12)
        XCTAssertEqual(singleOrders, [0],
                      "1×1-Gitter ohne Schrittweite liefert Ordnung 0")
    }
}

