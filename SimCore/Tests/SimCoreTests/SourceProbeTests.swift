import XCTest

/// Pins für die geteilte Quelltext-Probe (Issue #83).
///
/// Jede Sprache hat genau die Fallen, die vorher ein Wächter je eigenständig
/// (und je anders) behandelt hat: Kommentar-Marker INNERHALB einer Zeichenkette
/// sind kein Kommentar, eine Code-Zeile INNERHALB eines Literals ist kein Code.
/// Beide Richtungen sind hier je Sprache gepinnt — die MeasurementGate-Tests
/// pinnen zusätzlich die Gate-Semantik, die auf dieser Probe aufsetzt.
final class SourceProbeTests: XCTestCase {

    // MARK: Swift

    func testProbeSwiftStripsLineCommentsButKeepsStrings() {
        let probe = SourceProbe("let u = \"https://x\" // Kommentar", language: .swift)
        XCTAssertEqual(probe.code, "let u = \"https://x\" ",
                       "`//` in einer URL beendet den Code nicht; die Zeichenkette bleibt")
        XCTAssertEqual(probe.codeWithoutStrings, "let u =  ",
                       "die String-lose Sicht lässt auch die Anführungszeichen weg")
    }

    func testProbeSwiftMultilineLiteralIsNoCodeButKeepsItsLines() {
        let source = "let s = \"\"\"\nzeile im literal\n\"\"\"\nlet b = 2"
        let probe = SourceProbe(source, language: .swift)
        XCTAssertEqual(probe.codeWithoutStrings.components(separatedBy: "\n").count, 4,
                       "die Zeilenstruktur bleibt erhalten (zeilen-verankerte Abfragen)")
        XCTAssertFalse(probe.codeWithoutStrings.contains("zeile im literal"))
        XCTAssertTrue(probe.codeWithoutStrings.contains("let b = 2"),
                      "nach dem Literal zählt der Code wieder")
        XCTAssertTrue(probe.code.contains("zeile im literal"),
                      "die Code-Sicht behält Literal-Inhalte (Verträge matchen Strings)")
    }

    func testProbeSwiftStripsNestedBlockComments() {
        let probe = SourceProbe("a /* x /* y */ z */ b", language: .swift)
        XCTAssertEqual(probe.code, "a  b",
                       "Swift-Blockkommentare schachteln; erst das äußere `*/` beendet")
    }

