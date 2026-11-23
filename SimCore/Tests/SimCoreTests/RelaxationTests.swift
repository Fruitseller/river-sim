import XCTest
@testable import SimCore

final class RelaxationTests: XCTestCase {

    private let taus = [20.0, 250.0, 500.0, 800.0, 1200.0, 3000.0, 5500.0]
    private let dts = [0.2, 1.0, 9.0, 100.0, 240.0, 500.0, 2000.0, 10_000.0]

    func testFractionIsTheClosedFormBitForBit() {
        for tau in taus {
            for dt in dts {
                let f = Terrain.relaxFraction(dt: dt, tau: tau)
                XCTAssertEqual(f.bitPattern, (1 - exp(-dt / tau)).bitPattern,
                               "τ=\(tau), dt=\(dt): \(f) statt \(1 - exp(-dt / tau))")
            }
        }
    }

    func testFractionTelescopesAcrossSubsteps() {
        for tau in taus {
            for total in [240.0, 2000.0, 10_000.0] {
                for parts in [1, 3, 24, 1000] {
                    var rest = 1.0
                    for _ in 0..<parts {
                        rest *= 1 - Terrain.relaxFraction(dt: total / Double(parts), tau: tau)
                    }
                    XCTAssertEqual(1 - rest, Terrain.relaxFraction(dt: total, tau: tau),
                                   accuracy: 1e-9,
                                   "τ=\(tau), \(total) J. in \(parts) Teilschritten")
                }
            }
        }
    }

    func testFractionStaysAWeightBetweenZeroAndOne() {
        for tau in taus {
            var prev = 0.0
            for dt in dts {
                let f = Terrain.relaxFraction(dt: dt, tau: tau)
                XCTAssertGreaterThan(f, 0, "τ=\(tau), dt=\(dt)")
                XCTAssertLessThanOrEqual(f, 1, "τ=\(tau), dt=\(dt)")
                if prev < 1 {
                    XCTAssertGreaterThan(f, prev, "nicht monoton in dt (τ=\(tau), dt=\(dt))")
                } else {
                    XCTAssertEqual(f, 1, "gesättigt und wieder gefallen (τ=\(tau), dt=\(dt))")
                }
                prev = f
            }
        }
        for dt in dts {
            var prev = Double.infinity
            for tau in taus {
                let f = Terrain.relaxFraction(dt: dt, tau: tau)
                if prev <= 1 {
                    XCTAssertLessThanOrEqual(f, prev, "nicht fallend in τ (dt=\(dt), τ=\(tau))")
                    if prev < 1 {
                        XCTAssertLessThan(f, prev, "nicht strikt fallend in τ (dt=\(dt), τ=\(tau))")
                    }
                }
                prev = f
            }
        }
    }

    func testAnchorsAtZeroAndOneTimeConstant() {
        for tau in taus {
            XCTAssertEqual(Terrain.relaxFraction(dt: 0, tau: tau), 0,
                           "dt = 0 bewegt etwas (τ=\(tau))")
            XCTAssertEqual(Terrain.relaxFraction(dt: tau, tau: tau), 1 - 1 / exp(1.0),
                           accuracy: 1e-12, "τ=\(tau)")
            XCTAssertEqual(Terrain.relaxFraction(dt: 20 * tau, tau: tau), 1,
                           accuracy: 1e-8, "20 τ ist praktisch fertig (τ=\(tau))")
        }
    }

    func testZeroTimeConstantMeansInstantaneous() {
        XCTAssertEqual(Terrain.relaxFraction(dt: 100, tau: 0), 1)
        XCTAssertEqual(Terrain.relaxFraction(dt: 0.2, tau: 0), 1)
    }
}
