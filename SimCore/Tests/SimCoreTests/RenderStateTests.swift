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

    /// Produktionsphysik, nur `n` gesenkt (wie in `SimRenderTests`).
    private func renderConfig(n: Int = 96) -> SimConfig {
        var config = SimConfig()
        config.n = n
        config.world = calibrationWorld
        return config
    }

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

            let expected = TerrainColorRenderer.buffers(terrain)
            XCTAssertEqual(render.terrainColorBytes(terrain), expected.colors,
                           "\(name): Farb-Cache steht nach der Änderung noch auf dem alten Stand")
            XCTAssertEqual(render.terrainSurfaceBytes(terrain), expected.surfaces,
                           "\(name): Material-Cache steht nach der Änderung noch auf dem alten Stand")
            XCTAssertNotEqual(expected.colors, stale,
                              "\(name): Änderung wirkt nicht auf die Farbe — der Test "
                              + "würde einen stehengebliebenen Cache nicht bemerken")
        }
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
    /// OHNE Invalidierung (sie stand sechsmal von Hand da). Geprüft je Methode
    /// des Quelltexts — jede, die einen der Mutatoren aufruft, muss im selben
    /// Körper invalidieren.
    func testEveryTerrainMutationInTheBridgeInvalidates() throws {
        let bridge = try RepoSource.probe("\(RepoSource.extensionDirectory)/SimNode.swift")
        let mutators = ["terrain.generate(", "terrain.step(", "terrain.sculpt(",
                        "terrain.recomputeFlowAfterEdit(", "terrain = loaded",
                        "tool.apply("]
        for mutator in mutators {
            XCTAssertTrue(bridge.contains(mutator),
                          "`\(mutator)` steht nicht mehr in der Brücke — die Liste der "
                          + "geprüften Mutatoren mitziehen, sonst prüft der Wächter nichts")
        }
        for method in bridge.swiftMethods()
        where mutators.contains(where: method.body.contains) {
            XCTAssertTrue(method.body.contains("render.invalidate("),
                          "`\(method.name)` ändert das Terrain ohne `render.invalidate(` — "
                          + "genau die Handarbeit, die Issue #93 beendet hat")
        }
    }
}
