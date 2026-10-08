import XCTest

@testable import SimCore
@testable import SimRender

/// Wächter für die Schutzmaske (`WaterProtectMaskRenderer` / `RenderState.protectMaskBytes`, Issue #154).
///
/// Die Schutzmaske sperrt Kronendach und Verschiebung an Wasserflächen:
///  - Sichtbare Raster-Flüsse und Seen aus dem Wasserfeld
///  - Jede gebaute Bandfläche (`RiverRibbonRenderer.bandCoverage`)
///  - Einen Saum von etwa zwei Zellen (`WaterRender.protectSeamCells`) um beides
///  - Trockenes Land ohne Wasser/Bänder bleibt frei (0)
///  - Das Render-Wasserfeld selbst ändert sich nicht
///  - Gleiche Welt ergibt dieselbe Maske; Mutationen hinterlassen keine veraltete Maske
final class WaterProtectMaskTests: XCTestCase {

    private func makeTerrain(n: Int = 96, seed: UInt32 = 1337) -> Terrain {
        let cfg = renderConfig(n: n)
        let terrain = Terrain(config: cfg, seed: seed)
        terrain.computeFlow()
        return terrain
    }

    private func agedTerrain(years: Double = 4000, n: Int = 192, seed: UInt32 = 1337) -> Terrain {
        let cfg = renderConfig(n: n)
        let terrain = Terrain(config: cfg, seed: seed)
        while terrain.years < years {
            terrain.step(dtYears: min(1000, years - terrain.years))
        }
        terrain.computeFlow()
        return terrain
    }

    // MARK: - Inhalt der Maske

    /// Prüft, dass sichtbare Raster-Flüsse in der Maske geschützt sind (Wert 255).
    func testMaskIncludesVisibleRasterRivers() {
        let terrain = agedTerrain(years: 2000)
        let render = RenderState(geometryMode: true)
        let waterBytes = render.waterFieldBytes(terrain, blend: 1.0)
        let mask = render.protectMaskBytes(terrain)

        XCTAssertEqual(mask.count, terrain.cfg.count)
        let riverThresh = byte01(WaterRender.protectRiverThreshold)

        var foundRiver = false
        for k in 0..<terrain.cfg.count {
            if waterBytes[k * 4] >= riverThresh {
                foundRiver = true
                XCTAssertEqual(mask[k], 255, "Zelle \(k) mit sichtbarem Fluss muss geschützt (255) sein")
            }
        }
        XCTAssertTrue(foundRiver, "Testwelt muss mindestens eine sichtbare Flusszelle haben")
    }

    /// Prüft, dass sichtbare Seen in der Maske geschützt sind (Wert 255).
    func testMaskIncludesVisibleRasterLakes() {
        let terrain = makeTerrain()
        // See erzeugen: eine Vertiefung graben und füllen
        let n = terrain.cfg.n
        let cx = n / 2, cz = n / 2
        var state = terrain.state
        for dj in -5...5 {
            for di in -5...5 where di * di + dj * dj <= 25 {
                let k = (cz + dj) * n + (cx + di)
                state.h[k] = terrain.cfg.sea + 0.1
                state.waterLevel[k] = terrain.cfg.sea + 0.5
            }
        }
        terrain.restore(state)
        terrain.computeFlow()

        let render = RenderState(geometryMode: true)
        let waterBytes = render.waterFieldBytes(terrain, blend: 1.0)
        let mask = render.protectMaskBytes(terrain)

        let lakeThresh = byte01(WaterRender.protectLakeThreshold)
        var foundLake = false
        for k in 0..<terrain.cfg.count {
            if waterBytes[k * 4 + 1] >= lakeThresh {
                foundLake = true
                XCTAssertEqual(mask[k], 255, "Zelle \(k) mit sichtbarem See muss geschützt (255) sein")
            }
        }
        XCTAssertTrue(foundLake, "See-Zellen müssen vorhanden sein")
    }

