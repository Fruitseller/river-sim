import XCTest
@testable import SimCore

final class WaterRenderTests: XCTestCase {

    func testComponentFadeWindow() {
        XCTAssertEqual(WaterRender.componentFadeLoCells, 10.0)
        XCTAssertEqual(WaterRender.componentFadeHiCells, 50.0)
        XCTAssertEqual(WaterRender.componentFade(cells: 0), 0.0)
        XCTAssertEqual(WaterRender.componentFade(cells: 10), 0.0)
        XCTAssertEqual(WaterRender.componentFade(cells: 11), 0.025, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.componentFade(cells: 30), 0.5, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.componentFade(cells: 50), 1.0)
        XCTAssertEqual(WaterRender.componentFade(cells: 100_000), 1.0)
    }

    func testComponentFadeIsMonotonicAndBounded() {
        var previous = -1.0
        for cells in 0...200 {
            let fade = WaterRender.componentFade(cells: cells)
            XCTAssertGreaterThanOrEqual(fade, previous, "Fade darf nicht fallen")
            XCTAssertGreaterThanOrEqual(fade, 0.0)
            XCTAssertLessThanOrEqual(fade, 1.0)
            previous = fade
        }
    }

    func testFadeReplacesHardCutoffWithoutJump() {
        let step = 1.0 / (WaterRender.componentFadeHiCells - WaterRender.componentFadeLoCells)
        for cells in 0..<200 {
            let delta = WaterRender.componentFade(cells: cells + 1)
                - WaterRender.componentFade(cells: cells)
            XCTAssertLessThanOrEqual(delta, step + 1e-12)
        }
        XCTAssertGreaterThan(WaterRender.componentFade(cells: 25), 0.0)
        XCTAssertLessThan(WaterRender.componentFade(cells: 25), 1.0,
                          "25 Zellen liegen MITTEN im Fade — nicht wieder als Kante")
    }

    func testLakeGateVisibilityThresholds() {
        XCTAssertLessThanOrEqual(WaterRender.componentFade(cells: 11), WaterRender.lakeGateLo)
        XCTAssertGreaterThan(WaterRender.componentFade(cells: 12), WaterRender.lakeGateLo)
        XCTAssertLessThan(WaterRender.componentFade(cells: 23), WaterRender.lakeGateHi)
        XCTAssertGreaterThanOrEqual(WaterRender.componentFade(cells: 24), WaterRender.lakeGateHi)
    }

    func testStreamChannelIsGatedNotFaded() {
        XCTAssertEqual(WaterRender.streamGateFade, WaterRender.riverMaskHi)
        XCTAssertEqual(WaterRender.streamGateCells, 28)
        XCTAssertEqual(WaterRender.streamGate(componentFade: WaterRender.componentFade(cells: 27)), 0)
        XCTAssertEqual(WaterRender.streamGate(componentFade: WaterRender.componentFade(cells: 28)), 1)
        XCTAssertEqual(WaterRender.riverMask(stream: WaterRender.streamGateFade), 1.0, accuracy: 1e-12)
    }

    func testSmallStreamComponentPaintsNeitherWaterNorShore() {
        for cells in 0...(WaterRender.streamGateCells - 1) {
            let stream = 1.0 * WaterRender.streamGate(componentFade: WaterRender.componentFade(cells: cells))
            XCTAssertEqual(stream, 0.0, "\(cells) Zellen dürfen den Fluss-Kanal nicht speisen")
            XCTAssertEqual(WaterRender.riverMask(stream: stream), 0.0)
            XCTAssertEqual(WaterRender.shore(stream: stream, lakeGateChannel: 0, pond: 0), 0.0,
                           "\(cells) Zellen: kein Ufer-Saum ohne Wasser")
        }
    }

    func testFadingLakeShowsWaterBeforeShore() {
        let deepPond = WaterRender.pondContourHi + 0.01
        for cells in 0...60 {
            let gate = WaterRender.componentFade(cells: cells)
            XCTAssertEqual(WaterRender.shore(stream: 0, lakeGateChannel: gate, pond: deepPond), 0.0,
                           accuracy: 1e-12, "\(cells) Zellen: Saum im Wasser")
        }
        XCTAssertEqual(WaterRender.shore(stream: 0, lakeGateChannel: 0.1135, pond: 0), 0.27,
                       accuracy: 0.02)
    }

    func testGateSaturatesBeforeRiverMask() {
        XCTAssertLessThan(WaterRender.lakeGateHi, WaterRender.riverMaskHi)
        XCTAssertLessThan(WaterRender.lakeGateLo, WaterRender.riverMaskLo)
    }

