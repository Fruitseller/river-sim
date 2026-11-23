import XCTest
@testable import SimCore

final class RenderContractTests: XCTestCase {

    func testPausedIdleDisablesRenderLoop() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "RenderingServer.render_loop_enabled = false",
                       hint: "Pause-Leerlauf zeichnet keine Frames")
        assertContains(main, "RenderingServer.render_loop_enabled = true",
                       hint: "Eingabe weckt den Renderloop wieder auf")
        assertContains(main, "NOTIFICATION_WM_SIZE_CHANGED",
                       hint: "Fenster-Resize/Maximieren weckt den Renderloop (kein InputEvent)")
        assertContains(main, "NOTIFICATION_WM_WINDOW_FOCUS_IN",
                       hint: "Fokuswechsel weckt den Renderloop (kein InputEvent)")

        let code = main.code
        let exit = code.range(of: #"if idle:\s+return"#, options: .regularExpression)
        XCTAssertNotNil(exit,
                        "Leerlauf überspringt auch Shader-, Kamera- und Raycast-Arbeit")
        let toggle = code.range(of: "render_loop_suspended = idle")
        XCTAssertNotNil(toggle, "Leerlauf-Zustand schaltet den Renderloop um")
        let simStep = code.range(of: "if _simulation_should_step(")
        XCTAssertNotNil(simStep, "Sim-Schritt-Gate fehlt (s. testSculptingOwnsTheSimulationClock)")
        if let exit, let toggle, let simStep {
            XCTAssertLessThan(toggle.upperBound, exit.lowerBound,
                              "Der Leerlauf-Ausstieg muss nach dem Renderloop-Umschalter stehen")
            XCTAssertLessThan(exit.upperBound, simStep.lowerBound,
                              "Der Leerlauf-Ausstieg muss vor dem Sim-Schritt stehen")
        }
    }

    func testSculptingOwnsTheSimulationClock() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "if _simulation_should_step(year_rate, sculpting):",
                       hint: "Zeitraffer tritt während eines Werkzeugstrichs zurück")
    }

    func testTerrainDetailCounterbalancesVisualAging() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        let shader = try RepoSource.probe("game/shaders/terrain.gdshader")
        assertContains(main, "const TERRAIN_DETAIL_YOUNG := 0.16",
                       hint: "Jahr 0 überzeichnet die Rinnen nicht")
        assertContains(main, "const TERRAIN_DETAIL_OLD := 0.42",
                       hint: "100k behält sichtbare Reliefstruktur")
        assertContains(main, "const TERRAIN_DETAIL_AGE_YEARS := 100000.0",
                       hint: "Rampe endet am größten UI-Zeitsprung")
        assertContains(main, "func _upload_heights(bytes: PackedByteArray, year: float) -> void:",
                       hint: "Der Höhen-Upload kennt das Jahr seiner Höhen")
        assertContains(main,
                       "set_shader_parameter(\"detail_strength\", terrain_detail_strength(year))",
                       hint: "Shader-Kontrast folgt dem Sim-Alter der gezeigten Höhen")
        assertContains(main, "clampf(years / TERRAIN_DETAIL_AGE_YEARS, 0.0, 1.0)",
                       hint: "Detailkontrast bleibt vor Jahr 0 und nach 100k gedeckelt")
        assertContains(shader, "uniform float detail_strength = 0.16;",
                       hint: "Editor- und Jahr-0-Default stimmen überein")
    }

    func testTerrainDetailFollowsRealDischarge() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        let shader = try RepoSource.probe("game/shaders/terrain.gdshader")
        assertContains(main, "FieldTexture.new(\"flow_tex\", Image.FORMAT_R8, true)",
                       hint: "Abfluss-Dichte reist als R8-Textur")
        assertContains(main, "flow_field.upload(terrain_mat, N, frame[\"flow\"])",
                       hint: "Main lädt das Abfluss-Feld mit den Overlays hoch")
        assertContains(shader, "uniform sampler2D flow_tex",
                       hint: "Terrain-Shader kennt die Abfluss-Textur")
        assertContains(shader,
                       "mix(\(glsl(WaterRender.flowDetailGainLo)), "
                       + "\(glsl(WaterRender.flowDetailGainHi)), flow_at(v_uv))",
                       hint: "Stärke-Fenster == WaterRender.flowDetailGainLo/Hi")
    }

    func testHeightScaleIsTheSameInEveryLayer() throws {
        XCTAssertEqual(RenderContract.heightScale, 24.0)
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "terrain_mat.set_shader_parameter(\"hscale\", hscale)",
                       hint: "Shader-Uniform der Überhöhung == Main.gd hscale (Brücke)")
        let shader = try RepoSource.probe("game/shaders/terrain.gdshader")
        assertContains(shader, "uniform float hscale = \(glsl(RenderContract.heightScale));",
                       hint: "Shader-Default der Überhöhung == RenderContract.heightScale")
        for use in ["VERTEX.y = mix(hraw, hfv, lift) * hscale + relief_lift(uv) * (1.0 - lift);",
                    "NORMAL = normalize(vec3(-(hR - hL) * hscale, 2.0 * sw, -(hU - hD) * hscale));",
                    "vec3 n_ws = normalize(vec3(-s_uv.x * hscale / world_size, 1.0,"
                        + " -s_uv.y * hscale / world_size));",
                    "vec3 material_pos = vec3(wp.x - world_size * 0.5, hval * hscale,",
                    "float world_slope = length(coarse_slope) * hscale / world_size;"] {
            assertContains(shader, use,
                           hint: "Überhöhung wird unskaliert angewandt (keine Zusatzfaktoren)")
        }
        XCTAssertEqual(shader.count(of: "hscale"), 8,
                       "Neue oder entfernte `hscale`-Anwendung im Terrain-Shader —"
                       + " Liste der geprüften Stellen mitziehen")
        assertContains(main, "relief_mat.set_shader_parameter(\"hscale\", hscale)",
                       hint: "Back-Pass bekommt die Überhöhung aus Main.gd hscale")
        let bake = try RepoSource.probe("game/shaders/relief_bake.gdshader")
        assertContains(bake, "uniform float hscale;",
                       hint: "Back-Pass deklariert die Überhöhung default-frei")
        assertContains(bake, "relief = vec4((det.x + rib.x + ridge) * hscale,",
                       hint: "Überhöhung wird im Back-Pass unskaliert angewandt")
        assertContains(bake, "float cap = relief_ridge_cap / hscale;",
                       hint: "Gratdeckel steht in Welteinheiten (ReliefRender.ridgeCap)")
        assertContains(bake, "float wslope = length(slope) * hscale / max(world_size, 1e-6);",
                       hint: "Felsrippen wachsen mit der WELTsteigung (ReliefRender.ribSlopeLo/Hi)")
        assertContains(bake, "float bp = fract(h * hscale / max(relief_bench_spacing, 1e-6)",
                       hint: "Felsbänke stehen in Welt-Höhe (ReliefRender.benchSpacing)")
        XCTAssertEqual(bake.count(ofIdentifier: "hscale"), 5,
                       "Neue oder entfernte `hscale`-Anwendung im Back-Pass")
    }

    func testRiverLiftIsTheSameInEveryLayer() throws {
        XCTAssertEqual(RenderContract.riverLift, 0.35)
        XCTAssertLessThan(WaterRender.ribbonLakeSurfaceLift, RenderContract.riverLift)
        XCTAssertLessThan(abs(WaterRender.ribbonSeaSurfaceSink), RenderContract.riverLift)
    }

    func testOceanUsesAValidAlphaDepthPrepass() throws {
        let ocean = try RepoSource.probe("game/shaders/ocean.gdshader")
        assertContains(ocean,
                       "render_mode blend_mix, depth_prepass_alpha, cull_disabled;",
                       hint: "Ozean-Shader verwendet Godot-4-Rendermodus")
    }

    func testOceanClipsItsPlaneBelowLand() throws {
        let ocean = try RepoSource.probe("game/shaders/ocean.gdshader")
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(ocean, "uniform sampler2D height_tex",
                       hint: "Ozean liest dasselbe Höhenfeld wie das Terrain")
        assertContains(ocean, "if (inside_terrain) {",
                       hint: "Ozean liest die Höhe nur innerhalb des Terrain-Quadrats")
        assertContains(ocean, "h = texture(height_tex, terrain_uv).r;",
                       hint: "Küstenlinie bilinear wie im Terrain (nicht über den Schelf-B-Spline)")
        assertContains(ocean, "if (h > sea_level)",
                       hint: "Land schneidet die Ozeanplatte ab")
        assertContains(main, "height_field.mirror_to(ocean_mat)",
                       hint: "Main bindet die Höhentextur auch an den Ozean")
        assertContains(main, "ocean_mat.set_shader_parameter(\"sea_level\", sea)",
                       hint: "Ozean und Terrain verwenden denselben Meeresspiegel")
        assertContains(main, "wp.size = Vector2(cam.far * 3.0, cam.far * 3.0)",
                       hint: "Ozeanrand liegt bei jeder erlaubten Kamera hinter dem Far-Clip")
        assertContains(ocean, "ALPHA = 1.0;",
                       hint: "Offenes Meer verbirgt die rechteckige Terrain-Unterseite")
    }

    func testDefaultSeedIsTheSameInEveryLayer() throws {
        XCTAssertEqual(RenderContract.defaultSeed, 1337)
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "var sim_seed := \(RenderContract.defaultSeed)",
                       hint: "Start-Seed der Anzeige == RenderContract.defaultSeed")
        let bridge = try RepoSource.extensionSources()
        assertContains(bridge, "seed: RenderContract.defaultSeed",
                       hint: "Erstes Terrain der GDExtension == RenderContract.defaultSeed")
    }

    func testBothBridgeGeneratePathsSettle() throws {
        let bridge = try RepoSource.extensionSources()
        assertContains(bridge, "settleYears: SimConfig.productionSettleYears",
                       hint: "Start-Terrain läuft ein")
        XCTAssertEqual(bridge.count(of: "settleYears: SimConfig.productionSettleYears"), 2,
                       "Beide generate-Wege der Brücke (Init + @Callable) laufen ein")
    }

    func testBridgeReadsTheOneProductionConfig() throws {
        let bridge = try RepoSource.extensionSources()
        assertContains(bridge, "config: SimConfig.production",
                       hint: "Start-Terrain der Brücke fährt SimConfig.production")
        for flag in ["hydraulicSkipWaterSpawns", "meanderSpatialCutoffIndex"] {
            XCTAssertEqual(bridge.count(ofIdentifier: flag), 0,
                           "Die Brücke setzt \(flag) wieder von Hand — der Schalter "
                           + "gehört in SimConfig.production")
        }
        XCTAssertEqual(bridge.count(ofIdentifier: "productionConfig"), 0,
                       "Die Brücke baut wieder eine eigene Produktions-Config")
        XCTAssertEqual(bridge.count(ofIdentifier: "generationSettleYears"), 0,
                       "Die Brücke hält den Einlauf wieder selbst — er steht in "
                       + "SimConfig.productionSettleYears")
    }

    func testProductionConfigIsTheDefaultsPlusTheTwoPerformanceFlags() {
        var expected = SimConfig()
        expected.hydraulicSkipWaterSpawns = true
        expected.meanderSpatialCutoffIndex = true
        XCTAssertEqual(SimConfig.production, expected,
                       "SimConfig.production weicht über die zwei Perf-Schalter "
                       + "hinaus von SimConfig() ab")
        XCTAssertEqual(SimConfig.productionSettleYears, 3000)

        var custom = SimConfig()
        custom.enableProductionPerformance()
        XCTAssertEqual(custom, SimConfig.production,
                       "enableProductionPerformance() auf SimConfig() muss genau SimConfig.production entsprechen")

        var nonDefault = SimConfig()
        nonDefault.n = 832
        nonDefault.world = 130
        nonDefault.enableProductionPerformance()
        XCTAssertTrue(nonDefault.hydraulicSkipWaterSpawns)
        XCTAssertTrue(nonDefault.meanderSpatialCutoffIndex)
        XCTAssertEqual(nonDefault.n, 832)
        XCTAssertEqual(nonDefault.world, 130)
    }

    func testNoStaleSimNodeConfigReferencesInSimCore() throws {
        for path in ["SimCore/Sources/SimCore/Terrain.swift",
                     "SimCore/Sources/SimCore/Config.swift",
                     "SimCore/Sources/SimPerf/main.swift"] {
            let content = try RepoSource.file(path)
            XCTAssertFalse(content.contains("SimNode.generationSettleYears"),
                           "\(path) verweist noch auf SimNode.generationSettleYears")
            XCTAssertFalse(content.contains("SimNode.productionConfig"),
                           "\(path) verweist noch auf SimNode.productionConfig")
        }
    }

    func testTerrainDefaultSeedMatchesTheContract() {
        var cfg = SimConfig()
        cfg.n = 96; cfg.world = calibrationWorld
        let implicitSeed = Terrain(config: cfg)
        let explicitSeed = Terrain(config: cfg, seed: RenderContract.defaultSeed)
        XCTAssertEqual(implicitSeed.h, explicitSeed.h,
                       "Terrain-Default-Seed weicht von RenderContract.defaultSeed ab")
    }
}
