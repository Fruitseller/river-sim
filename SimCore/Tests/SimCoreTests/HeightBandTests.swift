import XCTest
@testable import SimCore

final class HeightBandTests: XCTestCase {

    private func snowFractions(_ t: Terrain) -> (ramp: Double, full: Double) {
        let b = t.heightBands
        var land = 0, ramp = 0, full = 0
        for v in t.h where v > t.cfg.sea {
            land += 1
            let s = b.snowAmount(v)
            if s > 0 { ramp += 1 }
            if s >= 1 { full += 1 }
        }
        guard land > 0 else { return (0, 0) }
        return (Double(ramp) / Double(land), Double(full) / Double(land))
    }

    func testSnowZoneFollowsTheClimateNotAFixedLandFraction() {
        var c = SimConfig(); c.n = 832; c.world = calibrationWorld
        c.pinIceBeforeAvalanche()
        let t = Terrain(config: c, seed: 1337)
        let atGen = snowFractions(t)
        let startGen = t.heightBands.snowStart
        XCTAssertGreaterThan(atGen.ramp, 0, "Schneezone bei der Generierung leer")
        while t.years < 30_000 { t.step(dtYears: 500) }
        let at30k = snowFractions(t)
        let start30k = t.heightBands.snowStart
        print(String(format: "[#33] n=832 Rampe %.4f → %.4f · snowStart %.4f → %.4f "
                     + "· maxH %.4f", atGen.ramp, at30k.ramp, startGen, start30k,
                     t.maxHeight()))

        XCTAssertEqual(start30k, startGen, accuracy: 0.005,
            "Schneegrenze ist nicht klima-gepinnt (\(startGen) → \(start30k))")
        let isotherm = c.sea + c.climateSeaLevelTemp / c.climateLapseRate
        XCTAssertEqual(startGen, isotherm, accuracy: 0.02,
            "Schneegrenze liegt nicht auf der 0-°C-Isotherme (\(startGen) gegen \(isotherm))")

        XCTAssertLessThan(t.maxHeight(), 0.70, "Vorbedingung: Insel trägt nicht ab")
        XCTAssertLessThan(at30k.ramp, atGen.ramp * 0.90,
            "Schneefläche folgt der abtragenden Insel nicht (\(atGen.ramp) → \(at30k.ramp))")
        XCTAssertGreaterThan(at30k.ramp, 0.002,
            "Schneezone nach 30k Jahren praktisch leer: \(at30k.ramp)")
    }

    func testBandsFollowFlatteningTerrain() {
        var c = SimConfig(); c.n = 160; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        let b0 = t.heightBands
        let max0 = t.maxHeight()
        while t.years < 60_000 { t.step(dtYears: 500) }
        let b1 = t.heightBands
        print(String(format: "[#33] n=160 60k: vegFull %.4f → %.4f · snowStart %.4f → %.4f "
                     + "· maxH %.4f → %.4f", b0.vegFull, b1.vegFull,
                     b0.snowStart, b1.snowStart, max0, t.maxHeight()))
        XCTAssertLessThan(t.maxHeight(), max0, "Vorbedingung: Terrain flacht ab")
        XCTAssertLessThan(b1.vegFull, b0.vegFull,
            "Vegetationsgrenze folgt nicht (\(b0.vegFull) → \(b1.vegFull))")
        XCTAssertGreaterThanOrEqual(b1.snowStart, b0.snowStart - 0.005,
            "Schneegrenze wandert mit dem Terrain statt mit dem Klima "
            + "(\(b0.snowStart) → \(b1.snowStart))")
    }