    func testShoreWindowSitsUnderTheWaterWindow() {
        XCTAssertLessThan(WaterRender.shoreLo, WaterRender.shoreHi)
        XCTAssertLessThanOrEqual(WaterRender.shoreHi, WaterRender.riverMaskLo)
        XCTAssertGreaterThan(WaterRender.ribbonHaloIntensity, WaterRender.shoreLo)
        XCTAssertLessThan(WaterRender.ribbonHaloIntensity, WaterRender.riverMaskLo)
    }

    func testPondWindowsStayInOrder() {
        XCTAssertEqual(WaterRender.pondContourLo, 0.003)
        XCTAssertEqual(WaterRender.pondContourHi, 0.02)
        XCTAssertLessThan(WaterRender.pondContourLo, WaterRender.pondContourHi)
        XCTAssertLessThan(WaterRender.pondContourLo, WaterRender.geometryLiftLo)
        XCTAssertLessThan(WaterRender.geometryLiftLo, WaterRender.geometryLiftHi)
        XCTAssertLessThan(WaterRender.lakeDepthLo, WaterRender.geometryLiftLo)
        XCTAssertGreaterThan(WaterRender.lakeDepthSpan, 0)
    }

    func testProtectMaskReadsVisibilityFromTheShaderWindows() {
        XCTAssertEqual(WaterRender.protectRiverThreshold, WaterRender.riverMaskLo)
        XCTAssertEqual(WaterRender.protectLakeThreshold, WaterRender.lakeGateLo)
        XCTAssertEqual(WaterRender.protectBandThreshold, 0.01)
        XCTAssertEqual(WaterRender.protectSeamCells, 2)
    }

    func testShaderReadsEveryWindowFromItsUniform() throws {
        let shader = try repoFile("game/shaders/terrain.gdshader")
        assertContains(shader,
            "float calib_window(float lo, float hi, float x)",
            hint: "Fenster-Helfer existiert (Totalität der Editor-Vorschau)")
        assertContains(shader,
            "smoothstep(lo, max(hi, lo + 1e-6), x)",
            hint: "Fenster-Helfer klemmt gegen edge0 >= edge1 (GLSL-UB)")
        assertContains(shader,
            "calib_window(water_pond_contour_lo, water_pond_contour_hi, pond)",
            hint: "Kontur-Fuß/Sattel der Uferlinie liest WaterRender.pondContour*")
        assertContains(shader,
            "calib_window(water_lake_gate_lo, water_lake_gate_hi, water_at(uv).g)",
            hint: "See-GATE liest WaterRender.lakeGate*")
        assertContains(shader,
            "calib_window(water_river_mask_lo, water_river_mask_hi, stream)",
            hint: "Fluss-INTENSITÄT liest WaterRender.riverMask*")
        assertContains(shader,
            "calib_window(water_river_depth_lo, water_river_depth_hi, stream)",
            hint: "Fluss-TIEFE liest WaterRender.riverDepth* (bis zum Review zu #174 eine Zahl im Shader)")
        assertContains(shader,
            "calib_window(water_lake_gate_lo, water_lake_gate_hi, lake_gate)",
            hint: "Pixel-Stufe liest das See-Gate aus demselben Abgriff wie den Fluss-Kanal")
        assertContains(shader,
            "calib_window(water_shore_lo, water_shore_hi, max(stream, lake_gate))",
            hint: "Ufer-Saum liest WaterRender.shore*")
        assertContains(shader,
            "calib_window(water_geometry_lift_lo, water_geometry_lift_hi, pond)",
            hint: "Hub der Wasser-Geometrie liest WaterRender.geometryLift*")
        assertContains(shader,
            "clamp((pond - water_lake_depth_lo) / max(water_lake_depth_span, 1e-6), 0.0, 1.0)",
            hint: "See-Tiefenrampe liest WaterRender.lakeDepth* (max: 0/0-NaN-Schutz)")
    }

    func testGeometryHandsOverExactlyWhereTheRasterStarts() {
        XCTAssertEqual(WaterRender.lakeRawWetDepth, 0.03)
        XCTAssertEqual(WaterRender.deltaFrontDepth, WaterRender.lakeRawWetDepth)
        XCTAssertLessThan(WaterRender.pondContourLo, WaterRender.deltaFrontDepth)
        XCTAssertLessThan(WaterRender.pondContourLo, WaterRender.pondContourHi)
        XCTAssertLessThanOrEqual(WaterRender.pondContourHi, WaterRender.deltaFrontDepth)
    }

    func testDeltaArmGeometryStaysASubordinatePlume() {
        XCTAssertGreaterThan(WaterRender.deltaArmOpacity, 0)
        XCTAssertLessThan(WaterRender.deltaArmOpacity, 0.5)
        XCTAssertGreaterThan(WaterRender.deltaArmSpread, 0)
        XCTAssertLessThan(WaterRender.deltaArmSpread, Double.pi / 4)
        XCTAssertLessThan(WaterRender.deltaMinArmCells, WaterRender.deltaMaxArmCells)
        XCTAssertGreaterThanOrEqual(WaterRender.deltaMinArmCells, 2)
        XCTAssertGreaterThan(WaterRender.mouthOverlapCells, 0)
    }

