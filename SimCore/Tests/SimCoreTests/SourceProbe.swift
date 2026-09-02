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
        /// daher kann ein verschachteltes `/*` in einem echten GLSL-Kommentar
        /// zu viel nachfolgenden Code strippen und einen legitimen Vertragstreffer
        /// verschwinden lassen). Keine Zeichenketten: `"` ist ein Zeichen.
        case gdshader
    }

    let raw: String
    /// Kommentare entfernt, Zeichenketten erhalten.
    let code: String
    /// Kommentare UND Zeichenketten (samt Anführungszeichen) entfernt.
    let codeWithoutStrings: String
    /// Mehrere Dateien zu EINEM Text gefügt (`RepoSource.extensionSources()`)?
    /// Dann ist jede Vorkommens-Reihenfolge Sortier-Zufall und die
    /// Reihenfolge-Abfragen unten verweigern sich.
    let joinedFromMultipleFiles: Bool

    init(_ source: String, language: Language, joinedFromMultipleFiles: Bool = false) {
        raw = source
        self.joinedFromMultipleFiles = joinedFromMultipleFiles
        (code, codeWithoutStrings) = Self.strip(source, language: language)
    }

    // MARK: Abfragen (alle auf der Code-Sicht — ein Kommentar erfüllt keinen Vertrag)

    func contains(_ needle: String) -> Bool { code.contains(needle) }

    /// Zählt nicht überlappende Vorkommen in der Code-Sicht.
    func count(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var remainder = code[...]
        while let range = remainder.firstRange(of: needle) {
            count += 1
            remainder = remainder[range.upperBound...]
        }
        return count
    }

    /// Zählt Vorkommen als GANZER Bezeichner in der Code-Sicht: ein Treffer,
    /// an dem links oder rechts ein Bezeichner-Zeichen anschließt, zählt
    /// nicht. Für Namens-Verträge statt `count(of:)` nehmen (Review zu #105):
    /// dort erfüllte sonst ein längerer Name mit gleichem Präfix
    /// (`water_shore_lo_scaled`) den Vertrag des kürzeren still mit.
    func count(ofIdentifier name: String) -> Int {
        guard !name.isEmpty else { return 0 }
        func isIdentChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_"
        }
        var count = 0
        var searchStart = code.startIndex
        while let range = code.range(of: name, range: searchStart..<code.endIndex) {
            let boundedLeft = range.lowerBound == code.startIndex
                || !isIdentChar(code[code.index(before: range.lowerBound)])
            let boundedRight = range.upperBound == code.endIndex
                || !isIdentChar(code[range.upperBound])
            if boundedLeft && boundedRight { count += 1 }
            searchStart = range.upperBound
        }
        return count
    }

    /// Alle Treffer der ersten Capture-Gruppe, in Vorkommens-Reihenfolge.
    /// Reihenfolge über MEHRERE Dateien wäre Sortier-Zufall — Verträge, die
    /// Reihenfolge prüfen, lesen deshalb genau EINE Datei (Werkzeug-Tabelle,
    /// `DBG_*`-Tabelle). Auf einer zusammengefügten Quelle wie
    /// `RepoSource.extensionSources()` verweigert sich der Aufruf laut,
    /// statt eine Alphabetisierungs-Reihenfolge als Vertrag auszugeben.
    func captures(pattern: String) throws -> [String] {
        try refuseOrderQueryOnJoinedSource()
        return try matches(pattern: pattern).map { String(code[$0[0]]) }
    }

    /// s. `captures(pattern:)` — als Zahl.
    func integers(pattern: String) throws -> [Int] {
        try captures(pattern: pattern).compactMap(Int.init)
    }

    /// s. `captures(pattern:)` — für Muster mit ZWEI Capture-Gruppen (Name + Wert).
    func pairs(pattern: String) throws -> [(String, String)] {
        try refuseOrderQueryOnJoinedSource()
        return try matches(pattern: pattern).map { (String(code[$0[0]]), String(code[$0[1]])) }
    }

    /// Der geworfene Fehler lässt den aufrufenden Test laut fehlschlagen
    /// (bewusst kein `XCTFail` hier: so bleibt die Verweigerung selbst pinbar).
    struct OrderQueryOnJoinedSource: Error, CustomStringConvertible {
        let description = "Reihenfolge-Abfrage auf einer aus mehreren Dateien "
            + "gefügten Probe — die Treffer-Reihenfolge wäre alphabetischer "
            + "Sortier-Zufall. Die eine Datei direkt proben."
    }

    private func refuseOrderQueryOnJoinedSource() throws {
        if joinedFromMultipleFiles { throw OrderQueryOnJoinedSource() }
    }

    /// Zeilen der String-losen Sicht — für zeilen-verankerte Anweisungs-Suchen
    /// wie das Mess-Gate.
    var codeLinesWithoutStrings: [String] {
        codeWithoutStrings.components(separatedBy: "\n")
    }

    /// Zerlegt eine Swift-Quelle in Methoden. Eine Methode reicht bis zur
    /// nächsten Deklarations-Zeile auf Methoden-Einrückung (vier Leerzeichen,
    /// damit verschachtelte Hilfsfunktionen nicht als eigene Methode zählen) —
    /// das genügt, weil nur nach EINEM Aufruf im Körper gesucht wird.
    /// Die Zerlegung läuft bewusst auf `codeWithoutStrings`: Kommentare und
    /// Literale dürfen weder eine Methode öffnen noch ihren Körper beenden.
    func swiftMethods() -> [(name: String, body: String)] {
        var result: [(String, String)] = []
        var current: String?
        var body = ""
        for line in codeWithoutStrings.split(separator: "\n", omittingEmptySubsequences: false) {
            if let name = Self.methodName(line) {
                if let open = current { result.append((open, body)) }
                current = name
                body = ""
            }
            if current != nil { body += line + "\n" }
        }
        if let open = current { result.append((open, body)) }
        return result
    }

    /// s. `swiftMethods()` — nur die XCTest-Methoden (Name beginnt mit `test`).
    /// Das Mess-Gate fragt nach genau diesen.
    func testMethods() -> [(name: String, body: String)] {
        swiftMethods().filter { $0.name.hasPrefix("test") }
    }

    /// `    func foo(`, `    private func foo(`, `    @Callable func foo(` → `foo`.
    /// Vor `func` darf nur Deklarations-Vorspann stehen (Attribute,
    /// Zugriffsschutz, `static` & Co.) — sonst wäre eine gewöhnliche Zeile mit
    /// dem Teilwort `func` eine Methode, und die Zerlegung zerfiele.
    private static func methodName(_ line: Substring) -> String? {
        guard line.hasPrefix("    "), !line.hasPrefix("     ") else { return nil }
        let tokens = line.dropFirst(4).split(separator: " ")
        guard let keyword = tokens.firstIndex(of: "func"), keyword + 1 < tokens.count,
              tokens[..<keyword].allSatisfy({
                  $0.hasPrefix("@") || declarationModifiers.contains(String($0))
              })
        else { return nil }
        let signature = tokens[keyword + 1]
        return String(signature[signature.startIndex..<(signature.firstIndex(of: "(")
                                                        ?? signature.endIndex)])
    }

    /// Was zwischen Einrückung und `func` stehen darf (Attribute zählt
    /// `methodName` selbst über das führende `@`).
    private static let declarationModifiers: Set<String> = [
        "public", "private", "internal", "fileprivate", "open", "package",
        "static", "class", "final", "override", "mutating", "nonmutating",
        "nonisolated", "convenience", "required", "dynamic", "distributed",
        "consuming", "borrowing", "isolated",
    ]

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

        /// Swift und GDScript schließen einen String-Trenner nur nach einer
        /// geraden Zahl unmittelbar vorangehender Backslashes.
        func delimiterIsEscaped() -> Bool {
            var backslashes = 0
            var cursor = i
            while cursor > 0, chars[cursor - 1] == "\\" {
                backslashes += 1
                cursor -= 1
            }
            return backslashes % 2 == 1
        }

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
                    if at(close), !delimiterIsEscaped() {
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