    func testBandsAreWellOrdered() {
        var c = SimConfig(); c.n = 160; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        let b = t.heightBands
        XCTAssertLessThan(b.coniferLow, b.coniferHigh)
        XCTAssertLessThan(b.vegFull, b.vegNone)
        XCTAssertLessThan(b.rockStart, b.rockFull)
        XCTAssertLessThan(b.snowStart, b.snowFull)
        XCTAssertGreaterThanOrEqual(b.vegNone - b.vegFull, c.bandMinRampWidth)
        XCTAssertGreaterThanOrEqual(b.snowFull - b.snowStart, c.bandMinRampWidth)
        XCTAssertGreaterThan(b.snowStart, b.rockStart)
        XCTAssertEqual(b.snowAmount(b.snowStart), 0)
        XCTAssertEqual(b.snowAmount(b.snowFull), 1, accuracy: 1e-12)
        XCTAssertEqual(b.vegetationAltitudeFactor(b.vegFull), 1)
        XCTAssertEqual(b.vegetationAltitudeFactor(b.vegNone), 0, accuracy: 1e-12)
    }

    func testDegenerateFields() {
        var c = SimConfig(); c.n = 64; c.world = calibrationWorld
        let flooded = HeightBands.fromLandHeights([Double](repeating: c.sea - 0.1, count: 100), cfg: c)
        XCTAssertEqual(flooded, HeightBands.legacyAbsolute)
        let plateau = HeightBands.fromLandHeights([Double](repeating: c.sea + 0.3, count: 1000), cfg: c)
        XCTAssertGreaterThanOrEqual(plateau.snowFull - plateau.snowStart, c.bandMinRampWidth)
        XCTAssertGreaterThanOrEqual(plateau.vegNone - plateau.vegFull, c.bandMinRampWidth)
        XCTAssertTrue(plateau.snowAmount(c.sea + 0.3).isFinite)
        XCTAssertTrue(plateau.vegetationAltitudeFactor(c.sea + 0.3).isFinite)
    }

    func testEmptySnowFieldPutsTheBandAboveTheLand() {
        var c = SimConfig(); c.n = 64; c.world = calibrationWorld
        var heights = [Double](repeating: c.sea - 0.1, count: 4000)
        for k in 0..<2000 { heights[k] = c.sea + 0.1 + Double(k) * 0.0002 }
        let maxLand = heights.max()!
        let bands = HeightBands.fromLandHeights(heights, cfg: c, snowFractions: (0, 0))
        XCTAssertGreaterThan(bands.snowStart, maxLand,
            "leeres Schneefeld: Band liegt im Land (snowStart \(bands.snowStart) ≤ \(maxLand))")
        XCTAssertGreaterThanOrEqual(bands.snowFull - bands.snowStart, c.bandMinRampWidth)
        for v in heights where v > c.sea {
            XCTAssertEqual(bands.snowAmount(v), 0, "Land trägt Schnee ohne Schneefeld")
        }

        let snowy = HeightBands.fromLandHeights(heights, cfg: c, snowFractions: (0.10, 0.02))
        let above = heights.filter { $0 > snowy.snowStart }.count
        let land = heights.filter { $0 > c.sea }.count
        XCTAssertEqual(Double(above) / Double(land), 0.10, accuracy: 0.01,
                       "Band schneidet nicht den gemessenen Landanteil ab")
    }

    func testQuantileSourceMatchesReliefSignal() {
        var c = SimConfig(); c.n = 160; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        let q = Terrain.landHeightQuantiles(heights: t.h, sea: c.sea, probs: [0.5, 0.95])
        XCTAssertNotNil(q)
        XCTAssertEqual(q![1] - q![0], t.landReliefRobust(), accuracy: 0)
        let many = Terrain.landHeightQuantiles(heights: t.h, sea: c.sea,
                                               probs: [0.1, 0.5, 0.9, 0.99])!
        XCTAssertEqual(many, many.sorted())
    }

