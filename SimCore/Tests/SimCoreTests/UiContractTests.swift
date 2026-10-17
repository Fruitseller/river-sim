import XCTest

/// Wächter der Bedienung (Issue #174, Paket E). `Main.gd` und `UiIcon.gd` sind
/// headless nicht ausführbar, ihr Quelltext aber lesbar (s. `RepoSource`); das
/// Verhalten im Spiel prüft `game/tests/ui_layout.gd` in CI.
final class UiContractTests: XCTestCase {

    /// EIN Theme statt verstreuter Overrides: vorher stand jede Farbe und
    /// Schriftgröße als `add_theme_*_override` am einzelnen Control, und zwei
    /// Karten derselben Leiste konnten auseinanderlaufen. Seit #174 kommt das
    /// Aussehen aus `game/ui/glass_theme.tres`; Main wählt nur Typ-Varianten.
    func testMainStylesThroughTheSharedTheme() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        XCTAssertEqual(main.count(of: "add_theme_"), 0,
                       "Main.gd setzt Theme-Overrides am Control — ins Theme verschieben "
                       + "(game/ui/glass_theme.tres) und per theme_type_variation wählen")
        XCTAssertEqual(main.count(of: "StyleBoxFlat.new()"), 0,
                       "Main.gd baut eigene StyleBoxen — die gehören ins Theme")
        assertContains(main, "const UI_THEME := \"res://ui/glass_theme.tres\"",
                       hint: "Main lädt das gemeinsame Theme")
        assertContains(main, "hud.theme = ui_theme",
                       hint: "Das Theme hängt an der Wurzel aller Bedienelemente")

