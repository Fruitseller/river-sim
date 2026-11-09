import XCTest
@testable import SimCore
@testable import SimGame
@testable import SimRender

/// Der Prototyp in der Welt-Sitzung (Issue #223): Schritte — auch im
/// Hintergrund — buchen Spieljahre, Pinselstriche laufen durch die
/// Spielregeln, Neustart ist bit-gleich, der Sandkasten bleibt unberührt.
final class NatureSessionTests: XCTestCase {
    private func nature() -> WorldSession<WorldFrame> {
        WorldSession(natureScenario: (), render: RenderState(geometryMode: true))
    }

    func testStepsBookGameYearsOnBothPaths() {
        let sync = nature(), background = nature()
        for _ in 0..<10 { sync.step(years: 0.5) }
        for _ in 0..<10 {
            XCTAssertTrue(background.beginStep(years: 0.5, trigger: .timelapse, now: 0) { $0 })
            XCTAssertNotNil(background.finishStep())
        }
        XCTAssertEqual(sync.natureView()?.year, 5)
        XCTAssertEqual(background.natureView()?.year, 5)
        XCTAssertEqual(sync.fingerprint(), background.fingerprint())
        XCTAssertEqual(sync.config.n, NatureScenario.n)
    }

    func testBrushGoesThroughTheRulesAndRestartIsIdentical() {
        let s = nature()
        let fresh = s.fingerprint()
        let talheim = s.natureView()!.settlements.first { $0.isTarget }!
        let n = s.config.n
        let house = talheim.houses[0]
        XCTAssertEqual(s.brush(.pickaxe, gx: Double(house % n), gz: Double(house / n),
                               radiusWorld: 1, strength: 1, target: 0),
                       .tooCloseToSettlement)
        XCTAssertEqual(s.fingerprint(), fresh, "abgelehnter Strich ändert nichts")
        for (tool, x, z) in NatureScenario.lowSaddleCut {
            XCTAssertEqual(s.brush(tool, gx: x, gz: z, radiusWorld: 1, strength: 1, target: 0), .applied)
        }
        s.recomputeFlow()
        XCTAssertEqual(s.lastChange, .edited)
        let after = s.natureView()!.settlements.first { $0.isTarget }!
        XCTAssertLessThan(after.supply.water, 0.4, "Anzeige misst sofort nach dem Nachzug")
        s.restartNature()
        XCTAssertEqual(s.lastChange, .replaced)
        XCTAssertEqual(s.fingerprint(), fresh)
        XCTAssertEqual(s.natureView()?.budgetLeft, NatureGame.defaultBudget)
    }

    func testSandboxHasNoGameAndGenerateEndsTheTrial() {
        let sandbox = WorldSession<WorldFrame>(config: tinyConfig(), seed: 7)
        XCTAssertFalse(sandbox.natureActive)
        XCTAssertNil(sandbox.brush(.raise, gx: 5, gz: 5, radiusWorld: 1, strength: 1, target: 0))
        let s = nature()
        XCTAssertTrue(s.natureActive)
        s.generate(seed: 3)
        XCTAssertFalse(s.natureActive)
    }

    private func tinyConfig() -> SimConfig {
        var c = SimConfig()
        c.n = 48
        c.world = SimConfig().cellSize * 47
        return c
    }
}
