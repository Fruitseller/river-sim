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
    return agedWorld(config, years: years)
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
    // Schranke 0.045 (Issue #108): die beiden Regeln der Übergabe lesen die
    // Wassersäule unterschiedlich — der Raster-Pfad ZELLWEISE (`rawWet[k]`,
    // Schwelle `lakeRawWetDepth`), der Band-Fade BILINEAR am Stützpunkt
    // (`lakeHandoverFade`, bewusst so: nearest-cell sprang an den Zellkanten um
    // bis zu 0.5 Deckkraft, s. Kommentar dort). An der Uferkante weichen sie
    // deshalb um einen Rest voneinander ab, und genau den deckelt diese Zahl.
    // Mit den tieferen Betten aus #108 ist der Pond-Gradient über eine Zelle
    // steiler und der Rest wuchs von ≤ 0.02 auf gemessen 0.024..0.032 — ein einzelner
    // Stützpunkt mit ~3 % Deckkraft, kein doppeltes Wasser. Die Obergrenze 0.045
    // deckelt diesen Übergangs-Rest mit Sicherheitsabstand (wie ein ECHTER Bruch
    // aussieht, ist in derselben Runde gemessen: der nicht ausgelieferte
    // Pfützen-Ausschluss in Flussbetten ließ stehendes Wasser im Bett stehen und
    // trieb diesen Wert auf 0.243). Weniger Rest-Deckkraft ist zulässig.
    // Die Bett-Inzision prüft ChannelIncision getrennt über die Terrain-Höhen.
    XCTAssertLessThanOrEqual(
      deepestRiverAlpha, 0.045,
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

  /// Prüft, dass `WaterFieldRenderer.bytes` deterministisch auswertet — sowohl
  /// für den normalen EWMA-Pfad, den ungefilterten Pfad (`deferTail: true`) als
  /// auch den Legacy-Stempelmodus (`geometryMode: false`), und pinnt den Inhalt
  /// über eine Gegenprobe (Normal vs. deferTail sowie sequenzielle Referenz).
  func testWaterFieldBytesIsDeterministicAndSupportsDeferTail() {
    let terrain = agedTerrain(years: 4000)
    let renderer = WaterFieldRenderer()
    let heights = terrain.h

    let normalFirst = renderer.bytes(
      terrain, blend: 1.0, geometryMode: true,
      bandChannelFlags: [], bandCoverage: [])
    XCTAssertEqual(normalFirst.count, terrain.cfg.count * 4)
    XCTAssertEqual(terrain.h, heights, "Render-Aufbereitung darf Terrain nicht verändern")

    let normalSecond = renderer.bytes(
      terrain, blend: 1.0, geometryMode: true,
      bandChannelFlags: [], bandCoverage: [])
    XCTAssertEqual(normalFirst, normalSecond, "Normaler Pfad muss bit-deterministisch sein")

    let deferred = renderer.bytes(
      terrain, blend: 1.0, geometryMode: true,
      bandChannelFlags: [], bandCoverage: [], deferTail: true)
    XCTAssertEqual(deferred.count, terrain.cfg.count * 4)
    XCTAssertEqual(
      deferred,
      renderer.bytes(
        terrain, blend: 1.0, geometryMode: true,
        bandChannelFlags: [], bandCoverage: [], deferTail: true),
      "deferTail-Pfad muss deterministisch sein")

    // Finding 1: Abdeckungslücke für den Legacy-Pfad (geometryMode == false) schließen.
    // Genau diese Schleife (u. a. Altarm-Overlay) wurde parallelisiert und muss
    // bit-deterministisch sein.
    let legacyFirst = renderer.bytes(
      terrain, blend: 1.0, geometryMode: false,
      bandChannelFlags: [], bandCoverage: [])
    XCTAssertEqual(legacyFirst.count, terrain.cfg.count * 4)

    let legacySecond = renderer.bytes(
      terrain, blend: 1.0, geometryMode: false,
      bandChannelFlags: [], bandCoverage: [])
    XCTAssertEqual(legacyFirst, legacySecond, "Legacy-Pfad (geometryMode: false) muss bit-deterministisch sein")

    // Finding 2: Gegenprobe auf Inhalt — Regressionen der Parallelisierung
    // (z. B. fehlerhafte Chunk-Grenzen, doppelt oder gar nicht geschriebene Zellen)
    // pinnen, anstatt nur Doppel-Läufe gegen sich selbst zu vergleichen.
    //
    // 1. Normal- vs deferTail-Pfad:
    //    - Die Richtungsvektoren (Kanäle 2 & 3) werden bei blend == 1.0 weder durch EWMA
    //      noch durch Blur verändert und müssen an jeder Zelle bit-identisch sein.
    //    - Der Normal-Pfad wendet blurMax auf Fluss (Kanal 0) und See (Kanal 1) an;
    //      dadurch muss an jeder Zelle normal >= deferred gelten.
    //    - Durch die Weichzeichnung müssen an den Gewässerrändern Zellen existieren,
    //      an denen der Normal-Pfad echt größer als der ungefilterte Pfad ist.
    XCTAssertNotEqual(
      normalFirst, deferred,
      "deferTail-Pfad (ungefiltert) muss sich vom normalen Pfad (geblurrt) unterscheiden")

    var firstMismatch: String?
    var blurExpandedRiver = false
    var blurExpandedLake = false
    var nonZeroRiver = false
    var nonZeroLake = false
    var hasNonTrivialFlow = false
    var verifiedDryCells = 0
    var verifiedNonTrivialDrainage = 0

    let n = terrain.cfg.n
    for k in 0..<terrain.cfg.count {
      let o = k * 4
      let normRiver = normalFirst[o]
      let defRiver = deferred[o]
      let normLake = normalFirst[o + 1]
      let defLake = deferred[o + 1]
      let normDx = normalFirst[o + 2]
      let defDx = deferred[o + 2]
      let normDz = normalFirst[o + 3]
      let defDz = deferred[o + 3]

      if normRiver > 0 { nonZeroRiver = true }
      if normLake > 0 { nonZeroLake = true }
      if defDx != 127 || defDz != 127 { hasNonTrivialFlow = true }

      if normDx != defDx || normDz != defDz {
        firstMismatch = "Strömungsvektoren ungleich an Zelle \(k): norm=(\(normDx),\(normDz)) def=(\(defDx),\(defDz))"
        break
      }
      if normRiver < defRiver {
        firstMismatch = "Fluss-Intensität verringert an Zelle \(k): norm=\(normRiver) def=\(defRiver)"
        break
      }
      if normLake < defLake {
        firstMismatch = "See-Intensität verringert an Zelle \(k): norm=\(normLake) def=\(defLake)"
        break
      }

      if normRiver > defRiver { blurExpandedRiver = true }
      if normLake > defLake { blurExpandedLake = true }

      // 2. Sequenzielle Referenzschleife: Wo kein Wasser vorliegt (Fluss == 0 und See == 0),
      //    ist kein Stempel aktiv (mstamp == false). Hier muss die gepackte Richtung exakt
      //    der D8-Nachbardifferenz zu terrain.receiver entsprechen.
      if defRiver == 0 && defLake == 0 {
        let r = terrain.receiver[k]
        let expectedDx = r >= 0 ? Double(Int(r) % n - k % n) : 0.0
        let expectedDz = r >= 0 ? Double(Int(r) / n - k / n) : 0.0
        let expectedByteX = byte01(min(1, max(-1, expectedDx)) * 0.5 + 0.5)
        let expectedByteZ = byte01(min(1, max(-1, expectedDz)) * 0.5 + 0.5)
        if defDx != expectedByteX || defDz != expectedByteZ {
          firstMismatch = "Strömungsrichtung an Zelle \(k) weicht von Referenz ab: def=(\(defDx),\(defDz)) exp=(\(expectedByteX),\(expectedByteZ))"
          break
        }
        verifiedDryCells += 1
        if expectedByteX != 127 || expectedByteZ != 127 {
          verifiedNonTrivialDrainage += 1
        }
      }
    }

    XCTAssertNil(firstMismatch, firstMismatch ?? "")
    XCTAssertTrue(nonZeroRiver, "Feld muss Flusszellen mit Intensität > 0 enthalten")
    XCTAssertTrue(hasNonTrivialFlow, "Strömungsvektoren müssen echte Flussrichtungen enthalten")
    XCTAssertTrue(blurExpandedRiver, "Normal-Pfad muss Flussränder durch Blur aufgeweitet haben")
    if nonZeroLake {
      XCTAssertTrue(blurExpandedLake, "Normal-Pfad muss Seeränder durch Blur aufgeweitet haben")
    }
    XCTAssertGreaterThan(verifiedDryCells, 1000, "Zu wenige trockene Zellen für Referenzvergleich gefunden")
    XCTAssertGreaterThan(verifiedNonTrivialDrainage, 100, "Referenzvergleich muss echte Gefällerichtungen im Trockenen prüfen")
  }

  func testRiverRibbonRendererHandlesEmptyTerrain() {
    let config = renderConfig(n: 0)
    let empty = Terrain(allocating: config, seed: 1337)
    let renderer = RiverRibbonRenderer()
    let mesh = renderer.build(empty, hscale: 24, lift: 0.35)
    XCTAssertTrue(mesh.vertices.isEmpty, "Leeres Terrain darf keine Vertices emittieren")
    XCTAssertTrue(mesh.colors.isEmpty)
    XCTAssertTrue(mesh.uvs.isEmpty)
    XCTAssertTrue(mesh.uv2s.isEmpty)
    XCTAssertTrue(mesh.indices.isEmpty)
    XCTAssertTrue(mesh.stripStarts.isEmpty)
    XCTAssertTrue(mesh.bandChannelFlags.isEmpty)
    XCTAssertTrue(mesh.bandCoverage.isEmpty)
    XCTAssertEqual(renderer.maxDelta(empty), 1e9)
    XCTAssertTrue(mouthPath(empty, fromX: 0, fromZ: 0).isEmpty)

    // Auch über RenderState absichern
    let render = RenderState(geometryMode: true)
    render.buildRiverRibbons(empty, hscale: 24, lift: 0.35)
    XCTAssertTrue(render.riverRibbonMesh.vertices.isEmpty)
    XCTAssertTrue(render.riverRibbonMesh.bandCoverage.isEmpty)
  }

  func testBilinearGridAndRenderSurfaceHeightHandleEmptyAndNonFiniteInputs() {
    let emptyField: [Double] = []
    XCTAssertEqual(bilinearGrid(emptyField, 0, 0, n: 0), 0)
    XCTAssertEqual(bilinearGrid(emptyField, 0, 0, n: 1), 0)
    XCTAssertEqual(bilinearGrid(emptyField, 0, 0, n: 2), 0)
    XCTAssertEqual(renderSurfaceHeight(emptyField, 0, 0, n: 0, renderGrid: 0), 0)
    XCTAssertEqual(renderSurfaceHeight(emptyField, 0, 0, n: 2, renderGrid: 2), 0)

    let singleField = [42.0]
    XCTAssertEqual(bilinearGrid(singleField, 0, 0, n: 1), 42.0)

    // 2x2-Gitter: [10, 20, 30, 40]
    let field = [10.0, 20.0, 30.0, 40.0]
    // Mitte (0.5, 0.5) -> Bilinear-Mittelwert 25.0
    XCTAssertEqual(bilinearGrid(field, 0.5, 0.5, n: 2), 25.0)
    XCTAssertEqual(renderSurfaceHeight(field, 0.5, 0.5, n: 2, renderGrid: 2), 25.0)

    let badInputs = [Double.nan, Double.infinity, -Double.infinity, 1e300, -1e300]
    for bad in badInputs {
      XCTAssertEqual(bilinearGrid(field, bad, 0.5, n: 2), 0)
      XCTAssertEqual(bilinearGrid(field, 0.5, bad, n: 2), 0)
      XCTAssertEqual(renderSurfaceHeight(field, bad, 0.5, n: 2, renderGrid: 2), 0)
      XCTAssertEqual(renderSurfaceHeight(field, 0.5, bad, n: 2, renderGrid: 2), 0)
    }
  }

  func testMouthPathAndOpenWaterSurfaceHandleNonFiniteAndOutOfBoundsInputs() {
    let badInputs = [Double.nan, Double.infinity, -Double.infinity, 1e300, -1e300]
    let terrain = Terrain(allocating: renderConfig(n: 16), seed: 1337)
    for bad in badInputs {
      XCTAssertTrue(mouthPath(terrain, fromX: bad, fromZ: 5).isEmpty)
      XCTAssertTrue(mouthPath(terrain, fromX: 5, fromZ: bad).isEmpty)
    }

    // Ungültiger Empfängerindex außerhalb des Gitters
    terrain.setReceiverForTests(at: 0, to: 999_999)
    XCTAssertTrue(mouthPath(terrain, fromX: 0, fromZ: 0).isEmpty)
    terrain.setReceiverForTests(at: 0, to: -5)
    XCTAssertTrue(mouthPath(terrain, fromX: 0, fromZ: 0).isEmpty)

    // openWaterSurface mit ungültigen Indizes
    XCTAssertNil(openWaterSurface(-1, h: terrain.h, wl: terrain.waterLevel, sea: terrain.cfg.sea))
    XCTAssertNil(openWaterSurface(terrain.h.count + 10, h: terrain.h, wl: terrain.waterLevel, sea: terrain.cfg.sea))
  }

  func testRiverRibbonRendererHandlesBufferMismatchAndCorruptedNodes() {
    let renderer = RiverRibbonRenderer()

    // 1. Puffergrößen-Mismatch liefert defensiv leeres Mesh statt OOB-Crash
    let baseTerrain = Terrain(allocating: renderConfig(n: 16), seed: 1337)
    var mismatchState = baseTerrain.state
    mismatchState.h = [1.0, 2.0]
    let mismatchTerrain = Terrain(allocating: renderConfig(n: 16), seed: 1337)
    mismatchTerrain.restore(mismatchState)
    let meshH = renderer.build(mismatchTerrain, hscale: 24, lift: 0.35)
    XCTAssertTrue(meshH.vertices.isEmpty, "Mismatch in h muss leeres Mesh liefern")
    XCTAssertTrue(meshH.bandCoverage.isEmpty)

    var mismatchWlState = baseTerrain.state
    mismatchWlState.waterLevel = []
    let mismatchWlTerrain = Terrain(allocating: renderConfig(n: 16), seed: 1337)
    mismatchWlTerrain.restore(mismatchWlState)
    let meshWl = renderer.build(mismatchWlTerrain, hscale: 24, lift: 0.35)
    XCTAssertTrue(meshWl.vertices.isEmpty, "Mismatch in waterLevel muss leeres Mesh liefern")
    XCTAssertTrue(meshWl.bandCoverage.isEmpty)

    // 2. Kanäle mit nicht-endlichen Koordinaten (NaN, ±inf) überspringen statt Int-Cast-Trap
    let nanTerrain = Terrain(allocating: renderConfig(n: 16), seed: 1337)
    let badChannel = RiverChannel(
      nodes: [MeanderNode(x: Double.nan, z: 0), MeanderNode(x: 10, z: 10)],
      discharge: [100.0, 100.0]
    )
    nanTerrain.meander.channels = [badChannel]
    let nanMesh = renderer.build(nanTerrain, hscale: 24, lift: 0.35)
    XCTAssertTrue(nanMesh.vertices.isEmpty, "Kanal mit NaN-Knoten muss sicher übersprungen werden")

    // 3. Altarme mit nicht-endlichen Koordinaten überspringen
    let oxbowTerrain = Terrain(allocating: renderConfig(n: 16), seed: 1337)
    var oxbowNodes = (0..<24).map { MeanderNode(x: Double($0 % 16), z: Double($0 % 16)) }
    oxbowNodes[5] = MeanderNode(x: Double.infinity, z: 0)
    oxbowTerrain.meander.oxbows = [oxbowNodes]
    oxbowTerrain.meander.oxbowAge = [10.0]
    let oxbowMesh = renderer.build(oxbowTerrain, hscale: 24, lift: 0.35)
    XCTAssertTrue(oxbowMesh.vertices.isEmpty, "Altarm mit inf-Knoten darf nicht trappen")
  }

  func testWaterFieldRendererHandlesReceiverOutOfBoundsAndCorruptedNodes() {
    let renderer = WaterFieldRenderer()

    // 1. Ungültige Empfängerindizes außerhalb des Gitters (r >= cnt oder r < 0)
    let testTerrain = Terrain(allocating: renderConfig(n: 16), seed: 1337)
    var state = testTerrain.state
    state.streamMap = [Double](repeating: 0.5, count: 16 * 16)
    state.areaMFD = [Double](repeating: 10_000.0, count: 16 * 16)
    state.h = [Double](repeating: 0.5, count: 16 * 16)
    state.waterLevel = [Double](repeating: 0.5, count: 16 * 16)
    state.receiver = [Int32](repeating: 999_999, count: 16 * 16)
    testTerrain.restore(state)

    let bytesNormal = renderer.bytes(
      testTerrain, blend: 1.0, geometryMode: true,
      bandChannelFlags: [], bandCoverage: [])
    XCTAssertEqual(bytesNormal.count, 16 * 16 * 4)

    let bytesDeferred = renderer.bytes(
      testTerrain, blend: 1.0, geometryMode: true,
      bandChannelFlags: [], bandCoverage: [], deferTail: true)
    XCTAssertEqual(bytesDeferred.count, 16 * 16 * 4)

    state.receiver = [Int32](repeating: -5, count: 16 * 16)
    testTerrain.restore(state)
    let bytesNeg = renderer.bytes(
      testTerrain, blend: 1.0, geometryMode: true,
      bandChannelFlags: [], bandCoverage: [])
    XCTAssertEqual(bytesNeg.count, 16 * 16 * 4)
    XCTAssertEqual(
      bytesNormal, bytesNeg,
      "Empfänger außerhalb des Gitters müssen neutral wie negative Empfänger behandelt werden")
    XCTAssertEqual(bytesNormal[2], 127, "Neutraler X-Flussrichtungs-Kanal")
    XCTAssertEqual(bytesNormal[3], 127, "Neutraler Z-Flussrichtungs-Kanal")

    // 2. Kanäle mit nicht-endlichen Koordinaten (NaN, ±inf) überspringen statt Int-Cast-Trap
    let nanTerrain = Terrain(allocating: renderConfig(n: 16), seed: 1337)
    let badChannel = RiverChannel(
      nodes: [MeanderNode(x: Double.nan, z: 0), MeanderNode(x: 10, z: 10)],
      discharge: [500.0, 500.0]
    )
    nanTerrain.meander.channels = [badChannel]
    let bytesNan = WaterFieldRenderer().bytes(
      nanTerrain, blend: 1.0, geometryMode: false,
      bandChannelFlags: [], bandCoverage: [])
    XCTAssertEqual(bytesNan.count, nanTerrain.cfg.count * 4)

    // Byteweiser Vergleich gegen Terrain ohne Kanäle: zeigt, dass der korrupte Kanal
    // nachweislich übersprungen und nicht (z. B. geklemmt) gestempelt wurde.
    let cleanTerrain = Terrain(allocating: renderConfig(n: 16), seed: 1337)
    let bytesClean = WaterFieldRenderer().bytes(
      cleanTerrain, blend: 1.0, geometryMode: false,
      bandChannelFlags: [], bandCoverage: [])
    XCTAssertEqual(
      bytesNan, bytesClean,
      "Kanal mit nicht-endlichen Koordinaten darf nachweislich nicht gestempelt werden")

    // 3. Altarme mit nicht-endlichen Koordinaten überspringen statt Int-Cast-Trap
    let oxbowTerrain = Terrain(allocating: renderConfig(n: 16), seed: 1337)
    var oxState = oxbowTerrain.state
    oxState.h = [Double](repeating: 0.5, count: 16 * 16)
    oxState.waterLevel = [Double](repeating: 0.51, count: 16 * 16)
    oxbowTerrain.restore(oxState)

    var oxbowNodes = (0..<24).map { MeanderNode(x: Double($0 % 16), z: Double($0 % 16)) }
    oxbowNodes[5] = MeanderNode(x: Double.infinity, z: 0)
    oxbowTerrain.meander.oxbows = [oxbowNodes]
    oxbowTerrain.meander.oxbowAge = [10.0]

    let bytesOxbowDeferred = renderer.bytes(
      oxbowTerrain, blend: 1.0, geometryMode: false,
      bandChannelFlags: [], bandCoverage: [], deferTail: true)
    XCTAssertEqual(bytesOxbowDeferred.count, oxbowTerrain.cfg.count * 4)

    // Nachbarknoten 4 (4, 4) und 6 (6, 6) müssen im G-Kanal (See/Altarm) gestempelt sein
    // (pinnt die continue-Semantik: Schleife bricht bei inf nicht ab).
    let cell4 = 4 * 16 + 4
    let cell6 = 6 * 16 + 6
    XCTAssertGreaterThan(bytesOxbowDeferred[cell4 * 4 + 1], 0, "Knoten 4 vor inf-Knoten muss gestempelt werden")
    XCTAssertGreaterThan(bytesOxbowDeferred[cell6 * 4 + 1], 0, "Knoten 6 nach inf-Knoten muss gestempelt werden")

    // Der inf-Knoten selbst darf weder an seiner ursprünglichen Position (5, 5)
    // noch an einer geklemmten Randposition (15, 0) gestempelt worden sein.
    let cell5 = 5 * 16 + 5
    let cellClamp = 0 * 16 + 15
    XCTAssertEqual(bytesOxbowDeferred[cell5 * 4 + 1], 0, "inf-Knoten-Zelle darf ungestempelt bleiben")
    XCTAssertEqual(bytesOxbowDeferred[cellClamp * 4 + 1], 0, "inf-Knoten darf nicht an den Rand geklemmt gestempelt werden")

    let bytesOxbow = renderer.bytes(
      oxbowTerrain, blend: 1.0, geometryMode: false,
      bandChannelFlags: [], bandCoverage: [])
    XCTAssertEqual(bytesOxbow.count, oxbowTerrain.cfg.count * 4)
    XCTAssertGreaterThan(bytesOxbow[cell4 * 4 + 1], 0)
    XCTAssertGreaterThan(bytesOxbow[cell6 * 4 + 1], 0)
    XCTAssertEqual(bytesOxbow[cellClamp * 4 + 1], 0)
  }

  /// Regression: ohne Schrittweite (`cellSize == 0`) gibt `emitRibbon` kein
  /// Band aus. Ohne den `cellSize > 0`-Guard entstanden Kanten-Offsets aus
  /// `0 / 0 = NaN`. Gegenprobe im selben Aufbau mit `world > 0`: derselbe
  /// Altarm wird sehr wohl gebaut, das leere Mesh liegt also am Guard.
  func testRibbonWithoutCellSpacingEmitsNothing() {
    func oxbowMesh(world: Double) -> RibbonMesh {
      var config = renderConfig(n: 16)
      config.world = world
      let terrain = Terrain(allocating: config, seed: 1337)
      var state = terrain.state
      state.h = [Double](repeating: 0.5, count: 16 * 16)
      state.waterLevel = [Double](repeating: 0.51, count: 16 * 16)
      terrain.restore(state)
      terrain.meander.oxbows = [(0..<24).map { MeanderNode(x: Double($0 % 16), z: Double($0 % 16)) }]
      terrain.meander.oxbowAge = [10.0]
      return RiverRibbonRenderer().build(terrain, hscale: 24, lift: 0.35)
    }
    XCTAssertFalse(oxbowMesh(world: calibrationWorld).vertices.isEmpty,
                   "Testaufbau: Altarm ergibt auch mit Schrittweite kein Band")
    let mesh = oxbowMesh(world: 0)
    XCTAssertTrue(mesh.vertices.isEmpty, "Band ohne Schrittweite emittiert")
    XCTAssertTrue(mesh.indices.isEmpty)
    XCTAssertTrue(mesh.stripStarts.isEmpty)
  }

  /// Regression: ohne definierte Schrittweite (`cellSize == 0`, etwa bei `world <= 0`)
  /// erzeugt `WaterFieldRenderer` weder Fluss-Intensität im R-Kanal des Wasserfelds
  /// noch Voll-Aussteuerung (255) im Flow-Detail-Feld durch ungesicherte Division
  /// durch 0 (`pa[k] / cellArea = +infinity`).
  func testWaterFieldWithoutCellSpacingEmitsNoRiverFlow() {
    var config = renderConfig(n: 16)
    config.world = 0
    XCTAssertEqual(config.cellSize, 0.0)
    let terrain = Terrain(allocating: config, seed: 1337)
    var state = terrain.state
    state.h = [Double](repeating: config.sea + 0.5, count: 16 * 16)
    state.waterLevel = state.h // trocken, kein See
    state.areaMFD = [Double](repeating: 50_000.0, count: 16 * 16)
    state.streamMap = [Double](repeating: 1.0, count: 16 * 16)
    terrain.restore(state)

    let renderer = WaterFieldRenderer()

    // 1. flowDetailField muss komplett 0 sein (ohne Zellfläche kein Abfluss-Detail)
    let detail = renderer.flowDetailField(terrain)
    XCTAssertEqual(detail.count, 16 * 16)
    XCTAssertTrue(detail.allSatisfy { $0 == 0 },
                  "Ohne Schrittweite darf kein Flow-Detail ausgesteuert werden")

    // 2. bytes() darf im R-Kanal (Fluss-Intensität) keine Flussbänder zeichnen
    let bytes = renderer.bytes(terrain, blend: 1.0, geometryMode: false,
                               bandChannelFlags: [], bandCoverage: [])
    XCTAssertEqual(bytes.count, 16 * 16 * 4)
    for k in 0..<(16 * 16) {
      XCTAssertEqual(bytes[k * 4], 0,
                     "Ohne Schrittweite darf im R-Kanal kein Fluss gezeichnet werden")
    }

    // Gegenprobe mit gültiger Weltgröße: Derselbe Zustand steuert Fluss-Intensität aus
    var normalConfig = renderConfig(n: 16)
    normalConfig.world = calibrationWorld
    let normalTerrain = Terrain(allocating: normalConfig, seed: 1337)
    normalTerrain.restore(state)
    let normalDetail = renderer.flowDetailField(normalTerrain)
    XCTAssertFalse(normalDetail.allSatisfy { $0 == 0 },
                   "Gegenprobe: Mit gültiger Schrittweite muss Flow-Detail aktiv sein")
    let normalBytes = renderer.bytes(normalTerrain, blend: 1.0, geometryMode: false,
                                     bandChannelFlags: [], bandCoverage: [])
    var hasStream = false
    for k in 0..<(16 * 16) where normalBytes[k * 4] > 0 { hasStream = true; break }
    XCTAssertTrue(hasStream,
                  "Gegenprobe: Mit gültiger Schrittweite muss Fluss im R-Kanal gezeichnet werden")
  }

  /// Nicht-endliche Knoten-Koordinaten (NaN, ±inf) in den Mäander-Kanälen müssen
  /// als maximale Änderung (Sentinel 1e9) gewertet werden und einen Rebuild erzwingen.
  /// Persistente Nicht-Endlichkeit erzwingt dauerhaft den Rebuild, bis der
  /// Zustand wieder endliche Koordinaten annimmt.
  func testRiverRibbonMaxDeltaHandlesNonFiniteValues() {
    let terrain = Terrain(config: renderConfig(n: 16), seed: 1337)
    terrain.meander.channels = [
      RiverChannel(nodes: [MeanderNode(x: 2, z: 2), MeanderNode(x: 4, z: 4)],
                   discharge: [100, 100])
    ]
    let renderer = RiverRibbonRenderer()
    renderer.markBuilt(terrain)
    XCTAssertEqual(renderer.maxDelta(terrain), 0.0, "Unverändertes Terrain hat maxDelta 0")

    // Nicht-endliche Koordinate (NaN) einbringen:
    terrain.meander.channels[0].nodes[0].x = .nan
    XCTAssertEqual(renderer.maxDelta(terrain), 1e9,
                   "NaN-Koordinate in Kanal muss Rebuild erzwingen (Sentinel 1e9)")

    // Persistente Nicht-Endlichkeit bleibt dirty:
    renderer.markBuilt(terrain)
    XCTAssertEqual(renderer.maxDelta(terrain), 1e9,
                   "Persistente Nicht-Endlichkeit muss weiterhin Rebuild erzwingen")

    // Unendlichkeit (±inf) prüfen:
    terrain.meander.channels[0].nodes[0].x = .infinity
    XCTAssertEqual(renderer.maxDelta(terrain), 1e9,
                   "Unendliche Koordinate in Kanal muss Rebuild erzwingen (Sentinel 1e9)")

    // Nach Heilung zu endlichen Werten und erneutem markBuilt beruhigt sich maxDelta wieder:
    terrain.meander.channels[0].nodes[0].x = 2.0
    XCTAssertEqual(renderer.maxDelta(terrain), 1e9,
                   "Übergang von Nicht-Endlichkeit zu endlichem Wert erfordert Rebuild")
    renderer.markBuilt(terrain)
    XCTAssertEqual(renderer.maxDelta(terrain), 0.0,
                   "Nach Heilung und markBuilt beruhigt sich maxDelta wieder auf 0")

    // Zweiter Operand dz: Nicht-endliche z-Koordinate (NaN, ±inf) pinnen:
    terrain.meander.channels[0].nodes[0].z = .nan
    XCTAssertEqual(renderer.maxDelta(terrain), 1e9,
                   "NaN in z-Koordinate muss Rebuild erzwingen (Sentinel 1e9)")

    terrain.meander.channels[0].nodes[0].z = .infinity
    XCTAssertEqual(renderer.maxDelta(terrain), 1e9,
                   "Unendliche z-Koordinate muss Rebuild erzwingen (Sentinel 1e9)")

    terrain.meander.channels[0].nodes[0].z = 2.0
    XCTAssertEqual(renderer.maxDelta(terrain), 1e9,
                   "Übergang von Nicht-Endlichkeit in z zu endlichem Wert erfordert Rebuild")
    renderer.markBuilt(terrain)
    XCTAssertEqual(renderer.maxDelta(terrain), 0.0,
                   "Nach Heilung der z-Koordinate beruhigt sich maxDelta wieder auf 0")
  }
}
