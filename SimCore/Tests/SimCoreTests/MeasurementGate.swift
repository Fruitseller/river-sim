import XCTest

// Gate für Mess-, Sweep- und Diagnose-Tests (Issue #52).
//
// Diese Tests prüfen nichts (oder fast nichts), sondern DRUCKEN die Tabellen,
// die in `docs/*-measurements.md` und in den Kalibrier-Kommentaren von
// `Config.swift` stehen. Sie kosten den Großteil der Suiten-Laufzeit — teils
// zwölf 20.000-Jahre-Läufe für eine einzige Zeile. In der Pflichtsuite (jeder
// Push, jeder PR) haben sie damit nichts verloren: sie können gar nicht rot
// werden, aber sie treiben die CI-Zeit.
//
// EIN Schalter für alle: `RS_MEASURE=1`. Vorher gab es drei (`RS_MEASURE`,
// `RS_SWEEP`, `RS_EVAP_MEASURE`) und ein Dutzend ungegateter Diagnose-Tests —
// wer eine Messreihe reproduzieren wollte, musste erst herausfinden, welcher
// Schalter gerade gemeint ist.
//
//     RS_MEASURE=1 swift test -c release --package-path SimCore \
//         -Xswiftc -swift-version -Xswiftc 5 --filter testDtSpreadDiagnostic
//
// Konvention, von `MeasurementGateTests` erzwungen: Der Methodenname endet auf
// `Diagnostic` GENAU DANN, wenn die Methode `try skipUnlessMeasuring()` aufruft.
// Beide Richtungen sind nötig — sonst schleicht sich entweder ein ungegateter
// Messlauf in die Pflichtsuite, oder ein echter Wächter verschwindet still
// hinter dem Schalter. Das `try` gehört zur Konvention: `try?` verschluckt den
// geworfenen Skip (s. `gatesOnMeasurement`).

extension XCTestCase {
    /// Überspringt den Test, außer `RS_MEASURE` steht **exakt** auf `1`.
    ///
    /// Bewusst der Gleichheitsvergleich und nicht „gesetzt?": ein versehentlich
    /// exportiertes `RS_MEASURE=0` (Shell-History, CI-Env-Default) würde sonst die
    /// ~270 s teuren Messläufe zurück in die Pflichtsuite holen — genau der
    /// Zustand, den das Gate abstellt. `1` ist der einzige Wert, den Doku und
    /// Aufrufe im Repo nennen (AGENTS.md, docs/ci-measurements.md); jeder andere
    /// Wert ist ein Versehen und zählt als „aus". Der Konventions-Wächter unten
    /// prüft nur „Diagnostic ↔ skipUnlessMeasuring()", nie den Wert — der muss
    /// hier stimmen.
    func skipUnlessMeasuring(file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RS_MEASURE"] == "1",
            "Mess-/Sweep-Test — nur mit RS_MEASURE=1 (Laufzeit, Issue #52)",
            file: file, line: line)
    }
}

/// Wächter über die Konvention selbst: Ohne ihn wäre „alle Messläufe sind
/// gegatet" eine Review-Zusage statt einer geprüften Eigenschaft, und genau das
/// war der Zustand, den Issue #52 abgestellt hat.
///
/// Der Test liest die Testquellen als Text. Reflexion über die Testmethoden
/// wäre der direktere Weg, steht aber nur unter dem ObjC-Runtime (Darwin) zur
/// Verfügung — die Pflichtsuite läuft auf Linux.
final class MeasurementGateTests: XCTestCase {
    func testDiagnosticSuffixAndGateAgreeInEveryTestFile() throws {
        var offenders: [String] = []
        for (file, source) in try testSources() {
            for (name, body) in testMethods(in: source) {
                let named = name.hasSuffix("Diagnostic")
                let gated = gatesOnMeasurement(body)
                if named && !gated {
                    offenders.append("\(file): \(name) heißt „…Diagnostic“, ruft aber "
                        + "kein wirksames `try skipUnlessMeasuring()` als eigene Anweisung "
                        + "am Zeilenanfang — der Messlauf hinge in der Pflichtsuite. "
                        + "Nicht wirksam: `try?`, auskommentiert, in einer Zeichenkette, "
                        + "geschachtelt in `if`/`XCTAssertNoThrow`")
                } else if !named && gated {
                    offenders.append("\(file): \(name) ist gegatet, heißt aber nicht "
                        + "„…Diagnostic“ — ein echter Wächter würde hier still übersprungen")
                }
            }
        }
        XCTAssertEqual(offenders, [], "Konvention verletzt:\n" + offenders.joined(separator: "\n"))
    }

