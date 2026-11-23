import XCTest
@testable import SimCore

final class PerfFlagAB: XCTestCase {

    func testSkipWaterSpawnsChangesTheRealizationNotTheCharacter() {
        var reference = SimConfig()
        reference.n = 256; reference.world = calibrationWorld
        var skipping = reference
        skipping.hydraulicSkipWaterSpawns = true

        let a = Terrain(config: reference, seed: 1337)
        let b = Terrain(config: skipping, seed: 1337)
        XCTAssertNotEqual(a.fingerprint(), b.fingerprint(),
                          "hydraulicSkipWaterSpawns war zur Generierung bisher "
                          + "NICHT bit-neutral (s. Kopfkommentar)")

        for _ in 1...10 {
            a.step(dtYears: 1000)
            b.step(dtYears: 1000)
        }
        XCTAssertNotEqual(a.fingerprint(), b.fingerprint(),
                          "hydraulicSkipWaterSpawns war nach 10 000 Jahren bisher "
                          + "NICHT bit-neutral (s. Kopfkommentar)")

        let (meanA, landA) = landStats(a)
        let (meanB, landB) = landStats(b)
        XCTAssertEqual(meanA, meanB, accuracy: max(0.005 * meanA, 1e-4),
                       "meanLand driftet — der Schalter verschiebt die Physik, "
                       + "nicht nur die Realisierung")
        XCTAssertEqual(Double(landA), Double(landB),
                       accuracy: max(0.005 * Double(landA), 1),
                       "Landzellenzahl driftet — der Schalter verschiebt die "
                       + "Küste, nicht nur die Realisierung")
    }

    private func landStats(_ t: Terrain) -> (meanLand: Double, cells: Int) {
        var sum = 0.0, count = 0
        for k in 0..<t.cfg.count where t.h[k] > t.cfg.sea {
            sum += t.h[k]; count += 1
        }
        return (sum / Double(max(1, count)), count)
    }
}
