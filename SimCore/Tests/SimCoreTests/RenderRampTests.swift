import XCTest

@testable import SimRender

/// Wächter für `smoothstep` (`SimRender/RenderSupport.swift`) — die eine weiche
/// Stufe, durch die seit dieser Vereinheitlichung ALLE Render-Rampen des Moduls
/// laufen (Kaskaden-Übergabe und Mündungs-Fade der Bänder, Klippen-Gewicht der
/// Materialien, Abfluss-Rampe und Kanal-Deckkraft).
///
/// Dieselben zwei Zusagen wie bei `byte01` (s. `RenderByteTests`): an der
/// DARSTELLUNG ändert sich nichts (bit-identisch zu den Fassungen, die sie
/// ersetzt hat), und ein NaN in `x` fällt auf 0, statt durch die Rampe zu
/// wandern. Reiner Rechen-Wächter, kein Terrain — Mikrosekunden, gehört also in
/// die Pflichtsuite.
final class RenderRampTests: XCTestCase {

    /// Die Schreibweise, die vor der Vereinheitlichung von Hand in
    /// `RiverRibbonRenderer` und als privater Zwilling in
    /// `TerrainColorRenderer` stand. Bewusst hier dupliziert: sie ist die
    /// Referenz, gegen die `smoothstep` bit-identisch sein muss — und der
    /// einzige Ort, an dem sie noch stehen darf.
    private func legacySmoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    func testSmoothstepMatchesTheHandwrittenRampForFiniteValues() {
        // Echte Kanten-Paarungen aus dem Modul plus ein Raster quer über und
        // über beide Kanten hinaus: eine verschobene Klemme fiele hier auf.
        let edges: [(Double, Double)] = [(0, 1), (0.004, 0.026), (0.35, 0.65), (0, 320)]
        for (e0, e1) in edges {
            let span = e1 - e0
            for step in -100...300 {
                let x = e0 + span * Double(step) / 200
                XCTAssertEqual(smoothstep(e0, e1, x), legacySmoothstep(e0, e1, x),
                               "smoothstep weicht bei \(x) über [\(e0), \(e1)] von der alten Rampe ab")
            }
        }
    }

    /// Der Unterschied zur alten Schreibweise, der KEINE Darstellungsänderung
    /// ist: die Klemme steht mit der Konstanten zuerst, wischt NaN also weg
    /// (`min`/`max` liefern bei NaN den ERSTEN Operanden). Die alte Fassung
    /// reichte es durch die ganze Rampe.
    func testSmoothstepWipesNaNInsteadOfPassingItThrough() {
        XCTAssertEqual(smoothstep(0, 1, Double.nan), 0)
        XCTAssertTrue(legacySmoothstep(0, 1, Double.nan).isNaN,
                      "die alte Rampe reichte NaN durch — genau deshalb steht die Konstante zuerst")
        XCTAssertEqual(smoothstep(0, 1, -Double.infinity), 0)
        XCTAssertEqual(smoothstep(0, 1, Double.infinity), 1)
    }
}
