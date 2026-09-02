import XCTest

@testable import SimCore
@testable import SimRender

final class WaterRendererTests: XCTestCase {
  private func agedTerrain(years: Double, productionGrid: Bool = false) -> Terrain {
    var config = SimConfig()
    if !productionGrid {
      config.n = 192
      config.world = calibrationWorld
    }
    let terrain = Terrain(config: config, seed: 1337)
    while terrain.years < years {
      terrain.step(dtYears: min(1000, years - terrain.years))
    }
    terrain.computeFlow()
    return terrain
  }

  func testRibbonMeshIsPODDeterministicAndPhysicsNeutral() {
    let terrain = agedTerrain(years: 4000)
    let renderer = RiverRibbonRenderer()
    let heights = terrain.h

    XCTAssertGreaterThan(renderer.maxDelta(terrain), 1)
    let first: RibbonMesh = renderer.build(terrain, hscale: 24, lift: 0.35)
    XCTAssertEqual(terrain.h, heights)
    XCTAssertFalse(first.vertices.isEmpty, "Testwelt emittiert keine Flussbänder")
    XCTAssertEqual(first.colors.count, first.vertices.count)
    XCTAssertEqual(first.uvs.count, first.vertices.count)
    XCTAssertEqual(first.uv2s.count, first.vertices.count)
    XCTAssertEqual(first.indices.count % 3, 0)
    XCTAssertLessThan(first.indices.max()!, Int32(first.vertices.count))
    let _: SIMD3<Float> = first.vertices[0]
    let _: SIMD4<Float> = first.colors[0]
    let _: SIMD2<Float> = first.uvs[0]

    var minimumWidth = Float.greatestFiniteMagnitude
    var maximumWidth: Float = 0
    var riverStrips = 0
    var maximumLandAlphaJump: Float = 0
    for strip in first.stripStarts.indices {
      let start = Int(first.stripStarts[strip])
      let end =
        strip + 1 < first.stripStarts.count
        ? Int(first.stripStarts[strip + 1]) : first.vertices.count
      guard first.uv2s[start].x < Float(WaterRender.ribbonDeltaLo) else { continue }
      riverStrips += 1
      var maximumRank: Float = 0
      var previousLandAlpha: Float?
      for vertex in stride(from: start, to: end, by: 2) {
        let left = first.vertices[vertex]
        let right = first.vertices[vertex + 1]
        let dx = left.x - right.x
        let dz = left.z - right.z
        let width = (dx * dx + dz * dz).squareRoot()
        minimumWidth = min(minimumWidth, width)
        maximumWidth = max(maximumWidth, width)
        maximumRank = max(maximumRank, first.colors[vertex].z)
        let middle = (left + right) * 0.5
        let half = terrain.cfg.world * 0.5
        let cellSize = terrain.cfg.cellSize
        let centerX = (Double(middle.x) + half) / cellSize
        let centerZ = (Double(middle.z) + half) / cellSize
        let leftX = (Double(left.x) + half) / cellSize
        let leftZ = (Double(left.z) + half) / cellSize
        let rightX = (Double(right.x) + half) / cellSize
        let rightZ = (Double(right.z) + half) / cellSize
        let centerHeight = bilinear(terrain.h, centerX, centerZ, n: terrain.cfg.n) * 24
        let crossTolerance = Double(width) * 0.5 * WaterRender.ribbonMaxCrossSlope
        let expectedLeft =
          min(
            max(
              bilinear(terrain.h, leftX, leftZ, n: terrain.cfg.n) * 24,
              centerHeight - crossTolerance),
            centerHeight + crossTolerance) + 0.35
        let expectedRight =
          min(
            max(
              bilinear(terrain.h, rightX, rightZ, n: terrain.cfg.n) * 24,
              centerHeight - crossTolerance),
            centerHeight + crossTolerance) + 0.35
        let landError = max(
          abs(Double(left.y) - expectedLeft),
          abs(Double(right.y) - expectedRight))
        let waterError = waterSurfaceError(
          terrain, gridX: centerX, gridZ: centerZ, renderedY: Double(left.y))
        XCTAssertLessThanOrEqual(
          min(landError, waterError), 0.002,
          "Bandkante liegt weder auf Gelände noch Wasserspiegel")
        if waterError <= 0.05 {
          previousLandAlpha = nil
        } else {
          if let previousLandAlpha {
            maximumLandAlphaJump = max(
              maximumLandAlphaJump,
              abs(first.colors[vertex].w - previousLandAlpha))
          }
          previousLandAlpha = first.colors[vertex].w
        }
      }
      XCTAssertGreaterThanOrEqual(
        maximumRank, Float(WaterRender.ribbonMinimumRank),
        "Band ohne Strahler-3-Anschluss")
    }
    XCTAssertGreaterThan(riverStrips, 0)
    XCTAssertGreaterThan(
      maximumWidth / max(minimumWidth, 1e-6), 1.5,
      "Bandbreite folgt dem Abfluss nicht")
    XCTAssertLessThanOrEqual(
      maximumLandAlphaJump, 0.40,
      "Segmentierte Alpha-Spitze im Land-Abschnitt eines Bands")

    let second = renderer.build(terrain, hscale: 24, lift: 0.35)
    XCTAssertEqual(first, second)
    renderer.markBuilt(terrain)
    XCTAssertEqual(renderer.maxDelta(terrain), 0)
    terrain.step(dtYears: 1000)
    XCTAssertGreaterThan(
      renderer.maxDelta(terrain), 0,
      "Mäander-Migration löst keinen Rebuild aus")
  }

