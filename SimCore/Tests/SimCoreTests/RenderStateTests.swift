import Foundation
import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter für `RenderState` (Issue #93): den Render-Zustand, der bis dahin der
/// GDExtension gehörte.
///
/// Zwei Ebenen, weil der Umzug zwei Zusicherungen trägt:
/// 1. VERHALTEN, headless ausführbar — nach jedem mutierenden Einstieg der
///    Brücke liefert der Material-Cache den frischen Stand, und „andere Welt"
///    verwirft zusätzlich die Vergleichsstände.
/// 2. QUELLTEXT der Brücke — sie darf den Zustand nicht wieder selbst halten
///    und keine Terrain-Änderung ohne Invalidierung fahren (`SourceProbe`; die
///    Extension ist headless nicht ausführbar, ihr Quelltext aber lesbar).
final class RenderStateTests: XCTestCase {

    // MARK: - Verhalten: der eine Invalidierungs-Einstieg

    /// Die Zusicherung von #93: JEDER mutierende Einstieg der Brücke endet in
    /// `invalidate`, und danach zeigt der Material-Cache den frischen Stand.
    ///
    /// Geprüft wird nicht ein internes Flag, sondern die Wirkung: der gepufferte
    /// Puffer muss dem entsprechen, den `TerrainColorRenderer` für das JETZIGE
    /// Terrain baut. Die Tabelle fährt die Änderungen genau so, wie `SimNode`
    /// sie fährt — eine vergessene Invalidierung liefert hier den alten Puffer.
    func testEveryMutatingEntryLeavesFreshMaterialsBehind() throws {
        let mutations: [(name: String, change: (Terrain, RenderState) -> Void)] = [
            ("generate", { terrain, render in
                terrain.generate(seed: 4711)
                render.invalidate(terrain, worldReplaced: true)
            }),
            ("step", { terrain, render in
                terrain.step(dtYears: 200)
                render.invalidate(terrain)
            }),
            ("sculpt", { terrain, render in
                terrain.sculpt(gx: 48, gz: 48, radiusWorld: 14, dir: 1, strength: 30)
                render.invalidate(terrain)
            }),
            ("brush", { terrain, render in
                BrushTool.flatten.apply(to: terrain, gx: 48, gz: 48, radiusWorld: 14,
                                        strength: 1, target: 0.6)
                render.invalidate(terrain)
            }),
            ("recomputeFlow", { terrain, render in
                terrain.sculpt(gx: 30, gz: 60, radiusWorld: 14, dir: -1, strength: 30)
                terrain.recomputeFlowAfterEdit()
                render.invalidate(terrain)
            }),
        ]

        for (name, change) in mutations {
            let terrain = Terrain(config: renderConfig(), seed: 1337)
            let render = RenderState(geometryMode: true)
            let stale = render.terrainColorBytes(terrain)   // Cache warmlaufen

            change(terrain, render)

            assertServesFreshMaterials(render, terrain, staleColors: stale, entry: name)
        }
    }

    /// `loadWorld` ist der sechste Einstieg — und der, an dem die Asymmetrie
    /// lebte, die #93 auflöst. Er steht getrennt, weil er über eine echte Datei
    /// geht (die Brücke ERSETZT das Terrain-Objekt, sie ändert es nicht).
    func testLoadingAWorldLeavesFreshMaterialsBehind() throws {
        let render = RenderState(geometryMode: true)
        var terrain = Terrain(config: renderConfig(), seed: 1337)
        let stale = render.terrainColorBytes(terrain)

        let other = Terrain(config: renderConfig(), seed: 4711)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-state-\(UUID().uuidString).\(WorldSnapshot.fileExtension)")
            .path
        _ = try WorldSnapshot.write(other, to: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        terrain = try WorldSnapshot.read(from: path)
        render.invalidate(terrain, worldReplaced: true)

        assertServesFreshMaterials(render, terrain, staleColors: stale, entry: "loadWorld")
        XCTAssertGreaterThanOrEqual(render.treeVegMaxDelta(terrain), 1,
                                    "loadWorld: Bäume müssen neu gebaut werden")
        XCTAssertGreaterThanOrEqual(render.riversMaxDelta(terrain), 1,
                                    "loadWorld: Bänder müssen neu gebaut werden")
    }

    /// Liefert der Cache den Stand des JETZIGEN Terrains — und war überhaupt
    /// etwas zu invalidieren (`staleColors` muss sich unterscheiden, sonst
    /// bemerkte die Prüfung einen stehengebliebenen Cache nicht)?
    private func assertServesFreshMaterials(_ render: RenderState, _ terrain: Terrain,
                                            staleColors: [UInt8], entry: String,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) {
        let expected = TerrainColorRenderer.buffers(terrain)
        XCTAssertEqual(render.terrainColorBytes(terrain), expected.colors,
                       "\(entry): Farb-Cache steht noch auf dem alten Stand",
                       file: file, line: line)
        XCTAssertEqual(render.terrainSurfaceBytes(terrain), expected.surfaces,
                       "\(entry): Material-Cache steht noch auf dem alten Stand",
                       file: file, line: line)
        XCTAssertNotEqual(expected.colors, staleColors,
                          "\(entry): Änderung wirkt nicht auf die Farbe — der Test würde "
                          + "einen stehengebliebenen Cache nicht bemerken",
                          file: file, line: line)
    }

    /// Der Cache ist einer: ohne Invalidierung bleibt der ALTE Puffer stehen.
    /// Die Gegenprobe zum Test oben — sie belegt, dass dort überhaupt ein Cache
    /// zu invalidieren war (sonst prüfte er nur, dass zweimal dasselbe
    /// gerechnet wird).
    func testMaterialsStayCachedUntilInvalidated() {
        let terrain = Terrain(config: renderConfig(), seed: 1337)
        let render = RenderState(geometryMode: true)
        let before = render.terrainColorBytes(terrain)

        terrain.generate(seed: 4711)
        XCTAssertEqual(render.terrainColorBytes(terrain), before,
                       "Ohne Invalidierung darf der Cache nicht neu rechnen")

        render.invalidate(terrain, worldReplaced: true)
        XCTAssertNotEqual(render.terrainColorBytes(terrain), before,
                          "Nach der Invalidierung muss die neue Welt gefärbt werden")
    }

    /// `worldReplaced` ist der aufgelöste Unterschied zwischen Neu-Generieren
    /// und Laden: dieselbe Welt behält ihre Vergleichsstände, eine ANDERE Welt
    /// verwirft Dirty-Snapshots und Diagnose-Vergleichspunkt.
    func testWorldReplacedDropsEveryComparisonPoint() {
        let terrain = Terrain(config: renderConfig(), seed: 1337)
        let render = RenderState(geometryMode: true)
        render.buildRiverRibbons(terrain, hscale: 24, lift: 0.35)
        render.markRiversBuilt(terrain)
        render.markTreesBuilt(terrain)
        render.captureDebugReference(terrain)
        XCTAssertEqual(render.riversMaxDelta(terrain), 0)
        XCTAssertEqual(render.treeVegMaxDelta(terrain), 0)

        render.invalidate(terrain)
        XCTAssertEqual(render.riversMaxDelta(terrain), 0,
                       "Dieselbe Welt: der Band-Vergleichsstand bleibt")
        XCTAssertEqual(render.treeVegMaxDelta(terrain), 0,
                       "Dieselbe Welt: der Baum-Vergleichsstand bleibt")

        terrain.step(dtYears: 500)
        render.invalidate(terrain, worldReplaced: true)
        // Ohne Vergleichsstand melden beide Renderer „riesig" (Bäume 1, Bänder
        // 1e9) — die Schwellen in `Main.gd` liegen weit darunter.
        XCTAssertGreaterThanOrEqual(render.riversMaxDelta(terrain), 1,
                                    "Andere Welt: Bänder müssen neu gebaut werden")
        XCTAssertGreaterThanOrEqual(render.treeVegMaxDelta(terrain), 1,
                                    "Andere Welt: Bäume müssen neu gebaut werden")
        // Vergleichspunkt der Diagnose steht auf dem NEUEN Stand: Δ-Karte leer,
        // Referenzjahr = jetzt (Indizes: `TerrainDiagnostics.stats`).
        let stats = render.debugTerrainStats(terrain)
        XCTAssertEqual(stats[5], 0, "deltaMax nach worldReplaced nicht 0")
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
    /// weiter entlang ihrer Korridore gedeckelt.
    ///
    /// `Terrain(allocating:seed:)` ist hier genau richtig: es legt die Puffer
    /// an, generiert aber nicht — eine gültige Welt ohne Mäander-Kanäle, ohne
    /// dass der Test einen Spin-up bezahlt.
    func testWorldReplacedDropsTheRibbonSnapshotEvenWithoutChannels() {
        let terrain = Terrain(config: renderConfig(), seed: 1337)
        let render = RenderState(geometryMode: true)
        render.buildRiverRibbons(terrain, hscale: 24, lift: 0.35)
        render.markRiversBuilt(terrain)
        XCTAssertEqual(render.riversMaxDelta(terrain), 0)

        let ungenerated = Terrain(allocating: renderConfig(), seed: 4711)
        XCTAssertTrue(ungenerated.meander.channels.isEmpty,
                      "Testaufbau: diese Welt soll gerade KEINE Zentrumslinien haben")
        render.invalidate(ungenerated, worldReplaced: true)
        XCTAssertGreaterThanOrEqual(
            render.riversMaxDelta(ungenerated), 1,
            "Andere Welt ohne Kanäle: die Bänder der alten Welt bleiben sonst stehen")
    }

    /// Die Kopplung der beiden Wasser-Pfade (Issue #34) liegt jetzt im
    /// Zustand, nicht beim Aufrufer: das Feld liest die Bandflags des LETZTEN
    /// Builds selbst. Ohne Band deckelt es nichts, mit Band entsteht der Saum —
    /// derselbe Vertrag wie in `WaterRendererTests`, hier über `RenderState`.
    func testWaterFieldReadsTheRibbonResultWithoutBeingTold() {
        // n = 192 und 4000 Jahre: die kleinste Paarung, in der Kanäle das
        // Band-Gate passieren (gemessen 8 von 59; bei n = 96 keiner) — sonst
        // verglichen die beiden Aufrufe nur leere gegen leere Bandflags.
        let terrain = Terrain(config: renderConfig(n: 192), seed: 1337)
        while terrain.years < 4000 { terrain.step(dtYears: 1000) }
        terrain.computeFlow()
        let render = RenderState(geometryMode: true)

        let withoutBands = render.waterFieldBytes(terrain, blend: 1.0)
        render.buildRiverRibbons(terrain, hscale: 24, lift: 0.35)
        let withBands = render.waterFieldBytes(terrain, blend: 1.0)

        XCTAssertEqual(withoutBands.count, terrain.cfg.count * 4)
        XCTAssertTrue(render.riverRibbonMesh.bandChannelFlags.contains(true),
                      "Testwelt baut keine Bänder — der Vergleich sagt dann nichts")
        XCTAssertNotEqual(withBands, withoutBands,
                          "Das Wasserfeld ignoriert das Bau-Ergebnis der Bänder")
    }

    /// `renderGrid` ist Render-Zustand des Band-Renderers und muss über den
    /// Zustand erreichbar bleiben (die Brücke hält ihn nicht mehr selbst).
    func testRenderGridIsForwardedToTheRibbonRenderer() {
        let render = RenderState(geometryMode: true)
        XCTAssertEqual(render.renderGrid, 0, "Standard: volle Auflösung")
        render.renderGrid = 256
        XCTAssertEqual(render.renderGrid, 256)
    }

    // MARK: - Quelltext: die Brücke hält keinen Render-Zustand mehr

    func testBridgeOwnsNoRenderState() throws {
        let bridge = try RepoSource.extensionSources()
        for owned in ["WaterFieldRenderer(", "RiverRibbonRenderer(", "TreeInstanceRenderer(",
                      "TerrainDiagnostics(", "TerrainColorRenderer"] {
            XCTAssertFalse(bridge.contains(owned),
                           "Die GDExtension baut `\(owned)` selbst — Render-Zustand gehört "
                           + "seit Issue #93 in `SimRender.RenderState`")
        }
        assertContains(bridge, "RenderState(", hint: "Die Brücke delegiert an RenderState")
    }

    /// Die Fehlerklasse, die #93 beendet: eine Terrain-Änderung in der Brücke
    /// OHNE Invalidierung (sie stand sechsmal von Hand da).
    ///
    /// Geprüft je `@Callable` der Brücke, und zwar mit UMGEKEHRTER Beweislast:
    /// nicht „diese bekannten Mutatoren müssen invalidieren" — dann wäre ein neu
    /// hinzugefügter Mutator still ungeprüft —, sondern JEDER Umgang mit dem
    /// Terrain gilt als ändernd, solange er nicht unten als lesend eingetragen
    /// ist. Ein neuer Eingriff (auch über ein neues Werkzeug, nicht nur über
    /// `terrain.…`) wird damit rot, bis er invalidiert oder sein Weg bewusst als
    /// Leser deklariert wird.
    func testEveryTerrainMutationInTheBridgeInvalidates() throws {
        let bridge = try RepoSource.probe("\(RepoSource.extensionDirectory)/SimNode.swift")
        for reader in Self.readOnlyTerrainMembers {
            XCTAssertTrue(bridge.contains("terrain.\(reader)"),
                          "`terrain.\(reader)` steht nicht mehr in der Brücke — toten "
                          + "Eintrag aus der Leser-Liste nehmen, sonst entschärft sie "
                          + "irgendwann einen echten Mutator")
        }

        var mutating: [String] = []
        for method in bridge.swiftMethods()
        where method.body.hasPrefix("    @Callable ") && changesTheWorld(method.body) {
            mutating.append(method.name)
            XCTAssertTrue(method.body.contains("render.invalidate("),
                          "`\(method.name)` ändert das Terrain ohne `render.invalidate(` — "
                          + "genau die Handarbeit, die Issue #93 beendet hat. Ist der "
                          + "Umgang nur lesend, gehört er in die Leser-Listen dieses "
                          + "Wächters.")
        }
        XCTAssertEqual(mutating.sorted(),
                       ["brush", "generate", "loadWorld", "recomputeFlow", "sculpt", "step"],
                       "Die ändernden Einstiege der Brücke haben sich verschoben — "
                       + "Liste mitziehen (sie ist der Umfang dieses Wächters)")
    }

    /// Zugriffe, die das Terrain nur LESEN. Jeder Eintrag ist eine bewusste
    /// Ausnahme von der Invalidierungs-Pflicht.
    private static let readOnlyTerrainMembers: Set<String> = [
        "cfg", "h", "years", "heightBands", "receiver", "waterLevel", "area",
    ]

    /// Fasst der Methodenkörper das Terrain auf einem Weg an, der es ändern
    /// könnte? Alles Lesende wird vorher herausgestrichen; bleibt danach noch
    /// eine Erwähnung stehen, gilt sie als Eingriff.
    private func changesTheWorld(_ body: String) -> Bool {
        var text = body
        // Lesende Wege, auf denen das Terrain die Brücke verlässt: der
        // Render-Zustand (liest, s. `RenderState`) und der Spielstand-Schreiber.
        // Bis zur ERSTEN schließenden Klammer streichen, auch über
        // Zeilenumbrüche. Steht in einem Leser-Argument eine Klammer VOR dem
        // `terrain`, bleibt es stehen und der Wächter wird laut rot — er kann
        // dadurch fälschlich anschlagen, aber nie still grün werden.
        for reader in ["render\\.[A-Za-z]+\\([^)]*", "WorldSnapshot\\.[A-Za-z]+\\([^)]*"] {
            text = text.replacingOccurrences(of: reader, with: "",
                                             options: .regularExpression)
        }
        for member in Self.readOnlyTerrainMembers {
            text = text.replacingOccurrences(of: "terrain.\(member)", with: "")
        }
        // Als Wort, nicht als Teilwort: `terrainColorBytes` im Methodennamen ist
        // kein Zugriff auf die Welt.
        return text.range(of: "\\bterrain\\b", options: .regularExpression) != nil
    }
}