    /// Gegenprobe zur Selbstprüfung oben: Der Scanner muss überhaupt etwas
    /// finden. Ein fehlgeschlagener Datei-Zugriff (Package woanders ausgecheckt)
    /// hätte sonst dasselbe Ergebnis wie „alles sauber".
    func testScannerSeesTheSuite() throws {
        let sources = try testSources()
        XCTAssertGreaterThan(sources.count, 10, "Testquellen nicht gefunden")
        let methods = sources.flatMap { testMethods(in: $0.source) }
        XCTAssertGreaterThan(methods.count, 100, "Testmethoden nicht erkannt")
        XCTAssertTrue(methods.contains { $0.name.hasSuffix("Diagnostic") },
                      "kein einziger Messlauf erkannt — Scanner oder Konvention kaputt")
    }

    /// Gegenprobe zum Erkenner unten: Schreibweisen, die WIE ein Gate aussehen und
    /// keins sind, müssen als „ungegatet“ durchfallen; wirksame Varianten der
    /// Schreibweise dagegen müssen zählen. Ohne diesen Test wäre die Verschärfung
    /// selbst ungeprüft — der alte `contains`-Scanner hätte jede der Zeilen hier
    /// als Gate gezählt.
    func testOnlyAnEffectiveGateCallCounts() {
        XCTAssertTrue(gatesOnMeasurement("        try skipUnlessMeasuring()\n"))
        XCTAssertTrue(gatesOnMeasurement("        try skipUnlessMeasuring() // Messlauf\n"))
        XCTAssertTrue(gatesOnMeasurement("        try  skipUnlessMeasuring ()\n"),
                      "Leerraum ändert die Wirkung nicht")
        XCTAssertTrue(gatesOnMeasurement(
            "        try skipUnlessMeasuring(file: #filePath, line: #line)\n"),
                      "die Argumente haben Defaults, explizit ist genauso wirksam")
        XCTAssertFalse(gatesOnMeasurement("        try? skipUnlessMeasuring()\n"),
                       "`try?` verschluckt den geworfenen Skip — kein Gate")
        XCTAssertFalse(gatesOnMeasurement("        // try skipUnlessMeasuring()\n"),
                       "auskommentiert ist kein Gate")
        XCTAssertFalse(gatesOnMeasurement("        print(\"skipUnlessMeasuring()\")\n"),
                       "eine Zeichenkette ist kein Gate")
        XCTAssertFalse(gatesOnMeasurement("        print(\"try skipUnlessMeasuring()\")\n"),
                       "auch als vollständige Zeichenkette kein Gate")
    }

    /// Der Erkenner liest Zeichenketten und Kommentare als solche — beides hat
    /// eine Richtung, in die es schiefgeht, und beide sind hier gepinnt:
    ///
    /// - `//` INNERHALB einer Zeichenkette (jede URL) ist kein Kommentarbeginn.
    ///   Ein naives Abschneiden am ersten `//` würde ein danach stehendes Gate
    ///   verschlucken und den Messlauf fälschlich als ungegatet melden.
    /// - eine Gate-Zeile INNERHALB eines `"""`-Literals ist kein Aufruf. Sie
    ///   naiv zu zählen wäre der gefährlichere Fehler: ein ungegateter Messlauf
    ///   gälte als gegatet, also genau der False-Positive, den Issue #52 abstellt.
    func testStringsAndCommentsAreToldApart() {
        XCTAssertTrue(gatesOnMeasurement(
            "        let u = \"https://example.org\"\n        try skipUnlessMeasuring()\n"),
                      "`//` in einer URL beendet den Code nicht")
        XCTAssertFalse(gatesOnMeasurement(
            "        let s = \"\"\"\n        try skipUnlessMeasuring()\n        \"\"\"\n"),
                       "im mehrzeiligen Literal steht Text, kein Aufruf")
        XCTAssertTrue(gatesOnMeasurement(
            "        let s = \"\"\"\n        egal\n        \"\"\"\n        try skipUnlessMeasuring()\n"),
                      "nach dem Literal zählt der Aufruf wieder")
    }

    // MARK: - Hilfen