  func testBuiltBandsAndRasterHandOverWithoutGapOrDoubleWater() {
    let terrain = agedTerrain(years: 30_000, productionGrid: true)
    let ribbons = RiverRibbonRenderer()
    let mesh = ribbons.build(terrain, hscale: 24, lift: 0.35)
    XCTAssertFalse(mesh.stripStarts.isEmpty, "Testwelt emittiert keine Bänder")
    XCTAssertTrue(
      mesh.bandChannelFlags.contains(true),
      "Kein Kanal hat das Band-Gate passiert")
    XCTAssertEqual(mesh.bandCoverage.count, terrain.cfg.count)
    XCTAssertTrue(mesh.bandCoverage.allSatisfy { $0 >= 0 && $0 <= 1 })
    XCTAssertTrue(
      mesh.bandCoverage.contains { $0 > 0 },
      "Gebautes RibbonMesh meldet keine gemalte Deckung")

    var deepestRiverAlpha: Float = 0
    var mouthGaps = 0
    var riverCount = 0
    var deltaCount = 0
    var oxbowCount = 0
    var oxbowMaximumAlpha: Float = 0
    for strip in mesh.stripStarts.indices {
      let start = Int(mesh.stripStarts[strip])
      let end =
        strip + 1 < mesh.stripStarts.count
        ? Int(mesh.stripStarts[strip + 1]) : mesh.vertices.count
      let kind = mesh.uv2s[start].x
      switch kind {
      case Float(WaterRender.ribbonKindRiver):
        riverCount += 1
      case Float(WaterRender.ribbonKindDelta):
        deltaCount += 1
      case Float(WaterRender.ribbonKindOxbow):
        oxbowCount += 1
        for vertex in stride(from: start, to: end, by: 2) {
          XCTAssertEqual(mesh.colors[vertex].x, 0.5, accuracy: 0.002)
          XCTAssertEqual(mesh.colors[vertex].y, 0.5, accuracy: 0.002)
          oxbowMaximumAlpha = max(oxbowMaximumAlpha, mesh.colors[vertex].w)
        }
      default:
        XCTFail("Unbekannter Bandtyp \(kind)")
      }
      guard mesh.uv2s[start].x == Float(WaterRender.ribbonKindRiver) else { continue }

      for vertex in stride(from: start, to: end, by: 2) {
        let cell = cellIndex(mesh.vertices[vertex], mesh.vertices[vertex + 1], terrain)
        if pondDepth(terrain, cell) >= WaterRender.lakeRawWetDepth {
          deepestRiverAlpha = max(deepestRiverAlpha, mesh.colors[vertex].w)
        }
      }

      let last = end - 2
      var cell = cellIndex(mesh.vertices[last], mesh.vertices[last + 1], terrain)
      if pondDepth(terrain, cell) > WaterRender.pondContourLo { continue }
      for _ in 0..<WaterRender.mouthSearchCells {
        let receiver = terrain.receiver[cell]
        if receiver < 0 { break }
        cell = Int(receiver)
        if pondDepth(terrain, cell) > WaterRender.pondContourLo {
          mouthGaps += 1
          break
        }
      }
    }
    XCTAssertGreaterThan(riverCount, 0)
    XCTAssertGreaterThan(deltaCount, 0, "Testwelt emittiert keine Delta-Arme")
    XCTAssertGreaterThan(oxbowCount, 0, "Testwelt emittiert keine Altarme")
    XCTAssertLessThanOrEqual(
      oxbowMaximumAlpha,
      Float(WaterRender.oxbowMaximumOpacity + 0.001))
    XCTAssertLessThanOrEqual(
      deepestRiverAlpha, 0.02,
      "Band und Raster malen tiefes Wasser doppelt")
    XCTAssertEqual(mouthGaps, 0, "Flussband endet vor erreichbarem Wasser")

    let field = WaterFieldRenderer()
    let coupled = field.bytes(
      terrain, blend: 1, geometryMode: true,
      bandChannelFlags: mesh.bandChannelFlags,
      bandCoverage: mesh.bandCoverage)
    XCTAssertEqual(coupled.count, terrain.cfg.count * 4)
    let uncoupled = WaterFieldRenderer().bytes(
      terrain, blend: 1, geometryMode: true,
      bandChannelFlags: [], bandCoverage: [])
    XCTAssertNotEqual(
      coupled, uncoupled,
      "Wasserfeld ignoriert das echte Band-Bauergebnis")
  }

