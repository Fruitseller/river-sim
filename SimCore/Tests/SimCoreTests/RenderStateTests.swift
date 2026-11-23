import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

final class RenderStateTests: XCTestCase {

    func testEveryMutatingEntryLeavesFreshMaterialsBehind() throws {
        let mutations: [(name: String, change: (Terrain, RenderState) -> Void)] = [
            ("generate", { terrain, render in
                terrain.generate(seed: 4711)
                render.invalidate(terrain, .replaced)
            }),
            ("step", { terrain, render in
                terrain.step(dtYears: 200)
                render.invalidate(terrain, .advanced)
            }),
            ("sculpt", { terrain, render in
                terrain.sculpt(gx: 48, gz: 48, radiusWorld: 14, dir: 1, strength: 30)
                render.invalidate(terrain, .edited)
            }),
            ("brush", { terrain, render in
                BrushTool.flatten.apply(to: terrain, gx: 48, gz: 48, radiusWorld: 14,
                                        strength: 1, target: 0.6)
                render.invalidate(terrain, .edited)
            }),
            ("recomputeFlow", { terrain, render in
                terrain.sculpt(gx: 30, gz: 60, radiusWorld: 14, dir: -1, strength: 30)
                terrain.recomputeFlowAfterEdit()
                render.invalidate(terrain, .edited)
            }),
        ]

        for (name, change) in mutations {
            let terrain = Terrain(config: renderConfig(), seed: 1337)
            let render = RenderState(geometryMode: true)
            let stale = frameOverlays(render, terrain).colors

            change(terrain, render)

            assertServesFreshMaterials(render, terrain, staleColors: stale, entry: name)
        }
    }