    func testProbeSwiftEscapedQuoteDoesNotEndTheString() {
        let probe = SourceProbe(#"let s = "a\"b // c" + d"#, language: .swift)
        XCTAssertTrue(probe.code.hasSuffix(" + d"),
                      "das maskierte Anführungszeichen beendet die Zeichenkette nicht")
        XCTAssertFalse(probe.codeWithoutStrings.contains("// c"),
                       "der Kommentar-Marker im String bleibt String")
    }

    // MARK: GDScript

    func testProbeGDScriptStripsHashCommentsButKeepsStrings() {
        let probe = SourceProbe("push_error(\"x # y\") # weg", language: .gdscript)
        XCTAssertEqual(probe.code, "push_error(\"x # y\") ",
                       "`#` in einer Zeichenkette ist kein Kommentar")
    }

    func testProbeGDScriptKnowsSingleQuotedStrings() {
        let probe = SourceProbe("var a = 'x # y' # weg", language: .gdscript)
        XCTAssertEqual(probe.code, "var a = 'x # y' ")
    }

    func testProbeGDScriptTripleQuotedLiteralIsNoCode() {
        let source = "var s = \"\"\"\nconst DBG_FAKE := 9\n\"\"\"\nconst DBG_REAL := 1"
        let probe = SourceProbe(source, language: .gdscript)
        XCTAssertFalse(probe.codeWithoutStrings.contains("DBG_FAKE"))
        XCTAssertTrue(probe.codeWithoutStrings.contains("DBG_REAL"))
    }

    // MARK: gdshader

    func testProbeShaderStripsBothCommentForms() {
        let probe = SourceProbe("float a = 0.5; // x\nfloat b /* mitte */ = 1.0;",
                                language: .gdshader)
        XCTAssertEqual(probe.code, "float a = 0.5; \nfloat b  = 1.0;")
    }

    func testProbeShaderHasNoStrings() {
        // GLSL kennt keine Zeichenketten: ein `"` ist ein gewöhnliches Zeichen
        // und darf keinen String-Modus öffnen, der den Rest der Datei schluckt.
        let probe = SourceProbe("a \" b // weg\nc", language: .gdshader)
        XCTAssertEqual(probe.code, "a \" b \nc")
    }

    // MARK: Abfragen laufen auf der Code-Sicht

    func testProbeQueriesIgnoreCommentedOutSource() throws {
        let source = "# const DBG_ALT := 0\nconst DBG_MIN := 0\nconst DBG_MAX := 1"
        let probe = SourceProbe(source, language: .gdscript)
        XCTAssertEqual(try probe.pairs(pattern: "const (DBG_[A-Z_]+) := ([0-9]+)").map(\.0),
                       ["DBG_MIN", "DBG_MAX"],
                       "eine auskommentierte Zeile ist kein Vertrag")
        XCTAssertEqual(try probe.integers(pattern: "const DBG_[A-Z_]+ := ([0-9]+)"), [0, 1])
        XCTAssertFalse(probe.contains("DBG_ALT"))
        XCTAssertEqual(probe.count(of: "const DBG_"), 2)
    }

    func testProbeCapturesKeepOccurrenceOrder() throws {
        let probe = SourceProbe("\"mode\": 0\n\"mode\": 1\n\"mode\": 2", language: .gdscript)
        XCTAssertEqual(try probe.integers(pattern: "\"mode\": ([0-9]+)"), [0, 1, 2],
                       "die Reihenfolge IST der Vertrag (Werkzeug-Tabelle)")
    }

    func testProbeEscapedLineEndKeepsTheLineCount() {
        // `\` am Zeilenende eines `"""`-Literals ist eine Zeilenfortsetzung —
        // die Zeile muss auch in der String-losen Sicht gezählt werden, sonst
        // verrutschen zeilen-verankerte Abfragen.
        let source = "let s = \"\"\"\na\\\nb\n\"\"\"\nx()"
        let probe = SourceProbe(source, language: .swift)
        XCTAssertEqual(probe.codeWithoutStrings.components(separatedBy: "\n").count,
                       source.components(separatedBy: "\n").count)
    }

    func testProbeRefusesOrderQueriesOnAJoinedSource() throws {
        // Über mehrere Dateien gefügt (RepoSource.extensionSources) ist jede
        // Vorkommens-Reihenfolge alphabetischer Sortier-Zufall — kein Vertrag.
        let joined = SourceProbe("let a = 1", language: .swift,
                                 joinedFromMultipleFiles: true)
        XCTAssertTrue(joined.contains("let a"),
                      "reihenfolge-unabhängige Abfragen bleiben erlaubt")
        XCTAssertThrowsError(try joined.captures(pattern: "let ([a-z]+)"))
        XCTAssertThrowsError(try joined.pairs(pattern: "let ([a-z]+) = ([0-9]+)"))
    }

    // MARK: Testmethoden-Zerlegung (Swift, für das Mess-Gate)

    func testProbeSplitsTestMethodsAndClosesThemAtTheNextFunc() {
        let source = """
        final class T: XCTestCase {
            func testEins() {
                körperEins()
            }
            private func helfer() {
                keinTest()
            }
            func testZwei() throws {
                körperZwei()
            }
        }
        """
        let methods = SourceProbe(source, language: .swift).testMethods()
        XCTAssertEqual(methods.map(\.name), ["testEins", "testZwei"])
        XCTAssertTrue(methods[0].body.contains("körperEins"))
        XCTAssertFalse(methods[0].body.contains("keinTest"),
                       "die nächste `func`-Zeile schließt den Körper")
        XCTAssertTrue(methods[1].body.contains("körperZwei"))
    }
}
