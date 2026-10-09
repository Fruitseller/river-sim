import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter für die Schutzmaske (`WaterProtectMask` / `RenderState.protectMaskBytes`, Issue #154).
///
/// Die Schutzmaske sperrt Kronendach und Verschiebung an Wasserflächen:
///  - Sichtbare Raster-Flüsse und Seen aus dem Wasserfeld
///  - Jede gebaute Bandfläche (`RiverRibbonRenderer.bandCoverage`), auch dort,
///    wo der Raster-Deckel das Wasser darunter entfernt hat
///  - Einen Saum von `WaterRender.protectSeamCells` Zellen um beides
///  - Trockenes Land ohne Wasser/Bänder im Saum-Abstand bleibt frei (0)
///  - Das Render-Wasserfeld selbst ändert sich nicht
///  - Gleiche Welt ergibt dieselbe Maske; Pinsel, Neugenerieren und Laden
///    hinterlassen keine veraltete Maske
///
/// Die Aufruf-Reihenfolge der Tests ist die von `Main.gd`: Bänder bauen, dann
/// das Wasserfeld ziehen, dann die Maske.
final class WaterProtectMaskTests: XCTestCase {

    private let seam = WaterRender.protectSeamCells

    private func aged(years: Double = 2000, seed: UInt32 = 1337) -> Terrain {
        agedWorld(renderConfig(n: 192), years: years, seed: seed)
    }

    /// Der Render-Takt aus `Main.gd` nach einer Terrain-Änderung.
    @discardableResult
    private func refresh(_ render: RenderState, _ terrain: Terrain)
        -> (water: [UInt8], mask: [UInt8]) {
        render.buildRiverRibbons(terrain, hscale: 24, lift: 0.35)
        let water = render.waterFieldBytes(terrain, blend: 1.0)
        return (water, render.protectMaskBytes(terrain))
    }

    /// Kern-Zellen (Wasser oder Band) nach den Vertrags-Schwellen.
    private func core(_ water: [UInt8], _ coverage: [Double], count: Int) -> [Bool] {
        let river = byte01(WaterRender.protectRiverThreshold)
        let lake = byte01(WaterRender.protectLakeThreshold)
        return (0..<count).map { k in
            water[k * 4] >= river || water[k * 4 + 1] >= lake
                || (k < coverage.count && coverage[k] >= WaterRender.protectBandThreshold)
        }
    }

    // MARK: - Inhalt der Maske

    /// Sichtbare Flüsse, jede Bandfläche und gerade die vom Raster-Deckel
    /// geleerten Bandzellen sind geschützt; außerhalb des Saums ist alles frei.
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

        // Exakt: geschützt genau dann, wenn eine Kernzelle im Saum-Abstand liegt.
        let isCore = core(water, coverage, count: cnt)
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
                XCTAssertEqual(mask[j * n + i], near ? 255 : 0, "Zelle (\(i), \(j))")
                if !near { free += 1 }
            }
        }
        XCTAssertGreaterThan(free, cnt / 4, "Testwelt braucht weite trockene Flächen")
    }

    /// Ein künstlicher See (Wasserspiegel über dem Boden) ist geschützt.
    func testMaskIncludesVisibleRasterLakes() {
        let terrain = Terrain(config: renderConfig(n: 96), seed: 1337)
        terrain.computeFlow()
        let n = terrain.cfg.n
        var state = terrain.state
        for dj in -5...5 {
            for di in -5...5 where di * di + dj * dj <= 25 {
                let k = (n / 2 + dj) * n + (n / 2 + di)
                state.h[k] = terrain.cfg.sea + 0.1
                state.waterLevel[k] = terrain.cfg.sea + 0.5
            }
        }
        terrain.restore(state)
        terrain.computeFlow()

        let render = RenderState(geometryMode: true)
        let water = render.waterFieldBytes(terrain, blend: 1.0)
        let mask = render.protectMaskBytes(terrain)

        let lake = byte01(WaterRender.protectLakeThreshold)
        var lakes = 0
        for k in 0..<terrain.cfg.count where water[k * 4 + 1] >= lake {
            lakes += 1
            XCTAssertEqual(mask[k], 255, "Sichtbarer See an Zelle \(k) ungeschützt")
        }
        XCTAssertGreaterThan(lakes, 0, "See-Zellen müssen vorhanden sein")
    }

    /// Der Saum reicht genau `protectSeamCells` Zellen (Chebyshev), für Bänder
    /// wie für Rasterwasser.
    func testSeamReachesExactlyProtectSeamCells() {
        let n = 32
        var coverage = [Double](repeating: 0, count: n * n)
        coverage[10 * n + 10] = 1.0
        var water = [UInt8](repeating: 0, count: n * n * 4)
        water[(20 * n + 22) * 4 + 1] = 255 // ein See-Texel

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

    // MARK: - Unveränderlichkeit des Render-Wasserfelds

    /// Die Maske liest das Wasserfeld nur: auch über einen EWMA-Übergang
    /// (`blend` < 1 nach einem Sim-Schritt) bleibt es bit-gleich zu einem
    /// Render-Zustand, der nie eine Maske gezogen hat.
    func testMaskLeavesTheWaterFieldUntouched() {
        let terrain = aged()
        let withMask = RenderState(geometryMode: true)
        let without = RenderState(geometryMode: true)
        refresh(withMask, terrain)
        without.buildRiverRibbons(terrain, hscale: 24, lift: 0.35)
        _ = without.waterFieldBytes(terrain, blend: 1.0)

        terrain.step(dtYears: 200)
        for render in [withMask, without] { render.invalidate(terrain) }
        _ = withMask.protectMaskBytes(terrain)
        let a = withMask.waterFieldBytes(terrain, blend: 0.3)
        _ = withMask.protectMaskBytes(terrain)
        let b = without.waterFieldBytes(terrain, blend: 0.3)
        XCTAssertEqual(a, b, "Die Schutzmaske hat das Wasserfeld verändert")
    }

    // MARK: - Determinismus

    func testSameWorldYieldsIdenticalMask() {
        let a = refresh(RenderState(geometryMode: true), aged(seed: 42)).mask
        let b = refresh(RenderState(geometryMode: true), aged(seed: 42)).mask
        XCTAssertEqual(a, b, "Gleiche Welt muss dieselbe Maske liefern")
    }

    // MARK: - Invalidierung

    /// Die Maske folgt beiden Quellen: jedem Wasser-Upload und jedem Band-Bau,
    /// auch ohne Terrain-Änderung dazwischen (Reihenfolge Bänder → Maske →
    /// Wasser → Maske, wie beim Fluss-Rebuild vor dem Textur-Update).
    func testMaskFollowsEachWaterUploadAndRibbonBuild() {
        let terrain = aged()
        let render = RenderState(geometryMode: true)
        let n = terrain.cfg.n

        let water = render.waterFieldBytes(terrain, blend: 1.0)
        let waterOnly = render.protectMaskBytes(terrain)
        XCTAssertEqual(waterOnly, WaterProtectMask.bytes(n: n, bandCoverage: [], waterBytes: water))

        render.buildRiverRibbons(terrain, hscale: 24, lift: 0.35)
        let coverage = render.riverRibbonMesh.bandCoverage
        let withBands = render.protectMaskBytes(terrain)
        XCTAssertEqual(withBands,
                       WaterProtectMask.bytes(n: n, bandCoverage: coverage, waterBytes: water))
        XCTAssertNotEqual(withBands, waterOnly, "Band-Bau muss die Maske erneuern")

        let water2 = render.waterFieldBytes(terrain, blend: 1.0)
        XCTAssertEqual(render.protectMaskBytes(terrain),
                       WaterProtectMask.bytes(n: n, bandCoverage: coverage, waterBytes: water2),
                       "Wasser-Upload muss die Maske erneuern")
    }

    /// Pinselstrich (über `BrushTool`, wie die Brücke) hinterlässt nach dem
    /// Render-Takt dieselbe Maske wie ein frischer Render-Zustand.
    func testBrushStrokeLeavesNoStaleMask() {
        let terrain = aged()
        let render = RenderState(geometryMode: true)
        let before = refresh(render, terrain).mask

        let n = Double(terrain.cfg.n)
        BrushTool.raise.apply(to: terrain, gx: n / 2, gz: n / 2,
                              radiusWorld: 25, strength: 40, target: 0)
        render.invalidate(terrain)
        terrain.recomputeFlowAfterEdit()
        render.invalidate(terrain)
        let after = refresh(render, terrain).mask

        XCTAssertNotEqual(before, after, "Pinselstrich muss die Maske verändern")
        XCTAssertEqual(after, refresh(RenderState(geometryMode: true), terrain).mask)
    }

    /// Neugenerieren: keine Wasser-Reste der alten Welt, danach frisch.
    func testRegenerateLeavesNoStaleMask() {
        let terrain = aged()
        let render = RenderState(geometryMode: true)
        refresh(render, terrain)

        terrain.generate(seed: 9999)
        terrain.computeFlow()
        render.invalidate(terrain, worldReplaced: true)
        let beforeUpload = render.protectMaskBytes(terrain)
        XCTAssertEqual(beforeUpload,
                       WaterProtectMask.bytes(n: terrain.cfg.n,
                                              bandCoverage: render.riverRibbonMesh.bandCoverage,
                                              waterBytes: []),
                       "Das Wasserfeld der alten Welt darf nicht in die neue Maske")

        XCTAssertEqual(refresh(render, terrain).mask,
                       refresh(RenderState(geometryMode: true), terrain).mask)
    }

    /// Laden: eine ANDERE Terrain-Instanz kommt herein (wie `SimNode.loadWorld`).
    func testLoadLeavesNoStaleMask() throws {
        let saved = aged(seed: 4242)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("protect-mask-\(UUID().uuidString).rsworld").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try WorldSnapshot.write(saved, to: path)

        let render = RenderState(geometryMode: true)
        let before = refresh(render, aged()).mask
        let loaded = try WorldSnapshot.read(from: path)
        render.invalidate(loaded, worldReplaced: true)
        let after = refresh(render, loaded).mask

        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after, refresh(RenderState(geometryMode: true), loaded).mask)
    }

    // MARK: - Grenzfälle

    /// Leeres Terrain (n == 0) darf nicht abstürzen und muss einen leeren Puffer liefern.
    func testEmptyTerrainReturnsEmptyBuffer() {
        var cfg = SimConfig()
        cfg.n = 0
        let empty = Terrain(allocating: cfg, seed: 1)
        XCTAssertEqual(RenderState(geometryMode: true).protectMaskBytes(empty), [UInt8]())
        XCTAssertEqual(WaterProtectMask.bytes(n: 0, bandCoverage: [], waterBytes: []), [UInt8]())
    }
}
