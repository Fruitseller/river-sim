import XCTest
@testable import SimCore
@testable import SimRender

/// Tests für den MultiMesh-Transform-Puffer der 3D-Bäume (`SimRender.TreeInstanceRenderer`).
///
/// Ergänzt die Dirty-Vertrags- und Delta-Wächter in `SimRenderTests` um Absicherungen für
/// leere Terrains, Kleinst-Gitter, ungültige Varianten und Puffer-Integrität.
final class TreeRendererTests: XCTestCase {

    /// Leeres Terrain (n == 0) muss defensiv einen leeren Puffer liefern, ohne Speicher
    /// unnötig zu reservieren oder auf ungültigen Gittergrenzen zu trappen.
    func testTreeBufferHandlesEmptyTerrain() {
        let config = renderConfig(n: 0)
        let empty = Terrain(allocating: config, seed: 1337)
        let renderer = TreeInstanceRenderer()

        for variant in 0...2 {
            XCTAssertEqual(renderer.buffer(empty, variant: variant, hscale: 24, coverage: 2), [],
                           "Leeres Terrain muss für Variante \(variant) leeren Puffer liefern")
        }

        // Auch über RenderState absichern
        let renderState = RenderState()
        XCTAssertEqual(renderState.treeInstanceBuffer(empty, variant: 0, hscale: 24, coverage: 2), [],
                       "RenderState muss für leeres Terrain leeren Puffer liefern")
    }

    /// Gitter ohne hinreichenden Rand für den 6-Zellen-Küstenabstand (n <= 12)
    /// müssen sofort einen leeren Puffer liefern.
    func testTreeBufferHandlesSmallGridWithoutCoastMargin() {
        let small = Terrain(allocating: renderConfig(n: 12), seed: 1337)
        let renderer = TreeInstanceRenderer()

        XCTAssertEqual(renderer.buffer(small, variant: 0, hscale: 24, coverage: 2), [],
                       "Gitter mit n <= 12 hat keine Kandidaten-Zellen und muss leeren Puffer liefern")
    }

    /// Ungültige Varianten-Indizes außerhalb von 0...2 werden vor dem Scan abgewiesen.
    func testTreeBufferRejectsInvalidVariant() {
        let terrain = Terrain(config: renderConfig(), seed: 1337)
        let renderer = TreeInstanceRenderer()

        XCTAssertEqual(renderer.buffer(terrain, variant: -1, hscale: 24, coverage: 2), [],
                       "Negative Variante muss leeren Puffer liefern")
        XCTAssertEqual(renderer.buffer(terrain, variant: 3, hscale: 24, coverage: 2), [],
                       "Variante > 2 muss leeren Puffer liefern")
    }

    /// Eine reguläre Testwelt erzeugt für gültige Varianten deterministische,
    /// endliche Instanz-Puffer im Godot-MultiMesh-Layout (12 Floats je Instanz).
    func testTreeBufferProducesValidMultiMeshBufferForPopulatedTerrain() {
        let terrain = Terrain(config: renderConfig(), seed: 1337)
        let renderer = TreeInstanceRenderer()
        let renderState = RenderState()

        let direct = renderer.buffer(terrain, variant: 0, hscale: 24, coverage: 2)
        let viaState = renderState.treeInstanceBuffer(terrain, variant: 0, hscale: 24, coverage: 2)

        XCTAssertFalse(direct.isEmpty, "Testwelt enthält Laubbäume")
        XCTAssertEqual(direct.count % 12, 0, "Pufferlänge muss Vielfaches von 12 Floats sein")
        XCTAssertEqual(direct, viaState, "Aufruf über RenderState muss identisch zum Renderer sein")
        XCTAssertTrue(direct.allSatisfy(\.isFinite), "Alle Floats im MultiMesh-Puffer müssen endlich sein")
    }

    /// Nicht-positive Abdeckung (`coverage <= 0`, z. B. TreeCoverage.NONE)
    /// liefert sofort einen leeren Puffer, ohne Instanzen zu erzeugen.
    func testTreeBufferRejectsNonPositiveCoverage() {
        let terrain = Terrain(config: renderConfig(), seed: 1337)
        let renderer = TreeInstanceRenderer()

        XCTAssertEqual(renderer.buffer(terrain, variant: 0, hscale: 24, coverage: 0), [],
                       "coverage == 0 (TreeCoverage.NONE) muss leeren Puffer liefern")
        XCTAssertEqual(renderer.buffer(terrain, variant: 0, hscale: 24, coverage: -1), [],
                       "Negative Abdeckung muss leeren Puffer liefern")

        let renderState = RenderState()
        XCTAssertEqual(renderState.treeInstanceBuffer(terrain, variant: 0, hscale: 24, coverage: 0), [],
                       "RenderState muss für coverage == 0 leeren Puffer liefern")
    }

