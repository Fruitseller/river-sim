import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter für `RenderState` (Issue #93): den Render-Zustand, der bis dahin der
/// GDExtension gehörte.
///
/// Zwei Ebenen, weil der Umzug zwei Zusicherungen trägt:
/// 1. VERHALTEN, headless ausführbar — nach jedem mutierenden Einstieg liefert
///    der nächste Frame den frischen Stand, und „andere Welt" verwirft
///    zusätzlich die Vergleichsstände.
/// 2. QUELLTEXT der Brücke — sie darf den Zustand nicht wieder selbst halten
///    und seit Issue #214 auch die Render-Pfade nur noch über den Frame
///    fahren. Dass keine Terrain-Änderung ohne Invalidierung bleibt, prüft
///    `WorldSessionTests` ausgeführt an der Welt-Sitzung.
///
/// Issue #214: Der Zustand hat nur noch `frame`/`invalidate` als öffentliches
/// Interface. Diese Wächter fahren genau das — Verhalten der Reihenfolge und
/// der Drosseln über `frame()`, Band-Mechanik (Delta, Snapshot, Rebuild-
/// Sentinel) direkt am `RiverRibbonRenderer`. Interne Zwischenergebnisse
/// (Band-Mesh nach dem Frame) werden mit `@testable` nur BEOBACHTET, nie
/// gefahren: angetrieben wird ausschließlich über `frame()`/`invalidate()`.
final class RenderStateTests: XCTestCase {

    // MARK: - Verhalten: der eine Invalidierungs-Einstieg

    /// Die Zusicherung von #93: JEDER mutierende Einstieg endet in
    /// `invalidate`, und danach zeigt der nächste Frame den frischen Stand.
    ///
    /// Geprüft wird nicht ein internes Flag, sondern die Wirkung über das
    /// öffentliche Interface: der Frame muss dieselben Farben liefern wie ein
    /// FRISCHER Render-Zustand auf demselben Terrain. Die Tabelle fährt die
    /// Änderungen genau so, wie die Welt-Sitzung sie fährt — eine vergessene
    /// Invalidierung liefert hier den alten Puffer weiter.
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
            let stale = frameOverlays(render, terrain).colors   // Cache warmlaufen

            change(terrain, render)

            assertServesFreshMaterials(render, terrain, staleColors: stale, entry: name)
        }
    }

    /// `loadWorld` ist der sechste Einstieg — und der, an dem die Asymmetrie
    /// lebte, die #93 auflöst. Er steht getrennt, weil er über eine echte Datei
    /// geht (die Sitzung ERSETZT das Terrain-Objekt, sie ändert es nicht).
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

        // Der ERSTE Frame nach `.replaced` muss neu bauen (bis #93 ließ das
        // Generieren den Band-Vergleichsstand stehen) — die Zusicherung geht
        // über `assertServesFreshMaterials` mit, weil deren Frame-Aufruf der
        // erste ist; ein zweiter Frame prüft nur noch den Delta-Deckel.
        let fresh = assertServesFreshMaterials(render, terrain, staleColors: stale, entry: "loadWorld")
        XCTAssertTrue(fresh.ribbonsRebuilt,
                      "loadWorld: Bänder müssen neu gebaut werden")
    }

    /// Liefert der nächste Frame den Stand des JETZIGEN Terrains — und war
    /// überhaupt etwas zu invalidieren (`staleColors` muss sich unterscheiden,
    /// sonst bemerkte die Prüfung einen stehengebliebenen Cache nicht)?
    /// Gibt den gefahrenen Frame zurück, damit Aufrufer Zusicherungen an ihm
    /// prüfen (etwa `ribbonsRebuilt` am ERSTEN Frame nach der Invalidierung).
    @discardableResult
    private func assertServesFreshMaterials(_ render: RenderState, _ terrain: Terrain,
                                            staleColors: [UInt8], entry: String,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) -> RenderFrame {
        // Die Referenz ist ein FRISCHER Zustand auf demselben Terrain: seine
        // Cache-Puffer entstehen garantiert aus dem Jetzt-Stand.
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

    /// Der Cache ist einer: ohne Invalidierung bleibt der ALTE Puffer stehen.
    /// Die Gegenprobe zu den Tests oben — sie belegt, dass dort überhaupt ein
    /// Cache zu invalidieren war.
    ///
    /// Einzelschritt-Beobachtung (`@testable`, Issue #214): Durch den Frame
    /// ist „Terrain geändert, aber nicht invalidiert" nicht mehr fahrbar —
    /// er zieht das Wasserfeld bedingungslos neu, und ändert sich dessen
    /// nasse Wiese, fällt der Material-Cache BEWUSST (#174 C, s.
    /// `RenderState.waterFieldBytes`). Vom Brücke-Pfad ist der Zustand eh
    /// unerreichbar: Jede Terrain-Änderung läuft über die Welt-Sitzung und
    /// invalidiert. Der reine Cache-Vertrag (stehen bis `invalidate`) ist damit
    /// nur am internen Schritt zu prüfen, nicht als Reihenfolge.
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

    /// `.replaced` ist der aufgelöste Unterschied zwischen Neu-Generieren
    /// und Laden: dieselbe Welt behält ihre Vergleichsstände, eine ANDERE Welt
    /// verwirft Dirty-Snapshots und Diagnose-Vergleichspunkt. Beides ist über
    /// den Frame sichtbar: „nicht neu gebaut" heißt, der Vergleichsstand
    /// meldet keine Bewegung — „neu gebaut" heißt, er ist gefallen.
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
        // Vergleichspunkt der Diagnose steht auf dem NEUEN Stand: Δ-Karte leer,
        // Referenzjahr = jetzt (Indizes: `TerrainDiagnostics.stats`).
        let stats = render.debugTerrainStats(terrain)
        XCTAssertEqual(stats[5], 0, "deltaMax nach .replaced nicht 0")
        XCTAssertEqual(stats[14], Float(terrain.years), "Referenzjahr nicht mitgezogen")
    }

    /// Der Band-Vergleichsstand muss auch dann fallen, wenn die NEUE Welt gar
    /// keine Zentrumslinien hat.
    ///
    /// Der Randfall, an dem der frühere Sentinel scheiterte: `maxDelta`
    /// verglich Längen, und „kein Vergleichspunkt" war dasselbe leere Array wie
    /// „Welt ohne Kanäle". Beides zusammen ergab „0 = unverändert" — der
    /// Rebuild blieb aus, obwohl `_rebuild_rivers` in `Main.gd` genau der
    /// Aufruf ist, der das alte Mesh leert. Sichtbar wären die Bänder der
    /// VORIGEN Welt geblieben, und `bandCoverage` hätte das Raster-Wasserfeld
    /// weiter entlang ihrer Korridore gedeckelt. Der Frame beweidet beides:
    /// er baut neu UND das Mesh ist danach leer.
    ///
    /// `Terrain(allocating:seed:)` ist hier genau richtig: es legt die Puffer
    /// an, generiert aber nicht — eine gültige Welt ohne Mäander-Kanäle, ohne
    /// dass der Test einen Spin-up bezahlt.
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
        // Beobachtung am internen Mesh (nicht gefahren): neu gebaut heißt
        // hier leer — die Bänder der alten Welt sind weg.
        XCTAssertTrue(render.riverRibbonMesh.vertices.isEmpty,
                      "Neue Welt ohne Kanäle: das Mesh muss leer sein")
    }

    // MARK: - Band-Mechanik (direkt am Renderer, Issue #214)

    /// `maxDelta` misst die maximale Knotenverschiebung gegen den Snapshot
    /// ohne Zwischen-Allokation und meldet bei Strukturänderungen (Knoten-
    /// oder Kanalzahl geändert) den Rebuild-Sentinel.
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

        // Bewegung eines einzelnen Knotens um exakt 0.04 Zellen:
        terrain.meander.channels[0].nodes[1].x += 0.04
        XCTAssertEqual(ribbons.maxDelta(terrain), 0.04, accuracy: 1e-9)

        // Größere Verschiebung an anderem Knoten (Z-Richtung):
        terrain.meander.channels[1].nodes[0].z -= 0.07
        XCTAssertEqual(ribbons.maxDelta(terrain), 0.07, accuracy: 1e-9)

        // Snapshot nachziehen:
        ribbons.markBuilt(terrain)
        XCTAssertEqual(ribbons.maxDelta(terrain), 0)

        // Strukturänderung 1: Knoten hinzugefügt -> Sentinel
        terrain.meander.channels[0].nodes.append(MeanderNode(x: 14, z: 14))
        terrain.meander.channels[0].discharge.append(100)
        XCTAssertGreaterThanOrEqual(ribbons.maxDelta(terrain), 1e8)

        // Snapshot nachziehen:
        ribbons.markBuilt(terrain)
        XCTAssertEqual(ribbons.maxDelta(terrain), 0)

        // Strukturänderung 2: Kanal entfernt -> Sentinel
        terrain.meander.channels.removeLast()
        XCTAssertGreaterThanOrEqual(ribbons.maxDelta(terrain), 1e8)
    }

    /// Nicht-endliche Knoten (NaN, ±inf) erzwingen den Rebuild-Sentinel, je
    /// Achse: `max(maxD, NaN)` liefert `maxD`, ohne Wächter meldete eine
    /// NaN-Koordinate also „unverändert". Liegt der Wert schon im Snapshot,
    /// bleibt der Zustand dirty, bis wieder endliche Koordinaten gebaut sind.
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

            // Nicht-endlicher Wert im Snapshot: auch die Heilung rebuildet.
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

    /// Determinismus des Band-Baus: derselbe Stand, zweimal gebaut — am selben
    /// Renderer wie an einer frischen Instanz —, liefert bit-gleiches Mesh.
    /// (Ersatz für den früheren Doppelbau in `game/tests/water_geometry.gd`;
    /// seit Issue #214 gibt es dort keinen Einzelschritt mehr, den ein Skript
    /// zweimal erzwingen könnte.)
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

    /// Leere Terrains (n == 0) fängt der Raster-Wasserpfad defensiv ab und
    /// liefert leere Puffer, statt auf 0-zähligen Pufferzeigern zu trappen —
    /// hier über den Frame geprüft, den eine leere Welt nicht umbringen darf.
    func testWaterFieldRendererHandlesEmptyTerrain() {
        let config = renderConfig(n: 0)
        let empty = Terrain(allocating: config, seed: 1337)
        let waterRenderer = WaterFieldRenderer()

        // Direkt auf WaterFieldRenderer: liefert leere Puffer statt auf nil-Pointern zu trappen
        XCTAssertEqual(waterRenderer.flowDetailField(empty), [],
                       "Leeres Terrain muss leeren flowDetailField-Puffer liefern")
        XCTAssertEqual(waterRenderer.bytes(empty, blend: 1.0, geometryMode: true,
                                           bandChannelFlags: [], bandCoverage: []), [],
                       "Leeres Terrain muss leeren bytes-Puffer liefern")

        // Auch über den Frame abgesichert
        let renderState = RenderState(geometryMode: true)
        let overlays = frameOverlays(renderState, empty)
        XCTAssertEqual(overlays.flowDetail, [UInt8](),
                       "Der Frame muss leeren flowDetail-Puffer liefern")
        XCTAssertEqual(overlays.water, [UInt8](),
                       "Der Frame muss leeren Wasser-Puffer liefern")

        // Nach Rückkehr zur gefüllten Welt bleibt die Funktionalität intakt
        let populated = Terrain(config: renderConfig(), seed: 1337)
        let populatedOverlays = frameOverlays(renderState, populated)
        XCTAssertEqual(populatedOverlays.flowDetail.count, populated.cfg.count)
        XCTAssertEqual(populatedOverlays.water.count, populated.cfg.count * 4)
    }

    /// Prüft den trap-freien Diagnose-Helfer für Feldgrößen-Mismatches
    /// (`WaterFieldRenderer.fieldSizeMismatchDetail`): Er sichert die Meldung
    /// ab, die der Guard im Debug-Build per `assertionFailure` ausgibt — der
    /// Guard selbst würde unter `swift test` den Runner trappen, der
    /// Release-Fallback (`[]`) ist darüber im Debug-Build mit abgesichert.
    func testWaterFieldRendererFieldSizeMismatchDetailIsPureAndDiagnosesAllFields() {
        // Stimmige Größen: keine Meldung.
        XCTAssertNil(WaterFieldRenderer.fieldSizeMismatchDetail(
            n: 4, cnt: 16, fieldCounts: [("h", 16), ("areaMFD", 16)]))
        // Ein korruptes Feld: Meldung nennt n, cnt und ALLE Feldgrößen.
        let message = WaterFieldRenderer.fieldSizeMismatchDetail(
            n: 4, cnt: 16,
            fieldCounts: [("h", 16), ("waterLevel", 15), ("areaMFD", 16),
                          ("receiver", 16), ("streamMap", 16)])
        XCTAssertNotNil(message, "Ein Größen-Mismatch muss eine Diagnose liefern")
        XCTAssertEqual(message, "Feldgrößen-Mismatch: n=4, cnt=16, "
                     + "h=16, waterLevel=15, areaMFD=16, receiver=16, streamMap=16",
                       "Die Diagnose nennt ALLE geprüften Felder, nicht nur das erste")
    }

    // MARK: - Quelltext: die Brücke hält keinen Render-Zustand mehr

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

    /// Issue #214: Die Brücke bedient den Render-Zustand NUR über den Frame.
    /// Kein Einzelschritt-Callable darf zurückkommen — sonst ließe sich die
    /// Reihenfolge Bänder → Wasser → Masken wieder von außen umgehen.
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
