import XCTest
@testable import SimCore
import SimRender

final class WaterUniformsTests: XCTestCase {

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
    private static let oceanScalars = [
        "water_ocean_surf_slope_lo", "water_ocean_surf_slope_hi",
        "water_ocean_depth_span", "water_ocean_mid_depth",
        "water_ocean_shoal_scale",
        "water_ocean_shoal_depth_variation",
        "water_ocean_breaker_spacing",
        "water_ocean_breaker_width",
        "water_ocean_breaker_depth",
        "water_ocean_breaker_strength",
        "water_ocean_surf_depth", "water_ocean_surf_strength",
        "water_ocean_surf_scale", "water_ocean_surf_drift",
        "water_ocean_surf_noise_lo", "water_ocean_surf_noise_hi",
        "water_ocean_surf_plume_cut",
        "water_ocean_wave_frequency", "water_ocean_wave_amplitude",
        "water_ocean_wave_lacunarity", "water_ocean_wave_gain",
        "water_ocean_wave_fade_lo", "water_ocean_wave_fade_hi",
        "water_ocean_wave_drift_x", "water_ocean_wave_drift_z",
        "water_ocean_wave_octave_speedup",
        "water_ocean_plume_lod", "water_ocean_plume_opacity",
    ]
    private static let oceanColors = [
        "water_ocean_shallow_color", "water_ocean_mid_color",
        "water_ocean_deep_color", "water_ocean_surf_color",
        "water_ocean_plume_color",
    ]

    private static let bendScalars = ["water_ribbon_bend_depth", "water_ribbon_shoal_mix"]
    private static let bendColors = ["water_ribbon_shoal_color"]
    private static let barScalars = [
        "water_bar_roughness",
        "water_beach_wet_height", "water_beach_height_hi",
        "water_beach_edge_lo", "water_beach_edge_hi", "water_beach_blend_height",
    ]
    private static let barColors = [
        "water_bar_sand_color", "water_bar_sand_wet_color",
        "water_beach_dry_color", "water_beach_wet_color",
    ]
    private static let profileScalars = [
        "water_ribbon_waterline", "water_ribbon_waterline_jitter",
        "water_ribbon_waterline_scale", "water_ribbon_bank_opacity",
        "water_ribbon_ripple_frequency", "water_ribbon_ripple_amplitude",
        "water_ribbon_ripple_stretch", "water_ribbon_ripple_speed",
    ]
    private static let profileColors = ["water_ribbon_bank_color"]
    private static let sharedWaveScalars = [
        "water_ocean_wave_lacunarity", "water_ocean_wave_gain",
        "water_ocean_wave_fade_lo", "water_ocean_wave_fade_hi",
    ]
    private static let lakeMaskScalars = [
        "water_lake_gate_lo", "water_lake_gate_hi",
        "water_pond_contour_lo", "water_pond_contour_hi",
    ]

    private static let ribbonFadeScalars = ["water_ribbon_fade_cap"]
    private static let wallScalars = ["water_wall_slope_lo", "water_wall_slope_hi"]
    private static let runScalars = [
        "water_riffle_depth", "water_foam_amount", "water_river_specular",
        "water_cloud_reflection",
    ]
    private static let runColors = ["water_riffle_color", "water_foam_color"]
    private static let ribbonFoamScalars = ["water_foam_scale"]
    private static let corridorShoreScalars = ["water_corridor_shore", "water_corridor_shore_bend"]
    private static let rasterRunScalars = ["water_raster_steep_lo", "water_raster_steep_hi"]
    private static let rasterRunColors = ["water_lake_color"]

    private static let expectedScalars: [String: [String]] = [
        "game/shaders/terrain.gdshader": windowScalars + opticsScalars + opacityScalars + barScalars
            + wallScalars + runScalars + rasterRunScalars,
        "game/shaders/water.gdshader": ribbonScalars + opticsScalars + opacityScalars + bendScalars
            + profileScalars + sharedWaveScalars + lakeMaskScalars + ribbonFadeScalars
            + runScalars + ribbonFoamScalars + corridorShoreScalars + ["water_ocean_depth_span"],
        "game/shaders/corridor.gdshaderinc": corridorShoreScalars,
        "game/shaders/ocean.gdshader": opticsScalars + oceanScalars,
    ]
    private static let expectedColors: [String: [String]] = [
        "game/shaders/terrain.gdshader": opticsColors + barColors + ["water_bed_color"]
            + runColors + rasterRunColors,
        "game/shaders/water.gdshader": opticsColors + ribbonColors + bendColors + profileColors
            + ["water_bed_color"] + runColors + ["water_ocean_shallow_color"],
        "game/shaders/corridor.gdshaderinc": ["water_bed_color"],
        "game/shaders/ocean.gdshader": oceanColors,
    ]

    func testShadersDeclareTheUniformsDefaultFreeAndReadThem() throws {
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

    func testEveryDeclaredWaterUniformIsListed() throws {
        let regex = try NSRegularExpression(pattern: #"uniform\s+(?:float|vec3)\s+(water_[a-z0-9_]+)\s*;"#)
        for path in Self.expectedScalars.keys {
            let code = try RepoSource.probe(path).code
            let listed = Set(Self.expectedScalars[path, default: []] + Self.expectedColors[path, default: []])
            let range = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: range) {
                let name = String(code[Range(match.range(at: 1), in: code)!])
                XCTAssertTrue(listed.contains(name), "\(path): \(name) fehlt in WaterUniformsTests")
            }
        }
    }

    func testMainAppliesTheCalibrationToAllWaterMaterials() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "var water_mats: Array[ShaderMaterial] = [terrain_mat, ocean_mat]",
                       hint: "Terrain- und Ozean-Material werden kalibriert")
        assertContains(main, "water_mats.append(river_mat)",
                       hint: "Band-Material wird kalibriert, wenn es existiert")
        assertContains(main, "apply_calibration(sim, \"water\", water_mats)",
                       hint: "Der Aufbau ruft die Anwendung mit der echten Brücke auf")
    }
}