    func testLoadingAWorldLeavesFreshMaterialsBehind() throws {
        let render = RenderState(geometryMode: true)
        var terrain = Terrain(config: renderConfig(), seed: 1337)
        let stale = frameOverlays(render, terrain).colors

        let other = Terrain(config: renderConfig(), seed: 4711)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-state-\(UUID().uuidString).\(WorldSnapshot.fileExtension)")
            .path
        _ = try WorldSnapshot.write(other, to: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        terrain = try WorldSnapshot.read(from: path)
        render.invalidate(terrain, .replaced)

        let fresh = assertServesFreshMaterials(render, terrain, staleColors: stale, entry: "loadWorld")
        XCTAssertTrue(fresh.ribbonsRebuilt,
                      "loadWorld: Bänder müssen neu gebaut werden")
    }

    @discardableResult
    private func assertServesFreshMaterials(_ render: RenderState, _ terrain: Terrain,
                                            staleColors: [UInt8], entry: String,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) -> RenderFrame {
        let expected = frameOverlays(RenderState(geometryMode: true), terrain)
        let frame = render.frame(terrain, .settled, now: 0)
        guard let fresh = frame.overlays else {
            fatalError("Ein .settled-Frame muss Overlays liefern (Drossel prüfen)")
        }
        XCTAssertEqual(fresh.colors, expected.colors,
                       "\(entry): Farb-Cache steht noch auf dem alten Stand",
                       file: file, line: line)
        XCTAssertEqual(fresh.surfaces, expected.surfaces,
                       "\(entry): Material-Cache steht noch auf dem alten Stand",
                       file: file, line: line)
        XCTAssertNotEqual(expected.colors, staleColors,
                          "\(entry): Änderung wirkt nicht auf die Farbe — der Test würde "
                          + "einen stehengebliebenen Cache nicht bemerken",
                          file: file, line: line)
        return frame
    }

    func testMaterialsStayCachedUntilInvalidated() {
        let terrain = Terrain(config: renderConfig(), seed: 1337)
        let render = RenderState(geometryMode: true)
        let before = render.terrainColorBytes(terrain)

        terrain.generate(seed: 4711)
        XCTAssertEqual(render.terrainColorBytes(terrain), before,
                       "Ohne Invalidierung darf der Cache nicht neu rechnen")

        render.invalidate(terrain, .replaced)
        XCTAssertNotEqual(frameOverlays(render, terrain).colors, before,
                          "Nach der Invalidierung muss die neue Welt gefärbt werden")
    }

    func testWorldReplacedDropsEveryComparisonPoint() {
        let terrain = Terrain(config: renderConfig(), seed: 1337)
        let render = RenderState(geometryMode: true)
        render.frame(terrain, .settled, now: 0)
        render.captureDebugReference(terrain)

        render.invalidate(terrain, .advanced)
        XCTAssertFalse(render.frame(terrain, .settled, now: 1).ribbonsRebuilt,
                       "Dieselbe Welt: der Band-Vergleichsstand bleibt")

        terrain.step(dtYears: 500)
        render.invalidate(terrain, .replaced)
        XCTAssertTrue(render.frame(terrain, .settled, now: 2).ribbonsRebuilt,
                     "Andere Welt: Bänder müssen neu gebaut werden")
        let stats = render.debugTerrainStats(terrain)
        XCTAssertEqual(stats[5], 0, "deltaMax nach .replaced nicht 0")
        XCTAssertEqual(stats[14], Float(terrain.years), "Referenzjahr nicht mitgezogen")
    }

    func testWorldReplacedDropsTheRibbonSnapshotEvenWithoutChannels() {
        let terrain = Terrain(config: renderConfig(), seed: 1337)
        let render = RenderState(geometryMode: true)
        XCTAssertTrue(render.frame(terrain, .settled, now: 0).ribbonsRebuilt,
                      "Testaufbau: erster Frame baut")

        let ungenerated = Terrain(allocating: renderConfig(), seed: 4711)
        XCTAssertTrue(ungenerated.meander.channels.isEmpty,
                      "Testaufbau: diese Welt soll gerade KEINE Zentrumslinien haben")
        render.invalidate(ungenerated, .replaced)
        XCTAssertTrue(render.frame(ungenerated, .settled, now: 1).ribbonsRebuilt,
                      "Andere Welt ohne Kanäle: die Bänder der alten Welt bleiben sonst stehen")
        XCTAssertTrue(render.riverRibbonMesh.vertices.isEmpty,
                      "Neue Welt ohne Kanäle: das Mesh muss leer sein")
    }

    func testRiversMaxDeltaMeasuresMovementAndDetectsStructuralChanges() {
        let terrain = Terrain(config: renderConfig(), seed: 1337)
        let ribbons = RiverRibbonRenderer()
        terrain.meander.channels = [
            RiverChannel(nodes: [MeanderNode(x: 10, z: 10), MeanderNode(x: 12, z: 12)],
                         discharge: [100, 100]),
            RiverChannel(nodes: [MeanderNode(x: 20, z: 20), MeanderNode(x: 25, z: 25)],
                         discharge: [200, 200]),
        ]
        ribbons.markBuilt(terrain)
        XCTAssertEqual(ribbons.maxDelta(terrain), 0)

        terrain.meander.channels[0].nodes[1].x += 0.04
        XCTAssertEqual(ribbons.maxDelta(terrain), 0.04, accuracy: 1e-9)

        terrain.meander.channels[1].nodes[0].z -= 0.07
        XCTAssertEqual(ribbons.maxDelta(terrain), 0.07, accuracy: 1e-9)

        ribbons.markBuilt(terrain)
        XCTAssertEqual(ribbons.maxDelta(terrain), 0)

        terrain.meander.channels[0].nodes.append(MeanderNode(x: 14, z: 14))
        terrain.meander.channels[0].discharge.append(100)
        XCTAssertGreaterThanOrEqual(ribbons.maxDelta(terrain), 1e8)

        ribbons.markBuilt(terrain)
        XCTAssertEqual(ribbons.maxDelta(terrain), 0)

        terrain.meander.channels.removeLast()
        XCTAssertGreaterThanOrEqual(ribbons.maxDelta(terrain), 1e8)
    }

    func testRiversMaxDeltaForcesRebuildOnNonFiniteNodes() {
        let sentinel = RiverRibbonRenderer.rebuildSentinel
        let axes: [(name: String, path: WritableKeyPath<MeanderNode, Double>)] = [
            ("x", \.x), ("z", \.z),
        ]
        for (axis, path) in axes {
            let terrain = Terrain(config: renderConfig(n: 16), seed: 1337)
            let ribbons = RiverRibbonRenderer()
            terrain.meander.channels = [
                RiverChannel(nodes: [MeanderNode(x: 2, z: 2), MeanderNode(x: 4, z: 4)],
                             discharge: [100, 100]),
            ]
            ribbons.markBuilt(terrain)
            for bad in [Double.nan, .infinity, -.infinity] {
                terrain.meander.channels[0].nodes[0][keyPath: path] = bad
                XCTAssertEqual(ribbons.maxDelta(terrain), sentinel,
                               "\(axis) = \(bad) gegen endlichen Snapshot muss rebuilden")
            }

            terrain.meander.channels[0].nodes[0][keyPath: path] = .nan
            ribbons.markBuilt(terrain)
            XCTAssertEqual(ribbons.maxDelta(terrain), sentinel,
                           "\(axis): NaN im Snapshot bleibt dirty")
            terrain.meander.channels[0].nodes[0][keyPath: path] = 2
            XCTAssertEqual(ribbons.maxDelta(terrain), sentinel,
                           "\(axis): Heilung gegen NaN-Snapshot muss rebuilden")
            ribbons.markBuilt(terrain)
            XCTAssertEqual(ribbons.maxDelta(terrain), 0,
                           "\(axis): nach Heilung und Rebuild wieder ruhig")
        }
    }

    func testRibbonBuildIsDeterministic() throws {
        let terrain = agedWorld(renderConfig(n: 192), years: 4000)
        let once = RiverRibbonRenderer()
        let first = once.build(terrain, hscale: RenderContract.heightScale,
                               lift: RenderContract.riverLift)
        let second = once.build(terrain, hscale: RenderContract.heightScale,
                                lift: RenderContract.riverLift)
        XCTAssertEqual(first, second, "zweiter Bau am selben Renderer weicht ab")
        let fresh = builtRibbons(terrain).mesh
        XCTAssertEqual(first, fresh, "Bau an frischem Renderer weicht ab")
    }

    func testWaterFieldRendererHandlesEmptyTerrain() {
        let config = renderConfig(n: 0)
        let empty = Terrain(allocating: config, seed: 1337)
        let waterRenderer = WaterFieldRenderer()

        XCTAssertEqual(waterRenderer.flowDetailField(empty), [],
                       "Leeres Terrain muss leeren flowDetailField-Puffer liefern")
        XCTAssertEqual(waterRenderer.bytes(empty, blend: 1.0, geometryMode: true,
                                           bandChannelFlags: [], bandCoverage: []), [],
                       "Leeres Terrain muss leeren bytes-Puffer liefern")

        let renderState = RenderState(geometryMode: true)
        let overlays = frameOverlays(renderState, empty)
        XCTAssertEqual(overlays.flowDetail, [UInt8](),
                       "Der Frame muss leeren flowDetail-Puffer liefern")
        XCTAssertEqual(overlays.water, [UInt8](),
                       "Der Frame muss leeren Wasser-Puffer liefern")

        let populated = Terrain(config: renderConfig(), seed: 1337)
        let populatedOverlays = frameOverlays(renderState, populated)
        XCTAssertEqual(populatedOverlays.flowDetail.count, populated.cfg.count)
        XCTAssertEqual(populatedOverlays.water.count, populated.cfg.count * 4)
    }

    func testWaterFieldRendererFieldSizeMismatchDetailIsPureAndDiagnosesAllFields() {
        XCTAssertNil(WaterFieldRenderer.fieldSizeMismatchDetail(
            n: 4, cnt: 16, fieldCounts: [("h", 16), ("areaMFD", 16)]))
        let message = WaterFieldRenderer.fieldSizeMismatchDetail(
            n: 4, cnt: 16,
            fieldCounts: [("h", 16), ("waterLevel", 15), ("areaMFD", 16),
                          ("receiver", 16), ("streamMap", 16)])
        XCTAssertNotNil(message, "Ein Größen-Mismatch muss eine Diagnose liefern")
        XCTAssertEqual(message, "Feldgrößen-Mismatch: n=4, cnt=16, "
                     + "h=16, waterLevel=15, areaMFD=16, receiver=16, streamMap=16",
                       "Die Diagnose nennt ALLE geprüften Felder, nicht nur das erste")
    }

    func testBridgeOwnsNoRenderState() throws {
        let bridge = try RepoSource.extensionSources()
        for owned in ["WaterFieldRenderer(", "RiverRibbonRenderer(",
                      "TerrainDiagnostics(", "TerrainColorRenderer"] {
            XCTAssertFalse(bridge.contains(owned),
                           "Die GDExtension baut `\(owned)` selbst — Render-Zustand gehört "
                           + "seit Issue #93 in `SimRender.RenderState`")
        }
        assertContains(bridge, "WorldSession<", hint: "Die Brücke delegiert an die Welt-Sitzung")
    }

    func testBridgeDrivesTheRenderOnlyThroughTheFrame() throws {
        let bridge = try RepoSource.extensionSources()
        for gone in ["func buildRiverRibbons", "func markRiversBuilt", "func riversMaxDelta",
                     "func waterFieldBytes", "func waterFieldRawBytes", "func flowDetailBytes",
                     "func protectMaskBytes", "func forestMaskBytes",
                     "func terrainColorBytes", "func terrainSurfaceBytes", "func terrainCoverBytes",
                     "func filled(", "func filledBytes", "func heightBands(",
                     "func riverRibbonVerts", "func riverRibbonColors", "func riverRibbonUVs",
                     "func riverRibbonUV2s", "func riverRibbonIndices", "func riverRibbonStripStarts",
                     "func sculpt("] {
            XCTAssertFalse(bridge.contains(gone),
                           "SimNode bedient mit `\(gone)` wieder einen Render-Einzelschritt — "
                           + "der Frame (renderFrame/beginStep) ist der einzige Weg (Issue #214)")
        }
        assertContains(bridge, "session.renderFrame(", hint: "Die Brücke fährt den Frame")
    }
}
