import SimCore

/// Das EINE Kalibrier-Register der Brücke (Issue #213): benannte Werte in
/// Gruppen, die alle denselben Weg nehmen (`SimNode.calibration(group)` →
/// `Main.calibration`/`Main.apply_calibration`). Es ersetzt die vier gleich
/// gebauten Tabellen `WaterUniforms`, `ReliefUniforms`, `CanopyUniforms` und
/// `MaterialUniforms` samt ihrer zwölf Callables.
///
/// Das Register vergibt nur NAMEN. Die einzige Quelle der Zahlen bleiben die
/// SimCore-Verträge (`WaterRender`, `ReliefRender`, `CanopyRender`,
/// `MaterialRender`, `RenderContract`); eine eigene Zahl hier wäre wieder die
/// Kopie, die #51/#92 abgeschafft haben.
///
/// Zwei Arten von Gruppen (`Group.isUniform`):
///  - Uniform-Gruppen (`water`, `relief`, `canopy`, `material`): jeder Name
///    trägt den Gruppen-Präfix und setzt eine gleichnamige Shader-Uniform. Die
///    Shader deklarieren sie OHNE Default (#92): die Editor-Vorschau ohne
///    SimNode ist bewusst unkalibriert (alles Null); damit das nur
///    unkalibriert heißt und nicht undefiniert, klemmen die Wasser-Shader ihre
///    Fenster, Divisionen und den Fresnel-Exponenten per Epsilon
///    (`calib_window`/`max`, Review zu #105), gepinnt in `WaterRenderTests`.
///  - Vertragsgruppen (`water_contract`, `contract`): keine Uniforms, sondern
///    Zahlen, die GDScript selbst braucht (Godot-Wächter, Überhöhung). Die
///    Namen sind die Swift-Bezeichner, damit die Paarung lesbar bleibt.
///
/// Wächter: `SimCoreTests/CalibrationRegistryTests.swift` (der eine
/// Name-Wert-Spiegel, Präfixe, default-freie Deklarationen, Brücke, `Main.gd`)
/// und End-to-End `game/tests/water_uniforms.gd`, `relief.gd`, `canopy.gd`
/// (jede deklarierte Uniform wird gesetzt).
public enum CalibrationRegistry {

    public enum Group: String, CaseIterable, Sendable {
        case water
        case waterContract = "water_contract"
        case relief
        case canopy
        case material
        case contract

        /// Setzt die Gruppe Shader-Uniforms (Präfix `<gruppe>_`)?
        public var isUniform: Bool {
            switch self {
            case .water, .relief, .canopy, .material: return true
            case .waterContract, .contract: return false
            }
        }
    }

    /// `scalar` reist als `float`, `color` als `vec3` (Godot `Vector3`).
    public enum Value: Equatable, Sendable {
        case scalar(Double)
        case color(r: Double, g: Double, b: Double)
    }

    public struct Entry: Sendable {
        public let group: Group
        public let name: String
        public let value: Value
    }

    /// Alle Einträge, gruppenweise in Deklarationsreihenfolge.
    public static let entries: [Entry] =
        water + waterContract + relief + canopy + material + contract

    /// Die Einträge EINER Gruppe in Deklarationsreihenfolge.
    public static func entries(_ group: Group) -> [Entry] {
        entries.filter { $0.group == group }
    }

    // MARK: water — Wasser-Kalibrierung aller drei Wasser-Shader (#91/#92)

