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
/// Was die Tests verhindern: eine Zeile in der Tabelle ohne `case` in der Brücke
/// — vorher fiel der `switch` dort auf `default: break`, das Werkzeug malte
/// einfach nichts, und im Spiel sah das wie ein Physik-Bug aus — und ein `case`,
/// das auf die falsche Terrain-Operation zeigt (dieselbe Failure-Mode, nur eine
/// Zeile weiter).
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

    /// Was jedes Werkzeug auf dem Terrain auslösen MUSS: der Methodenname und —
    /// wo er allein nicht unterscheidet (Heben und Senken teilen sich `sculpt`) —
    /// das Argument, das die Richtung festlegt.
    private static let expectedRouting: [(tool: String, call: String, marker: String?)] = [
        (tool: "raise",   call: "sculpt",  marker: "dir: 1"),
        (tool: "lower",   call: "sculpt",  marker: "dir: -1"),
        (tool: "smooth",  call: "smooth",  marker: nil),
        (tool: "flatten", call: "flatten", marker: "targetHeight: target"),
        (tool: "roughen", call: "roughen", marker: nil),
        (tool: "pickaxe", call: "pickaxe", marker: nil),
    ]

    /// Zweite Hälfte des Vertrags: die ZAHL stimmt, aber ruft ihr `case` auch die
    /// gemeinte Terrain-Operation?
    ///
    /// Der Test oben pinnt nur die Rohwerte. Ein vertauschtes Ziel im `switch`
    /// von `BrushTool.apply` (`case .smooth:` ruft `terrain.roughen`) bliebe dort
    /// grün und sieht im Spiel wieder aus wie ein Physik-Bug — dieselbe
    /// Failure-Mode wie das fehlende `case`, nur eine Zeile weiter. Also wird
    /// auch das Routing aus dem Quelltext gelesen: je `case` genau ein
    /// `terrain.…`-Aufruf, und zwar der erwartete.
    func testBrushToolRoutesEachCaseToItsTerrainOperation() throws {
        let bridge = try RepoSource.extensionSources()
        let body = try XCTUnwrap(switchBody(afterHeader: "switch self {", in: bridge),
                                 "`switch self {` von BrushTool.apply nicht in der Brücke "
                                 + "gefunden — Routing wäre damit ungeprüft")
        let cases = body.components(separatedBy: "case .").dropFirst().map { segment -> (String, [String]) in
            let name = String(segment.prefix { $0.isLetter })
            let calls = (try? captures(in: segment, pattern: "terrain\\.([a-zA-Z]+)\\(")) ?? []
            return (name, calls)
        }
        XCTAssertEqual(cases.map(\.0), Self.expectedRouting.map(\.tool),
                       "BrushTool.apply behandelt andere Werkzeuge (oder in anderer "
                       + "Reihenfolge) als dieser Vertrag erwartet")
        for (expected, actual) in zip(Self.expectedRouting, cases) {
            XCTAssertEqual(actual.1, [expected.call],
                           "Werkzeug \"\(expected.tool)\" muss genau `terrain.\(expected.call)` "
                           + "aufrufen, ruft aber \(actual.1)")
        }
        // Die Richtungs-/Ziel-Argumente stehen im Rumpf, nicht im Namen: ohne sie
        // wären Heben und Senken ununterscheidbar und Einebnen ohne sein Ziel.
        for (expected, segment) in zip(Self.expectedRouting,
                                       body.components(separatedBy: "case .").dropFirst()) {
            guard let marker = expected.marker else { continue }
            assertContains(String(segment), marker,
                           hint: "Werkzeug \"\(expected.tool)\" ohne sein unterscheidendes Argument")
        }
    }

    /// Rumpf des `switch`, der auf `header` folgt — von der öffnenden Klammer bis
    /// zur passenden schließenden. Ohne die Klammer-Zählung liefe die Suche in
    /// den restlichen Brücken-Quelltext weiter (`extensionSources()` ist ein Text
    /// aus allen Dateien) und der letzte `case` bliebe praktisch ungeprüft.
    private func switchBody(afterHeader header: String, in text: String) -> String? {
        guard let start = text.range(of: header) else { return nil }
        var depth = 1
        var index = start.upperBound
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return String(text[start.upperBound..<index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
