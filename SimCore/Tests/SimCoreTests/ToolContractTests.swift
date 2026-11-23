import XCTest
@testable import SimCore

final class ToolContractTests: XCTestCase {

    func testBrushToolCasesMatchTheGameToolTable() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        let tableModes = try main.integers(pattern: "\"mode\": ([0-9]+)")
        XCTAssertFalse(tableModes.isEmpty,
                       "Werkzeug-Tabelle in Main.gd nicht gefunden — trägt jede Zeile \"mode\"?")
        XCTAssertEqual(tableModes, BrushTool.allCases.map(\.rawValue),
                       "Werkzeug-Tabelle (Main.gd) und BrushTool (SimCore) sind "
                       + "auseinandergelaufen: \(tableModes) gegen "
                       + "\(BrushTool.allCases.map(\.rawValue))")
        XCTAssertEqual(tableModes, Array(0..<tableModes.count),
                       "Werkzeug-Modi müssen lückenlos ab 0 in Tabellen-Reihenfolge stehen")
    }

    func testBrushDomeFollowsTheBrushFalloff() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "const BRUSH_FALLOFF_POWER := 2.0",
                       hint: "Standard-Exponent der Kuppel == Gewicht in Terrain.forEachBrushCell")
        assertContains(main, "return pow(1.0 - d * d, power)",
                       hint: "Kuppelprofil ist (1 − d²)^p")
        XCTAssertEqual(main.count(of: "\"falloff_power\":"), 1,
                       "Nur die Spitzhacke weicht vom Standardprofil ab")
        XCTAssertEqual(try main.integers(pattern: "\"mode\": 5,[^}]*\"falloff_power\": ([0-9]+)"), [4],
                       "Spitzhacke (mode 5) trägt falloff_power 4 (Terrain.pickaxe: w²)")

        func assertProfile(_ tool: BrushTool, cells: Double, power: Double, sign: Double) {
            let t = makeTerrain()
            let before = t.h
            tool.apply(to: t, gx: gx, gz: gz, radiusWorld: cells * cfg.cellSize,
                       strength: 1, target: 0)
            let center = t.h[centerIndex] - before[centerIndex]
            XCTAssertGreaterThan(center * sign, 0, "\(tool) wirkt im Zentrum")
            for di in 1..<Int(cells.rounded(.up)) {
                let k = centerIndex + di
                let d = Double(di) / cells
                let expected = pow(1 - d * d, power)
                XCTAssertEqual((t.h[k] - before[k]) / center, expected, accuracy: 1e-9,
                               "\(tool): Profil bei d = \(d) weicht von (1 − d²)^\(power) ab")
            }
        }
        assertProfile(.raise, cells: 6, power: 2, sign: 1)
        assertProfile(.pickaxe, cells: Terrain.pickaxeMaxCells, power: 4, sign: -1)
    }

    private let n = 64

    private var cfg: SimConfig {
        var c = SimConfig(); c.n = n; c.world = calibrationWorld; return c
    }

    private func makeTerrain() -> Terrain { Terrain(config: cfg, seed: 7) }

    private var gx: Double { Double(n) / 2 }
    private var gz: Double { Double(n) / 2 }
    private var radius: Double { 6 * cfg.cellSize }

    private func heights(after tool: BrushTool, strength: Double = 1.0,
                         target: Double = 0.0, radiusWorld: Double? = nil)
        -> (before: [Double], after: [Double]) {
        let t = makeTerrain()
        let before = t.h
        tool.apply(to: t, gx: gx, gz: gz, radiusWorld: radiusWorld ?? radius,
                   strength: strength, target: target)
        return (before, t.h)
    }

    private var centerIndex: Int { Int(gz) * n + Int(gx) }

    private func brushRoughness(_ h: [Double]) -> Double {
        roughness(h, center: (gx, gz), radiusWorld: radius, cfg: cfg)
    }

    private func assertSculpt(_ tool: BrushTool, sign: Double,
                              file: StaticString = #filePath, line: UInt = #line) {
        let t = makeTerrain()
        let before = t.h, u0 = t.upliftBase[centerIndex]
        tool.apply(to: t, gx: gx, gz: gz, radiusWorld: radius, strength: 1, target: 0)
        XCTAssertGreaterThan((t.h[centerIndex] - before[centerIndex]) * sign, 0,
                             "\(tool) muss das Zentrum in Richtung \(sign) bewegen",
                             file: file, line: line)
        XCTAssertGreaterThan((t.upliftBase[centerIndex] - u0) * sign, 0,
                             "\(tool) muss in die Tektonik koppeln (sculpt, dir: \(sign))",
                             file: file, line: line)
        assertUntouchedOutside(t.h, before: before, center: (gx, gz),
                               radiusWorld: radius, cfg: cfg, file: file, line: line)
    }

    func testRaiseLiftsTheCenterAndCouplesIntoTectonics() throws {
        assertSculpt(.raise, sign: 1)
    }

    func testLowerDigsTheCenterAndCouplesIntoTectonics() throws {
        assertSculpt(.lower, sign: -1)
    }

    func testSmoothReducesLocalRoughness() throws {
        let (before, after) = heights(after: .smooth)
        XCTAssertLessThan(brushRoughness(after), brushRoughness(before),
                          "Glätten muss die lokale Rauheit im Pinsel senken")
    }

    func testFlattenPullsTowardTheGivenTarget() throws {
        let h0 = makeTerrain().h[centerIndex]
        let high = heights(after: .flatten, target: h0 + 0.5)
        XCTAssertGreaterThan(high.after[centerIndex], h0,
                             "Einebnen mit hohem Ziel muss Richtung Ziel heben")
        let low = heights(after: .flatten, target: h0 - 0.5)
        XCTAssertLessThan(low.after[centerIndex], high.after[centerIndex],
                          "Verschiedene Ziele müssen verschieden einebnen")
        XCTAssertLessThan(low.after[centerIndex], h0,
                          "Einebnen mit tiefem Ziel muss Richtung Ziel senken")
    }

    func testRoughenAddsReliefInBothDirections() throws {
        let t = makeTerrain()
        BrushTool.smooth.apply(to: t, gx: gx, gz: gz, radiusWorld: radius,
                               strength: 1, target: 0)
        let smoothed = t.h
        BrushTool.roughen.apply(to: t, gx: gx, gz: gz, radiusWorld: radius,
                                strength: 1, target: 0)
        XCTAssertGreaterThan(brushRoughness(t.h), brushRoughness(smoothed),
                             "Aufrauen muss die lokale Rauheit heben")
        let deltas = zip(t.h, smoothed).map { $0 - $1 }
        XCTAssertTrue(deltas.contains { $0 > 0 } && deltas.contains { $0 < 0 },
                      "Aufrauen ist Rauschen, kein gerichtetes Heben oder Senken")
    }

    func testPickaxeDigsDeeperThanLowerAndCapsItsRadius() throws {
        let lower = heights(after: .lower)
        let pickaxe = heights(after: .pickaxe)
        XCTAssertLessThan(pickaxe.after[centerIndex] - pickaxe.before[centerIndex],
                          lower.after[centerIndex] - lower.before[centerIndex],
                          "Die Spitzhacke muss bei gleicher Stärke tiefer schlagen als Absenken")
        let wide = heights(after: .pickaxe, radiusWorld: Double(n) * cfg.cellSize)
        assertUntouchedOutside(wide.after, before: wide.before, center: (gx, gz),
                               radiusWorld: Terrain.pickaxeMaxCells * cfg.cellSize,
                               cfg: cfg)
    }

    func testEachToolLeavesADistinctFootprint() throws {
        let results = BrushTool.allCases.map { tool in
            heights(after: tool, strength: 1, target: 1.2).after
        }
        for a in results.indices {
            for b in results.indices where b > a {
                XCTAssertNotEqual(results[a], results[b],
                                  "\(BrushTool.allCases[a]) und \(BrushTool.allCases[b]) "
                                  + "wirken identisch — Routing prüfen")
            }
        }
    }

    func testBrushToolsHandleNonFiniteInputsWithoutCrashing() throws {
        let nonFiniteValues = [Double.nan, Double.infinity, -Double.infinity, 1e300]
        for tool in BrushTool.allCases {
            for bad in nonFiniteValues {
                let (b1, a1) = heights(after: tool, radiusWorld: bad)
                XCTAssertEqual(a1, b1, "\(tool) mit fehlerhaftem radiusWorld darf Terrain nicht verändern")

                let tX = makeTerrain()
                let beforeX = tX.h
                tool.apply(to: tX, gx: bad, gz: gz, radiusWorld: radius, strength: 1.0, target: 0.0)
                XCTAssertEqual(tX.h, beforeX, "\(tool) mit fehlerhaftem gx darf Terrain nicht verändern")

                let tZ = makeTerrain()
                let beforeZ = tZ.h
                tool.apply(to: tZ, gx: gx, gz: bad, radiusWorld: radius, strength: 1.0, target: 0.0)
                XCTAssertEqual(tZ.h, beforeZ, "\(tool) mit fehlerhaftem gz darf Terrain nicht verändern")

                let tStrength = makeTerrain()
                let beforeStrength = tStrength.h
                tool.apply(to: tStrength, gx: gx, gz: gz, radiusWorld: radius, strength: bad, target: 0.0)
                XCTAssertEqual(tStrength.h, beforeStrength, "\(tool) mit fehlerhafter strength darf Terrain nicht verändern")

                let tTarget = makeTerrain()
                let beforeTarget = tTarget.h
                tool.apply(to: tTarget, gx: gx, gz: gz, radiusWorld: radius, strength: 1.0, target: bad)
                XCTAssertEqual(tTarget.h, beforeTarget, "\(tool) mit fehlerhaftem target darf Terrain nicht verändern")
            }
        }
    }

    func testTerrainBrushMethodsHandleNonFiniteInputsDirectly() throws {
        let nonFiniteValues = [Double.nan, Double.infinity, -Double.infinity, 1e300]
        for bad in nonFiniteValues {
            let t = makeTerrain()
            let h0 = t.h
            let u0 = t.upliftBase

            t.sculpt(gx: bad, gz: gz, radiusWorld: radius, dir: 1)
            t.sculpt(gx: gx, gz: bad, radiusWorld: radius, dir: 1)
            t.sculpt(gx: gx, gz: gz, radiusWorld: bad, dir: 1)
            t.sculpt(gx: gx, gz: gz, radiusWorld: radius, dir: bad)
            t.sculpt(gx: gx, gz: gz, radiusWorld: radius, dir: 1, strength: bad)

            t.smooth(gx: bad, gz: gz, radiusWorld: radius)
            t.smooth(gx: gx, gz: bad, radiusWorld: radius)
            t.smooth(gx: gx, gz: gz, radiusWorld: bad)
            t.smooth(gx: gx, gz: gz, radiusWorld: radius, strength: bad)

            t.flatten(gx: bad, gz: gz, radiusWorld: radius, targetHeight: 0.5)
            t.flatten(gx: gx, gz: bad, radiusWorld: radius, targetHeight: 0.5)
            t.flatten(gx: gx, gz: gz, radiusWorld: bad, targetHeight: 0.5)
            t.flatten(gx: gx, gz: gz, radiusWorld: radius, targetHeight: bad)
            t.flatten(gx: gx, gz: gz, radiusWorld: radius, targetHeight: 0.5, strength: bad)

            t.roughen(gx: bad, gz: gz, radiusWorld: radius)
            t.roughen(gx: gx, gz: bad, radiusWorld: radius)
            t.roughen(gx: gx, gz: gz, radiusWorld: bad)
            t.roughen(gx: gx, gz: gz, radiusWorld: radius, strength: bad)

            t.pickaxe(gx: bad, gz: gz, radiusWorld: radius)
            t.pickaxe(gx: gx, gz: bad, radiusWorld: radius)
            t.pickaxe(gx: gx, gz: gz, radiusWorld: bad)
            t.pickaxe(gx: gx, gz: gz, radiusWorld: radius, strength: bad)

            XCTAssertEqual(t.h, h0, "Terrain.h muss nach fehlerhaften Pinsel-Aufrufen unverändert sein")
            XCTAssertEqual(t.upliftBase, u0, "upliftBase muss nach fehlerhaften Pinsel-Aufrufen unverändert sein")
        }
    }

    func testSmoothAndFlattenWithNonPositiveStrengthAreNoOps() throws {
        let h0Center = makeTerrain().h[centerIndex]
        for nonPositive in [-1.0, -0.001, 0.0] {
            let (beforeSmooth, afterSmooth) = heights(after: .smooth, strength: nonPositive)
            XCTAssertEqual(afterSmooth, beforeSmooth,
                           "Glätten mit strength <= 0 (\(nonPositive)) muss ein No-op sein")

            let (beforeFlatten, afterFlatten) = heights(after: .flatten, strength: nonPositive, target: h0Center + 0.5)
            XCTAssertEqual(afterFlatten, beforeFlatten,
                           "Einebnen mit strength <= 0 (\(nonPositive)) muss ein No-op sein")

            let t = makeTerrain()
            let h0 = t.h
            let u0 = t.upliftBase
            t.smooth(gx: gx, gz: gz, radiusWorld: radius, strength: nonPositive)
            XCTAssertEqual(t.h, h0, "Terrain.smooth mit strength <= 0 (\(nonPositive)) muss ein No-op sein")
            XCTAssertEqual(t.upliftBase, u0, "Terrain.smooth darf upliftBase nicht verändern")

            t.flatten(gx: gx, gz: gz, radiusWorld: radius, targetHeight: h0Center + 0.5, strength: nonPositive)
            XCTAssertEqual(t.h, h0, "Terrain.flatten mit strength <= 0 (\(nonPositive)) muss ein No-op sein")
            XCTAssertEqual(t.upliftBase, u0, "Terrain.flatten darf upliftBase nicht verändern")
        }
    }

    func testBrushToolsWithInactiveParametersAreStrictNoOps() throws {
        let t = makeTerrain()
        let h0 = t.h
        let u0 = t.upliftBase

        for badRadius in [0.0, -1.0, -10.0] {
            t.smooth(gx: gx, gz: gz, radiusWorld: badRadius, strength: 1.0)
            t.flatten(gx: gx, gz: gz, radiusWorld: badRadius, targetHeight: 0.5, strength: 1.0)
        }
        XCTAssertEqual(t.h, h0, "Pinsel mit radiusWorld <= 0 darf Terrain.h nicht verändern")
        XCTAssertEqual(t.upliftBase, u0, "Pinsel mit radiusWorld <= 0 darf upliftBase nicht verändern")

        t.sculpt(gx: gx, gz: gz, radiusWorld: radius, dir: 0, strength: 1.0)
        t.sculpt(gx: gx, gz: gz, radiusWorld: radius, dir: 1, strength: 0.0)
        XCTAssertEqual(t.h, h0, "sculpt mit dir == 0 oder strength == 0 darf Terrain.h nicht verändern")
        XCTAssertEqual(t.upliftBase, u0, "sculpt mit dir == 0 oder strength == 0 darf upliftBase nicht verändern")

        t.roughen(gx: gx, gz: gz, radiusWorld: radius, strength: 0.0)
        XCTAssertEqual(t.h, h0, "roughen mit strength == 0 darf Terrain.h nicht verändern")

        for nonPositive in [0.0, -0.5, -1.0] {
            t.pickaxe(gx: gx, gz: gz, radiusWorld: radius, strength: nonPositive)
        }
        XCTAssertEqual(t.h, h0, "pickaxe mit strength <= 0 darf Terrain.h nicht verändern")
        XCTAssertEqual(t.upliftBase, u0, "pickaxe mit strength <= 0 darf upliftBase nicht verändern")
    }
}

