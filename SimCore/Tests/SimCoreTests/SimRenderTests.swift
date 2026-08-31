import XCTest

@testable import SimCore
@testable import SimRender

final class SimRenderTests: XCTestCase {
  func testTerrainMaterialsAreDeterministicPODBuffers() {
    let terrain = Terrain(config: renderConfig(), seed: 1337)

    let first = TerrainColorRenderer.buffers(terrain)
    let second = TerrainColorRenderer.buffers(terrain)

    XCTAssertEqual(first.colors.count, terrain.cfg.count * 4)
    XCTAssertEqual(first.surfaces.count, terrain.cfg.count * 4)
    XCTAssertEqual(first.colors, second.colors)
    XCTAssertEqual(first.surfaces, second.surfaces)
    XCTAssertTrue(
      stride(from: 3, to: first.colors.count, by: 4)
        .allSatisfy { first.colors[$0] == 255 },
      "RGBA-Farbpuffer muss vollständig opak sein")
  }

  func testTreeBuffersAreDeterministicAndHonorTheDirtyContract() {
    let terrain = Terrain(config: renderConfig(), seed: 1337)
    let renderer = TreeInstanceRenderer()

    XCTAssertEqual(renderer.maxDelta(terrain), 1)
    let first = renderer.buffer(terrain, variant: 0, hscale: 24, coverage: 2)
    let second = renderer.buffer(terrain, variant: 0, hscale: 24, coverage: 2)
    XCTAssertFalse(first.isEmpty, "Testwelt enthält keine Laubbäume")
    XCTAssertEqual(first.count % 12, 0)
    XCTAssertEqual(first, second)
    XCTAssertTrue(first.allSatisfy(\.isFinite))

    renderer.markBuilt(terrain)
    XCTAssertEqual(renderer.maxDelta(terrain), 0)
    renderer.invalidateSnapshot()
    XCTAssertEqual(renderer.maxDelta(terrain), 1)
  }

  func testDiagnosticStatsKeepTheirExecutableIndexContract() {
    let terrain = Terrain(config: renderConfig(), seed: 1337)
    let renderer = TerrainDiagnostics()
    renderer.capture(terrain)

    let stats = renderer.stats(terrain)
    let values = terrain.h.filter(\.isFinite)
    let sum = values.reduce(0, +)
    let halves = Terrain.landHeightQuantiles(heights: terrain.h, sea: terrain.cfg.sea)

    XCTAssertEqual(stats.count, 19)
    XCTAssertEqual(stats[0], Float(values.min()!))
    XCTAssertEqual(stats[1], Float(sum / Double(values.count)))
    XCTAssertEqual(stats[2], Float(values.max()!))
    XCTAssertEqual(stats[3], Float(terrain.landRelief()))
    for index in 4...10 {
      XCTAssertEqual(stats[index], 0, "Referenz-Differenz an Index \(index)")
    }
    XCTAssertEqual(stats[11], Float(terrain.reliefServoRate(reliefSignal: halves.high)))
    XCTAssertEqual(stats[12], Float(terrain.upliftDecayRatePer100y()))
    XCTAssertEqual(stats[13], Float(terrain.cfg.reliefTarget))
    XCTAssertEqual(stats[14], Float(terrain.years))
    XCTAssertEqual(stats[15], 0)
    XCTAssertEqual(stats[16], Float(halves.high))
    XCTAssertEqual(stats[17], Float(terrain.ridgeCurvature()))
    XCTAssertEqual(stats[18], Float(halves.low))

    let difference = renderer.differenceBytes(terrain, scale: 0.01)
    XCTAssertEqual(difference.count, terrain.cfg.count * 4)
    XCTAssertTrue(
      stride(from: 0, to: difference.count, by: 4).allSatisfy {
        Array(difference[$0...($0 + 3)]) == [198, 198, 198, 255]
      })
  }
}