  private func cellIndex(
    _ left: SIMD3<Float>, _ right: SIMD3<Float>,
    _ terrain: Terrain
  ) -> Int {
    let middle = (left + right) * 0.5
    let cellSize = terrain.cfg.cellSize
    let half = terrain.cfg.world * 0.5
    let i = min(
      max(Int(((Double(middle.x) + half) / cellSize).rounded()), 0),
      terrain.cfg.n - 1)
    let j = min(
      max(Int(((Double(middle.z) + half) / cellSize).rounded()), 0),
      terrain.cfg.n - 1)
    return j * terrain.cfg.n + i
  }

  private func waterSurfaceError(
    _ terrain: Terrain, gridX: Double, gridZ: Double, renderedY: Double
  ) -> Double {
    var best = abs(
      renderedY
        - (terrain.cfg.sea * 24 + WaterRender.ribbonSeaSurfaceSink))
    for i in cellCandidates(gridX, n: terrain.cfg.n) {
      for j in cellCandidates(gridZ, n: terrain.cfg.n) {
        let expected =
          terrain.waterLevel[j * terrain.cfg.n + i] * 24
          + WaterRender.ribbonLakeSurfaceLift
        best = min(best, abs(renderedY - expected))
      }
    }
    return best
  }

  private func cellCandidates(_ coordinate: Double, n: Int) -> [Int] {
    let base = min(max(Int(coordinate.rounded()), 0), n - 1)
    var candidates = [base]
    let fraction = coordinate - floor(coordinate)
    if abs(fraction - 0.5) < 0.001 {
      candidates.append(min(max(base + (fraction >= 0.5 ? -1 : 1), 0), n - 1))
    }
    return candidates
  }

  private func bilinear(_ field: [Double], _ x: Double, _ z: Double, n: Int) -> Double {
    let clampedX = min(max(x, 0), Double(n - 1))
    let clampedZ = min(max(z, 0), Double(n - 1))
    let i0 = min(Int(clampedX), n - 2)
    let j0 = min(Int(clampedZ), n - 2)
    let fx = clampedX - Double(i0)
    let fz = clampedZ - Double(j0)
    let index = j0 * n + i0
    return field[index] * (1 - fx) * (1 - fz)
      + field[index + 1] * fx * (1 - fz)
      + field[index + n] * (1 - fx) * fz
      + field[index + n + 1] * fx * fz
  }

  private func pondDepth(_ terrain: Terrain, _ index: Int) -> Double {
    if terrain.h[index] <= terrain.cfg.sea {
      return terrain.cfg.sea - terrain.h[index]
    }
    if terrain.waterLevel[index] > terrain.cfg.sea {
      return terrain.waterLevel[index] - terrain.h[index]
    }
    return 0
  }

  /// Abfluss-Feld fürs Shader-Detail (PR #106): die kosmetischen Rinnen des
  /// Terrain-Shaders bündeln sich in ECHTEN Abflussbahnen; ohne die Bindung
  /// degenerierte der Layer auf der gealterten Welt zu einem uniformen
  /// Tapeten-Muster. Hier das Kalibrier-Verhalten plus die Feld-Eigenschaften.
  func testFlowDetailFieldFollowsRealDischarge() {
    let creek = SimConfig().renderMinCells
    let floor = WaterRender.flowDetailFloorCells
    // 0 unter dem Floor (Einzelzellen-Abfluss ist Rauschen) …
    XCTAssertEqual(WaterRender.flowDetailIntensity(dischargeCells: 0, creekCells: creek), 0)
    XCTAssertEqual(WaterRender.flowDetailIntensity(dischargeCells: floor, creekCells: creek), 0)
    // … monoton dazwischen …
    let mid = WaterRender.flowDetailIntensity(dischargeCells: 30, creekCells: creek)
    XCTAssertGreaterThan(mid, 0)
    XCTAssertLessThan(mid, WaterRender.flowDetailIntensity(dischargeCells: 100, creekCells: creek))
    // … und gesättigt ab der Render-Schwelle (dort malt das sichtbare Wasser).
    XCTAssertEqual(WaterRender.flowDetailIntensity(dischargeCells: creek, creekCells: creek), 1)
    XCTAssertEqual(WaterRender.flowDetailIntensity(dischargeCells: creek * 50, creekCells: creek), 1)

    let terrain = agedTerrain(years: 4000)
    let renderer = WaterFieldRenderer()
    let heights = terrain.h
    let field = renderer.flowDetailField(terrain)
    XCTAssertEqual(terrain.h, heights, "Render-Ableitung ändert die Physik nicht")
    XCTAssertEqual(field.count, terrain.cfg.count)
    var seaNonZero = 0
    var levels = Set<UInt8>()
    for k in 0..<field.count {
      if terrain.h[k] <= terrain.cfg.sea, field[k] != 0 { seaNonZero += 1 }
      levels.insert(field[k])
    }
    XCTAssertEqual(seaNonZero, 0, "Meer-Zellen tragen kein Detail-Gewicht")
    XCTAssertGreaterThan(levels.count, 8,
                         "Feld trägt eine Abfluss-HIERARCHIE, keine Binär-Maske")
    XCTAssertEqual(field, renderer.flowDetailField(terrain), "deterministisch pro Zustand")
  }
}
