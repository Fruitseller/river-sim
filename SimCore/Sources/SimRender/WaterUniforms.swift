import SimCore

/// Wasser-Kalibrierung als benannte Uniform-Werte (Issue #91).
///
/// Expand-Schritt der Migration weg vom Substring-Vertrag: dieselben Zahlen,
/// die die Shader heute als Literal tragen, reisen zusätzlich über die Brücke
/// (`SimNode` → `Main.gd`) und überschreiben gleichnamige Shader-Uniforms,
/// deren Default das bisherige Literal ist. Die Shader-Bodies lesen vorerst
/// weiter ihre Literale; erst der Contract-Schritt stellt sie auf die Uniforms
/// um und baut die Text-Wächter zurück.
///
/// Die einzige QUELLE der Zahlen bleibt `SimCore.WaterRender` — diese Tabelle
/// vergibt nur Namen. Wächter: `SimCoreTests/WaterUniformsTests.swift` (Namen,
/// Shader-Defaults, Brücke, `Main.gd`) und End-to-End
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
}
