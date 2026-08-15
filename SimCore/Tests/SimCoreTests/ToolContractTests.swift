import XCTest
@testable import SimCore

/// Wächter für den WERKZEUG-Vertrag zwischen Game-Layer und GDExtension
/// (Issue #53).
///
/// Warum hier, obwohl in SimCore kein Werkzeug-Vertrag liegt: über die Brücke
/// geht nur eine ZAHL (`SimNode.brush(mode:)`). Die Bedeutung dieser Zahl steht
/// zwangsläufig doppelt — als `case` von `BrushTool` in der Extension und als
/// `"mode"` in der Werkzeug-Tabelle von `Main.gd`. Beide Schichten sind headless
/// nicht ausführbar (Extension-Build ~20 min, GDScript nur in Godot), ihr
/// Quelltext aber lesbar: derselbe Grund und dasselbe Verfahren wie bei den
/// Render-Verträgen (s. `RepoSource`).
///
/// Was der Test verhindert: eine Zeile in der Tabelle ohne `case` in der Brücke.
/// Vorher fiel der `switch` dort auf `default: break` — das Werkzeug malte
/// einfach nichts, und im Spiel sah das wie ein Physik-Bug aus.
final class ToolContractTests: XCTestCase {

    func testBrushToolCasesMatchTheGameToolTable() throws {
        let main = try RepoSource.file("game/scripts/Main.gd")
        let bridge = try RepoSource.extensionSources()
        let tableModes = try integers(in: main, pattern: "\"mode\": ([0-9]+)")
        let bridgeCases = try integers(in: bridge, pattern: "case [a-zA-Z]+ = ([0-9]+)")
        XCTAssertFalse(tableModes.isEmpty,
                       "Werkzeug-Tabelle in Main.gd nicht gefunden — trägt jede Zeile \"mode\"?")
        XCTAssertEqual(tableModes, bridgeCases,
                       "Werkzeug-Tabelle (Main.gd) und BrushTool (Extension) sind "
                       + "auseinandergelaufen: \(tableModes) gegen \(bridgeCases)")
        // Die Zahl IST der Rohwert der Aufzählung: lückenlos ab 0, in derselben
        // Reihenfolge. Sonst müsste der Game-Layer die Zuordnung kennen, und
        // genau das soll die Tabelle abschaffen.
        XCTAssertEqual(tableModes, Array(0..<tableModes.count),
                       "Werkzeug-Modi müssen lückenlos ab 0 in Tabellen-Reihenfolge stehen")
    }

    /// Alle Zahlen der ersten Capture-Gruppe von `pattern`, in Vorkommens-Reihenfolge.
    private func integers(in text: String, pattern: String) throws -> [Int] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let group = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[group])
        }
    }
}
