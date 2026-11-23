import XCTest
@testable import SimCore
import SimRender

final class ReliefUniformsTests: XCTestCase {

    private static let expected: [String: [String]] = [
        "game/shaders/relief_bake.gdshader": [
            "relief_scale", "relief_strength", "relief_sharpen", "relief_sharpen_radius",
            "relief_ridge_cap", "relief_height_code", "relief_slope_code",
            "relief_cavity_gully_gain", "relief_cavity_ridge_gain",
            "relief_rib_scale", "relief_rib_strength", "relief_rib_slope_lo",
            "relief_rib_slope_hi", "relief_rib_floor", "relief_cavity_rib_gain",
            "relief_bench_spacing", "relief_bench_relief", "relief_cavity_bench_gain",
        ],
        "game/shaders/terrain.gdshader": [
            "relief_height_code", "relief_slope_code",
            "relief_shade_dark", "relief_shade_light", "relief_geometry_age",
            "relief_detail_scale", "relief_detail_shade", "relief_detail_normal",
        ],
    ]

    func testHeightCodeCoversTheDisplacement() {
        let gullies = 2.0 * ReliefRender.strength * ReliefRender.scale * RenderContract.heightScale
        let ribs = 2.0 * ReliefRender.ribStrength * ReliefRender.ribScale * RenderContract.heightScale
        let range = 0.5 / ReliefRender.heightCode
        XCTAssertGreaterThan(range, gullies + ribs + ReliefRender.ridgeCap,
                             "Höhenkodierung schneidet die Verschiebung ab")
    }

    func testShadersDeclareTheUniformsDefaultFreeAndReadThem() throws {
        for (path, names) in Self.expected {
            let shader = try RepoSource.probe(path)
            for name in names {
                assertContains(shader, "uniform float \(name);",
                               hint: "\(path): \(name) default-frei deklariert (Muster #92)")
                XCTAssertGreaterThanOrEqual(shader.count(ofIdentifier: name), 2,
                                            "\(path): \(name) wird deklariert, aber nie gelesen")
            }
        }
    }

    func testTerrainShaderOnlyReadsTheBake() throws {
        let terrain = try RepoSource.probe("game/shaders/terrain.gdshader")
        assertContains(terrain, "uniform sampler2D relief_tex",
                       hint: "Terrain-Shader liest die gebackene Verschiebung")
        assertContains(terrain, "VERTEX.y = mix(hraw, hfv, lift) * hscale + relief_lift(uv) * (1.0 - lift);",
                       hint: "Seen bleiben flach auf ihrem Spiegel (Verschiebung × (1 − lift))")
        assertContains(terrain, "coarse_slope += relief_slope(relief);",
                       hint: "Pixel-Normale bekommt die Steigung der Verschiebung")
        assertContains(terrain, "vec4 relief = relief_pixel(v_uv);",
                       hint: "Pixel-Stufe liest die Backtextur einmal")
        XCTAssertEqual(terrain.count(ofIdentifier: "relief_pixel"), 2,
                       "relief_pixel: Definition plus genau ein Aufruf")
        XCTAssertEqual(terrain.count(ofIdentifier: "erosion_detail_at"), 1,
                       "Terrain-Shader ruft den Filter nur für das feine Detail auf")
        let bake = try RepoSource.probe("game/shaders/relief_bake.gdshader")
        assertContains(bake, "uniform sampler2D protect_tex",
                       hint: "Back-Pass endet an der Schutzmaske (#154)")
        assertContains(bake, "max(h - ring * 0.125, 0.0)",
                       hint: "Gratschärfung hebt nur, senkt nie")
    }
}
