import XCTest
@testable import SimCore
import SimRender

/// Wächter für die Render-Verschiebung von Rinnen und Graten (Issue #153).
///
/// Die Verschiebung ist eine GPU-Render-Ableitung: `relief_bake.gdshader`
/// rechnet sie einmal je Terrain-Update in eine Textur, `terrain.gdshader`
/// liest sie nur. Ausführbar ist davon headless nichts; gepinnt wird deshalb
/// wie bei der Wasser-Kalibrierung (#92) die STRUKTUR des Uniform-Wegs:
///   - welcher Shader welche `relief_*`-Uniform default-frei deklariert und liest,
///   - die Kodierung deckt die Verschiebung ab,
///   - der Terrain-Shader liest nur die Backtextur.
/// Spiegel der Zahlen, „nichts am Register vorbei", Brücke und `Main.gd`
/// prüft für alle Gruppen gemeinsam `CalibrationRegistryTests` (#213).
/// Dass die Werte in Godot ankommen und Pinselring, Kameraziel und Pinsel auf
/// der sichtbaren Fläche arbeiten, prüft End-to-End `game/tests/relief.gd`.
final class ReliefUniformsTests: XCTestCase {

    /// Welcher Shader welche Werte liest. Der Back-Pass braucht die
    /// Form-Parameter und beide Kodierungen; der Terrain-Shader dekodiert und
    /// schattiert nur.
    private static let expected: [String: [String]] = [
        "game/shaders/relief_bake.gdshader": [
            "relief_scale", "relief_strength", "relief_sharpen", "relief_sharpen_radius",
            "relief_ridge_cap", "relief_height_code", "relief_slope_code",
            "relief_cavity_gully_gain", "relief_cavity_ridge_gain",
        ],
        "game/shaders/terrain.gdshader": [
            "relief_height_code", "relief_slope_code",
            "relief_shade_dark", "relief_shade_light", "relief_geometry_age",
            // Feines Rinnen-Detail (bis zum Review zu #174 Literal-Defaults).
            "relief_detail_scale", "relief_detail_shade", "relief_detail_normal",
        ],
    ]

    /// Die Kodierung muss die größte vorkommende Verschiebung abbilden: die
    /// Rinnen bleiben unter `strength · scale · hscale` (Summe der Oktaven
    /// < 2 × erste Oktave), die Grate unter ihrem Deckel `ridgeCap` (tanh).
    /// Der Kanal ist 0…1 mit Mitte 0.5, also ± 0.5 / heightCode Einheiten.
    func testHeightCodeCoversTheDisplacement() {
        let gullies = 2.0 * ReliefRender.strength * ReliefRender.scale * RenderContract.heightScale
        let range = 0.5 / ReliefRender.heightCode
        XCTAssertGreaterThan(range, gullies + ReliefRender.ridgeCap,
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

    /// Vertex-Stufe liest die Höhe, Pixel-Stufe Steigung und Rinnen — aus der
    /// gebackenen Textur, nie aus einer eigenen Auswertung des Filters (pro
    /// Vertex kostete das in der Studie 35,6 ms je Bild).
    func testTerrainShaderOnlyReadsTheBake() throws {
        let terrain = try RepoSource.probe("game/shaders/terrain.gdshader")
        assertContains(terrain, "uniform sampler2D relief_tex",
                       hint: "Terrain-Shader liest die gebackene Verschiebung")
        assertContains(terrain, "VERTEX.y = mix(hraw, hfv, lift) * hscale + relief_lift(uv) * (1.0 - lift);",
                       hint: "Seen bleiben flach auf ihrem Spiegel (Verschiebung × (1 − lift))")
        assertContains(terrain, "coarse_slope += relief_slope(relief);",
                       hint: "Pixel-Normale bekommt die Steigung der Verschiebung")
        // EIN Abgriff je Pixel für Steigung und Rinnen (Review zu #174).
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
