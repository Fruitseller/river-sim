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
/// Was der Test verhindert: einen Wert in der Extension anhängen, einfügen,
/// entfernen oder UMSTELLEN, ohne `Main.gd` mitzuziehen. Die Längenprüfung dort
/// (`stats.size() != DEBUG_STATS_COUNT`) fällt nur in ein `push_warning` und
/// lässt die Diagnose-Anzeige STILL stehen — bei einer eingefügten oder
/// vertauschten (statt angehängten) Kennzahl passt die Länge sogar weiter und die
/// Anzeige beschriftet ab dort schlicht die falschen Zahlen. Eine Diagnose, die
/// lügt, ist in diesem Projekt teurer als eine, die fehlt („erst headless messen,
/// dann schrauben").
final class DiagStatsContractTests: XCTestCase {

    /// DER Vertrag, in Index-Reihenfolge: je Wert der Name, unter dem `Main.gd`
    /// ihn liest, und der Ausdruck, mit dem `TerrainDiagnostics.stats` ihn füllt.
    ///
    /// Warum der AUSDRUCK und nicht bloß die Anzahl: Länge und Index-Lückenlosigkeit
    /// bleiben bei einer reinen Umstellung unverändert (`reliefSignal` ↔ `reliefLow`
    /// sind beide ein Double auf Index 16 bzw. 18) — die Anzeige beschriftet dann
    /// aber ab dort falsch, also genau die Fehldiagnose, gegen die dieser Wächter
    /// steht. Der Vergleich ist entsprechend streng: wer eine Kennzahl umbenennt
    /// oder anders ausrechnet, zieht diese Tabelle mit. Sie ist damit zugleich die
    /// lesbare Fassung des Vertrags.
    private static let expectedLayout: [(dbg: String, expression: String)] = [
        (dbg: "DBG_MIN", expression: "minimum"),
        (dbg: "DBG_MEAN", expression: "sum / divisor"),
        (dbg: "DBG_MAX", expression: "maximum"),
        (dbg: "DBG_RELIEF", expression: "relief"),
        (dbg: "DBG_DELTA_MEAN", expression: "(sum - referenceSum) / divisor"),
        (dbg: "DBG_DELTA_MAX", expression: "maximum - referenceMaximum"),
        (dbg: "DBG_BELOW_REFERENCE_VOLUME", expression: "belowReference * cellArea"),
        (dbg: "DBG_ABOVE_REFERENCE_VOLUME", expression: "aboveReference * cellArea"),
        (dbg: "DBG_NET_VOLUME", expression: "(aboveReference - belowReference) * cellArea"),
        (dbg: "DBG_MAX_REMOVED", expression: "maxRemoved"),
        (dbg: "DBG_MAX_ADDED", expression: "maxAdded"),
        (dbg: "DBG_SERVO", expression: "servo"),
        (dbg: "DBG_UPLIFT", expression: "terrain.upliftDecayRatePer100y()"),
        (dbg: "DBG_RELIEF_TARGET", expression: "terrain.cfg.reliefTarget"),
        (dbg: "DBG_REFERENCE_YEAR", expression: "referenceYear"),
        (dbg: "DBG_INVALID", expression: "invalid"),
        (dbg: "DBG_RELIEF_SIGNAL", expression: "reliefSignal"),
        (dbg: "DBG_RIDGE_CURVATURE", expression: "terrain.ridgeCurvature()"),
        (dbg: "DBG_RELIEF_LOW", expression: "reliefLow"),
    ]