    private static let water: [Entry] = scalars(.water, [
        // Fenster, mit denen terrain.gdshader die Wasser-Kanäle liest.
        ("water_lake_gate_lo", WaterRender.lakeGateLo),
        ("water_lake_gate_hi", WaterRender.lakeGateHi),
        ("water_river_mask_lo", WaterRender.riverMaskLo),
        ("water_river_mask_hi", WaterRender.riverMaskHi),
        ("water_river_depth_lo", WaterRender.riverDepthLo),
        ("water_river_depth_hi", WaterRender.riverDepthHi),
        ("water_shore_lo", WaterRender.shoreLo),
        ("water_shore_hi", WaterRender.shoreHi),
        ("water_pond_contour_lo", WaterRender.pondContourLo),
        ("water_pond_contour_hi", WaterRender.pondContourHi),
        ("water_geometry_lift_lo", WaterRender.geometryLiftLo),
        ("water_geometry_lift_hi", WaterRender.geometryLiftHi),
        ("water_lake_depth_lo", WaterRender.lakeDepthLo),
        ("water_lake_depth_span", WaterRender.lakeDepthSpan),
        // Typ-Kanal-Fenster der Band-Geometrie (water.gdshader).
        ("water_ribbon_still_lo", WaterRender.ribbonStillLo),
        ("water_ribbon_still_hi", WaterRender.ribbonStillHi),
        ("water_ribbon_delta_lo", WaterRender.ribbonDeltaLo),
        ("water_ribbon_delta_hi", WaterRender.ribbonDeltaHi),
        // Gemeinsame Wasser-Optik aller drei Shader.
        ("water_fresnel_exponent", WaterRender.fresnelExponent),
        ("water_opacity_shallow", WaterRender.waterOpacityShallow),
        ("water_opacity_deep", WaterRender.waterOpacityDeep),
        ("water_roughness", WaterRender.waterRoughness),
        ("water_specular", WaterRender.waterSpecular),
        // Offenes Meer (ocean.gdshader, #155).
        ("water_ocean_depth_span", WaterRender.oceanDepthSpan),
        ("water_ocean_mid_depth", WaterRender.oceanMidDepth),
        ("water_ocean_surf_depth", WaterRender.oceanSurfDepth),
        ("water_ocean_surf_slope_lo", WaterRender.oceanSurfSlopeLo),
        ("water_ocean_surf_slope_hi", WaterRender.oceanSurfSlopeHi),
        ("water_ocean_surf_strength", WaterRender.oceanSurfStrength),
        ("water_ocean_surf_scale", WaterRender.oceanSurfScale),
        ("water_ocean_surf_drift", WaterRender.oceanSurfDrift),
        ("water_ocean_surf_noise_lo", WaterRender.oceanSurfNoiseLo),
        ("water_ocean_surf_noise_hi", WaterRender.oceanSurfNoiseHi),
        ("water_ocean_wave_frequency", WaterRender.oceanWaveFrequency),
        ("water_ocean_wave_amplitude", WaterRender.oceanWaveAmplitude),
        ("water_ocean_wave_lacunarity", WaterRender.oceanWaveLacunarity),
        ("water_ocean_wave_gain", WaterRender.oceanWaveGain),
        ("water_ocean_wave_fade_lo", WaterRender.oceanWaveFadeLo),
        ("water_ocean_wave_fade_hi", WaterRender.oceanWaveFadeHi),
        ("water_ocean_wave_drift_x", WaterRender.oceanWaveDriftX),
        ("water_ocean_wave_drift_z", WaterRender.oceanWaveDriftZ),
        ("water_ocean_wave_octave_speedup", WaterRender.oceanWaveOctaveSpeedup),
        // Sedimentfahne (ocean.gdshader, #174 C).
        ("water_ocean_plume_lod", WaterRender.oceanPlumeLod),
        ("water_ocean_plume_opacity", WaterRender.oceanPlumeOpacity),
        // Mäandergürtel (#174 C2): Querprofil im Band, Bank-Material im Terrain.
        ("water_ribbon_bend_depth", WaterRender.ribbonBendDepth),
        ("water_ribbon_shoal_mix", WaterRender.ribbonShoalMix),
        ("water_bar_roughness", WaterRender.barRoughness),
        // Querprofil und Oberfläche des Bands (Befund #174).
        ("water_ribbon_waterline", WaterRender.ribbonWaterline),
        ("water_ribbon_waterline_jitter", WaterRender.ribbonWaterlineJitter),
        ("water_ribbon_waterline_scale", WaterRender.ribbonWaterlineScale),
        ("water_ribbon_bank_opacity", WaterRender.ribbonBankOpacity),
        ("water_ribbon_ripple_frequency", WaterRender.ribbonRippleFrequency),
        ("water_ribbon_ripple_amplitude", WaterRender.ribbonRippleAmplitude),
        ("water_ribbon_ripple_stretch", WaterRender.ribbonRippleStretch),
        ("water_ribbon_ripple_speed", WaterRender.ribbonRippleSpeed),
        // Zeitraffer-Blende der Bänder und Raster an Steilwänden (Befund #174).
        ("water_ribbon_fade_cap", WaterRender.ribbonFadeOpacityCap),
        ("water_wall_slope_lo", WaterRender.rasterWallSlopeLo),
        ("water_wall_slope_hi", WaterRender.rasterWallSlopeHi),
    ]) + colors(.water, [
        ("water_shallow_color", WaterRender.waterShallowColor),
        ("water_deep_color", WaterRender.waterDeepColor),
        ("water_flow_shimmer_color", WaterRender.flowShimmerColor),
        ("water_delta_plume_color", WaterRender.deltaPlumeColor),
        ("water_oxbow_water_color", WaterRender.oxbowWaterColor),
        ("water_ocean_shallow_color", WaterRender.oceanShallowColor),
        ("water_ocean_mid_color", WaterRender.oceanMidColor),
        ("water_ocean_deep_color", WaterRender.oceanDeepColor),
        ("water_ocean_surf_color", WaterRender.oceanSurfColor),
        ("water_ocean_plume_color", WaterRender.oceanPlumeColor),
        ("water_ribbon_shoal_color", WaterRender.ribbonShoalColor),
        ("water_bar_sand_color", WaterRender.barSandColor),
        ("water_bar_sand_wet_color", WaterRender.barSandWetColor),
        ("water_ribbon_bank_color", WaterRender.ribbonBankColor),
        ("water_bed_color", WaterRender.waterBedColor),
    ])