        // Jede Typ-Variante, die Main wählt, steht im Theme (sonst fiele sie
        // still auf den Basistyp zurück).
        let theme = try RepoSource.file("game/ui/glass_theme.tres")
        let variations = try main.captures(pattern: "&\"([A-Za-z]+)\"")
        XCTAssertFalse(variations.isEmpty, "Main.gd wählt keine Typ-Varianten?")
        for name in Set(variations) where name != "Label" {
            XCTAssertTrue(theme.contains("\(name)/base_type = "),
                          "Typ-Variante \(name) fehlt in glass_theme.tres")
        }
    }

    /// Weichzeichner hinter den Glas-Panels (Abnahmepunkt 43, Paket E). Ein
    /// StyleBox kann den Hintergrund nicht verwischen, deshalb legt Main.gd je
    /// Panel einen Rahmen (`GlassFrame`) mit einem Rechteck darunter, dessen
    /// Material `game/ui/glass_blur.gdshader` den Bildschirm über die Mip-Kette
    /// liest. Die Werte bleiben im Theme: Radius als Konstante, Eckenradius vom
    /// Glas-Panel selbst; der Shader trägt keine Kopie (default-freie Uniforms).
    /// Verdrahtung im Spiel und Deckung von Rechteck und Glas prüft
    /// `game/tests/ui_layout.gd`; das Aussehen entscheidet der Projekteigner am
    /// Bild, die Kosten stehen in `docs/zielbild-measurements.md`.
    func testGlassPanelsCarryTheBlurFromTheTheme() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        assertContains(main, "const GLASS_BLUR_SHADER := \"res://ui/glass_blur.gdshader\"",
                       hint: "Main lädt den Weichzeichner-Shader")
        assertContains(main, "frame.theme_type_variation = &\"GlassFrame\"",
                       hint: "Jedes Panel sitzt in einem Rahmen")
        assertContains(main, "backdrop.material = glass_material",
                       hint: "Das Rechteck unter dem Glas trägt das Weichzeichner-Material")
        assertContains(main, "ui_theme.get_constant(\"blur_radius\", \"GlassBackdrop\")",
                       hint: "Der Radius kommt aus dem Theme")
        assertContains(main, "ui_theme.get_color(\"dim\", \"GlassBackdrop\")",
                       hint: "Die Abdunklung (Lesbarkeit auf Schnee) kommt aus dem Theme")
        assertContains(main, "glass.corner_radius_top_left",
                       hint: "Der Eckenradius ist der des Glas-Panels, keine zweite Zahl")
        assertContains(main, "OS.get_environment(\"RS_UI_BLUR\")",
                       hint: "RS_UI_BLUR=0 ist der A/B-Schalter der Kostenmessung")
        let behind = try XCTUnwrap(main.code.range(of: "frame.add_child(backdrop)"),
                                   "Weichzeichner-Rechteck wird in den Rahmen gehängt")
        let glass = try XCTUnwrap(main.code.range(of: "frame.add_child(panel)"),
                                  "Glas wird in den Rahmen gehängt")
        XCTAssertLessThan(behind.lowerBound, glass.lowerBound,
                          "Weichzeichner VOR dem Glas hängen, sonst verdeckt er es")

        let theme = try RepoSource.file("game/ui/glass_theme.tres")
        XCTAssertTrue(theme.contains("GlassBackdrop/constants/blur_radius = "),
                      "Weichzeichner-Radius steht im Theme")
        XCTAssertTrue(theme.contains("GlassBackdrop/colors/dim = "),
                      "Abdunklung des Weichzeichners steht im Theme")
        XCTAssertTrue(theme.contains("GlassFrame/base_type = &\"PanelContainer\""),
                      "Der Rahmen ist eine Typ-Variante des Theme")

        let shader = try RepoSource.probe("game/ui/glass_blur.gdshader")
        for token in ["hint_screen_texture", "filter_linear_mipmap", "textureLod("] {
            assertContains(shader, token, hint: "Weichzeichner liest die Mip-Kette des Bildschirms")
        }
        for declaration in ["uniform float blur_px;", "uniform float corner_px;", "uniform vec4 dim;"] {
            assertContains(shader, declaration,
                           hint: "default-frei: der Wert kommt aus dem Theme, nicht aus dem Shader")
        }
    }

    /// Jedes Werkzeug trägt ein GEZEICHNETES Icon (kein Emoji mehr), und
    /// `UiIcon.gd` kennt jeden Namen aus der Werkzeug-Tabelle. Ein Tippfehler
    /// ließe sonst einen leeren Knopf stehen.
    func testEveryToolHasADrawnIcon() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        let icons = try main.captures(pattern: "\\{\"icon\": \"([^\"]+)\", \"name\"")
        let modes = try main.integers(pattern: "\"mode\": ([0-9]+)")
        XCTAssertEqual(icons.count, modes.count, "Jede Werkzeug-Zeile in TOOLS trägt \"icon\"")
        let drawer = try RepoSource.probe("game/scripts/UiIcon.gd")
        for icon in icons {
            XCTAssertTrue(icon.unicodeScalars.allSatisfy { $0.isASCII },
                          "Icon '\(icon)' ist ein Name, kein Emoji")
            assertContains(drawer, "\"\(icon)\":", hint: "UiIcon.gd zeichnet '\(icon)'")
        }
        for icon in ["pause", "play", "faster"] {
            assertContains(drawer, "\"\(icon)\":", hint: "UiIcon.gd zeichnet die Tempo-Leiste")
        }
    }

    /// Kamera-Presets (Issue #174): adaptiv aus der laufenden Welt (Diorama
    /// rahmt die Landfläche, Tal/Nah zielen auf den größten Lauf), aber EINMAL
    /// beim Drücken gerechnet, nicht je Frame. Die Rechnung (Land-Raster,
    /// Abflussfeld über die Brücke) läuft deshalb nur über
    /// `_apply_camera_preset`; einen weiteren Aufrufer (etwa in `_process`)
    /// muss dieser Wächter sehen. Verhalten prüft `game/tests/ui_layout.gd`.
    func testCameraPresetsAreComputedOnPress() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        // Je Funktion: Definition + genau ein Aufruf.
        XCTAssertEqual(main.count(of: "camera_preset_view("), 2,
                       "camera_preset_view nur aus _apply_camera_preset aufrufen")
        XCTAssertEqual(main.count(of: "frame_land("), 2, "frame_land nur aus camera_preset_view")
        XCTAssertEqual(main.count(of: "river_view("), 2, "river_view nur aus camera_preset_view")
        XCTAssertEqual(main.count(of: "\"centered\""), 0,
                       "Diorama zielt nicht mehr fest auf die Kartenmitte, sondern auf das Land")
        // RS_CAMERA rahmt im FERTIGEN Fenster: `--maximized` greift erst nach
        // _ready, das Diorama hängt am Seitenverhältnis (Folgebefund #176).
        assertContains(main, "get_viewport().size_changed.connect(",
                       hint: "RS_CAMERA folgt der Fenstergröße bis zur ersten Eingabe")
    }

    /// Pinselkuppel lesbar auf jedem Grund (Abnahme-Befund #174 E: „zu schwer
    /// zu erkennen"). Vorher 1-px-GL-Linien in blassem Cyan unter Nebel und
    /// Tonemapper. Jetzt Bänder in Bildschirm-Pixeln mit dunklem Halo, unlit,
    /// ohne Nebel, der verdeckte Teil gedämpft sichtbar. Breiten und Farben
    /// stehen nur in Main.gd und reisen im Mesh; der Shader liest sie von dort
    /// statt eine Kopie zu führen. Geometrie und Bänder prüft
    /// `game/tests/ui_layout.gd`.
    func testBrushDomeReadsOnEveryGround() throws {
        let main = try RepoSource.probe("game/scripts/Main.gd")
        XCTAssertEqual(main.count(of: "PRIMITIVE_LINES"), 0,
                       "Kuppel nicht mehr als GL-Linien (1 px, keine Breite einstellbar)")
        assertContains(main, "Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT",
                       hint: "CUSTOM0 trägt den anderen Endpunkt als RGBA-Float")
        assertContains(main, "bmat.next_pass = bmat_visible",
                       hint: "Erst der verdeckte Pass, darüber der sichtbare")
        assertContains(main, "m.set_shader_parameter(\"px_scale\", DisplayServer.screen_get_scale())",
                       hint: "Pixelbreiten in logischen Pixeln (Retina)")

        let body = try RepoSource.probe("game/shaders/brush_dome.gdshaderinc")
        for channel in ["UV.y", "UV2.x", "CUSTOM0.w", "COLOR.rgb"] {
            assertContains(body, channel, hint: "Kuppel-Shader liest \(channel) aus dem Mesh")
        }
        assertContains(body, "POSITION = clip;", hint: "Band in Bildschirm-Pixeln aufgespannt")

        for (file, hidden) in [("brush_dome.gdshader", false), ("brush_dome_hidden.gdshader", true)] {
            let pass = try RepoSource.probe("game/shaders/\(file)")
            // Roh gelesen: der Shader-Lexer kennt keine Zeichenketten und hielte
            // das `//` in `res://` für einen Kommentar.
            XCTAssertTrue(pass.raw.contains("\n#include \"res://shaders/brush_dome.gdshaderinc\"\n"),
                          "\(file) teilt den Körper")
            for mode in ["unshaded", "fog_disabled", "depth_draw_never"] {
                assertContains(pass, mode, hint: "\(file): \(mode)")
            }
            XCTAssertEqual(pass.contains("depth_test_disabled"), hidden,
                           "\(file): nur der gedämpfte Pass zeichnet ohne Tiefentest")
        }
    }
}
