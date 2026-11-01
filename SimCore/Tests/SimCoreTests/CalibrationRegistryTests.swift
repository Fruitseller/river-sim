import XCTest
@testable import SimCore
import SimRender

/// Wächter für das Kalibrier-Register der Brücke (Issue #213).
///
/// Das Register vergibt nur Namen, die Zahlen stehen in den SimCore-Verträgen.
/// Gepinnt wird:
///   - der EINE Name-Wert-Spiegel über alle Gruppen, vollständig und in beide
///     Richtungen (ein Eintrag mit eigener Zahl, vertauschten Konstanten oder
///     ohne Spiegel-Zeile fällt auf),
///   - Präfixe und Eindeutigkeit der Namen,
///   - jede Uniform-Gruppe ist in den Shadern default-frei deklariert und
///     gelesen, und kein Shader deklariert eine Kalibrier-Uniform am Register
///     vorbei,
///   - EIN generischer Zugang in der Brücke, EINE Anwendung in `Main.gd`,
///     keine kopierten Render-Vertragswerte mehr in GDScript.
/// WO welcher Wert gelesen wird, pinnen die Fachtests (`WaterUniformsTests`,
/// `ReliefUniformsTests`); dass die Werte in Godot ankommen, End-to-End
/// `game/tests/water_uniforms.gd`, `relief.gd` und `canopy.gd`.
final class CalibrationRegistryTests: XCTestCase {

    typealias Value = CalibrationRegistry.Value

    /// Shader, die Kalibrier-Uniforms deklarieren dürfen.
    private static let shaders = [
        "game/shaders/terrain.gdshader",
        "game/shaders/water.gdshader",
        "game/shaders/ocean.gdshader",
        "game/shaders/relief_bake.gdshader",
    ]

    private static func color(_ c: (r: Double, g: Double, b: Double)) -> Value {
        .color(r: c.r, g: c.g, b: c.b)
    }

