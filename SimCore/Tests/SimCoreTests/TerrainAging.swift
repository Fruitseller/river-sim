import XCTest
@testable import SimCore

final class TerrainAging: XCTestCase {

    func testAgingTrajectoryOver100k() {
        var c = SimConfig(); c.n = 160; c.world = calibrationWorld
        c.rangeLandform = calibrationRangeLandform
        c.iceFirnTemp = calibrationIceFirnTemp
        c.pinIceBeforeAvalanche()
        c.meanderBeltRate = 0.02
        c.meanderBeltKernelWidths = 1.5
        c.meanderBeltCouplingYears = calibrationBeltCouplingYears
        c.meanderBeltSymmetricStamp = calibrationBeltSymmetricStamp
        c.deltaTrapFraction = calibrationDeltaTrapFraction
        let t = Terrain(config: c, seed: 1337)

        let relief0 = t.landRelief()
        let robust0 = t.landReliefRobust()
        let maxH0 = t.maxHeight()
        var maxHPeak = maxH0
        var servoFired = 0

        var curv20k = 0.0, relief50k = 0.0, robust50k = 0.0
        while t.years < 100_000 {
            if t.reliefServoRate() > 0 { servoFired += 1 }
            t.step(dtYears: 500)
            maxHPeak = max(maxHPeak, t.maxHeight())
            if t.years == 20_000 { curv20k = t.ridgeCurvature() }
            if t.years == 50_000 { relief50k = t.landRelief(); robust50k = t.landReliefRobust() }
        }
        let relief1 = t.landRelief()
        let robust1 = t.landReliefRobust()
        let curv1 = t.ridgeCurvature()
        print(String(format: "[#13] 100k Jahre, n=160: Relief %.4f → %.4f (50k %.4f), "
                     + "robust %.4f → %.4f (50k %.4f), maxH %.4f → %.4f",
                     relief0, relief1, relief50k, robust0, robust1, robust50k,
                     maxH0, t.maxHeight()))

        XCTAssertLessThanOrEqual(maxHPeak, maxH0,
            "Gipfel wuchs über den Startwert (\(maxH0) → Peak \(maxHPeak)) — U₀ zu hoch?")

        XCTAssertLessThan(relief1, relief0 * 0.85,
            "Relief altert nicht (\(relief0) → \(relief1)) — hebt etwas nach?")

        XCTAssertLessThan(robust1, robust50k * 0.95,
            "Relief plateaut nach 50k (robust \(robust50k) → \(robust1)) statt weiter zu altern")

        XCTAssertGreaterThan(relief1, 0.30,
            "Relief eingeebnet (\(relief0) → \(relief1)) — U_floor zu klein?")

        XCTAssertLessThan(abs(curv1), abs(curv20k) * 0.85,
            "Grate runden nicht aus (Gratkrümmung \(curv20k) → \(curv1))")
        XCTAssertLessThan(curv1, 0, "Grate müssen konvex bleiben, nicht Mulden werden")

        XCTAssertEqual(servoFired, 0,
            "Relief-Servo sprang \(servoFired)× an — er soll nur noch Notboden sein")
    }

    func testDecayingUpliftIsFramerateIndependent() {
        var c = SimConfig(); c.n = 48; c.world = calibrationWorld
        func total(dt: Double, steps: Int) -> Double {
            let t = Terrain(config: c, seed: 4242)
            var sum = 0.0
            for _ in 0..<steps { sum += t.upliftDecayAmount(dt: dt); t.step(dtYears: dt) }
            return sum
        }
        let coarse = total(dt: 10_000, steps: 10)
        let fine = total(dt: 250, steps: 400)
        XCTAssertEqual(fine, coarse, accuracy: coarse * 1e-12,
            "Hebungs-Eintrag hängt von der Schrittweite ab (\(coarse) vs \(fine))")
        XCTAssertGreaterThan(coarse, 0)
    }

    func testServoFloorCrossingIsFramerateIndependent() {
        var c = SimConfig(); c.n = 48; c.world = calibrationWorld
        let floorRate = c.upliftDecayFloorPer100y
            + (c.upliftDecayStartPer100y - c.upliftDecayFloorPer100y) * exp(-1.5)
        let tStar = 1.5 * c.upliftDecayYears
        let span = 40_000.0

        func total(dt: Double) -> Double {
            let t = Terrain(config: c, seed: 4242)
            var sum = 0.0
            while t.years < 40_000 { t.step(dtYears: 10_000) }
            let end = t.years + span
            while t.years < end {
                sum += t.upliftAmount(dt: dt, floorPer100y: floorRate)
                t.step(dtYears: dt)
            }
            return sum
        }
        let oneJump = total(dt: span)
        let manySteps = total(dt: 250)
        XCTAssertEqual(manySteps, oneJump, accuracy: oneJump * 1e-9,
            "Hebung am Servo-Schnittpunkt hängt von der Schrittweite ab (\(oneJump) vs \(manySteps))")

        let t = Terrain(config: c, seed: 4242)
        while t.years < 40_000 { t.step(dtYears: 10_000) }
        let rate = { (y: Double) in
            c.upliftDecayFloorPer100y + (c.upliftDecayStartPer100y - c.upliftDecayFloorPer100y)
                * exp(-y / c.upliftDecayYears)
        }
        XCTAssertGreaterThan(rate(40_000), floorRate)
        XCTAssertLessThan(rate(80_000), floorRate)
        XCTAssertEqual(rate(tStar), floorRate, accuracy: floorRate * 1e-12)

        let pureDecay = t.upliftDecayAmount(dt: span)
        let pureFloor = floorRate * span / 100
        XCTAssertGreaterThan(oneJump, pureDecay)
        XCTAssertGreaterThan(oneJump, pureFloor)
        XCTAssertLessThan(oneJump, pureDecay + pureFloor)
    }
}
