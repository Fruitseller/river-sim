import XCTest
@testable import SimCore
import SimRender

/// Wächter für den Uniform-Kanal der Wasser-Kalibrierung (Issues #91/#92).
///
/// Contract-Schritt (#92): die Kalibrier-Werte reisen NUR noch als benannte
/// Werte über die Brücke (Gruppe `water` im `SimRender.CalibrationRegistry`
/// → `SimNode.calibration` → `Main.apply_calibration`, seit #213).
/// Die Shader deklarieren gleichnamige Uniforms OHNE Default und lesen sie im
/// Body — ein Literal-Default wäre wieder genau die Kopie, die #92 abschafft
/// (die Editor-Vorschau ohne SimNode ist damit bewusst unkalibriert). Gepinnt
/// wird deshalb Struktur statt Zahlen:
///   - welcher Shader welche `water_*`-Uniform default-frei deklariert und liest,
///   - `Main.gd` kalibriert alle drei Wasser-Materialien.
/// Spiegel der Zahlen, „nichts am Register vorbei", Brücke und die
/// Vertragswerte der Godot-Wächter prüft `CalibrationRegistryTests` (#213).
/// Dass die gesetzten Werte in Godot wirklich ankommen, prüft End-to-End
/// `game/tests/water_uniforms.gd`.
final class WaterUniformsTests: XCTestCase {

    /// Welcher Shader welche Werte konsumiert — der Verteilungs-Vertrag.
    /// `Main.gd` setzt zwar alle Werte auf alle Wasser-Materialien (undeklarierte
    /// Namen ignoriert Godot), aber WO ein Wert als Uniform deklariert sein muss,
    /// entscheidet der Shader-Body, der ihn liest.
    private static let windowScalars = [
        "water_lake_gate_lo", "water_lake_gate_hi",
        "water_river_mask_lo", "water_river_mask_hi",
        "water_river_depth_lo", "water_river_depth_hi",
        "water_shore_lo", "water_shore_hi",
        "water_pond_contour_lo", "water_pond_contour_hi",
        "water_geometry_lift_lo", "water_geometry_lift_hi",
        "water_lake_depth_lo", "water_lake_depth_span",
    ]
    private static let ribbonScalars = [
        "water_ribbon_still_lo", "water_ribbon_still_hi",
        "water_ribbon_delta_lo", "water_ribbon_delta_hi",
    ]
    private static let opticsScalars = [
        "water_fresnel_exponent", "water_roughness", "water_specular",
    ]
    private static let opacityScalars = ["water_opacity_shallow", "water_opacity_deep"]
    private static let opticsColors = [
        "water_shallow_color", "water_deep_color",
        "water_flow_shimmer_color",
    ]
    private static let ribbonColors = ["water_delta_plume_color", "water_oxbow_water_color"]
    /// Offenes Meer (#155): Tiefen-Farbe über dem Schelf, Brandung, Rausch-Wellen.
    private static let oceanScalars = [
        "water_ocean_depth_span", "water_ocean_mid_depth",
        "water_ocean_surf_depth", "water_ocean_surf_strength",
        "water_ocean_surf_scale", "water_ocean_surf_drift",
        "water_ocean_surf_noise_lo", "water_ocean_surf_noise_hi",
        "water_ocean_wave_frequency", "water_ocean_wave_amplitude",
        "water_ocean_wave_lacunarity", "water_ocean_wave_gain",
        "water_ocean_wave_fade_lo", "water_ocean_wave_fade_hi",
        "water_ocean_wave_drift_x", "water_ocean_wave_drift_z",
        "water_ocean_wave_octave_speedup",
        // Sedimentfahne (#174 C).
        "water_ocean_plume_lod", "water_ocean_plume_opacity",
    ]
    private static let oceanColors = [
        "water_ocean_shallow_color", "water_ocean_mid_color",
        "water_ocean_deep_color", "water_ocean_surf_color",
        "water_ocean_plume_color",
    ]

    /// Mäandergürtel (#174 C2): Querprofil im Band, Bank-Material im Terrain.
    private static let bendScalars = ["water_ribbon_bend_depth", "water_ribbon_shoal_mix"]
    private static let bendColors = ["water_ribbon_shoal_color"]
    private static let barScalars = ["water_bar_roughness"]
    private static let barColors = ["water_bar_sand_color", "water_bar_sand_wet_color"]
    /// Querprofil und Oberfläche des Bands (Befund #174): Wasserlinie, nasses
    /// Ufer, Kräuselung. Die Oktaven-Folge und Pixel-Ausblendung der Kräuselung
    /// teilt das Band mit dem Ozean.
    private static let profileScalars = [
        "water_ribbon_waterline", "water_ribbon_waterline_jitter",
        "water_ribbon_waterline_scale", "water_ribbon_bank_opacity",
        "water_ribbon_ripple_frequency", "water_ribbon_ripple_amplitude",
        "water_ribbon_ripple_stretch", "water_ribbon_ripple_speed",
    ]
    private static let profileColors = ["water_ribbon_bank_color"]
    /// Ozean-Werte, die das Band für seine Kräuselung mitliest.
    private static let sharedWaveScalars = [
        "water_ocean_wave_lacunarity", "water_ocean_wave_gain",
        "water_ocean_wave_fade_lo", "water_ocean_wave_fade_hi",
    ]
    /// See-Maske des Terrain-Shaders, die das Band per Pixel nachrechnet
    /// (EINE Seite malt über einem Raster-See).
    private static let lakeMaskScalars = [
        "water_lake_gate_lo", "water_lake_gate_hi",
        "water_pond_contour_lo", "water_pond_contour_hi",
    ]

