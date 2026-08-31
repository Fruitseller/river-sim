import XCTest
@testable import SimCore
import SimRender

/// Wächter für den Uniform-Kanal der Wasser-Kalibrierung (Issue #91).
///
/// Expand-Schritt: die Kalibrier-Werte reisen als benannte Werte über die
/// Brücke (`SimRender.WaterUniforms` → `SimNode` → `Main.gd`) und überschreiben
/// in den Shadern gleichnamige Uniforms, deren DEFAULT das bisherige Literal
/// ist. Die Shader-Bodies lesen vorerst weiter ihre Literale — beide Wege
/// müssen deshalb dieselben Zahlen tragen, und genau das pinnen diese Tests:
///   - jede Uniform-Deklaration trägt den Tabellenwert als Default,
///   - jeder Tabellenwert ist in mindestens einem Shader deklariert,
///   - kein Shader deklariert eine `water_*`-Uniform an der Tabelle vorbei,
///   - Brücke und `Main.gd` sind verdrahtet.
/// Dass die gesetzten Werte in Godot wirklich ankommen, prüft End-to-End
/// `game/tests/water_uniforms.gd`.
final class WaterUniformsTests: XCTestCase {

    /// Welcher Shader welche Werte konsumiert — der Verteilungs-Vertrag.
    /// `Main.gd` setzt zwar alle Werte auf alle Wasser-Materialien (undeklarierte
    /// Namen ignoriert Godot), aber WO ein Wert als Uniform deklariert sein muss,
    /// entscheidet der Shader-Body, der das Literal heute liest.
    private static let windowScalars = [
        "water_lake_gate_lo", "water_lake_gate_hi",
        "water_river_mask_lo", "water_river_mask_hi",
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
        "water_fresnel_exponent", "water_fresnel_sky_mix",
        "water_roughness_steep", "water_roughness_grazing",
        "water_specular_steep", "water_specular_grazing",
    ]
    private static let opacityScalars = ["water_opacity_shallow", "water_opacity_deep"]
    private static let opticsColors = [
        "water_shallow_color", "water_deep_color",
        "water_sky_reflect_color", "water_flow_shimmer_color",
    ]
    private static let ribbonColors = ["water_delta_plume_color", "water_oxbow_water_color"]

    private static let expectedScalars: [String: [String]] = [
        "game/shaders/terrain.gdshader": windowScalars + opticsScalars + opacityScalars,
        "game/shaders/water.gdshader": ribbonScalars + opticsScalars + opacityScalars,
        // Das offene Meer ist opak (ALPHA = 1.0) — keine Deckkraft-Rampe.
        "game/shaders/ocean.gdshader": opticsScalars,
    ]
    private static let expectedColors: [String: [String]] = [
        "game/shaders/terrain.gdshader": opticsColors,
        "game/shaders/water.gdshader": opticsColors + ribbonColors,
        "game/shaders/ocean.gdshader": opticsColors,
    ]