    func testDiagnosticStatsLayoutMatchesTheGameIndexTable() throws {
        let bridge = try RepoSource.extensionSources()
        let main = try RepoSource.file("game/scripts/Main.gd")
        let expected = Self.expectedLayout

        // Die Werte des Diagnose-Arrays: je Eintrag genau ein `Float(…)`. Anker ist
        // der TYP samt seiner Methode, nicht die Datei — `extensionSources()` ist der
        // Text ALLER Brücken-Module: ein Umzug zwischen ihnen darf den Wächter nicht
        // brechen, ein fremdes `func stats(` in einem anderen Modul ihn aber auch
        // nicht still umlenken.
        let literal = try XCTUnwrap(
            arrayLiteral(afterHeaders: ["final class TerrainDiagnostics", "func stats("],
                         in: bridge),
            "`PackedFloat32Array([…])` von TerrainDiagnostics.stats nicht in der Brücke "
            + "gefunden — der Vertrag wäre damit ungeprüft")
        let entries = floatEntries(in: literal)
        XCTAssertFalse(entries.isEmpty,
                       "Kein `Float(…)`-Eintrag im Diagnose-Array gefunden — steht dort "
                       + "eine andere Schreibweise, muss dieser Wächter mitgezogen werden")

        // 1) Reihenfolge UND Inhalt der Werte.
        XCTAssertEqual(entries, expected.map(\.expression),
                       "TerrainDiagnostics.stats füllt andere Werte (oder in anderer "
                       + "Reihenfolge) als dieser Vertrag erwartet — die Anzeige in Main.gd "
                       + "beschriftet dann ab der ersten Abweichung falsch")

        // 2) Die Namen, unter denen Main.gd sie liest — lückenlos ab 0 und in
        //    derselben Reihenfolge. Sonst zeigt die Anzeige eine Kennzahl unter
        //    falscher Beschriftung oder liest ins Leere.
        let named = try pairs(in: main, pattern: "const (DBG_[A-Z0-9_]+) := ([0-9]+)")
        XCTAssertEqual(named.map(\.0), expected.map(\.dbg),
                       "Die DBG_*-Konstanten in Main.gd stehen in anderer Reihenfolge (oder "
                       + "unter anderen Namen) als dieser Vertrag erwartet")
        XCTAssertEqual(named.compactMap { Int($0.1) }, Array(0..<expected.count),
                       "Die DBG_*-Indizes in Main.gd müssen lückenlos und doppelfrei die "
                       + "\(expected.count) Werte von TerrainDiagnostics.stats abdecken")

        // 3) Die Längen-Konstante, an der Main.gd die Anzeige abschaltet.
        let declared = try integers(in: main, pattern: "const DEBUG_STATS_COUNT := ([0-9]+)")
        XCTAssertEqual(declared.count, 1,
                       "DEBUG_STATS_COUNT in Main.gd nicht (oder mehrfach) gefunden")
        XCTAssertEqual(declared.first, entries.count,
                       "TerrainDiagnostics.stats liefert \(entries.count) Werte, Main.gd "
                       + "erwartet \(declared.first ?? -1) (DEBUG_STATS_COUNT) — die Anzeige "
                       + "würde sich still mit einem push_warning abschalten")
    }

    /// Rumpf des ersten `PackedFloat32Array([…])`, das auf ALLE `headers` in dieser
    /// Reihenfolge folgt — von der öffnenden eckigen Klammer bis zur passenden
    /// schließenden. Ohne die Klammer-Zählung liefe die Suche in den restlichen
    /// Brücken-Quelltext weiter (`extensionSources()` ist ein Text aus allen
    /// Dateien) und zählte fremde `Float(…)` mit.
    private func arrayLiteral(afterHeaders headers: [String], in text: String) -> String? {
        var cursor = text.startIndex
        for header in headers {
            guard let hit = text.range(of: header, range: cursor..<text.endIndex)
            else { return nil }
            cursor = hit.upperBound
        }
        guard let start = text.range(of: "PackedFloat32Array([",
                                     range: cursor..<text.endIndex) else { return nil }
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

    /// Die Argumente aller `Float(…)` im Literal, in Vorkommens-Reihenfolge und mit
    /// auf einzelne Leerzeichen normiertem Zwischenraum (die Einträge sind im
    /// Quelltext über Zeilen umbrochen). Klammer-Zählung, damit `Float(f())` nicht
    /// an der inneren schließenden Klammer abgeschnitten wird.
    private func floatEntries(in literal: String) -> [String] {
        var out: [String] = []
        var cursor = literal.startIndex
        while let start = literal.range(of: "Float(", range: cursor..<literal.endIndex) {
            var depth = 1
            var index = start.upperBound
            while index < literal.endIndex {
                if literal[index] == "(" { depth += 1 }
                if literal[index] == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                index = literal.index(after: index)
            }
            guard index < literal.endIndex else { break }
            out.append(literal[start.upperBound..<index]
                .split(whereSeparator: \.isWhitespace).joined(separator: " "))
            cursor = literal.index(after: index)
        }
        return out
    }
}