    // MARK: water_contract — Vertragswerte der Godot-Wasser-Wächter (#92)

    /// Die Zahlen, gegen die `game/tests/water_geometry.gd` und
    /// `river_ribbons.gd` prüfen. `pondContourLo` und `ribbonDeltaLo` speisen
    /// ZUSÄTZLICH gleichnamige Uniforms in `water` — beide Zeilen lesen
    /// dieselbe Konstante, es entsteht keine zweite Zahl. `mouthSearchCells`
    /// ist ein Int und reist als Double; die GDScript-Seite castet zurück.
    private static let waterContract: [Entry] = scalars(.waterContract, [
        ("ribbonKindRiver", WaterRender.ribbonKindRiver),
        ("ribbonKindDelta", WaterRender.ribbonKindDelta),
        ("ribbonKindOxbow", WaterRender.ribbonKindOxbow),
        ("pondContourLo", WaterRender.pondContourLo),
        ("lakeRawWetDepth", WaterRender.lakeRawWetDepth),
        ("oxbowMaximumOpacity", WaterRender.oxbowMaximumOpacity),
        ("mouthSearchCells", Double(WaterRender.mouthSearchCells)),
        ("ribbonLakeSurfaceLift", WaterRender.ribbonLakeSurfaceLift),
        ("ribbonSeaSurfaceSink", WaterRender.ribbonSeaSurfaceSink),
        ("ribbonMinimumRank", WaterRender.ribbonMinimumRank),
        ("ribbonMaxCrossSlope", WaterRender.ribbonMaxCrossSlope),
        ("ribbonDeltaLo", WaterRender.ribbonDeltaLo),
        ("ribbonJoinCoverage", WaterRender.ribbonJoinCoverage),
    ])

    // MARK: relief — Render-Verschiebung von Rinnen und Graten (#153)

    private static let relief: [Entry] = scalars(.relief, [
        ("relief_scale", ReliefRender.scale),
        ("relief_strength", ReliefRender.strength),
        ("relief_sharpen", ReliefRender.sharpen),
        ("relief_sharpen_radius", ReliefRender.sharpenRadiusCells),
        ("relief_ridge_cap", ReliefRender.ridgeCap),
        ("relief_geometry_age", ReliefRender.geometryAgeYears),
        ("relief_height_code", ReliefRender.heightCode),
        ("relief_slope_code", ReliefRender.slopeCode),
        ("relief_shade_dark", ReliefRender.shadeDark),
        ("relief_shade_light", ReliefRender.shadeLight),
        ("relief_cavity_gully_gain", ReliefRender.cavityGullyGain),
        ("relief_cavity_ridge_gain", ReliefRender.cavityRidgeGain),
        ("relief_detail_scale", ReliefRender.detailScale),
        ("relief_detail_shade", ReliefRender.detailShade),
        ("relief_detail_normal", ReliefRender.detailNormal),
    ])