    /// Der Spiegel: Gruppe → Name → Konstante aus dem SimCore-Vertrag.
    private static let mirror: [CalibrationRegistry.Group: [String: Value]] = [
        .water: [
            "water_lake_gate_lo": .scalar(WaterRender.lakeGateLo),
            "water_lake_gate_hi": .scalar(WaterRender.lakeGateHi),
            "water_river_mask_lo": .scalar(WaterRender.riverMaskLo),
            "water_river_mask_hi": .scalar(WaterRender.riverMaskHi),
            "water_river_depth_lo": .scalar(WaterRender.riverDepthLo),
            "water_river_depth_hi": .scalar(WaterRender.riverDepthHi),
            "water_shore_lo": .scalar(WaterRender.shoreLo),
            "water_shore_hi": .scalar(WaterRender.shoreHi),
            "water_pond_contour_lo": .scalar(WaterRender.pondContourLo),
            "water_pond_contour_hi": .scalar(WaterRender.pondContourHi),
            "water_geometry_lift_lo": .scalar(WaterRender.geometryLiftLo),
            "water_geometry_lift_hi": .scalar(WaterRender.geometryLiftHi),
            "water_lake_depth_lo": .scalar(WaterRender.lakeDepthLo),
            "water_lake_depth_span": .scalar(WaterRender.lakeDepthSpan),
            "water_ribbon_still_lo": .scalar(WaterRender.ribbonStillLo),
            "water_ribbon_still_hi": .scalar(WaterRender.ribbonStillHi),
            "water_ribbon_delta_lo": .scalar(WaterRender.ribbonDeltaLo),
            "water_ribbon_delta_hi": .scalar(WaterRender.ribbonDeltaHi),
            "water_fresnel_exponent": .scalar(WaterRender.fresnelExponent),
            "water_opacity_shallow": .scalar(WaterRender.waterOpacityShallow),
            "water_opacity_deep": .scalar(WaterRender.waterOpacityDeep),
            "water_roughness": .scalar(WaterRender.waterRoughness),
            "water_specular": .scalar(WaterRender.waterSpecular),
            "water_ocean_depth_span": .scalar(WaterRender.oceanDepthSpan),
            "water_ocean_mid_depth": .scalar(WaterRender.oceanMidDepth),
            "water_ocean_surf_depth": .scalar(WaterRender.oceanSurfDepth),
            "water_ocean_surf_slope_lo": .scalar(WaterRender.oceanSurfSlopeLo),
            "water_ocean_surf_slope_hi": .scalar(WaterRender.oceanSurfSlopeHi),
            "water_ocean_surf_strength": .scalar(WaterRender.oceanSurfStrength),
            "water_ocean_surf_scale": .scalar(WaterRender.oceanSurfScale),
            "water_ocean_surf_drift": .scalar(WaterRender.oceanSurfDrift),
            "water_ocean_surf_noise_lo": .scalar(WaterRender.oceanSurfNoiseLo),
            "water_ocean_surf_noise_hi": .scalar(WaterRender.oceanSurfNoiseHi),
            "water_ocean_wave_frequency": .scalar(WaterRender.oceanWaveFrequency),
            "water_ocean_wave_amplitude": .scalar(WaterRender.oceanWaveAmplitude),
            "water_ocean_wave_lacunarity": .scalar(WaterRender.oceanWaveLacunarity),
            "water_ocean_wave_gain": .scalar(WaterRender.oceanWaveGain),
            "water_ocean_wave_fade_lo": .scalar(WaterRender.oceanWaveFadeLo),
            "water_ocean_wave_fade_hi": .scalar(WaterRender.oceanWaveFadeHi),
            "water_ocean_wave_drift_x": .scalar(WaterRender.oceanWaveDriftX),
            "water_ocean_wave_drift_z": .scalar(WaterRender.oceanWaveDriftZ),
            "water_ocean_wave_octave_speedup": .scalar(WaterRender.oceanWaveOctaveSpeedup),
            "water_ocean_plume_lod": .scalar(WaterRender.oceanPlumeLod),
            "water_ocean_plume_opacity": .scalar(WaterRender.oceanPlumeOpacity),
            "water_ribbon_bend_depth": .scalar(WaterRender.ribbonBendDepth),
            "water_ribbon_shoal_mix": .scalar(WaterRender.ribbonShoalMix),
            "water_bar_roughness": .scalar(WaterRender.barRoughness),
            "water_ribbon_waterline": .scalar(WaterRender.ribbonWaterline),
            "water_ribbon_waterline_jitter": .scalar(WaterRender.ribbonWaterlineJitter),
            "water_ribbon_waterline_scale": .scalar(WaterRender.ribbonWaterlineScale),
            "water_ribbon_bank_opacity": .scalar(WaterRender.ribbonBankOpacity),
            "water_ribbon_ripple_frequency": .scalar(WaterRender.ribbonRippleFrequency),
            "water_ribbon_ripple_amplitude": .scalar(WaterRender.ribbonRippleAmplitude),
            "water_ribbon_ripple_stretch": .scalar(WaterRender.ribbonRippleStretch),
            "water_ribbon_ripple_speed": .scalar(WaterRender.ribbonRippleSpeed),
            "water_ribbon_fade_cap": .scalar(WaterRender.ribbonFadeOpacityCap),
            "water_wall_slope_lo": .scalar(WaterRender.rasterWallSlopeLo),
            "water_wall_slope_hi": .scalar(WaterRender.rasterWallSlopeHi),
            "water_shallow_color": color(WaterRender.waterShallowColor),
            "water_deep_color": color(WaterRender.waterDeepColor),
            "water_flow_shimmer_color": color(WaterRender.flowShimmerColor),
            "water_delta_plume_color": color(WaterRender.deltaPlumeColor),
            "water_oxbow_water_color": color(WaterRender.oxbowWaterColor),
            "water_ocean_shallow_color": color(WaterRender.oceanShallowColor),
            "water_ocean_mid_color": color(WaterRender.oceanMidColor),
            "water_ocean_deep_color": color(WaterRender.oceanDeepColor),
            "water_ocean_surf_color": color(WaterRender.oceanSurfColor),
            "water_ocean_plume_color": color(WaterRender.oceanPlumeColor),
            "water_ribbon_shoal_color": color(WaterRender.ribbonShoalColor),
            "water_bar_sand_color": color(WaterRender.barSandColor),
            "water_bar_sand_wet_color": color(WaterRender.barSandWetColor),
            "water_ribbon_bank_color": color(WaterRender.ribbonBankColor),
            "water_bed_color": color(WaterRender.waterBedColor),
        ],
        .waterContract: [
            "ribbonKindRiver": .scalar(WaterRender.ribbonKindRiver),
            "ribbonKindDelta": .scalar(WaterRender.ribbonKindDelta),
            "ribbonKindOxbow": .scalar(WaterRender.ribbonKindOxbow),
            "pondContourLo": .scalar(WaterRender.pondContourLo),
            "lakeRawWetDepth": .scalar(WaterRender.lakeRawWetDepth),
            "oxbowMaximumOpacity": .scalar(WaterRender.oxbowMaximumOpacity),
            "mouthSearchCells": .scalar(Double(WaterRender.mouthSearchCells)),
            "ribbonLakeSurfaceLift": .scalar(WaterRender.ribbonLakeSurfaceLift),
            "ribbonSeaSurfaceSink": .scalar(WaterRender.ribbonSeaSurfaceSink),
            "ribbonMinimumRank": .scalar(WaterRender.ribbonMinimumRank),
            "ribbonMaxCrossSlope": .scalar(WaterRender.ribbonMaxCrossSlope),
            "ribbonDeltaLo": .scalar(WaterRender.ribbonDeltaLo),
            "ribbonJoinCoverage": .scalar(WaterRender.ribbonJoinCoverage),
        ],
        .relief: [
            "relief_scale": .scalar(ReliefRender.scale),
            "relief_strength": .scalar(ReliefRender.strength),
            "relief_sharpen": .scalar(ReliefRender.sharpen),
            "relief_sharpen_radius": .scalar(ReliefRender.sharpenRadiusCells),
            "relief_ridge_cap": .scalar(ReliefRender.ridgeCap),
            "relief_geometry_age": .scalar(ReliefRender.geometryAgeYears),
            "relief_height_code": .scalar(ReliefRender.heightCode),
            "relief_slope_code": .scalar(ReliefRender.slopeCode),
            "relief_shade_dark": .scalar(ReliefRender.shadeDark),
            "relief_shade_light": .scalar(ReliefRender.shadeLight),
            "relief_cavity_gully_gain": .scalar(ReliefRender.cavityGullyGain),
            "relief_cavity_ridge_gain": .scalar(ReliefRender.cavityRidgeGain),
            "relief_detail_scale": .scalar(ReliefRender.detailScale),
            "relief_detail_shade": .scalar(ReliefRender.detailShade),
            "relief_detail_normal": .scalar(ReliefRender.detailNormal),
        ],
        .canopy: [
            "canopy_cell": .scalar(CanopyRender.crownCell),
            "canopy_height": .scalar(CanopyRender.canopyHeight),
            "canopy_lift_lo": .scalar(CanopyRender.liftLo),
            "canopy_lift_hi": .scalar(CanopyRender.liftHi),
            "canopy_cover_lo": .scalar(CanopyRender.coverLo),
            "canopy_cover_hi": .scalar(CanopyRender.coverHi),
            "canopy_gap_lo": .scalar(CanopyRender.gapLo),
            "canopy_gap_hi": .scalar(CanopyRender.gapHi),
            "canopy_crown_mid": .scalar(CanopyRender.crownMid),
            "canopy_crown_spread": .scalar(CanopyRender.crownSpread),
            "canopy_crown_radius": .scalar(CanopyRender.crownRadius),
            "canopy_crown_radius_jitter": .scalar(CanopyRender.crownRadiusJitter),
            "canopy_detail_lo": .scalar(CanopyRender.detailFootprintLo),
            "canopy_detail_hi": .scalar(CanopyRender.detailFootprintHi),
            "canopy_meadow_lo": .scalar(CanopyRender.meadowLo),
            "canopy_meadow_hi": .scalar(CanopyRender.meadowHi),
            "canopy_meadow_share": .scalar(CanopyRender.meadowShare),
        ],
        .material: [
            "material_ridge_rock_gain": .scalar(MaterialRender.ridgeRockGain),
            "material_gully_scree_share": .scalar(MaterialRender.gullyScreeShare),
            "material_joint_spacing": .scalar(MaterialRender.jointSpacing),
            "material_joint_stretch": .scalar(MaterialRender.jointStretch),
            "material_joint_turn_cos": .scalar(MaterialRender.jointTurnCos),
            "material_joint_turn_sin": .scalar(MaterialRender.jointTurnSin),
            "material_joint_depth": .scalar(MaterialRender.jointDepth),
            "material_joint_gully_gain": .scalar(MaterialRender.jointGullyGain),
            "material_joint_relief": .scalar(MaterialRender.jointRelief),
            "material_rock_relief_gain": .scalar(MaterialRender.rockReliefGain),
            "material_scree_grain": .scalar(MaterialRender.screeGrain),
            "material_crevasse_spacing": .scalar(MaterialRender.crevasseSpacing),
            "material_crevasse_slope_lo": .scalar(MaterialRender.crevasseSlopeLo),
            "material_crevasse_slope_hi": .scalar(MaterialRender.crevasseSlopeHi),
            "material_moraine_lo": .scalar(MaterialRender.moraineLo),
            "material_moraine_hi": .scalar(MaterialRender.moraineHi),
        ],
        .contract: [
            "heightScale": .scalar(RenderContract.heightScale),
            "riverLift": .scalar(RenderContract.riverLift),
        ],
    ]

