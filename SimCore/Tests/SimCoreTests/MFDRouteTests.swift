import XCTest
@testable import SimCore

final class MFDRouteTests: XCTestCase {
    /// Referenz akkumuliert jede Zelle vollständig seriell. Das ungerade
    /// Gitter prüft auch die Randzellen und ungleich große Parallelbereiche.
    func testPreparedRoutesMatchSerialAccumulationBitForBit() {
        for exponent in [4.0, 2.0, 1.3] {
            var cfg = SimConfig.production
            cfg.n = 193
            cfg.world = Double(cfg.n) * SimConfig.production.cellSize
            cfg.mfdExponent = exponent
            cfg.braidDispersion = exponent == 1.3 ? 1.7 : (exponent == 4 ? 2 : 4)
            cfg.braidMinCells = 10
            cfg.meanderFlatSlope = 0.5
            let terrain = Terrain(config: cfg, seed: 42)
            terrain.step(dtYears: 100)
            terrain.computeFlow()
            let state = terrain.state
            let cellArea = cfg.cellSize * cfg.cellSize
            let weight = terrain.flowWeight
            var expected = (0..<cfg.count).map { cellArea * weight[$0] }
            var dispersed = 0, concentrated = 0, flat = 0
            for cell in state.order.reversed() {
                let k = Int(cell), hk = state.hf[k]
                if hk <= cfg.sea || state.endorheicBasin[k] == BasinRole.water.rawValue { continue }
                let i = k % cfg.n, j = k / cfg.n
                var neighbors: [Int] = [], slopes: [Double] = []
                var sMax = 0.0
                for dj in -1...1 {
                    for di in -1...1 {
                        if di == 0 && dj == 0 { continue }
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= cfg.n || nj < 0 || nj >= cfg.n { continue }
                        let nb = nj * cfg.n + ni
                        let slope = (hk - state.hf[nb]) / (di != 0 && dj != 0 ? 2.0.squareRoot() : 1.0)
                        if slope > 0 {
                            neighbors.append(nb); slopes.append(slope)
                            sMax = max(sMax, slope)
                        }
                    }
                }
                let a = expected[k]
                let p = terrain.mfdLocalExponent(a: a, sMax: sMax, pond: hk - state.h[k])
                if p == cfg.braidDispersion { dispersed += 1 } else { concentrated += 1 }
                var sum = 0.0
                for t in slopes.indices {
                    if p == 4 { let s2 = slopes[t] * slopes[t]; slopes[t] = s2 * s2 }
                    else if p == 2 { slopes[t] *= slopes[t] }
                    else { slopes[t] = pow(slopes[t], p) }
                    sum += slopes[t]
                }
                if neighbors.isEmpty || sum <= 0 {
                    flat += 1
                    if state.endorheicBasin[k] != BasinRole.none.rawValue { continue }
                    let parent = state.floodParent[k]
                    if parent >= 0 { expected[Int(parent)] += a }
                } else {
                    for t in neighbors.indices { expected[neighbors[t]] += a * (slopes[t] / sum) }
                }
            }
            XCTAssertGreaterThan(dispersed, 0)
            XCTAssertGreaterThan(concentrated, 0)
            XCTAssertGreaterThan(flat, 0)
            XCTAssertEqual(terrain.areaMFD.map(\.bitPattern), expected.map(\.bitPattern),
                           "MFD-Exponent \(exponent)")
        }
    }
}