    func testHeightBandEvaluationWithNonFiniteHeights() {
        let b = HeightBands.legacyAbsolute

        XCTAssertEqual(b.rockAmount(b.rockStart), 0)
        XCTAssertEqual(b.rockAmount(b.rockFull), 1)
        XCTAssertEqual(b.snowAmount(b.snowStart), 0)
        XCTAssertEqual(b.snowAmount(b.snowFull), 1)
        XCTAssertEqual(b.vegetationAltitudeFactor(b.vegFull), 1)
        XCTAssertEqual(b.vegetationAltitudeFactor(b.vegNone), 0, accuracy: 1e-12)

        XCTAssertEqual(b.rockAmount(Double.nan), 0, "NaN-Höhe darf keinen Fels ausweisen")
        XCTAssertEqual(b.snowAmount(Double.nan), 0, "NaN-Höhe darf keinen Schnee ausweisen")
        XCTAssertEqual(b.vegetationAltitudeFactor(Double.nan), 0, "NaN-Höhe darf keine Vegetation tragen")
        XCTAssertEqual(b.coniferShare(Double.nan), 0.1, "NaN-Höhe muss auf die Untergrenze fallen")

        XCTAssertEqual(b.rockAmount(Double.infinity), 1)
        XCTAssertEqual(b.rockAmount(-Double.infinity), 0)
        XCTAssertEqual(b.snowAmount(Double.infinity), 1)
        XCTAssertEqual(b.snowAmount(-Double.infinity), 0)
        XCTAssertEqual(b.vegetationAltitudeFactor(Double.infinity), 0)
        XCTAssertEqual(b.vegetationAltitudeFactor(-Double.infinity), 1)
        XCTAssertEqual(b.coniferShare(Double.infinity), 0.9)
        XCTAssertEqual(b.coniferShare(-Double.infinity), 0.1)
    }

    func testLandHeightQuantilesHandlesNonFiniteAndExtremeHeights() {
        let sea = 0.2
        var heights = [Double](repeating: 0.1, count: 50)
        for i in 0..<30 {
            heights.append(sea + 0.05 + Double(i) * 0.02)
        }

        let baseline = Terrain.landHeightQuantiles(heights: heights, sea: sea, probs: [0.5, 0.95])
        XCTAssertNotNil(baseline)

        var noisy = heights
        noisy.append(Double.nan)
        noisy.append(Double.infinity)
        noisy.append(-Double.infinity)

        let quantilesNoisy = Terrain.landHeightQuantiles(heights: noisy, sea: sea, probs: [0.5, 0.95])
        XCTAssertEqual(quantilesNoisy, baseline,
                       "Nicht-endliche Werte müssen ignoriert werden und dürfen das Quantil nicht verzerren")

        var extreme = heights
        extreme.append(100.0)
        extreme.append(1e12)
        extreme.append(1e300)
        let quantilesExtreme = Terrain.landHeightQuantiles(heights: extreme, sea: sea, probs: [0.5, 0.95])
        XCTAssertNotNil(quantilesExtreme, "Extreme Werte dürfen nicht zum Int-Trap führen")

        XCTAssertNil(Terrain.landHeightQuantiles(heights: heights, sea: Double.nan, probs: [0.5]))
        XCTAssertNil(Terrain.landHeightQuantiles(heights: heights, sea: Double.infinity, probs: [0.5]))
        XCTAssertNil(Terrain.landHeightQuantiles(heights: heights, sea: sea, probs: []))
        XCTAssertNil(Terrain.landHeightQuantiles(heights: heights, sea: sea, probs: [Double.nan]))
        XCTAssertNil(Terrain.landHeightQuantiles(heights: heights, sea: sea, probs: [-0.1]))
        XCTAssertNil(Terrain.landHeightQuantiles(heights: heights, sea: sea, probs: [1.5]))
        XCTAssertNil(Terrain.landHeightQuantiles(heights: heights, sea: sea, probs: [0.8, 0.2]),
                     "Nicht-aufsteigende Wahrscheinlichkeiten müssen abgelehnt werden")
    }