    /// Ruft dieser Methodenkörper das Gate WIRKSAM auf?
    ///
    /// Bewusst nicht `body.contains("skipUnlessMeasuring()")`: dieser Test ist der
    /// Wächter über „kein Messlauf hängt ungegatet in der Pflichtsuite“, und ein
    /// Textfund allein belegt das nicht. Drei Schreibweisen sahen für den
    /// `contains`-Scanner wie ein Gate aus und sind keins:
    ///
    /// - `try? skipUnlessMeasuring()` — `XCTSkipUnless` signalisiert den Skip durch
    ///   WERFEN, `try?` verschluckt ihn. Der ~270 s teure Messlauf liefe dann
    ///   vollständig, obwohl `RS_MEASURE` aus ist, und der Wächter hier hätte ihn
    ///   als gegatet abgesegnet. Genau dieser Fehler stand real im Baum
    ///   (`try? XCTSkipIf` in `EndorheicEvaporation`).
    /// - eine auskommentierte Zeile oder der Name in einer Zeichenkette,
    /// - dieselbe Zeile innerhalb eines mehrzeiligen `"""`-Literals.
    ///
    /// Gelesen wird deshalb der CODE-Teil jeder Zeile (`codeLines`, kennt
    /// Zeichenketten und Kommentare) und darin die Anweisung als Ganzes: `try`,
    /// der Aufrufname, eine Argumentliste, Zeilenende. Leerraum und die explizit
    /// gesetzten Default-Argumente (`file:`/`line:`) sind damit erlaubt — sie
    /// ändern die Wirkung nicht, und ein Autor, der sie notiert, soll nicht an
    /// einem CI-Bruch über eine Schreibweise rätseln. Am Zeilenanfang bleibt es
    /// verankert: ein Gate in einem `if`-Zweig oder in `XCTAssertNoThrow(…)`
    /// wirkt eben NICHT zuverlässig und soll auffallen.
    private func gatesOnMeasurement(_ body: String) -> Bool {
        codeLines(of: body).contains { line in
            line.trimmingCharacters(in: .whitespaces)
                .range(of: #"^try\s+skipUnlessMeasuring\s*\([^()]*\)$"#,
                       options: .regularExpression) != nil
        }
    }

    /// Jede Zeile ohne Zeichenketten-Inhalt und ohne Kommentar.
    ///
    /// Der kleine Zeichen-Scanner ersetzt `range(of: "//")`: der kannte keinen
    /// String-Kontext, schnitt also an jedem `https://…` mitten in der Zeile ab
    /// und zählte Gate-Zeilen in `"""`-Literalen mit. Raw Strings (`#"…"#`)
    /// braucht er nicht zu kennen — ihre Anführungszeichen öffnen und schließen
    /// hier genauso, der Inhalt fällt damit ebenfalls weg.
    private func codeLines(of body: String) -> [String] {
        var result: [String] = []
        var inMultiline = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let chars = Array(line)
            var code = ""
            var inString = false
            var escaped = false
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if inMultiline {
                    if isTripleQuote(chars, i) { inMultiline = false; i += 3; continue }
                    i += 1
                } else if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true }
                    else if c == "\"" { inString = false }
                    i += 1
                } else if isTripleQuote(chars, i) {
                    inMultiline = true
                    i += 3
                } else if c == "\"" {
                    inString = true
                    i += 1
                } else if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                    break
                } else {
                    code.append(c)
                    i += 1
                }
            }
            result.append(code)
        }
        return result
    }

    private func isTripleQuote(_ chars: [Character], _ i: Int) -> Bool {
        i + 2 < chars.count && chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\""
    }

    /// Alle `*.swift` neben dieser Datei. `#filePath` zeigt auf die Quelle, nicht
    /// auf das Build-Verzeichnis — der Ordner ist damit direkt der Testbaum.
    ///
    /// Diese Datei selbst ist ausgenommen: ihre Prüf-Methoden führen den
    /// Gate-Aufruf absichtlich in allen Schreibweisen als Zeichenkette
    /// (`testOnlyAnEffectiveGateCallCounts`). Sie ist der Scanner, sie kann sich
    /// nicht selbst prüfen.
    private func testSources() throws -> [(file: String, source: String)] {
        let own = URL(fileURLWithPath: #filePath).lastPathComponent
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let names = try XCTUnwrap(try? FileManager.default.contentsOfDirectory(atPath: dir.path),
                                  "Testquellen unter \(dir.path) nicht lesbar")
        return try names.filter { $0.hasSuffix(".swift") && $0 != own }.sorted().map {
            ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))
        }
    }

    /// Zerlegt eine Quelldatei in Testmethoden. Eine Methode reicht bis zur
    /// nächsten `func`-Zeile auf Methoden-Einrückung — das genügt, weil nur nach
    /// EINEM Aufruf in der Methode gesucht wird.
    private func testMethods(in source: String) -> [(name: String, body: String)] {
        var result: [(String, String)] = []
        var current: String?
        var body = ""
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if let name = testMethodName(line) {
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

    /// `    func testFoo(` → `testFoo`. Nur Methoden-Einrückung (vier Leerzeichen),
    /// damit verschachtelte Hilfsfunktionen nicht als Test zählen.
    private func testMethodName(_ line: Substring) -> String? {
        let prefix = "    func test"
        guard line.hasPrefix(prefix), let paren = line.firstIndex(of: "(") else { return nil }
        return String(line[line.index(line.startIndex, offsetBy: 9)..<paren])
    }
}