    func testBandsSitOnTheWaterSurfaceNotAboveIt() {
        XCTAssertLessThan(WaterRender.ribbonSeaSurfaceSink, 0)
        XCTAssertGreaterThan(WaterRender.ribbonLakeSurfaceLift, 0)
        XCTAssertLessThan(abs(WaterRender.ribbonSeaSurfaceSink), RenderContract.riverLift)
        XCTAssertLessThan(WaterRender.ribbonLakeSurfaceLift, RenderContract.riverLift)
    }

    func testRibbonKindsMapToTheShaderWeights() {
        XCTAssertEqual(WaterRender.ribbonStillWeight(kind: WaterRender.ribbonKindRiver), 0)
        XCTAssertEqual(WaterRender.ribbonDeltaWeight(kind: WaterRender.ribbonKindRiver), 0)
        XCTAssertEqual(WaterRender.ribbonStillWeight(kind: WaterRender.ribbonKindDelta), 0)
        XCTAssertEqual(WaterRender.ribbonDeltaWeight(kind: WaterRender.ribbonKindDelta), 1)
        XCTAssertEqual(WaterRender.ribbonStillWeight(kind: WaterRender.ribbonKindOxbow), 1)
        XCTAssertEqual(WaterRender.ribbonDeltaWeight(kind: WaterRender.ribbonKindOxbow), 0)
    }

    func testWaterShaderMatchesRibbonContract() throws {
        let shader = try repoFile("game/shaders/water.gdshader")
        assertContains(shader,
            "smoothstep(lo, max(hi, lo + 1e-6), x)",
            hint: "Fenster-Helfer klemmt gegen edge0 >= edge1 (GLSL-UB, s. Terrain)")
        assertContains(shader,
            "calib_window(water_ribbon_still_lo, water_ribbon_still_hi, v_kind)",
            hint: "Stillwasser-Gewicht liest WaterRender.ribbonStill*")
        assertContains(shader,
            "calib_window(water_ribbon_delta_lo, water_ribbon_delta_hi, v_kind)",
            hint: "Delta-Gewicht liest WaterRender.ribbonDelta*")
        assertContains(shader, "v_kind = UV2.x",
            hint: "Typ-Kanal des Vertex-Vertrags == UV2.x")
    }

    func testRibbonWidthFollowsDischarge() {
        let reference = 280.0
        XCTAssertEqual(WaterRender.ribbonHalfWidthAtReference, 0.8)
        XCTAssertEqual(WaterRender.ribbonHalfWidthFloorCells, 0.12)
        XCTAssertEqual(WaterRender.ribbonHalfWidthCapCells, 3.2)
        XCTAssertEqual(WaterRender.ribbonMaxCrossSlope, 0.4)
        XCTAssertEqual(WaterRender.ribbonHalfWidthCells(dischargeCells: reference,
                                                        referenceCells: reference),
                       WaterRender.ribbonHalfWidthAtReference, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.ribbonHalfWidthCells(dischargeCells: 4 * reference,
                                                        referenceCells: reference),
                       2 * WaterRender.ribbonHalfWidthAtReference, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.ribbonHalfWidthCells(dischargeCells: -5,
                                                        referenceCells: reference),
                       WaterRender.ribbonHalfWidthFloorCells)
        XCTAssertEqual(WaterRender.ribbonHalfWidthCells(dischargeCells: 1e9,
                                                        referenceCells: reference),
                       WaterRender.ribbonHalfWidthCapCells)
        XCTAssertEqual(WaterRender.oxbowHalfWidthCells, 1.0)
        XCTAssertGreaterThan(WaterRender.oxbowHalfWidthCells,
                             WaterRender.ribbonHalfWidthFloorCells)
        XCTAssertLessThan(WaterRender.oxbowHalfWidthCells,
                          WaterRender.ribbonHalfWidthCapCells)
    }

    func testHaloAlwaysCoversTheBand() {
        XCTAssertEqual(WaterRender.ribbonHaloMarginCells, 1.0)
        XCTAssertGreaterThan(WaterRender.ribbonHaloMarginCells, 0)
        XCTAssertEqual(WaterRender.ribbonHaloIntensity, 0.14)
    }

    func testDeltaArmIsWiderThanTheChannelItComesFrom() {
        XCTAssertEqual(WaterRender.deltaArmMinHalfWidthCells, 1.5)
        XCTAssertGreaterThan(WaterRender.deltaArmWidthAtMouth, 1)
        XCTAssertGreaterThan(WaterRender.deltaArmWidthAtMouth
                             - WaterRender.deltaArmWidthTaper, 0)
        XCTAssertLessThan(WaterRender.deltaArmWidthAtMouth
                          - WaterRender.deltaArmWidthTaper, 1)
        XCTAssertLessThan(WaterRender.deltaArmRankFactor, 1)
        XCTAssertGreaterThan(WaterRender.deltaArmRankFactor, 0)
    }

