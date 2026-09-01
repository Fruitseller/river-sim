import XCTest

@testable import SimRender

/// Wächter für `byte01` (`SimRender/RenderSupport.swift`) — die eine
/// Umrechnung 0…1 → Byte, mit der jeder RGBA8-Render-Puffer endet
/// (Makrofarbe, Materialgewichte, Wasserfeld, Δ-Karte).
///
/// Zwei Zusagen, die zusammengehören: sie ändert an der DARSTELLUNG nichts
/// (bit-identisch zu der ausgeschriebenen Fassung, die sie ersetzt hat) und sie
/// ist TOTAL (`UInt8(Double)` bricht bei NaN/±∞ ab). Fiele die erste weg, wäre
/// die Vereinheitlichung eine stille Render-Änderung; fiele die zweite weg,
/// wäre sie zwecklos.
///
/// Reine Rechen-Wächter, kein Terrain: sie laufen in Mikrosekunden und gehören
/// deshalb in die Pflichtsuite, nicht hinter `RS_MEASURE`.
final class RenderByteTests: XCTestCase {

    /// Die Schreibweise, die vor der Vereinheitlichung zwölfmal in
    /// `TerrainColorRenderer`, `TerrainDiagnostics` und `WaterFieldRenderer`
    /// stand. Bewusst hier dupliziert: sie ist die Referenz, gegen die `byte01`
    /// bit-identisch sein muss — und der einzige Ort, an dem sie noch stehen
    /// darf.
    private func legacyByte(_ value: Double) -> UInt8 {
        UInt8(min(max(value, 0), 1) * 255)
    }

    func testByte01MatchesTheClampedConversionForFiniteValues() {
        // Ränder, Werte außerhalb von [0, 1] und ein dichtes Raster darin: die
        // Umrechnung schneidet ab (sie rundet nicht), ein Off-by-one an einer
        // der beiden Grenzen fiele hier auf.
        var values: [Double] = [-1e9, -1, -1e-12, 0, 1, 1 + 1e-12, 2, 1e9]
        for step in 0...2000 { values.append(Double(step) / 2000) }
        for value in values {
            XCTAssertEqual(byte01(value), legacyByte(value),
                           "byte01 weicht bei \(value) von der alten Klemme ab")
        }
    }

    /// Der Grund, aus dem `byte01` überhaupt existiert — ausführbar
    /// festgehalten, weil er nicht offensichtlich ist: `min`/`max` liefern bei
    /// einem NaN-Operanden den ERSTEN Operanden. `max(v, 0)` reicht NaN also
    /// durch, `max(0, v)` wischt es weg. Die Rechen-Stufen vor der Byte-Zeile
    /// schreiben durchweg die Konstante zuerst und sind damit beiläufig
    /// abgesichert; die Byte-Zeile schrieb den Wert zuerst und war es nicht.
    func testTheClampDoesNotCatchNaNWhenTheValueComesFirst() {
        XCTAssertTrue(max(Double.nan, 0).isNaN, "max(NaN, 0) muss NaN bleiben")
        XCTAssertTrue(min(max(Double.nan, 0), 1).isNaN,
                      "die alte Klemme reichte NaN bis in UInt8(_:) durch")
        XCTAssertEqual(max(0, Double.nan), 0, "umgedreht wischt dieselbe Klemme NaN weg")
    }

    /// Totalität: nicht-endliche Werte müssen ein definiertes Byte liefern,
    /// statt den Prozess abzureißen. Ein Abbruch der Extension wäre die
    /// schlechtere Antwort als ein sichtbar falsches Pixel — ungültige Zahlen
    /// sind hier ein angezeigter Zustand und keine Unmöglichkeit
    /// (`TerrainDiagnostics` zählt sie als `DBG_INVALID` und malt sie magenta).
    func testByte01IsTotalForNonFiniteValues() {
        XCTAssertEqual(byte01(Double.nan), 0)
        XCTAssertEqual(byte01(Double.infinity), 255)
        XCTAssertEqual(byte01(-Double.infinity), 0)
    }
}
