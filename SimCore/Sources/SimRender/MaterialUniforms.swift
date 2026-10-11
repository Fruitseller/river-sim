import SimCore

/// Material-Kalibrierung des Terrain-Shaders als benannte Werte für die Brücke
/// (Issue #174 D, Muster wie `CanopyUniforms`). Die einzige Quelle der Zahlen
/// bleibt `SimCore.MaterialRender`; diese Tabelle vergibt nur Namen. Der
/// Terrain-Shader deklariert gleichnamige Uniforms ohne Default. Die Schwellen
/// der Verteilung (WO Fels, Halde, Eis, Rohboden liegen) stehen nicht hier:
/// sie wirken CPU-seitig in `TerrainColorRenderer`.
/// Wächter: `SimCoreTests/MaterialTests.swift`, `game/tests/canopy.gd`.
public enum MaterialUniforms {

    public static let scalars: [(name: String, value: Double)] = [
        ("material_ridge_rock_gain", MaterialRender.ridgeRockGain),
        ("material_gully_scree_share", MaterialRender.gullyScreeShare),
        ("material_joint_spacing", MaterialRender.jointSpacing),
        ("material_joint_depth", MaterialRender.jointDepth),
        ("material_scree_grain", MaterialRender.screeGrain),
        ("material_crevasse_spacing", MaterialRender.crevasseSpacing),
        ("material_crevasse_slope_lo", MaterialRender.crevasseSlopeLo),
        ("material_crevasse_slope_hi", MaterialRender.crevasseSlopeHi),
        ("material_moraine_lo", MaterialRender.moraineLo),
        ("material_moraine_hi", MaterialRender.moraineHi),
    ]
}