    func testBandEndsAndGatesStayInOrder() {
        XCTAssertEqual(WaterRender.ribbonSourceTaperCells, 4.0)
        XCTAssertEqual(WaterRender.ribbonTailTaperCells, 2.0)
        XCTAssertGreaterThan(WaterRender.ribbonSourceTaperCells,
                             WaterRender.ribbonTailTaperCells)
        XCTAssertEqual(WaterRender.ribbonMinimumAlpha, 0.02)
        XCTAssertEqual(WaterRender.ribbonRankDivisor, 6.0)
        XCTAssertLessThan(2 / WaterRender.ribbonRankDivisor, WaterRender.ribbonMinimumRank)
        XCTAssertLessThan(WaterRender.ribbonMinimumRank, 3 / WaterRender.ribbonRankDivisor)
        XCTAssertGreaterThan(Double(WaterRender.mouthSearchCells),
                             WaterRender.mouthOverlapCells)
        XCTAssertEqual(WaterRender.cascadeSlopeLo, 0.02)
        XCTAssertEqual(WaterRender.cascadeSlopeSpan, 0.03)
        XCTAssertEqual(WaterRender.cascadeWeight(slope: 0.01), 0)
        XCTAssertEqual(WaterRender.cascadeWeight(slope: 0.05), 1)
        XCTAssertEqual(WaterRender.cascadeWeight(slope: -0.05), 1,
                       "Gefälle-Richtung darf die Übergabe nicht umgehen")
    }

    func testRasterLeavesWallsOnlyAboveTheBandCascade() throws {
        XCTAssertEqual(WaterRender.rasterWallSlopeLo,
                       (WaterRender.cascadeSlopeLo + WaterRender.cascadeSlopeSpan) * RenderContract.heightScale,
                       accuracy: 1e-12, "Wand-Fenster beginnt an der vollen Kaskaden-Übergabe des Bands")
        XCTAssertGreaterThan(WaterRender.rasterWallSlopeHi, WaterRender.rasterWallSlopeLo)
        let shader = try repoFile("game/shaders/terrain.gdshader")
        assertContains(shader,
            "float stream = w.r * (1.0 - calib_window(water_wall_slope_lo, water_wall_slope_hi, world_slope));",
            hint: "Wand-Fenster liest WaterRender.rasterWallSlope* am Abfluss-Kanal")
    }

    func testOxbowFilterIsSharedAndSelfConsistent() {
        XCTAssertEqual(WaterRender.oxbowMinimumNodes, 20)
        XCTAssertEqual(WaterRender.oxbowMaximumTrimmedNodes, 3)
        XCTAssertEqual(WaterRender.oxbowEndFadeSteps, 3.0)
        XCTAssertEqual(WaterRender.oxbowMaximumOpacity, 0.7)
        XCTAssertEqual(WaterRender.oxbowVisibleYears, 6000.0)
        XCTAssertGreaterThan(WaterRender.oxbowMinimumNodes,
                             2 * WaterRender.oxbowMaximumTrimmedNodes)
        XCTAssertLessThan(WaterRender.oxbowMaximumOpacity, 1)
    }

    func testTrackMaskWindow() {
        XCTAssertEqual(WaterRender.trackMaskLo, 0.18)
        XCTAssertEqual(WaterRender.trackMaskSpan, 0.24)
        XCTAssertEqual(WaterRender.trackMask(streamMap: 0.18), 0)
        XCTAssertEqual(WaterRender.trackMask(streamMap: 0.0), 0)
        XCTAssertEqual(WaterRender.trackMask(streamMap: 0.3), 0.5, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.trackMask(streamMap: 0.42), 1, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.trackMask(streamMap: 9), 1)
        XCTAssertEqual(WaterRender.trackWeight(mask: 0), WaterRender.trackWeightFloor)
        XCTAssertEqual(WaterRender.trackWeight(mask: 1), 1, accuracy: 1e-12)
    }

    func testCorridorMaskSitsUnderTheTrackMask() {
        XCTAssertEqual(WaterRender.corridorTrackLo, 0.1)
        XCTAssertEqual(WaterRender.corridorTrackSpan, 0.2)
        XCTAssertLessThan(WaterRender.corridorTrackLo, WaterRender.trackMaskLo)
        XCTAssertEqual(WaterRender.corridorMask(streamMap: 0.2), 0.5, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.corridorWeight(mask: 0), WaterRender.corridorWeightFloor)
        XCTAssertEqual(WaterRender.corridorWeight(mask: 1), 1, accuracy: 1e-12)
        XCTAssertLessThan(WaterRender.corridorWeightFloor, WaterRender.trackWeightFloor)
        XCTAssertEqual(WaterRender.ribbonSupportLo, 0.35)
        XCTAssertEqual(WaterRender.ribbonSupportSpan, 0.3)
        XCTAssertLessThan(WaterRender.ribbonSupportLo + WaterRender.ribbonSupportSpan, 1)
    }

