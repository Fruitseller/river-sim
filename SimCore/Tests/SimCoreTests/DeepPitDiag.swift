import XCTest
@testable import SimCore

final class DeepPitDiag: XCTestCase {
    private func newDeepPits(_ t: Terrain, _ h0: [Double]) -> Int {
        let sea = t.cfg.sea
        var count = 0
        for k in 0..<t.cfg.count where h0[k] > sea - 0.02 && t.h[k] < sea - 0.10 {
            count += 1
        }
        return count
    }

    private func newDeepPonds(_ t: Terrain, _ pond0: [Double]) -> Int {
        var count = 0
        for k in 0..<t.cfg.count where t.hf[k] > t.cfg.sea
            && t.hf[k] - t.h[k] > 0.16 && pond0[k] < 0.05 {
            count += 1
        }
        return count
    }

    func testSimulationCreatesNoDeepPits() {
        var seed = 1337
        for _ in 0..<4 {
            let t = Terrain(config: .production, seed: UInt32(seed))
            let h0 = t.h
            var pond0 = [Double](repeating: 0, count: t.cfg.count)
            for k in 0..<t.cfg.count { pond0[k] = max(0, t.hf[k] - t.h[k]) }
            var years = 0.0
            while years < 24000 { t.step(dtYears: 240); years += 240 }
            XCTAssertEqual(newDeepPits(t, h0), 0, "Sim gräbt dauerhafte Tiefen-Löcher (seed \(seed))")
            XCTAssertEqual(newDeepPonds(t, pond0), 0, "Sim gräbt neue TIEFE Seen (seed \(seed))")
            seed = (seed * 16807 + 1) % 2147483647
        }
    }

    func testSculptLowerLeavesNoEternalSubsidence() {
        let t = Terrain(config: .production, seed: 1337)
        var spot = -1
        for k in 0..<t.cfg.count where t.h[k] > 0.45 { spot = k; break }
        XCTAssertGreaterThanOrEqual(spot, 0)
        let gx = Double(spot % t.cfg.n), gz = Double(spot / t.cfg.n)
        for _ in 0..<200 {
            t.sculpt(gx: gx, gz: gz, radiusWorld: 10.0, dir: -1, strength: 3)
        }
        let h0 = t.h
        var years = 0.0
        while years < 18000 { t.step(dtYears: 240); years += 240 }
        XCTAssertEqual(newDeepPits(t, h0), 0,
            "Kraterränder sacken durch Tektonik-Kopplung unter den Meeresspiegel")
    }
}
