import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

final class WaterProtectMaskTests: XCTestCase {

    private let seam = WaterRender.protectSeamCells

    private func aged(years: Double = 2000, seed: UInt32 = 1337) -> Terrain {
        agedWorld(renderConfig(n: 192), years: years, seed: seed)
    }

    @discardableResult
    private func refresh(_ render: RenderState, _ terrain: Terrain)
        -> (water: [UInt8], mask: [UInt8]) {
        let overlays = frameOverlays(render, terrain)
        return (overlays.water, overlays.protectMask)
    }

    private func core(_ water: [UInt8], _ coverage: [Double], meadow: [Bool],
                      count: Int) -> [Bool] {
        let river = byte01(WaterRender.protectRiverThreshold)
        let lake = byte01(WaterRender.protectLakeThreshold)
        return (0..<count).map { k in
            water[k * 4] >= river || water[k * 4 + 1] >= lake
                || (k < coverage.count && coverage[k] >= WaterRender.protectBandThreshold)
                || (k < meadow.count && meadow[k])
        }
    }

    func testMaskCoversWaterAndBandsAndLeavesDryLandFree() {
        let terrain = aged()
        let render = RenderState(geometryMode: true)
        let (water, mask) = refresh(render, terrain)
        let coverage = render.riverRibbonMesh.bandCoverage
        let n = terrain.cfg.n, cnt = n * n
        XCTAssertEqual(mask.count, cnt)

        let river = byte01(WaterRender.protectRiverThreshold)
        var rivers = 0, cappedBands = 0
        for k in 0..<cnt {
            if water[k * 4] >= river {
                rivers += 1
                XCTAssertEqual(mask[k], 255, "Sichtbarer Fluss an Zelle \(k) ungeschützt")
            }
            if coverage[k] >= WaterRender.protectBandThreshold {
                XCTAssertEqual(mask[k], 255, "Bandzelle \(k) ungeschützt")
                if water[k * 4] < river { cappedBands += 1 }
            }
        }
        XCTAssertGreaterThan(rivers, 0, "Testwelt braucht sichtbare Raster-Flüsse")
        XCTAssertGreaterThan(cappedBands, 0,
                             "Testwelt braucht Bandzellen ohne sichtbares Raster (Raster-Deckel)")

        let isCore = core(water, coverage, meadow: render.wetMeadowMask, count: cnt)
        let bars = render.barMaterial(terrain)
        var free = 0
        for j in 0..<n {
            for i in 0..<n {
                var near = false
                for nj in max(0, j - seam)...min(n - 1, j + seam) where !near {
                    for ni in max(0, i - seam)...min(n - 1, i + seam) where isCore[nj * n + ni] {
                        near = true
                        break
                    }
                }
                let bar = bars.sand[j * n + i] >= Float(WaterRender.barProtectSand)
                XCTAssertEqual(mask[j * n + i], near || bar ? 255 : 0, "Zelle (\(i), \(j))")
                if !near && !bar { free += 1 }
            }
        }
        XCTAssertGreaterThan(free, cnt / 4, "Testwelt braucht weite trockene Flächen")
    }

    func testMaskIncludesVisibleRasterLakes() {
        let terrain = Terrain(config: renderConfig(n: 96), seed: 1337)
        terrain.computeFlow()
        let n = terrain.cfg.n
        var state = terrain.state
        for dj in -9...9 {
            for di in -9...9 where di * di + dj * dj <= 81 {
                let k = (n / 2 + dj) * n + (n / 2 + di)
                state.h[k] = terrain.cfg.sea + 0.1
                state.waterLevel[k] = terrain.cfg.sea + 0.5
            }
        }
        terrain.restore(state)
        terrain.computeFlow()

        let overlays = frameOverlays(RenderState(geometryMode: true), terrain)
        let water = overlays.water
        let mask = overlays.protectMask

        let lake = byte01(WaterRender.protectLakeThreshold)
        var lakes = 0
        for k in 0..<terrain.cfg.count where water[k * 4 + 1] >= lake {
            lakes += 1
            XCTAssertEqual(mask[k], 255, "Sichtbarer See an Zelle \(k) ungeschützt")
        }
        XCTAssertGreaterThan(lakes, 0, "See-Zellen müssen vorhanden sein")
    }

    func testSeamReachesExactlyProtectSeamCells() {
        let n = 32
        var coverage = [Double](repeating: 0, count: n * n)
        coverage[10 * n + 10] = 1.0
        var water = [UInt8](repeating: 0, count: n * n * 4)
        water[(20 * n + 22) * 4 + 1] = 255

        let mask = WaterProtectMask.bytes(n: n, bandCoverage: coverage, waterBytes: water)
        for (ci, cj) in [(10, 10), (22, 20)] {
            for dj in -(seam + 1)...(seam + 1) {
                for di in -(seam + 1)...(seam + 1) {
                    let inside = max(abs(di), abs(dj)) <= seam
                    XCTAssertEqual(mask[(cj + dj) * n + ci + di], inside ? 255 : 0,
                                   "Abstand (\(di), \(dj)) um (\(ci), \(cj))")
                }
            }
        }
    }