    func testEveryEntryCarriesItsContractConstant() {
        XCTAssertEqual(Set(Self.mirror.keys), Set(CalibrationRegistry.Group.allCases),
                       "Gruppe ohne Spiegel (oder umgekehrt)")
        for group in CalibrationRegistry.Group.allCases {
            let entries = CalibrationRegistry.entries(group)
            let expected = Self.mirror[group] ?? [:]
            XCTAssertFalse(entries.isEmpty, "\(group.rawValue): leere Gruppe")
            XCTAssertEqual(entries.count, expected.count,
                           "\(group.rawValue): Eintrag ohne Spiegel-Zeile (oder umgekehrt)")
            for entry in entries {
                XCTAssertEqual(entry.value, expected[entry.name],
                               "\(group.rawValue)/\(entry.name) trägt nicht seine Vertrags-Konstante")
            }
        }
    }

    func testNamesAreUniqueAndUniformGroupsCarryTheirPrefix() {
        for group in CalibrationRegistry.Group.allCases {
            let names = CalibrationRegistry.entries(group).map(\.name)
            XCTAssertEqual(names.count, Set(names).count, "\(group.rawValue): Namen kollidieren")
        }
        // Alle Uniform-Gruppen landen auf denselben Materialien (das Terrain
        // liest vier davon): der Präfix hält sie auseinander und von den
        // übrigen Uniforms (hscale, sea_level, …) fern.
        for entry in CalibrationRegistry.entries where entry.group.isUniform {
            XCTAssertTrue(entry.name.hasPrefix(entry.group.rawValue + "_"),
                          "\(entry.name): Uniform-Name ohne Präfix \(entry.group.rawValue)_")
        }
    }

