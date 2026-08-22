import XCTest
@testable import SimCore

/// Wächter für den DIAGNOSE-Vertrag zwischen GDExtension und Game-Layer.
///
/// Über die Brücke geht ein namenloser `PackedFloat32Array`
/// (`SimNode.debugTerrainStats` → `TerrainDiagnostics.stats`). Was an welchem
/// Index steht, ist Konvention — und sie steht zwangsläufig doppelt: als
/// Reihenfolge des Array-Literals in der Extension und als `DBG_*`-Indizes plus
/// `DEBUG_STATS_COUNT` in `Main.gd`. Beide Schichten sind headless nicht
/// AUSFÜHRBAR, ihr Quelltext aber lesbar: derselbe Grund und dasselbe Verfahren
/// wie beim Werkzeug-Vertrag (`ToolContractTests`) und den Render-Verträgen
/// (s. `RepoSource`).
///
/// Was der Test verhindert: einen Wert in der Extension anhängen, einfügen oder
/// entfernen, ohne `Main.gd` mitzuziehen. Die Längenprüfung dort
/// (`stats.size() != DEBUG_STATS_COUNT`) fällt nur in ein `push_warning` und
/// lässt die Diagnose-Anzeige STILL stehen — bei einer eingefügten (statt
/// angehängten) Kennzahl passt die Länge sogar weiter und die Anzeige beschriftet
/// ab dort schlicht die falschen Zahlen. Eine Diagnose, die lügt, ist in diesem
/// Projekt teurer als eine, die fehlt („erst headless messen, dann schrauben").
final class DiagStatsContractTests: XCTestCase {

    func testDiagnosticStatsLengthMatchesTheGameIndexTable() throws {
        let bridge = try RepoSource.extensionSources()
        let main = try RepoSource.file("game/scripts/Main.gd")

        // Die Werte des Diagnose-Arrays: je Eintrag genau ein `Float(…)`. Anker ist
        // die Funktion, nicht die Datei — `extensionSources()` ist der Text ALLER
        // Brücken-Module, ein Umzug zwischen ihnen darf den Wächter nicht brechen.
        let literal = try XCTUnwrap(arrayLiteral(afterHeader: "func stats(", in: bridge),
                                    "`PackedFloat32Array([…])` von TerrainDiagnostics.stats "
                                    + "nicht in der Brücke gefunden — der Vertrag wäre damit "
                                    + "ungeprüft")
        let bridgeCount = literal.components(separatedBy: "Float(").count - 1
        XCTAssertGreaterThan(bridgeCount, 0,
                             "Kein `Float(…)`-Eintrag im Diagnose-Array gefunden — steht dort "
                             + "eine andere Schreibweise, muss dieser Wächter mitgezogen werden")

        let declared = try integers(in: main, pattern: "const DEBUG_STATS_COUNT := ([0-9]+)")
        XCTAssertEqual(declared.count, 1,
                       "DEBUG_STATS_COUNT in Main.gd nicht (oder mehrfach) gefunden")
        XCTAssertEqual(declared.first, bridgeCount,
                       "TerrainDiagnostics.stats liefert \(bridgeCount) Werte, Main.gd erwartet "
                       + "\(declared.first ?? -1) (DEBUG_STATS_COUNT) — die Anzeige würde sich "
                       + "still mit einem push_warning abschalten")

        // Jeder Index trägt einen Namen, lückenlos ab 0: sonst zeigt die Anzeige
        // eine Kennzahl unter falscher Beschriftung oder liest ins Leere.
        let indices = try integers(in: main, pattern: "const DBG_[A-Z0-9_]+ := ([0-9]+)")
        XCTAssertEqual(indices.sorted(), Array(0..<bridgeCount),
                       "Die DBG_*-Indizes in Main.gd müssen lückenlos und doppelfrei die "
                       + "\(bridgeCount) Werte von TerrainDiagnostics.stats abdecken, sind aber "
                       + "\(indices.sorted())")
    }

    /// Rumpf des ersten `PackedFloat32Array([…])` nach `header` — von der
    /// öffnenden eckigen Klammer bis zur passenden schließenden. Ohne die
    /// Klammer-Zählung liefe die Suche in den restlichen Brücken-Quelltext weiter
    /// (`extensionSources()` ist ein Text aus allen Dateien) und zählte fremde
    /// `Float(…)` mit.
    private func arrayLiteral(afterHeader header: String, in text: String) -> String? {
        guard let anchor = text.range(of: header),
              let start = text.range(of: "PackedFloat32Array([", range: anchor.upperBound..<text.endIndex)
        else { return nil }
        var depth = 1
        var index = start.upperBound
        while index < text.endIndex {
            if text[index] == "[" { depth += 1 }
            if text[index] == "]" {
                depth -= 1
                if depth == 0 { return String(text[start.upperBound..<index]) }
            }
            index = text.index(after: index)
        }
        return nil
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
