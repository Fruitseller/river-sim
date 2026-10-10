import SimCore

/// Kronen-Kalibrierung als benannte Werte für die Brücke (Issue #152, Muster
/// wie `ReliefUniforms`). Die einzige Quelle der Zahlen bleibt
/// `SimCore.CanopyRender`; diese Tabelle vergibt nur Namen. Der Terrain-Shader
/// deklariert gleichnamige Uniforms ohne Default. Die Schwellen der Waldmaske
/// stehen nicht hier: sie wirken CPU-seitig in `ForestCanopyMask`.
/// Wächter: `SimCoreTests/CanopyTests.swift`.
public enum CanopyUniforms {

    public static let scalars: [(name: String, value: Double)] = [
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
    ]
}