    /// Nicht-endliche (NaN, ±inf), nicht-positive (<= 0) oder extrem große `hscale`-Werte werden defensiv
    /// mit einem leeren Puffer abgewiesen, um ungültige Floats im MultiMesh zu verhindern.
    func testTreeBufferRejectsNonFiniteAndExtremeHScale() {
        let terrain = Terrain(config: renderConfig(), seed: 1337)
        let renderer = TreeInstanceRenderer()

        for badScale in [Double.nan, Double.infinity, -Double.infinity, 1e12, -1e12, 0.0, -24.0] {
            XCTAssertEqual(renderer.buffer(terrain, variant: 0, hscale: badScale, coverage: 2), [],
                           "Ungültiges hscale \(badScale) muss leeren Puffer liefern")
        }

        let renderState = RenderState()
        XCTAssertEqual(renderState.treeInstanceBuffer(terrain, variant: 0, hscale: -24, coverage: 2), [],
                       "RenderState muss für negatives hscale leeren Puffer liefern")
        XCTAssertEqual(renderState.treeInstanceBuffer(terrain, variant: 0, hscale: 0, coverage: 2), [],
                       "RenderState muss für hscale == 0 leeren Puffer liefern")
    }

    /// Gitter ohne definierte Schrittweite (`cellSize == 0`, etwa bei `world <= 0`
    /// oder nicht-endlicher Weltgröße) liefern defensiv einen leeren Puffer,
    /// um Positionskollaps oder NaN-Werte im MultiMesh zu verhindern.
    func testTreeBufferWithoutCellSpacingReturnsEmptyBuffer() {
        let normalTerrain = Terrain(config: renderConfig(), seed: 1337)
        let populatedState = normalTerrain.state
        let renderer = TreeInstanceRenderer()
        let renderState = RenderState()

        // Vorbedingung der Gegenprobe: mit normaler Weltgröße existieren Bäume
        XCTAssertFalse(renderer.buffer(normalTerrain, variant: 0, hscale: 24, coverage: 2).isEmpty,
                       "Vorbedingung: Normales Terrain muss Bäume erzeugen")

        var c = renderConfig()
        c.world = 0
        XCTAssertEqual(c.cellSize, 0.0)
        let zeroWorld = Terrain(allocating: c, seed: 1337)
        zeroWorld.restore(populatedState)

        for variant in 0...2 {
            XCTAssertEqual(renderer.buffer(zeroWorld, variant: variant, hscale: 24, coverage: 2), [],
                           "Terrain mit world = 0 muss für Variante \(variant) leeren Puffer liefern")
        }
        XCTAssertEqual(renderState.treeInstanceBuffer(zeroWorld, variant: 0, hscale: 24, coverage: 2), [],
                       "RenderState muss für world = 0 leeren Puffer liefern")

        c.world = -10
        XCTAssertEqual(c.cellSize, 0.0)
        let negWorld = Terrain(allocating: c, seed: 1337)
        negWorld.restore(populatedState)
        XCTAssertEqual(renderer.buffer(negWorld, variant: 0, hscale: 24, coverage: 2), [],
                       "Terrain mit world < 0 muss leeren Puffer liefern")

        c.world = .infinity
        XCTAssertEqual(c.cellSize, 0.0)
        let infWorld = Terrain(allocating: c, seed: 1337)
        infWorld.restore(populatedState)
        XCTAssertEqual(renderer.buffer(infWorld, variant: 0, hscale: 24, coverage: 2), [],
                       "Terrain mit world = .infinity muss leeren Puffer liefern")

        c.world = .nan
        XCTAssertEqual(c.cellSize, 0.0)
        let nanWorld = Terrain(allocating: c, seed: 1337)
        nanWorld.restore(populatedState)
        XCTAssertEqual(renderer.buffer(nanWorld, variant: 0, hscale: 24, coverage: 2), [],
                       "Terrain mit world = NaN muss leeren Puffer liefern")
    }

    /// Nicht-endliche Werte (NaN, ±inf) im Vegetationsfeld müssen als maximale
    /// Änderung (Sentinel 1.0) gewertet werden und einen Rebuild erzwingen.
    /// Persistente Nicht-Endlichkeit erzwingt dauerhaft den Rebuild, bis der
    /// Zustand wieder endliche Werte annimmt.
    func testTreeVegMaxDeltaHandlesNonFiniteValues() {
        let terrain = Terrain(config: renderConfig(), seed: 1337)
        let renderer = TreeInstanceRenderer()
        renderer.markBuilt(terrain)
        XCTAssertEqual(renderer.maxDelta(terrain), 0.0, "Unverändertes Terrain hat maxDelta 0")

        var state = terrain.state
        state.veg[0] = Double.nan
        terrain.restore(state)
        XCTAssertEqual(renderer.maxDelta(terrain), 1.0,
                       "Nicht-endliche Werte in veg müssen Rebuild erzwingen (maxDelta 1.0)")

        // Bei persistenter Nicht-Endlichkeit bleibt der Rebuild aktiv:
        renderer.markBuilt(terrain)
        XCTAssertEqual(renderer.maxDelta(terrain), 1.0,
                       "Persistente Nicht-Endlichkeit in veg muss weiterhin Rebuild erzwingen")

        // Nach Heilung zu endlichen Werten und erneutem markBuilt beruhigt sich maxDelta wieder:
        state.veg[0] = 0.5
        terrain.restore(state)
        XCTAssertEqual(renderer.maxDelta(terrain), 1.0,
                       "Übergang von NaN zu endlichem Wert erfordert Rebuild")
        renderer.markBuilt(terrain)
        XCTAssertEqual(renderer.maxDelta(terrain), 0.0,
                       "Nach Heilung und markBuilt beruhigt sich maxDelta wieder auf 0")
    }
}