    func testStreamGradingIsMonotonicAndBounded() {
        let creek = 280.0
        XCTAssertEqual(WaterRender.streamIntensityBase, 0.4)
        XCTAssertEqual(WaterRender.streamIntensityLogDivisor, 4.0)
        var previous = 0.0
        for q in stride(from: creek, through: 400 * creek, by: creek) {
            let value = WaterRender.streamIntensity(dischargeCells: q, creekCells: creek)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThanOrEqual(value, 1)
            previous = value
        }
        XCTAssertGreaterThan(WaterRender.streamIntensity(dischargeCells: creek,
                                                         creekCells: creek),
                             WaterRender.riverMaskLo)
        XCTAssertEqual(WaterRender.streamIntensity(dischargeCells: -10 * creek,
                                                   creekCells: creek),
                       WaterRender.streamIntensityBase)
        XCTAssertEqual(WaterRender.streamPondTolerance, 0.01)
        XCTAssertLessThan(WaterRender.streamPondTolerance, WaterRender.lakeRawWetDepth)
    }

    func testWideningKeepsTheHierarchy() {
        XCTAssertEqual(WaterRender.widenThresholds, [0.55, 0.8])
        XCTAssertEqual(WaterRender.widenFalloff, 0.09)
        XCTAssertEqual(WaterRender.widenBarTolerance, 0.004)
        XCTAssertEqual(WaterRender.widenThresholds, WaterRender.widenThresholds.sorted())
        for thresh in WaterRender.widenThresholds {
            XCTAssertGreaterThan(thresh, WaterRender.riverMaskLo)
            XCTAssertLessThan(thresh, 1)
        }
        XCTAssertGreaterThan(WaterRender.widenThresholds[0] - WaterRender.widenFalloff,
                             WaterRender.riverMaskLo)
        XCTAssertLessThan(WaterRender.widenBarTolerance, WaterRender.pondContourHi)
    }

    func testContinuityChainStaysVisible() {
        XCTAssertEqual(WaterRender.continuityDecayPerCell, 0.015)
        XCTAssertEqual(WaterRender.continuityFloor, 0.3)
        XCTAssertGreaterThan(WaterRender.continuityFloor, WaterRender.riverMaskLo)
        XCTAssertGreaterThan(WaterRender.continuityDecayPerCell, 0)
        XCTAssertGreaterThan((1 - WaterRender.continuityFloor)
                             / WaterRender.continuityDecayPerCell, 30)
    }

    func testLegacyStampPathKeepsItsGrading() {
        let creek = 280.0
        XCTAssertEqual(WaterRender.stampHalfWidthCapCells, 1.0)
        XCTAssertEqual(WaterRender.stampHalfWidthCells(dischargeCells: 1e9,
                                                       creekCells: creek),
                       WaterRender.stampHalfWidthCapCells)
        XCTAssertGreaterThan(WaterRender.stampHalfWidthCells(dischargeCells: 0,
                                                             creekCells: creek), 0)
        XCTAssertGreaterThan(WaterRender.stampIntensityBase, WaterRender.streamIntensityBase)
        XCTAssertGreaterThan(WaterRender.stampIntensity(dischargeCells: 0, creekCells: creek),
                             WaterRender.riverMaskLo)
        XCTAssertLessThanOrEqual(WaterRender.stampIntensity(dischargeCells: 1e9,
                                                            creekCells: creek), 1)
    }

