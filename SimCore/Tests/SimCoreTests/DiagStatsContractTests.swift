import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter für den DIAGNOSE-Vertrag zwischen GDExtension und Game-Layer.
///
/// Über die Brücke geht ein namenloser `PackedFloat32Array`
/// (`SimNode.debugTerrainStats` → `TerrainDiagnostics.stats`). Was an welchem
/// Index steht, ist Konvention — und sie steht zwangsläufig doppelt: als
/// ausführbarer `[Float]`-Puffer in `SimRender` und als `DBG_*`-Indizes plus
/// `DEBUG_STATS_COUNT` in `Main.gd`. Der Renderer wird hier direkt ausgeführt;
/// nur die GDScript-Tabelle bleibt ein Quelltext-Vertrag.
///
/// Was der Test verhindert: einen Wert im Renderer anhängen, einfügen,
/// entfernen oder UMSTELLEN, ohne `Main.gd` mitzuziehen. Die semantische
/// Belegung der ausführbaren Indizes prüft `SimRenderTests`.
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
    let main = try RepoSource.file("game/scripts/Main.gd")
    let expected = Self.expectedLayout

    XCTAssertEqual(
      stats.count, expected.count,
      "Ausführbarer Diagnosepuffer und Vertragstabelle sind verschieden lang")

    let named = try pairs(in: main, pattern: "const (DBG_[A-Z0-9_]+) := ([0-9]+)")
    XCTAssertEqual(
      named.map(\.0), expected,
      "Die DBG_*-Konstanten in Main.gd stehen in anderer Reihenfolge")
    XCTAssertEqual(
      named.compactMap { Int($0.1) }, Array(0..<stats.count),
      "Die DBG_*-Indizes in Main.gd müssen lückenlos und doppelfrei sein")

    let declared = try integers(in: main, pattern: "const DEBUG_STATS_COUNT := ([0-9]+)")
    XCTAssertEqual(
      declared.count, 1,
      "DEBUG_STATS_COUNT in Main.gd nicht (oder mehrfach) gefunden")
    XCTAssertEqual(
      declared.first, stats.count,
      "TerrainDiagnostics.stats und DEBUG_STATS_COUNT weichen ab")
  }
}