    // MARK: canopy — Kronendach und Wiese (#152/#168)

    /// Die Schwellen der Waldmaske stehen nicht hier: sie wirken CPU-seitig in
    /// `ForestCanopyMask`.
    private static let canopy: [Entry] = scalars(.canopy, [
        ("canopy_cell", CanopyRender.crownCell),
        ("canopy_height", CanopyRender.canopyHeight),
        ("canopy_lift_lo", CanopyRender.liftLo),
        ("canopy_lift_hi", CanopyRender.liftHi),
        ("canopy_cover_lo", CanopyRender.coverLo),
        ("canopy_cover_hi", CanopyRender.coverHi),
        ("canopy_gap_lo", CanopyRender.gapLo),
        ("canopy_gap_hi", CanopyRender.gapHi),
        ("canopy_crown_mid", CanopyRender.crownMid),
        ("canopy_crown_spread", CanopyRender.crownSpread),
        ("canopy_crown_radius", CanopyRender.crownRadius),
        ("canopy_crown_radius_jitter", CanopyRender.crownRadiusJitter),
        ("canopy_detail_lo", CanopyRender.detailFootprintLo),
        ("canopy_detail_hi", CanopyRender.detailFootprintHi),
        ("canopy_meadow_lo", CanopyRender.meadowLo),
        ("canopy_meadow_hi", CanopyRender.meadowHi),
        ("canopy_meadow_share", CanopyRender.meadowShare),
    ])

    // MARK: material — Materialien des Terrain-Shaders (#174 D)

    /// WO Fels, Halde, Eis und Rohboden liegen, steht nicht hier: das wirkt
    /// CPU-seitig in `TerrainColorRenderer`.
    private static let material: [Entry] = scalars(.material, [
        ("material_ridge_rock_gain", MaterialRender.ridgeRockGain),
        ("material_gully_scree_share", MaterialRender.gullyScreeShare),
        ("material_joint_spacing", MaterialRender.jointSpacing),
        ("material_joint_stretch", MaterialRender.jointStretch),
        ("material_joint_turn_cos", MaterialRender.jointTurnCos),
        ("material_joint_turn_sin", MaterialRender.jointTurnSin),
        ("material_joint_depth", MaterialRender.jointDepth),
        ("material_joint_gully_gain", MaterialRender.jointGullyGain),
        ("material_joint_relief", MaterialRender.jointRelief),
        ("material_rock_relief_gain", MaterialRender.rockReliefGain),
        ("material_scree_grain", MaterialRender.screeGrain),
        ("material_crevasse_spacing", MaterialRender.crevasseSpacing),
        ("material_crevasse_slope_lo", MaterialRender.crevasseSlopeLo),
        ("material_crevasse_slope_hi", MaterialRender.crevasseSlopeHi),
        ("material_moraine_lo", MaterialRender.moraineLo),
        ("material_moraine_hi", MaterialRender.moraineHi),
    ])

    // MARK: contract — Render-Vertrag, den GDScript selbst rechnet (#51)

    /// Überhöhung und Band-Anhebung. Bis #213 standen sie als kopierte
    /// Literale (`HSCALE`, `RIVER_LIFT`) in `Main.gd`, nur von Grep-Wächtern
    /// synchron gehalten. Der `hscale`-Default im Terrain-Shader bleibt als
    /// dokumentierte Ausnahme (Editor-Vorschau ohne SimNode).
    private static let contract: [Entry] = scalars(.contract, [
        ("heightScale", RenderContract.heightScale),
        ("riverLift", RenderContract.riverLift),
    ])

    // MARK: Bauhilfen

    private static func scalars(_ group: Group, _ rows: [(String, Double)]) -> [Entry] {
        rows.map { Entry(group: group, name: $0.0, value: .scalar($0.1)) }
    }

    private static func colors(_ group: Group,
                               _ rows: [(String, (r: Double, g: Double, b: Double))]) -> [Entry] {
        rows.map { Entry(group: group, name: $0.0, value: .color(r: $0.1.r, g: $0.1.g, b: $0.1.b)) }
    }
}
