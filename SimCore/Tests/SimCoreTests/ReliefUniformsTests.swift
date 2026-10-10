import XCTest
@testable import SimCore
import SimRender

/// Wächter für die Render-Verschiebung von Rinnen und Graten (Issue #153).
///
/// Die Verschiebung ist eine GPU-Render-Ableitung: `relief_bake.gdshader`
/// rechnet sie einmal je Terrain-Update in eine Textur, `terrain.gdshader`
/// liest sie nur. Ausführbar ist davon headless nichts; gepinnt wird deshalb
/// wie bei der Wasser-Kalibrierung (#92) die STRUKTUR des Uniform-Wegs:
///   - jede Zahl kommt aus `SimCore.ReliefRender`, die Tabelle vergibt nur Namen,
///   - die Shader deklarieren die Uniforms default-frei und lesen sie,
///   - kein Shader deklariert eine `relief_*`-Zahl an der Tabelle vorbei,
///   - Brücke und `Main.gd` sind verdrahtet.
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
            "relief_shade_dark", "relief_shade_light",
        ],
    ]

    func testEveryTableValueComesFromReliefRender() {
        let mirror: [String: Double] = [
            "relief_scale": ReliefRender.scale,
            "relief_strength": ReliefRender.strength,
            "relief_sharpen": ReliefRender.sharpen,
            "relief_sharpen_radius": ReliefRender.sharpenRadiusCells,
            "relief_ridge_cap": ReliefRender.ridgeCap,
            "relief_height_code": ReliefRender.heightCode,
            "relief_slope_code": ReliefRender.slopeCode,
            "relief_shade_dark": ReliefRender.shadeDark,
            "relief_shade_light": ReliefRender.shadeLight,
            "relief_cavity_gully_gain": ReliefRender.cavityGullyGain,
            "relief_cavity_ridge_gain": ReliefRender.cavityRidgeGain,
        ]
        XCTAssertEqual(ReliefUniforms.scalars.count, mirror.count,
                       "Tabellen-Eintrag ohne Spiegel-Zeile (oder umgekehrt)")
        for entry in ReliefUniforms.scalars {
            XCTAssertEqual(entry.value, mirror[entry.name],
                           "\(entry.name) trägt nicht seine ReliefRender-Konstante")
        }
        let names = ReliefUniforms.scalars.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "Uniform-Namen kollidieren")
    }

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

    func testNoShaderDeclaresAReliefNumberBeyondTheTable() throws {
        var declared = Set<String>()
        for path in Self.expected.keys {
            let shader = try RepoSource.probe(path)
            let found = try shader.pairs(
                pattern: "uniform\\s+([A-Za-z0-9_]+)\\s+(relief_[A-Za-z0-9_]+)")
            for (kind, name) in found {
                // Textur und Schalter sind keine Kalibrier-Zahlen.
                if kind.hasPrefix("sampler") || kind == "bool" { continue }
                XCTAssertEqual(kind, "float", "\(path): \(name) — die Brücke kennt nur float")
                XCTAssertTrue(ReliefUniforms.scalars.contains { $0.name == name },
                              "\(path) deklariert \(name) an ReliefUniforms vorbei")
                declared.insert(name)
            }
        }
        for entry in ReliefUniforms.scalars {
            XCTAssertTrue(declared.contains(entry.name),
                          "\(entry.name) wird von keinem Shader deklariert")
        }
    }

    func testBridgeAndMainCarryTheTable() throws {
        let bridge = try RepoSource.extensionSources()
        for needle in ["func reliefUniformNames", "func reliefUniformValues",
                       "ReliefUniforms.scalars"] {
            assertContains(bridge, needle, hint: "Brücke marshallt die Relief-Tabelle")
        }
        let main = try RepoSource.probe("game/scripts/Main.gd")
        for needle in ["reliefUniformNames()", "reliefUniformValues()",
                       "static func relief_calibration"] {
            assertContains(main, needle, hint: "Main.gd liest die Relief-Tabelle über die Brücke")
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
        assertContains(terrain, "coarse_slope += relief_slope(v_uv);",
                       hint: "Pixel-Normale bekommt die Steigung der Verschiebung")
        XCTAssertEqual(terrain.count(ofIdentifier: "erosion_detail_at"), 1,
                       "Terrain-Shader ruft den Filter nur für das feine Detail auf")
        let bake = try RepoSource.probe("game/shaders/relief_bake.gdshader")
        assertContains(bake, "uniform sampler2D protect_tex",
                       hint: "Back-Pass endet an der Schutzmaske (#154)")
        assertContains(bake, "max(h - ring * 0.125, 0.0)",
                       hint: "Gratschärfung hebt nur, senkt nie")
    }
}