    func testMaskLeavesTheWaterFieldUntouched() {
        let terrain = aged()
        let withMask = RenderState(geometryMode: true)
        let without = RenderState(geometryMode: true)
        refresh(withMask, terrain)
        without.buildRiverRibbons(terrain, hscale: 24, lift: 0.35)
        _ = without.waterFieldBytes(terrain, blend: 1.0)

        terrain.step(dtYears: 200)
        for render in [withMask, without] { render.invalidate(terrain, .advanced) }
        _ = withMask.protectMaskBytes(terrain)
        let a = withMask.waterFieldBytes(terrain, blend: 0.3)
        _ = withMask.protectMaskBytes(terrain)
        let b = without.waterFieldBytes(terrain, blend: 0.3)
        XCTAssertEqual(a, b, "Die Schutzmaske hat das Wasserfeld verändert")
    }

    func testSameWorldYieldsIdenticalMask() {
        let a = refresh(RenderState(geometryMode: true), aged(seed: 42)).mask
        let b = refresh(RenderState(geometryMode: true), aged(seed: 42)).mask
        XCTAssertEqual(a, b, "Gleiche Welt muss dieselbe Maske liefern")
    }

    func testMaskFollowsEachWaterUploadAndRibbonBuild() {
        let terrain = aged()
        let render = RenderState(geometryMode: true)
        let n = terrain.cfg.n

        let first = frameOverlays(render, terrain)
        XCTAssertEqual(first.protectMask,
                        WaterProtectMask.bytes(n: n,
                                               bandCoverage: render.riverRibbonMesh.bandCoverage,
                                               waterBytes: first.water,
                                               wetMeadow: render.wetMeadowMask,
                                               barSand: BarMaterial.field(terrain).sand),
                        "Maske des ersten Frames folgt nicht dessen Wasser und Bändern")

        terrain.step(dtYears: 200)
        render.invalidate(terrain, .advanced)
        let second = frameOverlays(render, terrain)
        XCTAssertNotEqual(second.protectMask, first.protectMask,
                          "Ein Schritt muss die Maske erneuern (Wasser und Bänder folgen ihm)")
        XCTAssertEqual(second.protectMask,
                        WaterProtectMask.bytes(n: n,
                                               bandCoverage: render.riverRibbonMesh.bandCoverage,
                                               waterBytes: second.water,
                                               wetMeadow: render.wetMeadowMask,
                                               barSand: BarMaterial.field(terrain).sand),
                        "Maske des zweiten Frames folgt nicht dessen Wasser und Bändern")
    }

    func testBrushStrokeLeavesNoStaleMask() {
        let terrain = aged()
        let render = RenderState(geometryMode: true)
        let before = refresh(render, terrain).mask

        let n = Double(terrain.cfg.n)
        BrushTool.raise.apply(to: terrain, gx: n / 2, gz: n / 2,
                              radiusWorld: 25, strength: 40, target: 0)
        render.invalidate(terrain, .edited)
        terrain.recomputeFlowAfterEdit()
        render.invalidate(terrain, .edited)
        let after = refresh(render, terrain)

        XCTAssertNotEqual(before, after.mask, "Pinselstrich muss die Maske verändern")
        XCTAssertEqual(after.mask,
                       WaterProtectMask.bytes(n: terrain.cfg.n,
                                              bandCoverage: render.riverRibbonMesh.bandCoverage,
                                              waterBytes: after.water,
                                              wetMeadow: render.wetMeadowMask,
                                              barSand: BarMaterial.field(terrain).sand),
                       "Die Maske folgt nicht dem Wasser und den Bändern ihres Frames")
    }

    func testRegenerateLeavesNoStaleMask() {
        let terrain = aged()
        let render = RenderState(geometryMode: true)
        refresh(render, terrain)

        terrain.generate(seed: 9999)
        terrain.computeFlow()
        render.invalidate(terrain, .replaced)
        let beforeUpload = render.protectMaskBytes(terrain)
        XCTAssertEqual(beforeUpload,
                       WaterProtectMask.bytes(n: terrain.cfg.n,
                                              bandCoverage: render.riverRibbonMesh.bandCoverage,
                                              waterBytes: []),
                       "Das Wasserfeld der alten Welt darf nicht in die neue Maske")

        XCTAssertEqual(refresh(render, terrain).mask,
                       refresh(RenderState(geometryMode: true), terrain).mask)
    }

    func testLoadLeavesNoStaleMask() throws {
        let saved = aged(seed: 4242)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("protect-mask-\(UUID().uuidString).rsworld").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try WorldSnapshot.write(saved, to: path)

        let render = RenderState(geometryMode: true)
        let before = refresh(render, aged()).mask
        let loaded = try WorldSnapshot.read(from: path)
        render.invalidate(loaded, .replaced)
        let after = refresh(render, loaded).mask

        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after, refresh(RenderState(geometryMode: true), loaded).mask)
    }

    func testEmptyTerrainReturnsEmptyBuffer() {
        var cfg = SimConfig()
        cfg.n = 0
        let empty = Terrain(allocating: cfg, seed: 1)
        XCTAssertEqual(frameOverlays(RenderState(geometryMode: true), empty).protectMask,
                       [UInt8]())
        XCTAssertEqual(WaterProtectMask.bytes(n: 0, bandCoverage: [], waterBytes: []), [UInt8]())
    }
}