    func testLandReliefHandlesNonFiniteHeightsAndEmptyTerrain() {
        var c = SimConfig()
        c.n = 16
        c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        let reliefBefore = t.landRelief()
        XCTAssertGreaterThan(reliefBefore, 0)

        var h = t.h
        h[0] = Double.nan
        h[1] = Double.nan
        h[2] = Double.nan
        t.setBedForTests(h: h, sed: t.sed, rock: t.rock, underIce: t.underIce)

        let reliefAfter = t.landRelief()
        XCTAssertTrue(reliefAfter.isFinite, "landRelief muss endlich bleiben")
        XCTAssertGreaterThan(reliefAfter, 0)

        var emptyConfig = renderConfig(n: 0)
        emptyConfig.world = 0
        let empty = Terrain(allocating: emptyConfig, seed: 1337)
        XCTAssertEqual(empty.landRelief(), 0, "Leeres Terrain muss Relief 0 liefern")

        var extremeConfig = SimConfig()
        extremeConfig.n = 16
        extremeConfig.world = calibrationWorld
        extremeConfig.sea = -1.5e308
        let tExtreme = Terrain(allocating: extremeConfig, seed: 1337)
        var hExt = [Double](repeating: 0, count: extremeConfig.count)
        var rockExt = [Double](repeating: 0, count: extremeConfig.count)
        let sedExt = [Double](repeating: 0, count: extremeConfig.count)
        hExt[0] = 1e308
        rockExt[0] = 1e308
        hExt[1] = -1e308
        rockExt[1] = -1e308
        tExtreme.setBedForTests(h: hExt, sed: sedExt, rock: rockExt, underIce: [])
        let reliefExtreme = tExtreme.landRelief()
        XCTAssertTrue(reliefExtreme.isFinite, "landRelief muss auch bei Differenzüberlauf endlich bleiben")
        XCTAssertEqual(reliefExtreme, Double.greatestFiniteMagnitude)
    }

    func testDiagnosticMetricsHandleNonFiniteValuesAndEmptyTerrain() {
        var c = SimConfig()
        c.n = 16
        c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)
        let curvBefore = t.ridgeCurvature()
        XCTAssertTrue(curvBefore.isFinite)

        var state = t.state
        state.h[20] = Double.nan
        state.h[1] = Double.infinity
        state.h[2] = -Double.infinity
        t.restore(state)

        let curvAfter = t.ridgeCurvature()
        XCTAssertTrue(curvAfter.isFinite, "ridgeCurvature muss trotz nicht-endlicher Höhen endlich bleiben")

        XCTAssertEqual(t.ridgeCurvature(maxAreaCells: 0), 0)
        XCTAssertEqual(t.ridgeCurvature(maxAreaCells: -1), 0)
        XCTAssertEqual(t.ridgeCurvature(maxAreaCells: Double.nan), 0)

        var emptyConfig = renderConfig(n: 0)
        emptyConfig.world = 0
        let empty = Terrain(allocating: emptyConfig, seed: 1337)
        XCTAssertEqual(empty.ridgeCurvature(), 0, "Leeres Terrain muss ridgeCurvature 0 liefern")
        XCTAssertEqual(empty.totalOutletArea(), 0, "Leeres Terrain muss totalOutletArea 0 liefern")
        XCTAssertEqual(empty.landCellCount(), 0, "Leeres Terrain muss landCellCount 0 liefern")
        XCTAssertEqual(empty.receiverAgreement(with: []), 1, "Leeres Terrain muss receiverAgreement 1 liefern")

        var c1 = renderConfig(n: 1)
        c1.world = 0
        let t1 = Terrain(allocating: c1, seed: 1337)
        XCTAssertEqual(t1.ridgeCurvature(), 0, "Terrain mit n = 1 darf nicht trappen")

        var c2 = renderConfig(n: 2)
        c2.world = 0
        let t2 = Terrain(allocating: c2, seed: 1337)
        XCTAssertEqual(t2.ridgeCurvature(), 0, "Terrain mit n = 2 darf nicht trappen")

        var mismatchState = t.state
        mismatchState.receiver = [1, 2]
        mismatchState.hf = [1.0]
        let tMismatch = Terrain(allocating: c, seed: 1337)
        tMismatch.restore(mismatchState)
        XCTAssertEqual(tMismatch.totalOutletArea(), 0, "Mismatch in receiver/area muss 0 liefern")
        XCTAssertEqual(tMismatch.landCellCount(), 0, "Mismatch in hf muss 0 liefern")
        XCTAssertEqual(tMismatch.receiverAgreement(with: [1, 2, 3]), 1, "Mismatch in receiverAgreement muss 1 liefern")
    }
}

