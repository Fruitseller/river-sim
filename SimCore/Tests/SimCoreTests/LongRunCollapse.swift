import XCTest
@testable import SimCore

final class LongRunCollapse: XCTestCase {

    private func fractionInBasins(_ t: Terrain) -> Double {
        var wet = 0, land = 0
        for k in 0..<t.cfg.count where t.hf[k] > t.cfg.sea {
            land += 1
            if t.hf[k] - t.h[k] > 0.01 { wet += 1 }
        }
        return land == 0 ? 0 : Double(wet) / Double(land)
    }

    func testLongRunDoesNotRunAway() {
        var c = SimConfig(); c.n = 160; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        let relief0 = t.landRelief()
        let maxH0 = t.maxHeight()
        let water0 = fractionInBasins(t)

        while t.years < 100_000 { t.step(dtYears: 500) }

        let relief1 = t.landRelief()
        let water1 = fractionInBasins(t)

        XCTAssertLessThan(t.maxHeight(), maxH0 + 0.02,
                          "Berge wachsen (\(maxH0) → \(t.maxHeight())) — Hebung zu stark?")
        XCTAssertGreaterThan(relief1, 0.30,
                             "Relief eingeebnet (\(relief0) → \(relief1)) — Erosion zu stark?")
        XCTAssertLessThan(water1, 0.30,
                          "See-Anteil wuchert (\(water0) → \(water1)) — Becken entwässern nicht mehr (outletIncision/Hangdiffusion zu schwach)?")
    }
}
