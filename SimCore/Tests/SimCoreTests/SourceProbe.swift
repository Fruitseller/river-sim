import Foundation

/// DIE Quelltext-Probe der Text-Wächter (Issue #83).
///
/// Vier Wächter-Familien lasen fremden Quelltext mit je eigener Implementation
/// (Regex-Wrapper, Tiefenzähler, Brace-Matcher, String/Kommentar-Lexer). Seit
/// #79/#82 ist ausführbar geworden, was ausführbar sein kann; übrig bleibt das
/// Text-Matching gegen echt unausführbare Gegenseiten (Shader auf der GPU,
/// `Main.gd` in Godot) und das Mess-Gate über den Testquellen selbst. Deren
/// gemeinsames Fundament — Strings und Kommentare als solche lesen — liegt
/// GENAU EINMAL hier; der frühere MeasurementGate-Lexer ist die Vorlage.
///
/// Zwei Sichten, weil die Konsumenten Gegensätzliches brauchen:
/// - `code`: Kommentare entfernt, Zeichenketten wörtlich erhalten. Die
///   Vertrags-Wächter matchen hierauf — ihre Erwartungen enthalten selbst
///   String-Literale (`set_shader_parameter("hscale", …)`), aber eine
///   auskommentierte Zeile darf keinen Vertrag erfüllen.
/// - `codeWithoutStrings`: zusätzlich jeden String-Inhalt samt Anführungszeichen
///   entfernt. Das Mess-Gate fragt „steht dieser AUFRUF als Anweisung im Code?",
///   und ein Aufruf-Text in einer Zeichenkette ist keiner.
///
/// Beide Sichten erhalten die Zeilenstruktur (jedes `\n` bleibt), damit
/// zeilen-verankerte Abfragen (`^…$`) funktionieren.
struct SourceProbe {

    /// Nur die drei Sprachen, deren Quelltext im Repo tatsächlich als Text
    /// geprüft wird — jede mit ihren eigenen Kommentar- und String-Formen.
    enum Language {
        /// `//`, geschachtelte `/* */`, `"…"`, `"""…"""` (Escape `\`).
        case swift
        /// `#`, `"…"`, `'…'`, `"""…"""`, `'''…'''` (Escape `\`), keine Blockkommentare.
        case gdscript
        /// `//`, `/* */` (GLSL schachtelt nicht — großzügig wie Swift gelesen,
        /// das strippt im Zweifel MEHR und lässt den Wächter laut fehlschlagen
        /// statt still grün werden). Keine Zeichenketten: `"` ist ein Zeichen.
        case gdshader
    }

    let raw: String
    /// Kommentare entfernt, Zeichenketten erhalten.
    let code: String
    /// Kommentare UND Zeichenketten (samt Anführungszeichen) entfernt.
    let codeWithoutStrings: String

    init(_ source: String, language: Language) {
        raw = source
        (code, codeWithoutStrings) = Self.strip(source, language: language)
    }

    // MARK: Abfragen (alle auf der Code-Sicht — ein Kommentar erfüllt keinen Vertrag)

    func contains(_ needle: String) -> Bool { code.contains(needle) }

    func count(of needle: String) -> Int {
        code.components(separatedBy: needle).count - 1
    }

    /// Alle Treffer der ersten Capture-Gruppe, in Vorkommens-Reihenfolge.
    /// Reihenfolge über MEHRERE Dateien wäre Sortier-Zufall — Verträge, die
    /// Reihenfolge prüfen, lesen deshalb genau EINE Datei (Werkzeug-Tabelle,
    /// `DBG_*`-Tabelle), nie eine zusammengefügte Quelle wie
    /// `RepoSource.extensionSources()`.
    func captures(pattern: String) throws -> [String] {
        try matches(pattern: pattern).map { String(code[$0[0]]) }
    }

    /// s. `captures(pattern:)` — als Zahl.
    func integers(pattern: String) throws -> [Int] {
        try captures(pattern: pattern).compactMap(Int.init)
    }

    /// s. `captures(pattern:)` — für Muster mit ZWEI Capture-Gruppen (Name + Wert).
    func pairs(pattern: String) throws -> [(String, String)] {
        try matches(pattern: pattern).map { (String(code[$0[0]]), String(code[$0[1]])) }
    }

