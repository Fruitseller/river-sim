import XCTest

@testable import SimRender

final class RenderRampTests: XCTestCase {

    private func legacySmoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func legacyClamp01(_ x: Double) -> Double {
        min(max(x, 0), 1)
    }

    func testSmoothstepMatchesTheHandwrittenRampForFiniteValues() {
        let edges: [(Double, Double)] = [(0, 1), (0.004, 0.026), (0.35, 0.65), (0, 320)]
        for (e0, e1) in edges {
            let span = e1 - e0
            for step in -100...300 {
                let x = e0 + span * Double(step) / 200
                XCTAssertEqual(smoothstep(e0, e1, x), legacySmoothstep(e0, e1, x),
                               "smoothstep weicht bei \(x) über [\(e0), \(e1)] von der alten Rampe ab")
            }
        }
    }

    func testSmoothstepWipesNaNInsteadOfPassingItThrough() {
        XCTAssertEqual(smoothstep(0, 1, Double.nan), 0)
        XCTAssertTrue(legacySmoothstep(0, 1, Double.nan).isNaN,
                      "die alte Rampe reichte NaN durch — genau deshalb steht die Konstante zuerst")
        XCTAssertEqual(smoothstep(0, 1, -Double.infinity), 0)
        XCTAssertEqual(smoothstep(0, 1, Double.infinity), 1)
    }

    func testClamp01MatchesTheHandwrittenClampForFiniteValues() {
        var values: [Double] = [-1e9, -1, -1e-12, 0, 1, 1 + 1e-12, 2, 1e9]
        for step in 0...2000 { values.append(Double(step) / 2000) }
        for value in values {
            XCTAssertEqual(clamp01(value), legacyClamp01(value),
                           "clamp01 weicht bei \(value) von der alten Klemme ab")
        }
    }

    func testClamp01WipesNaNInsteadOfPassingItThrough() {
        XCTAssertEqual(clamp01(Double.nan), 0)
        XCTAssertTrue(legacyClamp01(Double.nan).isNaN,
                      "die alte Klemme reichte NaN durch — genau deshalb steht die Konstante zuerst")
        XCTAssertEqual(clamp01(-Double.infinity), 0)
        XCTAssertEqual(clamp01(Double.infinity), 1)
    }
}