    /// Prüft, dass gebaute Flussbänder (`bandCoverage > 0`) geschützt sind,
    /// selbst wenn das Rasterwasser unter ihnen durch den Raster-Deckel entfernt wurde.
    func testMaskIncludesBuiltRiverRibbonCoverage() {
        let terrain = agedTerrain(years: 2000)
        let render = RenderState(geometryMode: true)
        render.buildRiverRibbons(terrain, hscale: 24, lift: 0.35)
        let coverage = render.riverRibbonMesh.bandCoverage
        XCTAssertFalse(coverage.isEmpty, "Testwelt muss Bänder bauen")

        let mask = render.protectMaskBytes(terrain)
        XCTAssertEqual(mask.count, terrain.cfg.count)

        var foundBand = false
        for k in 0..<terrain.cfg.count where coverage[k] >= WaterRender.protectBandThreshold {
            foundBand = true
            XCTAssertEqual(mask[k], 255, "Bandzelle \(k) (Deckung \(coverage[k])) muss geschützt sein")
        }
        XCTAssertTrue(foundBand, "Mindestens eine Zelle mit Band-Deckung erwartet")
    }

    /// Prüft, dass die Maske um jede Wasser- und Bandzelle einen Saum von etwa
    /// zwei Zellen aufspannt (Chebyshev-Abstand 1 und 2 = 255).
    func testMaskExpandsByTwoCellsAroundWaterAndRibbons() {
        let terrain = makeTerrain(n: 32)
        // Flache Hochebene, weit über dem Meer (kein natürliches Wasser)
        var state = terrain.state
        for k in 0..<terrain.cfg.count {
            state.h[k] = 2.0
            state.waterLevel[k] = 2.0
        }
        terrain.restore(state)
        let renderer = WaterProtectMaskRenderer()

        // Künstliche Bandabdeckung an genau EINER Zelle (10, 10)
        let n = 32
        var coverage = [Double](repeating: 0, count: n * n)
        coverage[10 * n + 10] = 1.0

        let mask = renderer.bytes(terrain: terrain, bandCoverage: coverage, waterBytes: [])

        // Kernzelle (10, 10)
        XCTAssertEqual(mask[10 * n + 10], 255, "Kernzelle muss geschützt sein")

        // Abstand 1 Zelle (8-Nachbarn)
        for dj in -1...1 {
            for di in -1...1 {
                let k = (10 + dj) * n + (10 + di)
                XCTAssertEqual(mask[k], 255, "Abstand 1 (\(di), \(dj)) muss im Saum liegen")
            }
        }

        // Abstand 2 Zellen
        for dj in -2...2 {
            for di in -2...2 {
                let k = (10 + dj) * n + (10 + di)
                XCTAssertEqual(mask[k], 255, "Abstand 2 (\(di), \(dj)) muss im Saum liegen")
            }
        }

        // Abstand 3 Zellen: trockenes Land, frei (0)
        for di in [-3, 3] {
            let k = 10 * n + (10 + di)
            XCTAssertEqual(mask[k], 0, "Abstand 3 (\(di), 0) muss frei (0) bleiben")
        }
        for dj in [-3, 3] {
            let k = (10 + dj) * n + 10
            XCTAssertEqual(mask[k], 0, "Abstand 3 (0, \(dj)) muss frei (0) bleiben")
        }
    }

    /// Prüft, dass trockenes Land weitab von Wasser und Bändern frei (0) bleibt.
    func testMaskLeavesDryLandFree() {
        let terrain = makeTerrain(n: 48)
        let render = RenderState(geometryMode: true)
        let mask = render.protectMaskBytes(terrain)

        // Auf einer frischen Testwelt gibt es weite trockene Berg-/Plateauflächen
        var freeCount = 0
        for k in 0..<terrain.cfg.count where mask[k] == 0 {
            freeCount += 1
        }
        XCTAssertGreaterThan(freeCount, terrain.cfg.count / 2,
                             "Mehr als die Hälfte des Terrains sollte trockenes freies Land sein")
    }

    // MARK: - Unveränderlichkeit des Render-Wasserfelds

