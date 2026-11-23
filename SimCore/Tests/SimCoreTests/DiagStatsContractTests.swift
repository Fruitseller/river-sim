import XCTest

@testable import SimCore
@testable import SimRender

final class DiagStatsContractTests: XCTestCase {
  private static let expectedLayout = [
    "DBG_MIN",
    "DBG_MEAN",
    "DBG_MAX",
    "DBG_RELIEF",
    "DBG_DELTA_MEAN",
    "DBG_DELTA_MAX",
    "DBG_BELOW_REFERENCE_VOLUME",
    "DBG_ABOVE_REFERENCE_VOLUME",
    "DBG_NET_VOLUME",
    "DBG_MAX_REMOVED",
    "DBG_MAX_ADDED",
    "DBG_SERVO",
    "DBG_UPLIFT",
    "DBG_RELIEF_TARGET",
    "DBG_REFERENCE_YEAR",
    "DBG_INVALID",
    "DBG_RELIEF_SIGNAL",
    "DBG_RIDGE_CURVATURE",
    "DBG_RELIEF_LOW",
  ]

  func testDiagnosticStatsLayoutMatchesTheGameIndexTable() throws {
    var config = SimConfig()
    config.n = 96
    config.world = calibrationWorld
    let stats = TerrainDiagnostics().stats(Terrain(config: config, seed: 1337))
    let main = try RepoSource.probe("game/scripts/Main.gd")
    let expected = Self.expectedLayout

    XCTAssertEqual(
      stats.count, expected.count,
      "Ausführbarer Diagnosepuffer und Vertragstabelle sind verschieden lang")

    let named = try main.pairs(pattern: "const (DBG_[A-Z0-9_]+) := ([0-9]+)")
    XCTAssertEqual(
      named.map(\.0), expected,
      "Die DBG_*-Konstanten in Main.gd stehen in anderer Reihenfolge")
    XCTAssertEqual(
      named.compactMap { Int($0.1) }, Array(0..<stats.count),
      "Die DBG_*-Indizes in Main.gd müssen lückenlos und doppelfrei sein")

    let declared = try main.integers(pattern: "const DEBUG_STATS_COUNT := ([0-9]+)")
    XCTAssertEqual(
      declared.count, 1,
      "DEBUG_STATS_COUNT in Main.gd nicht (oder mehrfach) gefunden")
    XCTAssertEqual(
      declared.first, stats.count,
      "TerrainDiagnostics.stats und DEBUG_STATS_COUNT weichen ab")
  }
}
