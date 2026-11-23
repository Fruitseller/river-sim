import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

final class RenderFrameTests: XCTestCase {

    private func channelWorld() -> Terrain {
        let terrain = Terrain(config: renderConfig(), seed: 1337)
        terrain.meander.channels = [
            RiverChannel(nodes: [MeanderNode(x: 10, z: 10), MeanderNode(x: 12, z: 12)],
                         discharge: [100, 100]),
        ]
        return terrain
    }

    func testRibbonResultReachesTheWaterFieldOfTheSameFrame() throws {
        let terrain = agedWorld(renderConfig(n: 192), years: 4000)

        let framed = RenderState(geometryMode: true)
        let frame = framed.frame(terrain, .settled, now: 0)
        let water = try XCTUnwrap(frame.overlays).water
        XCTAssertTrue(frame.ribbonsRebuilt, "Erster Frame muss die Bänder bauen")

        let byHand = builtRibbons(terrain)
        XCTAssertEqual(water,
                       WaterFieldRenderer().bytes(terrain, blend: 1.0, geometryMode: true,
                                                  bandChannelFlags: byHand.bandChannelFlags,
                                                  bandCoverage: byHand.bandCoverage,
                                                  bandOwner: byHand.bandOwner),
                       "Frame-Wasser weicht vom Handbau Bänder → Wasser ab")
        XCTAssertEqual(framed.riverRibbonMesh.vertices, byHand.mesh.vertices)

        let withoutBands = WaterFieldRenderer().bytes(terrain, blend: 1.0, geometryMode: true,
                                                      bandChannelFlags: [], bandCoverage: [])
        XCTAssertNotEqual(water, withoutBands,
                          "Testwelt ohne Bandwirkung — der Vergleich sagt dann nichts")
    }

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

        let refMaterial = WetMeadow.apply(
            TerrainColorRenderer.buffers(terrain, bars: render.barMaterial(terrain)),
            mask: render.wetMeadowMask)
        let n = terrain.cfg.n
        XCTAssertEqual(overlays.forestMask,
                       ForestCanopyMask.target(
                           terrain, surfaces: refMaterial.surfaces, colors: refMaterial.colors,
                           bandCore: render.bandCore, waterBytes: overlays.water,
                           wetMeadow: render.wetMeadowMask, barSand: render.barMaterial(terrain).sand,
                           clump: ForestCanopyMask.clumpField(n: n, world: terrain.cfg.world),
                           riparianNoise: ForestCanopyMask.riparianField(n: n, world: terrain.cfg.world),
                           protect: overlays.protectMask).mask,
                       "Frame-Waldmaske weicht von der Zusammensetzung ab")
        XCTAssertTrue(overlays.forestMask.contains { $0 > 0 },
                      "Testwelt ohne Wald — der Vergleich sagt dann nichts")
    }

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

    func testRibbonRebuildNeedsMovementAboveTheThreshold() {
        let terrain = channelWorld()
        let render = RenderState(geometryMode: true)
        _ = render.frame(terrain, .settled, now: 0)
        terrain.meander.channels[0].nodes[1].x += RenderState.ribbonRebuildDelta * 0.5
        XCTAssertFalse(render.frame(terrain, .settled, now: 5).ribbonsRebuilt)
    }

    func testSettledFrameAfterAnEditRebuildsTheRibbons() {
        let terrain = channelWorld()
        let render = RenderState(geometryMode: true)
        _ = render.frame(terrain, .settled, now: 0)
        render.invalidate(terrain, .edited)
        XCTAssertFalse(render.frame(terrain, .stroke, now: 1).ribbonsRebuilt,
                       "Während des Strichs zählt weiter die Knoten-Bewegung")
        XCTAssertTrue(render.frame(terrain, .settled, now: 2).ribbonsRebuilt,
                      "Endstand nach dem Eingriff baut die Bänder neu")
        XCTAssertFalse(render.frame(terrain, .settled, now: 3).ribbonsRebuilt,
                       "Ohne neuen Eingriff kein zweiter Bau")
        render.invalidate(terrain, .advanced)
        XCTAssertFalse(render.frame(terrain, .settled, now: 4).ribbonsRebuilt,
                       "Ein Sim-Schritt ohne Bewegung baut nicht")
    }

    func testFinishedStrokeMatchesTheLoadedWorld() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-load-\(UUID().uuidString).\(WorldSnapshot.fileExtension)").path
        let edited = path + ".edited.\(WorldSnapshot.fileExtension)"
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: edited)
        }
        let world = agedWorld(renderConfig(n: 192), years: 2000, seed: 1337)
        _ = try WorldSnapshot.write(world, to: path)
        let session = WorldSession<WorldFrame>(config: world.cfg, seed: 1337,
                                               render: RenderState(geometryMode: true))
        var now = 0.0
        func settled() -> WorldFrame {
            now += 1
            return session.renderFrame(.settled, now: now)
        }
        try session.load(from: path)
        _ = settled()
        let n = world.cfg.n
        for (gx, gz) in [(60.0, 60.0), (130.0, 90.0)] {
            for _ in 0..<6 {
                session.brush(.flatten, gx: gx, gz: gz, radiusWorld: 1.0, strength: 3.0,
                              target: world.cfg.sea - 0.05)
            }
            session.recomputeFlow()
            let stroke = settled()
            _ = try session.save(to: edited)
            session.generate(seed: 99)
            _ = settled()
            try session.load(from: edited)
            let loaded = settled()
            let a = try XCTUnwrap(stroke.frame.overlays), b = try XCTUnwrap(loaded.frame.overlays)
            XCTAssertEqual(a.forestMask.count, n * n)
            XCTAssertEqual(zip(a.forestMask, b.forestMask).filter { $0 != $1 }.count, 0,
                           "Wald nach dem Laden wie nach dem Strich (\(gx), \(gz))")
            XCTAssertEqual(zip(a.protectMask, b.protectMask).filter { $0 != $1 }.count, 0,
                           "Schutzmaske nach dem Laden wie nach dem Strich (\(gx), \(gz))")
            XCTAssertEqual(stroke.ribbons.vertices, loaded.ribbons.vertices,
                           "Bänder nach dem Laden wie nach dem Strich (\(gx), \(gz))")
        }
    }

    func testStampModeNeverBuildsRibbons() {
        let render = RenderState(geometryMode: false)
        XCTAssertFalse(render.frame(channelWorld(), .settled, now: 0).ribbonsRebuilt)
    }

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
        let bridge = try RepoSource.probe("Extension/Sources/RiverSimGD/SimNode.swift")
        for key in ["trigger", "year", "heights", "water", "water_blend", "color", "surface",
                    "cover", "flow", "protect", "forest", "plume", "filled", "bands", "ribbons",
                    "ribbon_verts", "ribbon_colors", "ribbon_uvs", "ribbon_uv2s", "ribbon_flows",
                    "ribbon_indices"] {
            assertContains(bridge, "out[Variant(\"\(key)\")]",
                           hint: "SimNode.packFrame setzt den Schlüssel \(key)")
            XCTAssertTrue(main.contains("frame[\"\(key)\"]") || main.contains("frame.has(\"\(key)\")")
                          || main.contains("frame.get(\"\(key)\""),
                          "Main.gd liest den Frame-Schlüssel \(key) nicht")
        }
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