    func testUniformNamesAreUnique() {
        let names = WaterUniforms.scalars.map(\.name) + WaterUniforms.colors.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "Uniform-Namen kollidieren")
        for name in names {
            XCTAssertTrue(name.hasPrefix("water_"),
                          "\(name): der Präfix gruppiert die Kalibrier-Uniforms und "
                          + "hält sie von den bestehenden (hscale, sea_level, …) fern")
        }
    }

    func testEveryTableValueComesFromWaterRender() {
        // Die Tabelle DARF keine eigenen Zahlen einführen — WaterRender bleibt
        // die einzige Quelle. Stichproben über alle Wertegruppen; die
        // vollständige Paarung Name ↔ Zahl pinnen die Shader-Deklarationen.
        XCTAssertEqual(scalar("water_lake_gate_lo"), WaterRender.lakeGateLo)
        XCTAssertEqual(scalar("water_river_mask_hi"), WaterRender.riverMaskHi)
        XCTAssertEqual(scalar("water_lake_depth_span"), WaterRender.lakeDepthSpan)
        XCTAssertEqual(scalar("water_ribbon_delta_hi"), WaterRender.ribbonDeltaHi)
        XCTAssertEqual(scalar("water_fresnel_exponent"), WaterRender.fresnelExponent)
        XCTAssertEqual(scalar("water_opacity_deep"), WaterRender.waterOpacityDeep)
        XCTAssertEqual(scalar("water_specular_grazing"), WaterRender.waterSpecularGrazing)
        let shallow = color("water_shallow_color")
        XCTAssertEqual(shallow?.r, WaterRender.waterShallowColor.r)
        XCTAssertEqual(shallow?.g, WaterRender.waterShallowColor.g)
        XCTAssertEqual(shallow?.b, WaterRender.waterShallowColor.b)
        let oxbow = color("water_oxbow_water_color")
        XCTAssertEqual(oxbow?.b, WaterRender.oxbowWaterColor.b)
    }

    func testShadersDeclareTheUniformsWithTheTableDefaults() throws {
        // Beide Wege — Literal im Body und Uniform-Default — müssen dieselbe
        // Zahl tragen, sonst zeigt die Editor-Vorschau (Material ohne SimNode)
        // anderes Wasser als das Spiel. Genau diese Drift-Klasse hat #51 beim
        // `hscale`-Default schon einmal beendet.
        for (path, names) in Self.expectedScalars {
            let shader = try RepoSource.probe(path)
            for name in names {
                let value = try XCTUnwrap(scalar(name), "\(name) fehlt in WaterUniforms.scalars")
                assertContains(shader, "uniform float \(name) = \(glsl(value));",
                               hint: "\(path): Uniform-Default von \(name) == WaterUniforms")
            }
        }
        for (path, names) in Self.expectedColors {
            let shader = try RepoSource.probe(path)
            for name in names {
                let value = try XCTUnwrap(color(name), "\(name) fehlt in WaterUniforms.colors")
                assertContains(shader, "uniform vec3 \(name) = \(glsl(value));",
                               hint: "\(path): Uniform-Default von \(name) == WaterUniforms")
            }
        }
    }

    func testEveryTableEntryIsDeclaredSomewhereAndNothingBeyondTheTable() throws {
        // Ein Tabellenwert ohne Deklaration würde von Main.gd gesetzt und von
        // keinem Shader gelesen (toter Kanal); eine `water_*`-Uniform außerhalb
        // der Tabelle bliebe still auf ihrem Default stehen — beides ist genau
        // das Fehlerbild, das der Godot-Vertragstest ausschließen soll.
        var declared = Set<String>()
        for path in Self.expectedScalars.keys {
            let shader = try RepoSource.probe(path)
            // Typ BREIT matchen und dann prüfen: eine künftige `uniform vec2
            // water_*` soll laut scheitern, nicht still am Wächter vorbei.
            let found = try shader.pairs(
                pattern: "uniform\\s+([A-Za-z0-9_]+)\\s+(water_[A-Za-z0-9_]+)")
            for (kind, name) in found {
                if kind.hasPrefix("sampler") { continue } // water_tex: Textur.
                switch kind {
                case "float":
                    XCTAssertNotNil(scalar(name),
                                    "\(path) deklariert \(name) an WaterUniforms.scalars vorbei")
                case "vec3":
                    XCTAssertNotNil(color(name),
                                    "\(path) deklariert \(name) an WaterUniforms.colors vorbei")
                default:
                    XCTFail("\(path): \(name) hat Typ \(kind) — die Brücke kennt "
                            + "nur float und vec3")
                }
                declared.insert(name)
            }
        }
        for entry in WaterUniforms.scalars {
            XCTAssertTrue(declared.contains(entry.name),
                          "\(entry.name) wird von keinem Shader deklariert")
        }
        for entry in WaterUniforms.colors {
            XCTAssertTrue(declared.contains(entry.name),
                          "\(entry.name) wird von keinem Shader deklariert")
        }
    }

    func testBridgeMarshalsTheTable() throws {
        // Die GDExtension bleibt reines Marshalling: sie reicht die Tabelle
        // durch, ohne eigene Namen oder Zahlen zu halten.
        let bridge = try RepoSource.extensionSources()
        for needle in ["func waterScalarUniformNames", "func waterScalarUniformValues",
                       "func waterColorUniformNames", "func waterColorUniformValues",
                       "WaterUniforms.scalars", "WaterUniforms.colors"] {
            assertContains(bridge, needle,
                           hint: "Brücke marshallt die Uniform-Tabelle (Issue #91)")
        }
    }

    func testMainAppliesTheCalibrationToAllWaterMaterials() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "static func apply_water_calibration",
                       hint: "Main.gd trägt die (headless testbare) Anwendung")
        for needle in ["waterScalarUniformNames()", "waterScalarUniformValues()",
                       "waterColorUniformNames()", "waterColorUniformValues()"] {
            assertContains(main, needle, hint: "Main.gd liest die Brücken-Tabelle")
        }
        // Alle drei Wasser-Materialien bekommen die Werte; das Band-Material
        // existiert im RS_WATER_STAMP-Modus nicht.
        assertContains(main, "var water_mats: Array[ShaderMaterial] = [terrain_mat, ocean_mat]",
                       hint: "Terrain- und Ozean-Material werden kalibriert")
        assertContains(main, "water_mats.append(river_mat)",
                       hint: "Band-Material wird kalibriert, wenn es existiert")
        assertContains(main, "apply_water_calibration(sim, water_mats)",
                       hint: "Der Aufbau ruft die Anwendung mit der echten Brücke auf")
    }

    // MARK: Hilfen

    private func scalar(_ name: String) -> Double? {
        WaterUniforms.scalars.first { $0.name == name }?.value
    }

    private func color(_ name: String) -> (r: Double, g: Double, b: Double)? {
        WaterUniforms.colors.first { $0.name == name }?.value
    }
}
