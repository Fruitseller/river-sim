import XCTest
@testable import SimCore
import SimRender

/// Wächter für den Uniform-Kanal der Wasser-Kalibrierung (Issues #91/#92).
///
/// Contract-Schritt (#92): die Kalibrier-Werte reisen NUR noch als benannte
/// Werte über die Brücke (`SimRender.WaterUniforms` → `SimNode` → `Main.gd`).
/// Die Shader deklarieren gleichnamige Uniforms OHNE Default und lesen sie im
/// Body — ein Literal-Default wäre wieder genau die Kopie, die #92 abschafft
/// (die Editor-Vorschau ohne SimNode ist damit bewusst unkalibriert). Gepinnt
/// wird deshalb Struktur statt Zahlen:
///   - jede Uniform-Deklaration ist default-frei und wird im Body gelesen,
///   - jeder Tabellenwert ist in mindestens einem Shader deklariert,
///   - kein Shader deklariert eine `water_*`-Uniform an der Tabelle vorbei,
///   - Brücke und `Main.gd` sind verdrahtet,
///   - die beiden Godot-Vertragstests holen ihre Vertragswerte über die Brücke.
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
        // die einzige Quelle. Der Spiegel hier pinnt die Paarung Name ↔
        // Konstante VOLLSTÄNDIG und in beide Richtungen: ein Eintrag mit
        // eigener Zahl (oder vertauschten Konstanten) fällt sofort auf, ebenso
        // ein neuer Tabellen-Eintrag ohne Spiegel-Zeile (Review zu #91 — die
        // frühere Stichprobe hätte genau das durchgelassen).
        let expectedScalars: [String: Double] = [
            "water_lake_gate_lo": WaterRender.lakeGateLo,
            "water_lake_gate_hi": WaterRender.lakeGateHi,
            "water_river_mask_lo": WaterRender.riverMaskLo,
            "water_river_mask_hi": WaterRender.riverMaskHi,
            "water_shore_lo": WaterRender.shoreLo,
            "water_shore_hi": WaterRender.shoreHi,
            "water_pond_contour_lo": WaterRender.pondContourLo,
            "water_pond_contour_hi": WaterRender.pondContourHi,
            "water_geometry_lift_lo": WaterRender.geometryLiftLo,
            "water_geometry_lift_hi": WaterRender.geometryLiftHi,
            "water_lake_depth_lo": WaterRender.lakeDepthLo,
            "water_lake_depth_span": WaterRender.lakeDepthSpan,
            "water_ribbon_still_lo": WaterRender.ribbonStillLo,
            "water_ribbon_still_hi": WaterRender.ribbonStillHi,
            "water_ribbon_delta_lo": WaterRender.ribbonDeltaLo,
            "water_ribbon_delta_hi": WaterRender.ribbonDeltaHi,
            "water_fresnel_exponent": WaterRender.fresnelExponent,
            "water_fresnel_sky_mix": WaterRender.fresnelSkyMix,
            "water_opacity_shallow": WaterRender.waterOpacityShallow,
            "water_opacity_deep": WaterRender.waterOpacityDeep,
            "water_roughness_steep": WaterRender.waterRoughnessSteep,
            "water_roughness_grazing": WaterRender.waterRoughnessGrazing,
            "water_specular_steep": WaterRender.waterSpecularSteep,
            "water_specular_grazing": WaterRender.waterSpecularGrazing,
        ]
        let expectedColors: [String: (r: Double, g: Double, b: Double)] = [
            "water_shallow_color": WaterRender.waterShallowColor,
            "water_deep_color": WaterRender.waterDeepColor,
            "water_sky_reflect_color": WaterRender.skyReflectColor,
            "water_flow_shimmer_color": WaterRender.flowShimmerColor,
            "water_delta_plume_color": WaterRender.deltaPlumeColor,
            "water_oxbow_water_color": WaterRender.oxbowWaterColor,
        ]
        XCTAssertEqual(WaterUniforms.scalars.count, expectedScalars.count,
                       "Tabellen-Eintrag ohne Spiegel-Zeile (oder umgekehrt)")
        for entry in WaterUniforms.scalars {
            XCTAssertEqual(entry.value, expectedScalars[entry.name],
                           "\(entry.name) trägt nicht seine WaterRender-Konstante")
        }
        XCTAssertEqual(WaterUniforms.colors.count, expectedColors.count,
                       "Farb-Eintrag ohne Spiegel-Zeile (oder umgekehrt)")
        for entry in WaterUniforms.colors {
            let expected = expectedColors[entry.name]
            XCTAssertEqual(entry.value.r, expected?.r, "\(entry.name).r")
            XCTAssertEqual(entry.value.g, expected?.g, "\(entry.name).g")
            XCTAssertEqual(entry.value.b, expected?.b, "\(entry.name).b")
        }
    }

    func testEveryContractValueComesFromWaterRender() {
        // Wie bei der Uniform-Tabelle: die Vertragstabelle der Godot-Wächter
        // vergibt nur Namen, `WaterRender` bleibt die einzige Quelle — der
        // Spiegel pinnt die Paarung vollständig und in beide Richtungen.
        let expected: [String: Double] = [
            "ribbonKindRiver": WaterRender.ribbonKindRiver,
            "ribbonKindDelta": WaterRender.ribbonKindDelta,
            "ribbonKindOxbow": WaterRender.ribbonKindOxbow,
            "pondContourLo": WaterRender.pondContourLo,
            "lakeRawWetDepth": WaterRender.lakeRawWetDepth,
            "oxbowMaximumOpacity": WaterRender.oxbowMaximumOpacity,
            "mouthSearchCells": Double(WaterRender.mouthSearchCells),
            "ribbonLakeSurfaceLift": WaterRender.ribbonLakeSurfaceLift,
            "ribbonSeaSurfaceSink": WaterRender.ribbonSeaSurfaceSink,
            "ribbonMinimumRank": WaterRender.ribbonMinimumRank,
            "ribbonMaxCrossSlope": WaterRender.ribbonMaxCrossSlope,
            "ribbonDeltaLo": WaterRender.ribbonDeltaLo,
        ]
        XCTAssertEqual(WaterUniforms.contract.count, expected.count,
                       "Vertrags-Eintrag ohne Spiegel-Zeile (oder umgekehrt)")
        for entry in WaterUniforms.contract {
            XCTAssertEqual(entry.value, expected[entry.name],
                           "\(entry.name) trägt nicht seine WaterRender-Konstante")
        }
        let names = WaterUniforms.contract.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "Vertragsnamen kollidieren")
    }

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

    func testEveryTableEntryIsDeclaredSomewhereAndNothingBeyondTheTable() throws {
        // Ein Tabellenwert ohne Deklaration würde von Main.gd gesetzt und von
        // keinem Shader gelesen (toter Kanal); eine `water_*`-Uniform außerhalb
        // der Tabelle bliebe still auf ihrem Null-Default stehen — beides ist
        // genau das Fehlerbild, das der Godot-Vertragstest ausschließen soll.
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
        // Die GDExtension bleibt reines Marshalling: sie reicht die Tabellen
        // durch, ohne eigene Namen oder Zahlen zu halten.
        let bridge = try RepoSource.extensionSources()
        for needle in ["func waterScalarUniformNames", "func waterScalarUniformValues",
                       "func waterColorUniformNames", "func waterColorUniformValues",
                       "func waterContractNames", "func waterContractValues",
                       "WaterUniforms.scalars", "WaterUniforms.colors",
                       "WaterUniforms.contract"] {
            assertContains(bridge, needle,
                           hint: "Brücke marshallt die Uniform-/Vertragstabelle (#91/#92)")
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

    func testGodotGuardsReadTheContractOverTheBridge() throws {
        // Bis #92 führten die beiden Godot-Vertragstests die Vertragswerte als
        // eigene Konstanten (zuletzt gepinnt vom Zahl-Wächter aus #90). Jetzt
        // holen sie sie über die Brücke — hier ist nur die VERDRAHTUNG zu
        // prüfen; welchen Wert ein Name trägt, pinnt der ausführbare Spiegel
        // `testEveryContractValueComesFromWaterRender`. Die Brücken-Aufrufe
        // stehen seit dem Review zu #105 EINMAL im geteilten Helfer statt
        // doppelt in beiden Skripten.
        let helper = try RepoSource.probe("game/tests/water_contract.gd")
        assertContains(helper, "waterContractNames()",
                       hint: "der Helfer holt die Vertragsnamen über die Brücke")
        assertContains(helper, "waterContractValues()",
                       hint: "der Helfer holt die Vertragswerte über die Brücke")
        for path in ["game/tests/water_geometry.gd", "game/tests/river_ribbons.gd"] {
            let guardScript = try RepoSource.probe(path)
            assertContains(guardScript,
                           "preload(\"res://tests/water_contract.gd\")",
                           hint: "\(path) lädt den geteilten Vertrags-Helfer")
            assertContains(guardScript, "WaterContract.fetch(sim)",
                           hint: "\(path) holt die Vertragstabelle über den Helfer")
        }
    }

    // MARK: Hilfen

    private func scalar(_ name: String) -> Double? {
        WaterUniforms.scalars.first { $0.name == name }?.value
    }

    private func color(_ name: String) -> (r: Double, g: Double, b: Double)? {
        WaterUniforms.colors.first { $0.name == name }?.value
    }
}
