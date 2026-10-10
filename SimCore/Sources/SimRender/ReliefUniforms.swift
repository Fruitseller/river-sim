import SimCore

/// Kalibrierung der Render-Verschiebung als benannte Werte für die Brücke
/// (Issue #153, Muster wie `WaterUniforms`). Die einzige Quelle der Zahlen
/// bleibt `SimCore.ReliefRender`; diese Tabelle vergibt nur Namen. Die Shader
/// deklarieren gleichnamige Uniforms ohne Default.
/// Wächter: `SimCoreTests/ReliefUniformsTests.swift`, `game/tests/relief.gd`.
public enum ReliefUniforms {

    public static let scalars: [(name: String, value: Double)] = [
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
    ]
}
