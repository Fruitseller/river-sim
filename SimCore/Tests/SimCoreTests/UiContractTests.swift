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
}