    func testShadersDeclareExactlyTheUniformGroupsDefaultFree() throws {
        let uniforms = CalibrationRegistry.entries.filter(\.group.isUniform)
        let byName = Dictionary(uniqueKeysWithValues: uniforms.map { ($0.name, $0) })
        let prefixes = CalibrationRegistry.Group.allCases.filter(\.isUniform)
            .map(\.rawValue).joined(separator: "|")
        var declared = Set<String>()
        for path in Self.shaders {
            let shader = try RepoSource.probe(path)
            // Typ BREIT matchen und dann prüfen: eine künftige `uniform vec2
            // water_*` soll laut scheitern, nicht still am Wächter vorbei.
            let found = try shader.pairs(
                pattern: "uniform\\s+([A-Za-z0-9_]+)\\s+((?:\(prefixes))_[A-Za-z0-9_]+)")
            for (kind, name) in found {
                // Texturen und Schalter sind keine Kalibrier-Zahlen.
                if kind.hasPrefix("sampler") || kind == "bool" { continue }
                guard let entry = byName[name] else {
                    XCTFail("\(path) deklariert \(name) am Kalibrier-Register vorbei — "
                            + "der Wert bliebe still auf seinem Null-Default stehen")
                    continue
                }
                switch (kind, entry.value) {
                case ("float", .scalar), ("vec3", .color): break
                default:
                    XCTFail("\(path): \(name) ist als \(kind) deklariert, "
                            + "das Register führt \(entry.value)")
                }
                // Ein Literal-Default wäre wieder eine Kopie der Kalibrierung (#92).
                assertContains(shader, "uniform \(kind) \(name);",
                               hint: "\(path): \(name) default-frei deklariert")
                // Deklaration + mindestens eine Lesung; als GANZER Bezeichner
                // gezählt (Review zu #105).
                XCTAssertGreaterThanOrEqual(shader.count(ofIdentifier: name), 2,
                                            "\(path): \(name) wird deklariert, aber nie gelesen")
                declared.insert(name)
            }
        }
        for entry in uniforms {
            XCTAssertTrue(declared.contains(entry.name),
                          "\(entry.name) wird von keinem Shader deklariert (toter Kanal)")
        }
    }

