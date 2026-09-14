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
        var config = renderConfig(n: 0)
        config.world = 0 // cellSize ist hier −0.0, wird aber nie gelesen
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
}