    func testAllWaterShadersShareTheSameWater() throws {
        let terrain = try repoFile("game/shaders/terrain.gdshader")
        let water = try repoFile("game/shaders/water.gdshader")
        let ocean = try repoFile("game/shaders/ocean.gdshader")
        for (name, shader) in [("terrain", terrain), ("water", water)] {
            assertContains(shader, "mix(water_shallow_color, water_deep_color, depth)",
                           hint: "\(name): Wasserfarbe liest WaterRender.water*Color")
            assertContains(shader, "flow * water_flow_shimmer_color",
                           hint: "\(name): Strömungs-Schimmer liest WaterRender.flowShimmerColor")
        }
        for (name, shader) in [("terrain", terrain), ("water", water), ("ocean", ocean)] {
            assertContains(shader, "pow(1.0 - ndv, max(water_fresnel_exponent, 1e-6))",
                           hint: "\(name): Fresnel liest WaterRender.fresnelExponent "
                               + "(max: pow(0.0, 0.0) ist GLSL-UB, Null-Uniform der "
                               + "Editor-Vorschau)")
            assertContains(shader, "*= 1.0 - fresnel;",
                hint: "\(name): Wasserkörper tritt mit Fresnel hinter die Spiegelung zurück")
            XCTAssertFalse(shader.contains("sky_reflect"),
                "\(name): keine Himmelsfarbe in der Albedo (Godot spiegelt die Umgebung selbst)")
            XCTAssertTrue(shader.contains("ROUGHNESS = water_roughness;")
                          || shader.contains("mix(land_roughness, mix(water_roughness, 0.7, foam), wet)")
                          || shader.contains("mix(water_roughness, 0.55, still)"),
                "\(name): Rauheit liest WaterRender.waterRoughness")
            XCTAssertTrue(shader.contains("SPECULAR = water_specular;")
                          || shader.contains("mix(water_specular, water_river_specular,"),
                "\(name): Specular liest WaterRender.waterSpecular/waterRiverSpecular")
        }
        for (name, shader) in [("terrain", terrain), ("water", water)] {
            assertContains(shader, "mix(water_opacity_shallow, water_opacity_deep, depth)",
                           hint: "\(name): Deckkraft liest WaterRender.waterOpacity*")
        }
        assertContains(ocean, "ALPHA = 1.0;", hint: "Offenes Meer ist opak")
        assertContains(water, "mix(water, water_delta_plume_color, delta * 0.5)",
                       hint: "Trübungsfahne liest WaterRender.deltaPlumeColor")
        assertContains(water, "mix(water, water_oxbow_water_color, still * 0.5)",
                       hint: "Altarm-Wasser liest WaterRender.oxbowWaterColor")
    }

