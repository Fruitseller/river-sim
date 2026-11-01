import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter für die Schutzmaske (`WaterProtectMask` / `RenderState.frame`, Issue #154).
///
/// Die Schutzmaske sperrt Kronendach und Verschiebung an Wasserflächen:
///  - Sichtbare Raster-Flüsse und Seen aus dem Wasserfeld
///  - Jede gebaute Bandfläche (`RiverRibbonRenderer.bandCoverage`), auch dort,
///    wo der Raster-Deckel das Wasser darunter entfernt hat
///  - Die nasse Wiese (Issue #174 C, `WaterFieldRenderer.wetMeadow`)
///  - Einen Saum von `WaterRender.protectSeamCells` Zellen um alles
///  - Trockenes Land ohne Wasser/Bänder im Saum-Abstand bleibt frei (0)
///  - Das Render-Wasserfeld selbst ändert sich nicht
///  - Gleiche Welt ergibt dieselbe Maske; Pinsel, Neugenerieren und Laden
///    hinterlassen keine veraltete Maske
///
/// Seit Issue #214 fährt der Wächter die Reihenfolge über den FRAME
/// (`RenderState.frame` — dieselbe wie `Main.gd`); interne Zwischenergebnisse
/// (Bandabdeckung, nasse Wiese, Gürtel-Material) werden mit `@testable` nur
/// BEOBACHTET. Die beiden Einzelschritt-Tests unten (Reinheit des Maskenpfads,
/// Maske vor dem ersten Wasser) tragen ihre Begründung am Test.
final class WaterProtectMaskTests: XCTestCase {

    private let seam = WaterRender.protectSeamCells

    private func aged(years: Double = 2000, seed: UInt32 = 1337) -> Terrain {
        agedWorld(renderConfig(n: 192), years: years, seed: seed)
    }

    /// Der Render-Takt aus `Main.gd` — seit Issue #214 über den Frame:
    /// Bänder, Wasserfeld und Masken entstehen gemeinsam in Frame-Reihenfolge.
    @discardableResult
    private func refresh(_ render: RenderState, _ terrain: Terrain)
        -> (water: [UInt8], mask: [UInt8]) {
        let overlays = frameOverlays(render, terrain)
        return (overlays.water, overlays.protectMask)
    }

    /// Kern-Zellen (Wasser, Band oder nasse Wiese, #174 C) nach den
    /// Vertrags-Schwellen.
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
                // Frische Bänke (#174 C2) sind ohne Saum geschützt.
                let bar = bars.sand[j * n + i] >= Float(WaterRender.barProtectSand)
                XCTAssertEqual(mask[j * n + i], near || bar ? 255 : 0, "Zelle (\(i), \(j))")
                if !near && !bar { free += 1 }
            }
        }
        XCTAssertGreaterThan(free, cnt / 4, "Testwelt braucht weite trockene Flächen")
    }

    /// Ein künstlicher See (Wasserspiegel über dem Boden) ist geschützt.
    ///
    /// Radius 9 bewusst über `WaterRender.wetMeadowMaxCells` (200 Zellen):
    /// kleinere Tümpel malt der Frame als NASSE WIESE statt als See (#174 C),
    /// der See-Kanal trägt sie nicht. Der alte Test sah kleinere Seen nur,
    /// weil er das Wasserfeld OHNE vorherigen Band-Bau zog — ohne Mesh gilt
    /// jeder Kanal als „hat ein Band" (Fallback in `WaterFieldRenderer.bytes`),
    /// und der Korridor-Stempel zählte den Tümpel als „banded". Durch den Frame
    /// baut der Band-Bau zuerst und meldet ehrlich „kein Kanal mit Band".
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
    ///
    /// Einzelschritt-Beobachtung (`@testable`, Issue #214): Der Frame koppelt
    /// Wasser und Maske immer im selben Takt — ein Zustand „ohne je eine
    /// Maske" ist über ihn nicht erreichbar. Der Test pinnt die Reinheit des
    /// Maskenpfads (er schreibt nie in den Wasserzustand), keine Reihenfolge.
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

    // MARK: - Determinismus

    func testSameWorldYieldsIdenticalMask() {
        let a = refresh(RenderState(geometryMode: true), aged(seed: 42)).mask
        let b = refresh(RenderState(geometryMode: true), aged(seed: 42)).mask
        XCTAssertEqual(a, b, "Gleiche Welt muss dieselbe Maske liefern")
    }

    // MARK: - Invalidierung

    /// Die Maske folgt beiden Quellen: jedem Wasser-Upload und jedem Band-Bau
    /// — seit Issue #214 über den Frame beobachtet: JEDE Maske ist aus dem
    /// Wasser und den Bändern IHRES Frames abgeleitet (die Folge stand vorher
    /// hier von Hand). Die Bänder des Frames werden nur beobachtet
    /// (`riverRibbonMesh`), nicht selbst gebaut.
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

    /// Pinselstrich (über `BrushTool`, wie die Brücke) hinterlässt keine
    /// veraltete Maske: die Maske des nächsten Frames ist aus DEM Wasser und
    /// DEN Bändern dieses Frames abgeleitet — aus nichts Gecachtem.
    ///
    /// Bewusst KEIN Vergleich gegen einen frischen Render-Zustand: der Frame
    /// deckelt den Band-Neubau an der Zentrumslinien-Bewegung (#93/#94), und
    /// ein Pinselstrich bewegt die Linien nicht (Delta 0) — der gebrauchtere
    /// Zustand behält seine Bänder legitim, während ein frischer Zustand sie
    /// baut (noch ohne Vergleichsstand). Verglichen wird stattdessen gegen die
    /// Neuberechnung aus den eigenen Frame-Eingaben; ein stehengebliebener
    /// Cache (der Fall, den #93 behob) wiche davon ab.
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

    /// Neugenerieren: keine Wasser-Reste der alten Welt, danach frisch.
    /// Der erste Teil (Maske VOR dem ersten Wasser-Upload der neuen Welt)
    /// beobachtet eine interne Zusicherung über `@testable`: `.replaced`
    /// verwirft `visibleWater` — durch den Frame ist der Zustand nicht
    /// erreichbar, dort kommt die Maske immer NACH dem frischen Wasser.
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
        render.invalidate(loaded, .replaced)
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
        XCTAssertEqual(frameOverlays(RenderState(geometryMode: true), empty).protectMask,
                       [UInt8]())
        XCTAssertEqual(WaterProtectMask.bytes(n: 0, bandCoverage: [], waterBytes: []), [UInt8]())
    }
}
