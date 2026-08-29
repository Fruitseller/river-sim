import Foundation
import XCTest

/// Zugriff auf die ECHTEN Quelltexte der anderen Schichten (Shader, GDScript,
/// GDExtension) aus den headless-Tests heraus.
///
/// Warum Textvergleich: die Kalibrier-Zahlen stehen zwangsläufig doppelt — hier
/// als Swift-Konstante, dort als GLSL-/GDScript-Literal. Keine dieser Schichten
/// ist headless AUSFÜHRBAR (Shader nur auf der GPU, Extension nur nach ~20 min
/// Build), ihr Quelltext aber lesbar. Der Vergleich ist damit die einzige
/// Testebene, die Drift überhaupt bemerkt — Wächter für `WaterRender` und
/// `RenderContract`.
enum RepoSource {

    /// Verzeichnis der GDExtension-Quellen (relativ zur Repo-Wurzel).
    static let extensionDirectory = "Extension/Sources/RiverSimGD"

    /// Datei relativ zur Repo-Wurzel lesen.
    ///
    /// `XCTSkip` NUR, wenn die Repo-Wurzel selbst nicht erreichbar ist (das
    /// Package woanders ausgecheckt) — dann kann der Vergleich prinzipiell nicht
    /// laufen. Steht die Wurzel und fehlt die Datei, ist sie umbenannt oder
    /// verschoben worden: dann MUSS der Test rot werden, sonst überspringt sich
    /// genau die Drift weg, die er abfangen soll.
    static func file(_ relativePath: String) throws -> String {
        let url = try root().appendingPathComponent(relativePath)
        return try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8),
                             "\(relativePath) fehlt oder ist umbenannt — die "
                             + "Kalibrierung wäre damit ungeprüft")
    }

    /// s. `file(_:)` — als `SourceProbe`, Sprache nach Dateiendung. Die Wächter
    /// matchen damit auf der Code-Sicht: eine auskommentierte Zeile der
    /// Gegenseite erfüllt keinen Vertrag mehr (Issue #83).
    static func probe(_ relativePath: String) throws -> SourceProbe {
        let language: SourceProbe.Language
        switch (relativePath as NSString).pathExtension {
        case "swift": language = .swift
        case "gd": language = .gdscript
        case "gdshader": language = .gdshader
        default:
            // Laut fehlschlagen, nie überspringen: ein Skip hier wäre genau die
            // stille Entschärfung, die `file(_:)` oben ausschließt.
            struct UnknownLanguage: Error {}
            XCTFail("Keine Sprachregel für \(relativePath) — SourceProbe.Language erweitern")
            throw UnknownLanguage()
        }
        return SourceProbe(try file(relativePath), language: language)
    }

    /// ALLE Swift-Quellen der GDExtension als ein Text.
    ///
    /// Die Verträge fragen „steht dieser Wert in der Brücke?", nicht „steht er in
    /// DIESER Datei": seit Issue #53 liegt die Render-Aufbereitung in mehreren
    /// Modulen neben `SimNode`, und ein Umzug zwischen ihnen darf den Wächter
    /// weder brechen noch heimlich entschärfen. Der generierte Build-Stempel
    /// (Unterordner `Generated/`) fällt weg, weil hier nicht rekursiv gesucht
    /// wird — er enthält ohnehin nur einen Hash.
    static func extensionSources() throws -> String {
        let directory = try root().appendingPathComponent(extensionDirectory)
        let names = try XCTUnwrap(
            try? FileManager.default.contentsOfDirectory(atPath: directory.path),
            "\(extensionDirectory) fehlt — die Kalibrierung wäre damit ungeprüft")
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertFalse(names.isEmpty, "Keine Swift-Quellen in \(extensionDirectory)")
        return try names
            .map { try file("\(extensionDirectory)/\($0)") }
            .joined(separator: "\n")
    }

    private static func root() throws -> URL {
        // #filePath = <repo>/SimCore/Tests/SimCoreTests/RepoSource.swift
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let marker = root.appendingPathComponent("AGENTS.md")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("Repo-Wurzel nicht erreichbar (\(root.path) ohne AGENTS.md)")
        }
        return root
    }
}

/// Enthält `haystack` den erwarteten Quelltext-Ausschnitt? `hint` sagt, WELCHE
/// Kopplung bricht, wenn nicht.
func assertContains(_ haystack: String, _ needle: String, hint: String,
                    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(haystack.contains(needle),
                  "\(hint) — erwartet im Quelltext: \(needle)", file: file, line: line)
}

/// s. o. — auf der Code-Sicht der Probe: eine auskommentierte Zeile der
/// Gegenseite erfüllt den Vertrag nicht.
func assertContains(_ haystack: SourceProbe, _ needle: String, hint: String,
                    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(haystack.contains(needle),
                  "\(hint) — erwartet im Quelltext (ohne Kommentare): \(needle)",
                  file: file, line: line)
}

/// Alle Treffer der ersten Capture-Gruppe von `pattern`, in Vorkommens-Reihenfolge.
///
/// Die Quelltext-Verträge lesen ihre Gegenseite ausnahmslos so; die Hilfe liegt
/// deshalb hier bei `RepoSource` und nicht als private Kopie in jedem Test
/// (`ToolContractTests` und `DiagStatsContractTests` hatten sie doppelt).
func captures(in text: String, pattern: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { match in
        guard let group = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[group])
    }
}

/// s. `captures(in:pattern:)` — als Zahl.
func integers(in text: String, pattern: String) throws -> [Int] {
    try captures(in: text, pattern: pattern).compactMap(Int.init)
}

/// s. `captures(in:pattern:)` — für Muster mit ZWEI Capture-Gruppen (Name + Wert).
func pairs(in text: String, pattern: String) throws -> [(String, String)] {
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { match in
        guard let first = Range(match.range(at: 1), in: text),
              let second = Range(match.range(at: 2), in: text) else { return nil }
        return (String(text[first]), String(text[second]))
    }
}

/// Double in der Schreibweise, in der er in Shader-/GDScript-Quelltext stehen
/// MUSS, damit der Vergleich greift: Swifts eigene Ausgabe (kürzeste
/// rundreise-treue Form, immer mit Dezimalpunkt — also stets ein gültiges
/// GLSL-Float). Praktische Folge: im Shader steht `0.7`, nicht `0.70`.
///
/// Die Auflage ist mit Issue #83 BEWUSST bestätigt statt wegnormalisiert:
/// eine Zahlen-Normalisierung müsste jedes Float-Literal der Gegenseite
/// umschreiben — auch in GDScript-Zeichenketten und Format-Strings — und
/// kaufte damit eine eigene Fehlerklasse ein, um einen Fehlschlag zu sparen,
/// der ohnehin laut ist: der Wächter nennt im Hinweis die erwartete
/// Schreibweise wörtlich.
func glsl(_ value: Double) -> String { "\(value)" }

/// s. `glsl(_:)` — für Farb-Tripel.
func glsl(_ color: (r: Double, g: Double, b: Double)) -> String {
    "vec3(\(color.r), \(color.g), \(color.b))"
}