    func testOceanColorDarkensWithDepth() {
        func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
            0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        }
        XCTAssertGreaterThan(luminance(WaterRender.oceanShallowColor),
                             luminance(WaterRender.oceanMidColor))
        XCTAssertGreaterThan(luminance(WaterRender.oceanMidColor),
                             luminance(WaterRender.oceanDeepColor))
        XCTAssertGreaterThan(luminance(WaterRender.oceanSurfColor),
                             luminance(WaterRender.oceanShallowColor))
    }

    func testOceanDepthWindowsStayInOrder() {
        XCTAssertGreaterThan(WaterRender.oceanDepthSpan, 0)
        XCTAssertGreaterThan(WaterRender.oceanSurfDepth, 0)
        XCTAssertLessThan(WaterRender.oceanSurfDepth, WaterRender.oceanBreakerDepth)
        XCTAssertLessThanOrEqual(WaterRender.oceanBreakerDepth, WaterRender.oceanMidDepth)
        XCTAssertGreaterThan(WaterRender.oceanBreakerWidth, 0)
        XCTAssertLessThan(2 * WaterRender.oceanBreakerWidth, WaterRender.oceanBreakerSpacing,
                          "Zwischen den Wellenkämmen bleibt offenes Wasser")
        XCTAssertTrue((0...1).contains(WaterRender.oceanBreakerStrength))
        XCTAssertTrue((0...1).contains(WaterRender.oceanShoalDepthVariation),
                      "Die Schlieren lassen die Schelftiefe positiv")
        XCTAssertLessThan(WaterRender.oceanMidDepth, 1)
        XCTAssertGreaterThan(WaterRender.oceanSurfStrength, 0)
        XCTAssertLessThanOrEqual(WaterRender.oceanSurfStrength, 1)
        XCTAssertLessThan(WaterRender.oceanSurfNoiseLo, WaterRender.oceanSurfNoiseHi)
        XCTAssertGreaterThan(WaterRender.oceanDepthSpan, WaterRender.lakeRawWetDepth)
    }

    func testOceanWavesFadeBeforeTheyAlias() {
        XCTAssertGreaterThan(WaterRender.oceanWaveFrequency, 0)
        XCTAssertGreaterThan(WaterRender.oceanWaveAmplitude, 0)
        XCTAssertGreaterThan(WaterRender.oceanWaveLacunarity, 1)
        XCTAssertLessThan(WaterRender.oceanWaveGain, 1)
        XCTAssertGreaterThan(WaterRender.oceanWaveGain, 0)
        XCTAssertLessThan(WaterRender.oceanWaveFadeLo, WaterRender.oceanWaveFadeHi)
        XCTAssertLessThanOrEqual(WaterRender.oceanWaveFadeHi, 1)
    }

    func testOceanShaderReadsTheOceanContract() throws {
        let ocean = try repoFile("game/shaders/ocean.gdshader")
        assertContains(ocean, "smoothstep(lo, max(hi, lo + 1e-6), x)",
                       hint: "Fenster-Helfer klemmt gegen edge0 >= edge1 (GLSL-UB, s. Terrain)")
        assertContains(ocean,
            "clamp((sea_level - h_shelf) / max(water_ocean_depth_span, 1e-6), 0.0, 1.0)",
            hint: "Tiefe über dem Schelf liest WaterRender.oceanDepthSpan (max: 0/0-Schutz)")
        assertContains(ocean,
            "calib_window(0.0, water_ocean_mid_depth, depth)",
            hint: "Rampe seicht → mittel liest WaterRender.oceanMidDepth")
        assertContains(ocean,
            "calib_window(water_ocean_mid_depth, 1.0, depth)",
            hint: "Rampe mittel → tief liest WaterRender.oceanMidDepth")
        assertContains(ocean,
            "1.0 - calib_window(0.0, water_ocean_surf_depth, line_depth)",
            hint: "Brandungssaum liest WaterRender.oceanSurfDepth")
        assertContains(ocean,
            "clamp((sea_level - h) / max(water_ocean_depth_span, 1e-6), 0.0, 1.0)",
            hint: "Saum misst die scharfe Wassersäule an der Küstenlinie (Hill-Climber Nr. 8)")
        assertContains(ocean,
            "clamp(1.0 - plume * water_ocean_surf_plume_cut, 0.0, 1.0)",
            hint: "Vor Mündungen keine Brandung (WaterRender.oceanSurfPlumeCut)")
        assertContains(ocean,
            "calib_window(water_ocean_surf_noise_lo, water_ocean_surf_noise_hi,",
            hint: "Brechung des Saums liest WaterRender.oceanSurfNoise*")
        assertContains(ocean,
            "1.0 - calib_window(water_ocean_wave_fade_lo, water_ocean_wave_fade_hi, footprint * freq)",
            hint: "Wellen blenden mit ihrer Pixelgröße aus (WaterRender.oceanWaveFade*)")
        assertContains(ocean, "length(fwidth(p))",
                       hint: "Pixelgröße der Welle aus den Bildschirm-Ableitungen")
        XCTAssertFalse(ocean.contains("sin("), "Ozean ohne Sinuswellen (#155: Streifenmuster)")
        XCTAssertFalse(ocean.contains("cos("), "Ozean ohne Kosinuswellen (#155: Streifenmuster)")
    }

    func testExtensionKeepsWaterCalibrationOutOfMarshalling() throws {
        let bridge = try RepoSource.extensionSources()
        XCTAssertFalse(
            bridge.contains("WaterRender."),
            "Die GDExtension darf im Code nicht auf `WaterRender.` verweisen; "
                + "Wasser-Kalibrierung und ihre Verwendung gehören nach SimRender"
        )
    }

    func testWaterRenderFunctionsHandleNonFiniteAndEdgeInputs() {
        let creek = 280.0

        XCTAssertEqual(WaterRender.cascadeWeight(slope: Double.nan), 0.0)
        XCTAssertEqual(WaterRender.cascadeWeight(slope: Double.infinity), 1.0)
        XCTAssertEqual(WaterRender.cascadeWeight(slope: -Double.infinity), 1.0)

        XCTAssertEqual(WaterRender.trackMask(streamMap: Double.nan), 0.0)
        XCTAssertEqual(WaterRender.trackMask(streamMap: Double.infinity), 1.0)
        XCTAssertEqual(WaterRender.trackMask(streamMap: -Double.infinity), 0.0)
        XCTAssertEqual(WaterRender.corridorMask(streamMap: Double.nan), 0.0)
        XCTAssertEqual(WaterRender.corridorMask(streamMap: Double.infinity), 1.0)
        XCTAssertEqual(WaterRender.corridorMask(streamMap: -Double.infinity), 0.0)

        XCTAssertEqual(WaterRender.trackWeight(mask: Double.nan), WaterRender.trackWeightFloor)
        XCTAssertEqual(WaterRender.trackWeight(mask: -1.0), WaterRender.trackWeightFloor)
        XCTAssertEqual(WaterRender.trackWeight(mask: -Double.infinity), WaterRender.trackWeightFloor)
        XCTAssertEqual(WaterRender.trackWeight(mask: Double.infinity), 1.0, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.corridorWeight(mask: Double.nan), WaterRender.corridorWeightFloor)
        XCTAssertEqual(WaterRender.corridorWeight(mask: -1.0), WaterRender.corridorWeightFloor)
        XCTAssertEqual(WaterRender.corridorWeight(mask: -Double.infinity), WaterRender.corridorWeightFloor)
        XCTAssertEqual(WaterRender.corridorWeight(mask: Double.infinity), 1.0, accuracy: 1e-12)

        XCTAssertGreaterThan(WaterRender.shore(stream: Double.nan, lakeGateChannel: 0.2, pond: 0.0), 0.0)
        XCTAssertGreaterThan(WaterRender.shore(stream: 0.2, lakeGateChannel: Double.nan, pond: 0.0), 0.0)
        XCTAssertEqual(WaterRender.shore(stream: Double.nan, lakeGateChannel: Double.nan, pond: 0.0), 0.0)

        XCTAssertEqual(WaterRender.ribbonStillWeight(kind: Double.nan), 0.0)
        XCTAssertEqual(WaterRender.ribbonStillWeight(kind: Double.infinity), 1.0)
        XCTAssertEqual(WaterRender.ribbonStillWeight(kind: -Double.infinity), 0.0)
        XCTAssertEqual(WaterRender.ribbonDeltaWeight(kind: Double.nan), 0.0)
        XCTAssertEqual(WaterRender.ribbonDeltaWeight(kind: Double.infinity), 0.0)
        XCTAssertEqual(WaterRender.ribbonDeltaWeight(kind: -Double.infinity), 0.0)

        XCTAssertEqual(WaterRender.ribbonHalfWidthCells(dischargeCells: Double.nan, referenceCells: creek),
                       WaterRender.ribbonHalfWidthFloorCells)
        XCTAssertEqual(WaterRender.ribbonHalfWidthCells(dischargeCells: creek, referenceCells: 0),
                       WaterRender.ribbonHalfWidthFloorCells)
        XCTAssertEqual(WaterRender.ribbonHalfWidthCells(dischargeCells: creek, referenceCells: -creek),
                       WaterRender.ribbonHalfWidthFloorCells)
        XCTAssertEqual(WaterRender.ribbonHalfWidthCells(dischargeCells: creek, referenceCells: Double.nan),
                       WaterRender.ribbonHalfWidthFloorCells)
        XCTAssertEqual(WaterRender.ribbonHalfWidthCells(dischargeCells: Double.infinity, referenceCells: creek),
                       WaterRender.ribbonHalfWidthCapCells)

        XCTAssertEqual(WaterRender.streamIntensity(dischargeCells: Double.nan, creekCells: creek),
                       WaterRender.streamIntensityBase)
        XCTAssertEqual(WaterRender.streamIntensity(dischargeCells: creek, creekCells: 0),
                       WaterRender.streamIntensityBase)
        XCTAssertEqual(WaterRender.streamIntensity(dischargeCells: creek, creekCells: -creek),
                       WaterRender.streamIntensityBase)
        XCTAssertEqual(WaterRender.streamIntensity(dischargeCells: creek, creekCells: Double.nan),
                       WaterRender.streamIntensityBase)
        XCTAssertEqual(WaterRender.streamIntensity(dischargeCells: Double.infinity, creekCells: creek), 1.0)

        XCTAssertEqual(WaterRender.stampHalfWidthCells(dischargeCells: creek, creekCells: 0),
                       WaterRender.stampHalfWidthBase)
        XCTAssertEqual(WaterRender.stampHalfWidthCells(dischargeCells: creek, creekCells: -creek),
                       WaterRender.stampHalfWidthBase)
        XCTAssertEqual(WaterRender.stampHalfWidthCells(dischargeCells: creek, creekCells: Double.nan),
                       WaterRender.stampHalfWidthBase)
        XCTAssertEqual(WaterRender.stampHalfWidthCells(dischargeCells: Double.nan, creekCells: creek),
                       WaterRender.stampHalfWidthBase)
        XCTAssertEqual(WaterRender.stampHalfWidthCells(dischargeCells: Double.infinity, creekCells: creek),
                       WaterRender.stampHalfWidthCapCells)

        XCTAssertEqual(WaterRender.stampIntensity(dischargeCells: creek, creekCells: 0),
                       WaterRender.stampIntensityBase)
        XCTAssertEqual(WaterRender.stampIntensity(dischargeCells: creek, creekCells: -creek),
                       WaterRender.stampIntensityBase)
        XCTAssertEqual(WaterRender.stampIntensity(dischargeCells: creek, creekCells: Double.nan),
                       WaterRender.stampIntensityBase)
        XCTAssertEqual(WaterRender.stampIntensity(dischargeCells: Double.nan, creekCells: creek),
                       WaterRender.stampIntensityBase)
        XCTAssertEqual(WaterRender.stampIntensity(dischargeCells: Double.infinity, creekCells: creek), 1.0)

        XCTAssertEqual(WaterRender.flowDetailIntensity(dischargeCells: Double.nan, creekCells: creek), 0.0)
        XCTAssertEqual(WaterRender.flowDetailIntensity(dischargeCells: 1.0, creekCells: creek), 0.0)
        XCTAssertGreaterThan(WaterRender.flowDetailIntensity(dischargeCells: 10.0, creekCells: Double.nan), 0.0)
        XCTAssertLessThanOrEqual(WaterRender.flowDetailIntensity(dischargeCells: 10.0, creekCells: Double.nan), 1.0)
    }

    private func repoFile(_ relativePath: String) throws -> SourceProbe {
        try RepoSource.probe(relativePath)
    }
}
