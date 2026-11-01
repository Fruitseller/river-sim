import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter für das Frame-Protokoll (Issue #94): `RenderState.frame` liefert die
/// Puffer eines Frames, Reihenfolge und Drosseln leben in SimRender statt in
/// `Main.gd`.
final class RenderFrameTests: XCTestCase {

    /// Kleine Welt mit zwei Hand-Kanälen: genug für Band-Bau und Dirty-Vertrag,
    /// ohne einen Spin-up zu bezahlen.
    private func channelWorld() -> Terrain {
        let terrain = Terrain(config: renderConfig(), seed: 1337)
        terrain.meander.channels = [
            RiverChannel(nodes: [MeanderNode(x: 10, z: 10), MeanderNode(x: 12, z: 12)],
                         discharge: [100, 100]),
        ]
        return terrain
    }

    // MARK: - Reihenfolge

    /// Das Bänder-Ergebnis geht ins Wasserfeld DESSELBEN Frames: bit-gleich zum
    /// Handbau am eigenen `RiverRibbonRenderer` (Bänder, dann Wasser), und
    /// verschieden vom Feld ohne Bänder (sonst bewiese die Gleichheit nichts).
    func testRibbonResultReachesTheWaterFieldOfTheSameFrame() throws {
        // n = 192 und 4000 Jahre: die kleinste Paarung mit Bändern (s.
        // `WaterProtectMaskTests`, `CanopyTests`).
        let terrain = agedWorld(renderConfig(n: 192), years: 4000)

        let framed = RenderState(geometryMode: true)
        let frame = framed.frame(terrain, .settled, now: 0)
        let water = try XCTUnwrap(frame.overlays).water
        XCTAssertTrue(frame.ribbonsRebuilt, "Erster Frame muss die Bänder bauen")

        let byHand = builtRibbons(terrain)
        XCTAssertEqual(water,
                       WaterFieldRenderer().bytes(terrain, blend: 1.0, geometryMode: true,
                                                  bandChannelFlags: byHand.bandChannelFlags,
                                                  bandCoverage: byHand.bandCoverage),
                       "Frame-Wasser weicht vom Handbau Bänder → Wasser ab")
        XCTAssertEqual(framed.riverRibbonMesh.vertices, byHand.mesh.vertices)

        let withoutBands = WaterFieldRenderer().bytes(terrain, blend: 1.0, geometryMode: true,
                                                      bandChannelFlags: [], bandCoverage: [])
        XCTAssertNotEqual(water, withoutBands,
                          "Testwelt ohne Bandwirkung — der Vergleich sagt dann nichts")
    }

    /// Schutz- und Waldmaske eines Frames sehen dessen Wasser und Bänder:
    /// bit-gleich zur Zusammensetzung aus den Renderern desselben Standes
    /// (Bänder → Wasser → Schutz → Wald) — intern beobachtet, extern gefahren
    /// nur der Frame (Issue #214).
    func testMasksAreBuiltFromTheSameFrame() throws {
        let terrain = agedWorld(renderConfig(n: 192), years: 4000)
        let render = RenderState(geometryMode: true)
        let overlays = try XCTUnwrap(render.frame(terrain, .settled, now: 0).overlays)
        XCTAssertEqual(overlays.protectMask,
                       WaterProtectMask.bytes(n: terrain.cfg.n,
                                              bandCoverage: render.riverRibbonMesh.bandCoverage,
                                              waterBytes: overlays.water,
                                              wetMeadow: render.wetMeadowMask,
                                              barSand: render.barMaterial(terrain).sand))

        // Wald: Zielmaske aus denselben Quellen wie im Frame — ein Gedächtnis,
        // das noch nichts hält, nimmt das Ziel an.
        let refSurfaces = WetMeadow.apply(
            TerrainColorRenderer.buffers(terrain, bars: render.barMaterial(terrain)),
            mask: render.wetMeadowMask).surfaces
        XCTAssertEqual(overlays.forestMask,
                       ForestCanopyMask.bytes(terrain, surfaces: refSurfaces,
                                              protect: overlays.protectMask,
                                              clump: ForestCanopyMask.clumpField(
                                                  n: terrain.cfg.n, world: terrain.cfg.world)),
                       "Frame-Waldmaske weicht von der Zusammensetzung ab")
        XCTAssertTrue(overlays.forestMask.contains { $0 > 0 },
                      "Testwelt ohne Wald — der Vergleich sagt dann nichts")
    }

    // MARK: - Drosseln

    /// Der 1-Hz-Band-Deckel unterdrückt den Rebuild und lässt ihn nach Ablauf
    /// wieder zu; `settled` und `stroke` gehen an ihm vorbei.
    func testRibbonThrottleSuppressesAndThenAllowsTheRebuild() {
        let terrain = channelWorld()
        let render = RenderState(geometryMode: true)
        XCTAssertTrue(render.frame(terrain, .jumpChunk, now: 10).ribbonsRebuilt,
                      "Erste Prüfung ist immer fällig")

        terrain.meander.channels[0].nodes[1].x += 0.1
        XCTAssertFalse(render.frame(terrain, .jumpChunk, now: 10.999).ribbonsRebuilt,
                       "Vor Ablauf des Deckels darf nicht gebaut werden")
        XCTAssertTrue(render.frame(terrain, .jumpChunk, now: 11).ribbonsRebuilt,
                      "Nach Ablauf muss der Rebuild wieder zugelassen sein")

        terrain.meander.channels[0].nodes[1].x += 0.1
        XCTAssertTrue(render.frame(terrain, .stroke, now: 11.1).ribbonsRebuilt,
                      "Pinsel-Nachzug geht am Deckel vorbei")
        terrain.meander.channels[0].nodes[1].x += 0.1
        XCTAssertTrue(render.frame(terrain, .settled, now: 11.2).ribbonsRebuilt,
                      "Endstand geht am Deckel vorbei")
    }

    /// Unter der Delta-Schwelle wird nicht gebaut, auch wenn der Deckel frei ist.
    func testRibbonRebuildNeedsMovementAboveTheThreshold() {
        let terrain = channelWorld()
        let render = RenderState(geometryMode: true)
        _ = render.frame(terrain, .settled, now: 0)
        terrain.meander.channels[0].nodes[1].x += RenderState.ribbonRebuildDelta * 0.5
        XCTAssertFalse(render.frame(terrain, .settled, now: 5).ribbonsRebuilt)
    }

    /// Raster-Stempel-Modus (`RS_WATER_STAMP`): es gibt keine Bänder zu bauen.
    func testStampModeNeverBuildsRibbons() {
        let render = RenderState(geometryMode: false)
        XCTAssertFalse(render.frame(channelWorld(), .settled, now: 0).ribbonsRebuilt)
    }

    /// Die Overlay-Drossel des Zeitraffers: höchstens alle 0,30 s, mit dem
    /// kalibrierten Blend; alle anderen Auslöser laden sofort und hart.
    func testTimelapseThrottlesOverlaysAndBlendsTheWater() throws {
        let terrain = channelWorld()
        let render = RenderState(geometryMode: true)
        let first = try XCTUnwrap(render.frame(terrain, .timelapse, now: 0).overlays)
        XCTAssertEqual(first.waterBlend, RenderState.timelapseWaterBlend)
        XCTAssertEqual(RenderState.timelapseWaterBlend, 0.15)

        let throttled = render.frame(terrain, .timelapse, now: 0.25)
        XCTAssertNil(throttled.overlays, "Vor 0,30 s kein Overlay-Upload")
        XCTAssertFalse(throttled.ribbonsRebuilt)
        XCTAssertNotNil(render.frame(terrain, .timelapse, now: 0.30).overlays,
                        "Nach Ablauf wieder zugelassen")

        let settled = try XCTUnwrap(render.frame(terrain, .settled, now: 0.31).overlays)
        XCTAssertEqual(settled.waterBlend, 1.0, "Endstand blendet nicht")
    }

    /// GPU-Pfad: die CPU liefert das rohe Feld, der Blend reist zur GPU.
    /// Die Referenz entsteht direkt an den Renderern (Issue #214) — dieselben
    /// Bänder, dasselbe Wasser ohne Schwanzstufen.
    func testDeferredWaterTailHandsTheBlendToTheGPU() throws {
        let terrain = agedWorld(renderConfig(n: 96), years: 1000)
        let render = RenderState(geometryMode: true)
        render.deferWaterTail = true
        let overlays = try XCTUnwrap(render.frame(terrain, .timelapse, now: 0).overlays)
        XCTAssertEqual(overlays.waterBlend, RenderState.timelapseWaterBlend)
        let ribbons = builtRibbons(terrain)
        XCTAssertEqual(overlays.water,
                       WaterFieldRenderer().bytes(terrain, blend: 1.0, geometryMode: true,
                                                  bandChannelFlags: ribbons.bandChannelFlags,
                                                  bandCoverage: ribbons.bandCoverage,
                                                  deferTail: true))
    }

    // MARK: - Vertrag mit Main.gd

    /// `Main.gd` meldet den Auslöser als Zahl; die Konstanten dort müssen die
    /// Rohwerte von `FrameTrigger` tragen. Und die Taktung liegt nicht mehr dort.
    func testMainUsesTheFrameTriggerValues() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        let names: [FrameTrigger: String] = [
            .settled: "FRAME_SETTLED", .jumpChunk: "FRAME_JUMP_CHUNK",
            .timelapse: "FRAME_TIMELAPSE", .stroke: "FRAME_STROKE",
        ]
        XCTAssertEqual(names.count, FrameTrigger.allCases.count)
        for (trigger, name) in names {
            assertContains(main, "const \(name) := \(trigger.rawValue)",
                           hint: "FrameTrigger.\(trigger) == Main.gd \(name)")
        }
        // Die Schlüssel des Frame-Dictionarys: was die Brücke setzt, liest Main.gd.
        // Seit dem Hintergrund-Schritt (perf-measurements §L) trägt der Frame
        // auch Höhe, Jahr, Seespiegel, Höhenbänder und das Band-Mesh: der
        // Hauptthread lädt den Stand hoch, den der Job verpackt hat, und fragt
        // die Sim dafür nicht noch einmal.
        let bridge = try RepoSource.probe("Extension/Sources/RiverSimGD/SimNode.swift")
        for key in ["trigger", "year", "heights", "water", "water_blend", "color", "surface",
                    "cover", "flow", "protect", "forest", "plume", "filled", "bands", "ribbons",
                    "ribbon_verts", "ribbon_colors", "ribbon_uvs", "ribbon_uv2s", "ribbon_indices"] {
            assertContains(bridge, "out[Variant(\"\(key)\")]",
                           hint: "SimNode.packFrame setzt den Schlüssel \(key)")
            XCTAssertTrue(main.contains("frame[\"\(key)\"]") || main.contains("frame.has(\"\(key)\")")
                          || main.contains("frame.get(\"\(key)\""),
                          "Main.gd liest den Frame-Schlüssel \(key) nicht")
        }
        // EINZIGE Ausnahme (Issue #214): die Band-Anfänge gehören zum Mesh
        // (Struktur wie der Typ-Kanal), aber Main malt einen Dreiecks-Supp —
        // die Godot-Wächter (river_ribbons, water_geometry) zählen je Band
        // und lesen sie aus dem Frame; der Einzel-Callable dafür ist weg.
        assertContains(bridge, "out[Variant(\"ribbon_strip_starts\")]",
                       hint: "SimNode.packFrame setzt die Band-Anfänge")
        XCTAssertTrue(main.count(ofIdentifier: "ribbon_strip_starts") == 0,
                      "Main.gd liest ribbon_strip_starts — gehört den Wächtern (s. oben)")
        for gone in ["filledBytes", "heightBands", "riverRibbonVerts", "riverRibbonIndices"] {
            XCTAssertEqual(main.count(ofIdentifier: gone), 0,
                           "Main.gd holt \(gone) selbst — der Frame bringt den Stand mit")
        }
        for gone in ["riversMaxDelta", "markRiversBuilt", "buildRiverRibbons",
                     "waterFieldBytes", "waterFieldRawBytes", "protectMaskBytes",
                     "forestMaskBytes"] {
            XCTAssertEqual(main.count(ofIdentifier: gone), 0,
                           "Main.gd ruft \(gone) selbst — Reihenfolge und Drossel "
                           + "gehören in RenderState.frame (Issue #94)")
        }
    }
}
