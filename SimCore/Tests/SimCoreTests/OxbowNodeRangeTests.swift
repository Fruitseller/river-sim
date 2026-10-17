import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter der EINEN Altarm-Knotenauswahl (`oxbowNodeRange`, Review zu #174 C).
/// Raster-Wasserfeld, Altarm-Bänder und Gürtel-Material müssen dieselben
/// Schleifen meinen; die Auswahl stand dreimal mit verschiedenen Wächtern.
final class OxbowNodeRangeTests: XCTestCase {

    /// Die drei alten Fassungen, wörtlich nachgebaut (Mindestlänge, Trimmung,
    /// dann je Leser ein anderer Wächter).
    private func legacy(count: Int, guardRange: (Int, Int) -> Bool) -> ClosedRange<Int>? {
        guard count >= WaterRender.oxbowMinimumNodes else { return nil }
        let trim = min(WaterRender.oxbowMaximumTrimmedNodes, max(1, count / 8))
        let first = trim, last = count - trim - 1
        guard guardRange(first, last) else { return nil }
        return first...last
    }

    /// Bit-gleiches Verhalten: für JEDE Knotenzahl dieselbe Auswahl wie die
    /// drei alten Wege, und die drei waren einander schon gleich.
    func testHelperMatchesAllThreeLegacySelections() {
        for count in 0...400 {
            let water = legacy(count: count) { first, last in first <= last }
            let ribbon = legacy(count: count) { first, last in last - first >= 2 }
            let bars = legacy(count: count) { first, last in last - first >= 2 }
            let shared = oxbowNodeRange(count: count)
            XCTAssertEqual(shared, water, "Wasserfeld, Knotenzahl \(count)")
            XCTAssertEqual(shared, ribbon, "Altarm-Bänder, Knotenzahl \(count)")
            XCTAssertEqual(shared, bars, "Gürtel-Material, Knotenzahl \(count)")
        }
    }

    func testRangeTrimsTheNeckEndsAndKeepsEnoughNodes() {
        XCTAssertNil(oxbowNodeRange(count: WaterRender.oxbowMinimumNodes - 1))
        XCTAssertNotNil(oxbowNodeRange(count: WaterRender.oxbowMinimumNodes))
        for count in WaterRender.oxbowMinimumNodes...300 {
            let range = oxbowNodeRange(count: count)!
            XCTAssertGreaterThanOrEqual(range.lowerBound, 1, "mindestens ein Knoten Hals getrimmt")
            XCTAssertLessThanOrEqual(range.lowerBound, WaterRender.oxbowMaximumTrimmedNodes)
            XCTAssertEqual(range.lowerBound, count - 1 - range.upperBound, "symmetrisch getrimmt")
            XCTAssertGreaterThanOrEqual(range.count, 3)
        }
    }

    /// Alle drei Leser benutzen den Helfer und tragen keine eigene Trimmung mehr.
    func testAllThreeReadersUseTheSharedSelection() throws {
        for file in ["WaterFieldRenderer", "RiverRibbonRenderer", "BarMaterial"] {
            let source = try RepoSource.probe("SimCore/Sources/SimRender/\(file).swift")
            XCTAssertTrue(source.contains("oxbowNodeRange(count:"), "\(file) liest die Auswahl nicht aus dem Helfer")
            XCTAssertFalse(source.contains("oxbowMaximumTrimmedNodes"), "\(file) trimmt selbst")
            XCTAssertFalse(source.contains("oxbowMinimumNodes"), "\(file) filtert selbst")
            XCTAssertFalse(source.contains("count / 8"), "\(file) rechnet die Trimmung selbst")
        }
    }
}