    /// Zeitraffer-Blende der Bänder (geteilte optische Dicke) und Raster an
    /// Steilwänden (Befund #174, Seed 1337 / Jahr 2.305).
    private static let ribbonFadeScalars = ["water_ribbon_fade_cap"]
    private static let wallScalars = ["water_wall_slope_lo", "water_wall_slope_hi"]

    private static let expectedScalars: [String: [String]] = [
        "game/shaders/terrain.gdshader": windowScalars + opticsScalars + opacityScalars + barScalars
            + wallScalars,
        "game/shaders/water.gdshader": ribbonScalars + opticsScalars + opacityScalars + bendScalars
            + profileScalars + sharedWaveScalars + lakeMaskScalars + ribbonFadeScalars,
        // Das offene Meer ist opak (ALPHA = 1.0) — keine Deckkraft-Rampe.
        "game/shaders/ocean.gdshader": opticsScalars + oceanScalars,
    ]
    private static let expectedColors: [String: [String]] = [
        // Das Bett unter dem Wasser teilen Band und Raster-Wasser.
        "game/shaders/terrain.gdshader": opticsColors + barColors + ["water_bed_color"],
        "game/shaders/water.gdshader": opticsColors + ribbonColors + bendColors + profileColors
            + ["water_bed_color"],
        // Das Meer färbt nach der Schelf-Tiefe (#155) statt nach Seicht/Tief
        // des Binnenwassers und trägt keinen Strömungs-Schimmer; geteilt
        // bleibt die Optik (Fresnel, Rauheit, Specular, oben).
        "game/shaders/ocean.gdshader": oceanColors,
    ]

    func testShadersDeclareTheUniformsDefaultFreeAndReadThem() throws {
        // Contract-Schritt (#92): ein Literal-Default wäre wieder eine Kopie
        // der Kalibrierung — die Deklaration bleibt default-frei, den Wert
        // setzt `Main.gd` aus der Brücke. Und eine deklarierte, aber nie
        // gelesene Uniform wäre ein toter Kanal, den der End-to-End-Wächter
        // (er prüft nur „wird gesetzt") nicht sehen kann: jeder Name muss im
        // Quelltext deshalb mindestens zweimal stehen — Deklaration + Lesung.
        // Gezählt wird als GANZER Bezeichner (Review zu #105): ein
        // Substring-Zähler ließe eine Lesung von `water_shore_lo_scaled` als
        // Lesung von `water_shore_lo` durchgehen.
        for (path, names) in Self.expectedScalars {
            let shader = try RepoSource.probe(path)
            for name in names {
                assertContains(shader, "uniform float \(name);",
                               hint: "\(path): \(name) default-frei deklariert (#92)")
                XCTAssertGreaterThanOrEqual(shader.count(ofIdentifier: name), 2,
                                            "\(path): \(name) wird deklariert, aber nie gelesen")
            }
        }
        for (path, names) in Self.expectedColors {
            let shader = try RepoSource.probe(path)
            for name in names {
                assertContains(shader, "uniform vec3 \(name);",
                               hint: "\(path): \(name) default-frei deklariert (#92)")
                XCTAssertGreaterThanOrEqual(shader.count(ofIdentifier: name), 2,
                                            "\(path): \(name) wird deklariert, aber nie gelesen")
            }
        }
    }

    func testMainAppliesTheCalibrationToAllWaterMaterials() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        // Alle drei Wasser-Materialien bekommen die Werte; das Band-Material
        // existiert im RS_WATER_STAMP-Modus nicht.
        assertContains(main, "var water_mats: Array[ShaderMaterial] = [terrain_mat, ocean_mat]",
                       hint: "Terrain- und Ozean-Material werden kalibriert")
        assertContains(main, "water_mats.append(river_mat)",
                       hint: "Band-Material wird kalibriert, wenn es existiert")
        assertContains(main, "apply_calibration(sim, \"water\", water_mats)",
                       hint: "Der Aufbau ruft die Anwendung mit der echten Brücke auf")
    }
}