    func testBridgeHasOneGenericAccess() throws {
        // Die GDExtension bleibt reines Marshalling: EIN Callable für alle
        // Gruppen statt zwei je Tabelle, keine eigenen Namen oder Zahlen.
        let bridge = try RepoSource.extensionSources()
        assertContains(bridge, "@Callable func calibration(group: String) -> VariantDictionary",
                       hint: "Brücke bietet den generischen Zugang je Gruppe")
        assertContains(bridge, "CalibrationRegistry.Group(rawValue: group)",
                       hint: "Brücke löst die Gruppe über das Register auf")
        for gone in ["UniformNames", "UniformValues", "waterContractNames", "waterContractValues"] {
            XCTAssertFalse(bridge.contains(gone),
                           "\(gone): die Einzel-Callables sind im Register aufgegangen (#213)")
        }
    }

    func testMainAppliesEveryGroupThroughOneFunction() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "static func calibration(sim_node: Object, group: String) -> Dictionary:",
                       hint: "Main.gd liest eine Gruppe über die Brücke")
        assertContains(main, "static func apply_calibration(",
                       hint: "Main.gd wendet eine Gruppe generisch auf Materialien an")
        assertContains(main, "apply_calibration(sim, \"water\", water_mats)",
                       hint: "alle Wasser-Materialien werden kalibriert")
        assertContains(main, "apply_calibration(sim, \"relief\", [relief_mat, terrain_mat])",
                       hint: "Back-Pass und Terrain bekommen die Relief-Gruppe")
        assertContains(main, "apply_calibration(sim, \"canopy\", [terrain_mat])",
                       hint: "Terrain bekommt die Kronen-Gruppe")
        assertContains(main, "apply_calibration(sim, \"material\", [terrain_mat])",
                       hint: "Terrain bekommt die Material-Gruppe")
        for gone in ["apply_water_calibration", "relief_calibration(", "canopy_calibration(",
                     "material_calibration("] {
            XCTAssertFalse(main.contains(gone), "\(gone): kopierte Variante ist weg (#213)")
        }
    }

    func testRenderContractComesOverTheBridge() throws {
        // Bis #213 standen Überhöhung und Band-Anhebung als Literale in
        // Main.gd (`HSCALE`, `RIVER_LIFT`), von Grep-Wächtern auf die Zahl
        // gehalten. Jetzt holt GDScript sie aus der Gruppe `contract`; welche
        // Zahl sie tragen, pinnt der Spiegel oben.
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "calibration(sim, \"contract\")[\"heightScale\"]",
                       hint: "Main.gd holt die Überhöhung über die Brücke")
        for gone in ["HSCALE", "RIVER_LIFT"] {
            XCTAssertFalse(main.contains(gone), "Main.gd führt \(gone) nicht mehr als Kopie")
        }
        for path in ["game/tests/render_fingerprint.gd", "game/tests/sculpt_cost.gd",
                     "game/tests/river_ribbons.gd", "game/tests/water_geometry.gd"] {
            let script = try RepoSource.probe(path)
            assertContains(script, "Main.calibration(sim, \"contract\")",
                           hint: "\(path) holt Überhöhung und Band-Anhebung über die Brücke")
            XCTAssertFalse(script.contains("RIVER_LIFT"),
                           "\(path): Band-Anhebung nicht als Kopie")
        }
    }

    func testGodotGuardsReadTheWaterContractOverTheBridge() throws {
        // Die beiden Godot-Wasser-Wächter prüfen gegen Zahlen aus der Gruppe
        // `water_contract`; welchen Wert ein Name trägt, pinnt der Spiegel.
        for path in ["game/tests/water_geometry.gd", "game/tests/river_ribbons.gd"] {
            let script = try RepoSource.probe(path)
            assertContains(script, "Main.calibration(sim, \"water_contract\")",
                           hint: "\(path) holt die Vertragswerte über die Brücke")
        }
    }
}