    /// Zeilen der String-losen Sicht — für zeilen-verankerte Anweisungs-Suchen
    /// wie das Mess-Gate.
    var codeLinesWithoutStrings: [String] {
        codeWithoutStrings.components(separatedBy: "\n")
    }

    /// Zerlegt eine Swift-Testquelle in Testmethoden. Eine Methode reicht bis
    /// zur nächsten `func`-Zeile auf Methoden-Einrückung (vier Leerzeichen,
    /// damit verschachtelte Hilfsfunktionen nicht als Test zählen) — das
    /// genügt, weil nur nach EINEM Aufruf in der Methode gesucht wird.
    /// Die Körper kommen aus `raw`: was darin Kommentar oder String ist,
    /// entscheidet der Konsument mit einer eigenen Probe über dem Körper.
    func testMethods() -> [(name: String, body: String)] {
        var result: [(String, String)] = []
        var current: String?
        var body = ""
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if let name = Self.testMethodName(line) {
                if let open = current { result.append((open, body)) }
                current = name
                body = ""
            } else if line.hasPrefix("    func ") || line.hasPrefix("    private func ") {
                if let open = current { result.append((open, body)) }
                current = nil
            }
            if current != nil { body += line + "\n" }
        }
        if let open = current { result.append((open, body)) }
        return result
    }

    /// `    func testFoo(` → `testFoo`.
    private static func testMethodName(_ line: Substring) -> String? {
        guard line.hasPrefix("    func test"), let paren = line.firstIndex(of: "(") else { return nil }
        return String(line[line.index(line.startIndex, offsetBy: "    func ".count)..<paren])
    }

    private func matches(pattern: String) throws -> [[Range<String.Index>]] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap { match in
            var groups: [Range<String.Index>] = []
            for i in 1..<match.numberOfRanges {
                guard let group = Range(match.range(at: i), in: code) else { return nil }
                groups.append(group)
            }
            return groups.isEmpty ? nil : groups
        }
    }

    // MARK: Der Lexer

    /// Ein Durchlauf, beide Sichten. Zeilenumbrüche werden in JEDEM Modus
    /// ausgegeben (auch mitten im Blockkommentar oder Literal), damit die
    /// Zeilenstruktur der Quelle erhalten bleibt.
    private static func strip(_ source: String, language: Language)
        -> (code: String, codeWithoutStrings: String) {
        let chars = Array(source)
        var code = "", sansStrings = ""
        var i = 0

        func at(_ text: String) -> Bool {
            i + text.count <= chars.count
                && String(chars[i..<i + text.count]) == text
        }
        func emit(_ c: Character) { code.append(c); sansStrings.append(c) }

        /// Öffnet an `i` eine Zeichenkette? Liefert (Öffner, Schließer).
        /// Dreifach-Zitate VOR den einfachen prüfen, sie beginnen gleich.
        func stringDelimiter() -> (open: String, close: String)? {
            let forms: [String]
            switch language {
            case .swift: forms = ["\"\"\"", "\""]
            case .gdscript: forms = ["\"\"\"", "'''", "\"", "'"]
            case .gdshader: return nil
            }
            for form in forms where at(form) { return (form, form) }
            return nil
        }

        let lineComment = language == .gdscript ? "#" : "//"
        let blockComments = language != .gdscript

        while i < chars.count {
            if at(lineComment) {
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if blockComments, at("/*") {
                var depth = 1
                i += 2
                while i < chars.count, depth > 0 {
                    if at("/*") { depth += 1; i += 2 }
                    else if at("*/") { depth -= 1; i += 2 }
                    else {
                        if chars[i] == "\n" { emit("\n") }
                        i += 1
                    }
                }
            } else if let (open, close) = stringDelimiter() {
                code += open
                i += open.count
                let multiline = open.count == 3
                while i < chars.count {
                    if chars[i] == "\\", i + 1 < chars.count {
                        code.append(chars[i]); code.append(chars[i + 1])
                        i += 2
                    } else if at(close) {
                        code += close
                        i += close.count
                        break
                    } else if chars[i] == "\n", !multiline {
                        // Eine einzeilige Zeichenkette endet spätestens am
                        // Zeilenende — sonst schluckte ein Tippfehler die Datei.
                        break
                    } else {
                        if chars[i] == "\n" { sansStrings.append("\n") }
                        code.append(chars[i])
                        i += 1
                    }
                }
            } else {
                emit(chars[i])
                i += 1
            }
        }
        return (code, sansStrings)
    }
}
