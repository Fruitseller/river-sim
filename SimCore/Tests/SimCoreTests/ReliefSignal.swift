import XCTest
@testable import SimCore

final class ReliefSignal: XCTestCase {

    private func maxMinusMin(_ heights: [Double], sea: Double) -> Double {
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for v in heights where v > sea { lo = min(lo, v); hi = max(hi, v) }
        return hi < lo ? 0 : hi - lo
    }

    func testSinglePeakBarelyMovesSignal() {
        var c = SimConfig(); c.n = 160; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        for _ in 0..<40 { t.step(dtYears: 500) }

        let base = t.h
        let spanBefore = maxMinusMin(base, sea: c.sea)
        let signalBefore = Terrain.landReliefRobust(heights: base, sea: c.sea)
        XCTAssertGreaterThan(signalBefore, 0.05, "Testterrain muss überhaupt Relief haben")

        var spiked = base
        let peak = spiked.indices.first { spiked[$0] > c.sea }!
        spiked[peak] = 1.4

        let spanAfter = maxMinusMin(spiked, sea: c.sea)
        let signalAfter = Terrain.landReliefRobust(heights: spiked, sea: c.sea)

        XCTAssertGreaterThan(spanAfter, spanBefore * 1.5,
                             "max − min müsste durch die Nadel voll ausschlagen (\(spanBefore) → \(spanAfter))")
        let drift = abs(signalAfter - signalBefore) / signalBefore
        XCTAssertLessThan(drift, 0.01,
                          "Nadel verschiebt das Regelsignal um \(drift * 100) % (\(signalBefore) → \(signalAfter))")
    }

    func testSignalFollowsRealFlattening() {
        var c = SimConfig(); c.n = 160; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        let base = t.h
        let signal0 = Terrain.landReliefRobust(heights: base, sea: c.sea)

        let land = base.filter { $0 > c.sea }
        let mean = land.reduce(0, +) / Double(land.count)
        let flattened = base.map { $0 > c.sea ? mean + ($0 - mean) * 0.5 : $0 }
        let signal1 = Terrain.landReliefRobust(heights: flattened, sea: c.sea)

        XCTAssertEqual(signal1, signal0 * 0.5, accuracy: signal0 * 0.05,
                       "Halbiertes Relief muss das Signal halbieren (\(signal0) → \(signal1))")
    }

    func testServoRateFollowsSignal() {
        var base = SimConfig(); base.n = 96; base.world = calibrationWorld
        let signal = Terrain(config: base, seed: 4242).landReliefRobust()
        func servo(target: Double) -> Double {
            var c = base; c.reliefTarget = target
            return Terrain(config: c, seed: 4242).reliefServoRate()
        }
        XCTAssertEqual(servo(target: signal - 0.01), 0, "Über Ziel darf der Servo nicht heben")
        XCTAssertEqual(servo(target: signal + base.reliefServoBand * 0.5),
                       base.reliefServoPer100y * 0.5,
                       accuracy: base.reliefServoPer100y * 0.02,
                       "Servo muss linear über das Band rampen")
        XCTAssertEqual(servo(target: signal + base.reliefServoBand * 10),
                       base.reliefServoPer100y,
                       "Servo muss bei reliefServoPer100y deckeln")
    }

    func testServoRateOnMeasuredSignalMatchesSelfMeasured() {
        var c = SimConfig(); c.n = 96; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 4242)

        XCTAssertEqual(t.reliefServoRate(reliefSignal: t.landReliefRobust()),
                       t.reliefServoRate(), accuracy: 0,
                       "Delegation weicht von der parameterlosen Variante ab")

        let band = c.reliefServoBand, rate = c.reliefServoPer100y
        let cases: [(signal: Double, expected: Double, why: String)] = [
            (c.reliefTarget + 0.05, 0, "über Ziel → aus"),
            (c.reliefTarget, 0, "genau auf Ziel → aus, Defizit 0 hebt nicht"),
            (c.reliefTarget - band * 0.5, rate * 0.5, "halbes Band → halbe Rate"),
            (c.reliefTarget - band * 10, rate, "weit unter Ziel → Deckel"),
            (0, rate * (c.reliefTarget / band), "Signal 0 → Defizit ist reliefTarget"),
            (-0.5, rate, "negatives Signal → Deckel, nicht darüber hinaus"),
        ]
        for k in cases {
            XCTAssertEqual(t.reliefServoRate(reliefSignal: k.signal), k.expected,
                           accuracy: rate * 1e-12, "Signal \(k.signal): \(k.why)")
        }
    }

    func testSignalIsResolutionStable() {
        var values: [Double] = []
        for n in [80, 160, 320, 640, SimConfig().n] {
            var c = SimConfig(); c.n = n; c.world = calibrationWorld
            values.append(Terrain(config: c, seed: 1337).landReliefRobust())
        }
        let lo = values.min()!, hi = values.max()!
        XCTAssertLessThan((hi - lo) / hi, 0.15,
                          "Signal driftet mit der Auflösung: \(values)")
        let fromTestRes = Array(values.dropFirst())
        let lo2 = fromTestRes.min()!, hi2 = fromTestRes.max()!
        XCTAssertLessThan((hi2 - lo2) / hi2, 0.06,
                          "Signal bei Produktionsauflösung weicht ab: \(values)")
    }
}
