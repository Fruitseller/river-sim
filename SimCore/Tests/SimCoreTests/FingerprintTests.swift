import XCTest
@testable import SimCore

final class FingerprintTests: XCTestCase {

    private func makeTerrain() -> Terrain {
        var c = SimConfig()
        c.n = 96; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 99)
        t.step(dtYears: 1000)
        return t
    }

    private func ulpFlip(_ v: Double) -> Double { Double(bitPattern: v.bitPattern ^ 1) }

    private func assertDetects(_ name: String, base: TerrainState,
                               baseline: UInt64,
                               file: StaticString = #filePath, line: UInt = #line,
                               _ perturb: (inout TerrainState) -> Void) {
        var s = base
        perturb(&s)
        XCTAssertNotEqual(s.fingerprint(), baseline,
                          "Fingerprint ist blind für \(name)",
                          file: file, line: line)
    }

    private func assertDetectsField<T>(_ f: WorldSnapshot.FieldSpec<T>,
                                       base: TerrainState, baseline: UInt64,
                                       seed: T, flip: (T) -> T,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        assertDetects(f.name, base: base, baseline: baseline,
                      file: file, line: line) { s in
            if s[keyPath: f.path].isEmpty { s[keyPath: f.path] = [seed] }
            else { s[keyPath: f.path][0] = flip(s[keyPath: f.path][0]) }
        }
    }

    func testFingerprintCoversEveryInventoryField() {
        let t = makeTerrain()
        let base = t.state
        let baseline = base.fingerprint()
        XCTAssertEqual(t.fingerprint(), baseline)

        for f in WorldSnapshot.doubleFields {
            assertDetectsField(f, base: base, baseline: baseline, seed: 1.0, flip: ulpFlip)
        }
        for f in WorldSnapshot.int32Fields {
            assertDetectsField(f, base: base, baseline: baseline, seed: 1) { $0 ^ 1 }
        }
        for f in WorldSnapshot.uint8Fields {
            assertDetectsField(f, base: base, baseline: baseline, seed: 1) { $0 ^ 1 }
        }
        for f in WorldSnapshot.boolFields {
            assertDetectsField(f, base: base, baseline: baseline, seed: true) { !$0 }
        }
    }

    func testFingerprintCoversScalarsAndMeander() {
        var base = makeTerrain().state
        if base.meanderChannels.first?.nodes.isEmpty != false {
            base.meanderChannels = [RiverChannel(nodes: [MeanderNode(x: 1, z: 2)],
                                                 discharge: [3])]
        }
        if base.oxbows.first?.isEmpty != false {
            base.oxbows = [[MeanderNode(x: 1, z: 2)]]
            base.oxbowAge = [1]
        }
        let baseline = base.fingerprint()

        assertDetects("seed", base: base, baseline: baseline) { $0.seed ^= 1 }
        assertDetects("years", base: base, baseline: baseline) { $0.years = ulpFlip($0.years) }
        assertDetects("dropsEmitted", base: base, baseline: baseline) { $0.dropsEmitted ^= 1 }
        assertDetects("dropCarry", base: base, baseline: baseline) { $0.dropCarry = ulpFlip($0.dropCarry) }
        assertDetects("beltCouplingCarry", base: base, baseline: baseline) { $0.beltCouplingCarry = ulpFlip($0.beltCouplingCarry) }
        assertDetects("flowStepCount", base: base, baseline: baseline) { $0.flowStepCount ^= 1 }
        assertDetects("disturbActive", base: base, baseline: baseline) { $0.disturbActive.toggle() }
        assertDetects("heightBands", base: base, baseline: baseline) {
            $0.heightBands.vegFull = ulpFlip($0.heightBands.vegFull)
        }
        assertDetects("meanderChannels", base: base, baseline: baseline) {
            $0.meanderChannels[0].nodes[0].x = ulpFlip($0.meanderChannels[0].nodes[0].x)
        }
        assertDetects("meanderDischarge", base: base, baseline: baseline) {
            $0.meanderChannels[0].discharge[0] = ulpFlip($0.meanderChannels[0].discharge[0])
        }
        assertDetects("oxbows", base: base, baseline: baseline) {
            $0.oxbows[0][0].x = ulpFlip($0.oxbows[0][0].x)
        }
        assertDetects("oxbowAge", base: base, baseline: baseline) {
            $0.oxbowAge[0] = ulpFlip($0.oxbowAge[0])
        }
    }

    func testEveryStoredPropertyIsAccountedFor() {
        let tabled = Set(WorldSnapshot.doubleFields.map(\.name)
            + WorldSnapshot.int32Fields.map(\.name)
            + WorldSnapshot.uint8Fields.map(\.name)
            + WorldSnapshot.boolFields.map(\.name))
        let scalars: Set<String> = [
            "years", "seed", "dropsEmitted", "dropCarry", "flowStepCount", "beltCouplingCarry",
            "disturbActive", "heightBands",
            "meanderChannels", "oxbows", "oxbowAge",
        ]
        for child in Mirror(reflecting: TerrainState()).children {
            guard let label = child.label else { continue }
            XCTAssertTrue(tabled.contains(label) || scalars.contains(label),
                          "TerrainState.\(label) ist weder tabelliert noch als "
                          + "Skalar-/Mäander-Bestandteil erfasst — Fingerprint und "
                          + "Speicherformat wären blind dafür (s. WorldSnapshot.swift)")
        }
        for child in Mirror(reflecting: HeightBands.legacyAbsolute).children {
            XCTAssertTrue(child.value is Double,
                          "HeightBands.\(child.label ?? "?") ist kein Double — "
                          + "fingerprint() würde das Band still überspringen")
        }
    }

    func testGenerateOnUsedTerrainYieldsFreshWorld() {
        let cfg = SimConfig.production
        let settle = 200.0
        let a = Terrain(config: cfg, seed: 1337, settleYears: settle)
        for _ in 0..<3 {
            a.step(dtYears: 100)
        }
        a.generate(seed: 42, settleYears: settle)

        let b = Terrain(config: cfg, seed: 42, settleYears: settle)

        XCTAssertEqual(a.fingerprint(), b.fingerprint(),
                       "generate(seed: 42) auf gebrauchtem Terrain muss bit-identisch zu frischem Terrain sein")

        for _ in 0..<3 {
            a.step(dtYears: 100)
            b.step(dtYears: 100)
        }
        XCTAssertEqual(a.fingerprint(), b.fingerprint(),
                       "Folgeschritte nach generate müssen auf beiden Terrains bit-identisch bleiben")
    }
}
