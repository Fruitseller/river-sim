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

    /// Datei relativ zur Repo-Wurzel lesen.
    ///
    /// `XCTSkip` NUR, wenn die Repo-Wurzel selbst nicht erreichbar ist (das
    /// Package woanders ausgecheckt) — dann kann der Vergleich prinzipiell nicht
    /// laufen. Steht die Wurzel und fehlt die Datei, ist sie umbenannt oder
    /// verschoben worden: dann MUSS der Test rot werden, sonst überspringt sich
    /// genau die Drift weg, die er abfangen soll.
    static func file(_ relativePath: String) throws -> String {
        // #filePath = <repo>/SimCore/Tests/SimCoreTests/RepoSource.swift
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let marker = root.appendingPathComponent("AGENTS.md")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("Repo-Wurzel nicht erreichbar (\(root.path) ohne AGENTS.md)")
        }
        let url = root.appendingPathComponent(relativePath)
        return try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8),
                             "\(relativePath) fehlt oder ist umbenannt — die "
                             + "Kalibrierung wäre damit ungeprüft")
    }
}

/// Enthält `haystack` den erwarteten Quelltext-Ausschnitt? `hint` sagt, WELCHE
/// Kopplung bricht, wenn nicht.
func assertContains(_ haystack: String, _ needle: String, hint: String,
                    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(haystack.contains(needle),
                  "\(hint) — erwartet im Quelltext: \(needle)", file: file, line: line)
}

/// Double in der Schreibweise, in der er in Shader-/GDScript-Quelltext stehen
/// MUSS, damit der Vergleich greift: Swifts eigene Ausgabe (kürzeste
/// rundreise-treue Form, immer mit Dezimalpunkt — also stets ein gültiges
/// GLSL-Float). Praktische Folge: im Shader steht `0.7`, nicht `0.70`.
func glsl(_ value: Double) -> String { "\(value)" }

/// s. `glsl(_:)` — für Farb-Tripel.
func glsl(_ color: (r: Double, g: Double, b: Double)) -> String {
    "vec3(\(color.r), \(color.g), \(color.b))"
}
