import XCTest
@testable import SimCore

final class IndexMathTests: XCTestCase {

    func testNeighbourDiagonalityFromIndexDifference() {
        for n in [3, 96, 832] {
            let probes = [0, 1, 2, n / 2, n - 2, n - 1].filter { $0 >= 0 && $0 < n }
            for j in probes {
                for i in probes {
                    let k = j * n + i
                    for dj in -1...1 {
                        for di in -1...1 {
                            if di == 0 && dj == 0 { continue }
                            let ni = i + di, nj = j + dj
                            if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                            let r = nj * n + ni
                            let expected = (i != ni) && (j != nj)
                            let d = k > r ? k - r : r - k
                            XCTAssertEqual(d == n - 1 || d == n + 1, expected,
                                           "n = \(n), k = \(k), r = \(r)")
                        }
                    }
                }
            }
        }
    }

    func testBeltCellRoundingMatchesRoundedAtHalfBoundaries() {
        let n = 720
        let refCell: (Double, Double) -> Int = { x, z in
            min(max(Int(z.rounded()), 0), n - 1) * n + min(max(Int(x.rounded()), 0), n - 1)
        }

        let halfBoundaryProbes: [Double] = [
            (0.5).nextDown, 0.5, (0.5).nextUp,
            (-0.5).nextDown, -0.5, (-0.5).nextUp,
            0.0, 0.49, 0.51, 1.0,
            (1.5).nextDown, 1.5, (1.5).nextUp,
            (2.5).nextDown, 2.5, (2.5).nextUp,
            Double(n - 1) + (0.5).nextDown,
            Double(n - 1) + 0.5,
            Double(n - 1) + (0.5).nextUp,
            -1.5, -1.0, -0.1, 0.1, Double(n), Double(n + 10)
        ]

        for z in halfBoundaryProbes {
            for x in halfBoundaryProbes {
                let actual = Terrain.cellIndex(x, z, n: n)
                let expected = refCell(x, z)
                XCTAssertEqual(actual, expected,
                               "Mismatch at cellIndex(x: \(x), z: \(z)): actual=\(actual), expected=\(expected)")
            }
        }

        for coord in halfBoundaryProbes {
            XCTAssertEqual(Terrain.gridRound(coord), Int(coord.rounded()),
                           "Mismatch at gridRound(\(coord))")
        }

        for k in -100...1000 {
            let half = Double(k) + 0.5
            let probes = [Double(k), half.nextDown, half, half.nextUp]
            for c in probes {
                XCTAssertEqual(Terrain.gridRound(c), Int(c.rounded()),
                               "Mismatch at gridRound for k=\(k), c=\(c)")
            }
        }
    }
}
