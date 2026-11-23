import XCTest

@testable import SimRender

final class RenderByteTests: XCTestCase {

    private func legacyByte(_ value: Double) -> UInt8 {
        UInt8(min(max(value, 0), 1) * 255)
    }

    func testByte01MatchesTheClampedConversionForFiniteValues() {
        var values: [Double] = [-1e9, -1, -1e-12, 0, 1, 1 + 1e-12, 2, 1e9]
        for step in 0...2000 { values.append(Double(step) / 2000) }
        for value in values {
            XCTAssertEqual(byte01(value), legacyByte(value),
                           "byte01 weicht bei \(value) von der alten Klemme ab")
        }
    }

    func testTheClampDoesNotCatchNaNWhenTheValueComesFirst() {
        XCTAssertTrue(max(Double.nan, 0).isNaN, "max(NaN, 0) muss NaN bleiben")
        XCTAssertTrue(min(max(Double.nan, 0), 1).isNaN,
                      "die alte Klemme reichte NaN bis in UInt8(_:) durch")
        XCTAssertEqual(max(0, Double.nan), 0, "umgedreht wischt dieselbe Klemme NaN weg")
    }

    func testByte01IsTotalForNonFiniteValues() {
        XCTAssertEqual(byte01(Double.nan), 0)
        XCTAssertEqual(byte01(Double.infinity), 255)
        XCTAssertEqual(byte01(-Double.infinity), 0)
    }
}