    /// Zusicherung: Die Berechnung der Maske verändert das Render-Wasserfeld und dessen
    /// EWMA-Glättung nicht ("Das Render-Wasserfeld selbst ändert sich nicht").
    func testWaterFieldBytesRemainsUntouchedByMaskComputation() {
        let terrain = agedTerrain(years: 2000)
        let renderA = RenderState(geometryMode: true)
        let renderB = RenderState(geometryMode: true)

        // renderA berechnet NUR das Wasserfeld
        let waterA = renderA.waterFieldBytes(terrain, blend: 0.5)

        // renderB berechnet erst die Schutzmaske, dann das Wasserfeld
        _ = renderB.protectMaskBytes(terrain)
        let waterB = renderB.waterFieldBytes(terrain, blend: 0.5)

        XCTAssertEqual(waterA, waterB,
                       "Das Wasserfeld muss bit-identisch sein, egal ob die Schutzmaske berechnet wurde")
    }

    // MARK: - Determinismus

    /// Gleiche Welt ergibt dieselbe Maske.
    func testDeterministicSameWorldYieldsIdenticalMask() {
        let terrainA = agedTerrain(years: 2000, seed: 42)
        let terrainB = agedTerrain(years: 2000, seed: 42)
        let renderA = RenderState(geometryMode: true)
        let renderB = RenderState(geometryMode: true)

        renderA.buildRiverRibbons(terrainA, hscale: 24, lift: 0.35)
        renderB.buildRiverRibbons(terrainB, hscale: 24, lift: 0.35)

        let maskA = renderA.protectMaskBytes(terrainA)
        let maskB = renderB.protectMaskBytes(terrainB)

        XCTAssertEqual(maskA, maskB, "Gleiche Welt muss deterministisch dieselbe Maske liefern")

        // Wiederholter Aufruf auf demselben render-Objekt
        let maskA2 = renderA.protectMaskBytes(terrainA)
        XCTAssertEqual(maskA, maskA2, "Wiederholter Aufruf muss identisch sein (Cache)")
    }

    // MARK: - Invalidierung

    /// Prüft, dass mutierende Operationen (Pinsel, Hebung, Recompute, Generieren)
    /// den Cache invalidieren und keine veraltete Maske hinterlassen.
    func testInvalidationLeavesFreshMaskBehind() {
        let terrain = agedTerrain(years: 4000, n: 192, seed: 1337)
        let render = RenderState(geometryMode: true)
        let maskBefore = render.protectMaskBytes(terrain)
        XCTAssertTrue(maskBefore.contains(255), "Maske vor Änderung muss geschützte Wasserzellen enthalten")

        // 1. Terrain verändern durch Graben einer tiefen Vertiefung / See
        let n = terrain.cfg.n
        terrain.sculpt(gx: Double(n / 4), gz: Double(n / 4), radiusWorld: 20.0, dir: -1.0, strength: 100.0)
        terrain.recomputeFlowAfterEdit()
        render.invalidate(terrain)

        let maskAfterSculpt = render.protectMaskBytes(terrain)
        XCTAssertNotEqual(maskBefore, maskAfterSculpt, "Nach Sculpting muss eine frische Maske entstehen")

        // 2. Band-Rebuild invalidiert die Maske
        render.buildRiverRibbons(terrain, hscale: 24, lift: 0.35)
        let maskAfterRibbons = render.protectMaskBytes(terrain)
        XCTAssertEqual(maskAfterRibbons.count, terrain.cfg.count)
        XCTAssertTrue(maskAfterRibbons.contains(255))

        // 3. Neugenerieren
        terrain.generate(seed: 9999)
        render.invalidate(terrain, worldReplaced: true)
        let maskAfterGenerate = render.protectMaskBytes(terrain)
        XCTAssertNotEqual(maskAfterRibbons, maskAfterGenerate,
                          "Nach Neu-Generieren muss eine frische Maske entstehen")
    }

    // MARK: - Grenzfälle

    /// Leeres Terrain (n == 0) darf nicht abstürzen und muss einen leeren Puffer liefern.
    func testEmptyTerrainReturnsEmptyBuffer() {
        var cfg = SimConfig()
        cfg.n = 0
        let empty = Terrain(allocating: cfg, seed: 1)
        let render = RenderState(geometryMode: true)
        XCTAssertEqual(render.protectMaskBytes(empty), [UInt8]())

        let renderer = WaterProtectMaskRenderer()
        XCTAssertEqual(renderer.bytes(terrain: empty, bandCoverage: [], waterBytes: []), [UInt8]())
    }
}
