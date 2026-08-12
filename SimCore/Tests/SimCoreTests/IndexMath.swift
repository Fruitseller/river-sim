import XCTest
@testable import SimCore

/// Wächter für die Index-Abkürzung aus Issue #43: `outletIncision` entscheidet
/// „diagonaler Schritt?" über die INDEX-DIFFERENZ statt über zwei i/j-Paare und
/// spart damit zwei Integer-Divisionen je Zelle. Das ist nur zulässig, weil der
/// Empfänger immer einer der acht Nachbarn ist. Ein Fehler hier wäre keine
/// Perf-Regression, sondern eine falsche Distanz in der Stream-Power — also
/// eine andere Welt.
final class IndexMathTests: XCTestCase {

    /// Für jeden 8-Nachbarn (inklusive aller Randlagen) muss `|k − r| ∈ {n−1,
    /// n+1}` genau dann gelten, wenn sich Spalte UND Zeile ändern.
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
}
