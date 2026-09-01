import SimCore

/// Wasser-Kalibrierung als benannte Werte für die Brücke (Issues #91/#92).
///
/// Contract-Schritt der Migration weg vom Substring-Vertrag: die Werte reisen
/// NUR noch über die Brücke (`SimNode` → `Main.gd`) und setzen gleichnamige
/// Shader-Uniforms; die Shader deklarieren sie ohne Default und lesen sie im
/// Body. Ein Literal-Default wäre wieder eine Kopie — die Editor-Vorschau
/// ohne SimNode ist damit bewusst unkalibriert (alles Null).
///
/// Die einzige QUELLE der Zahlen bleibt `SimCore.WaterRender` — diese Tabellen
/// vergeben nur Namen. Wächter: `SimCoreTests/WaterUniformsTests.swift`
/// (Namen, default-freie Deklarationen, Brücke, `Main.gd`) und End-to-End
/// `game/tests/water_uniforms.gd` (jede deklarierte Uniform wird gesetzt).
public enum WaterUniforms {

    /// Skalare Uniforms (`uniform float` in den Shadern).
    public static let scalars: [(name: String, value: Double)] = [
        // Fenster, mit denen terrain.gdshader die Wasser-Kanäle liest.
        ("water_lake_gate_lo", WaterRender.lakeGateLo),
        ("water_lake_gate_hi", WaterRender.lakeGateHi),
        ("water_river_mask_lo", WaterRender.riverMaskLo),
        ("water_river_mask_hi", WaterRender.riverMaskHi),
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
        ("water_fresnel_sky_mix", WaterRender.fresnelSkyMix),
        ("water_opacity_shallow", WaterRender.waterOpacityShallow),
        ("water_opacity_deep", WaterRender.waterOpacityDeep),
        ("water_roughness_steep", WaterRender.waterRoughnessSteep),
        ("water_roughness_grazing", WaterRender.waterRoughnessGrazing),
        ("water_specular_steep", WaterRender.waterSpecularSteep),
        ("water_specular_grazing", WaterRender.waterSpecularGrazing),
    ]

    /// Farb-Uniforms (`uniform vec3` in den Shadern).
    public static let colors: [(name: String, value: (r: Double, g: Double, b: Double))] = [
        ("water_shallow_color", WaterRender.waterShallowColor),
        ("water_deep_color", WaterRender.waterDeepColor),
        ("water_sky_reflect_color", WaterRender.skyReflectColor),
        ("water_flow_shimmer_color", WaterRender.flowShimmerColor),
        ("water_delta_plume_color", WaterRender.deltaPlumeColor),
        ("water_oxbow_water_color", WaterRender.oxbowWaterColor),
    ]

    /// Vertragswerte der Godot-Wächter (Issue #92) — KEINE Shader-Uniforms,
    /// sondern die Zahlen, gegen die `game/tests/water_geometry.gd` und
    /// `game/tests/river_ribbons.gd` prüfen. Bis #92 führten die beiden Tests
    /// sie als eigene Konstanten (gehalten von einem Substring-Wächter); jetzt
    /// reisen sie denselben Weg wie die Uniforms. Die Namen sind die
    /// `WaterRender`-Bezeichner selbst, damit die Paarung lesbar bleibt.
    ///
    /// `pondContourLo` und `ribbonDeltaLo` speisen ZUSÄTZLICH gleichnamige
    /// Uniforms oben — beide Zeilen lesen dieselbe Konstante, es entsteht
    /// keine zweite Zahl. `mouthSearchCells` ist ein Int und reist als Double;
    /// die GDScript-Seite castet zurück.
    public static let contract: [(name: String, value: Double)] = [
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
    ]
}
