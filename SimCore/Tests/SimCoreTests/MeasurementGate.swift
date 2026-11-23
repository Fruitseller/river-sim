import XCTest

extension XCTestCase {
    func skipUnlessMeasuring(file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RS_MEASURE"] == "1",
            "Mess-/Sweep-Test — nur mit RS_MEASURE=1 (Laufzeit, Issue #52)",
            file: file, line: line)
    }
}

func flushStdout() {
    fflush(nil)
}

final class MeasurementGateTests: XCTestCase {
    func testDiagnosticSuffixAndGateAgreeInEveryTestFile() throws {
        var offenders: [String] = []
        for (file, source) in try testSources() {
            for (name, body) in SourceProbe(source, language: .swift).testMethods() {
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

    func testScannerSeesTheSuite() throws {
        let sources = try testSources()
        XCTAssertGreaterThan(sources.count, 10, "Testquellen nicht gefunden")
        let methods = sources.flatMap { SourceProbe($0.source, language: .swift).testMethods() }
        XCTAssertGreaterThan(methods.count, 100, "Testmethoden nicht erkannt")
        XCTAssertTrue(methods.contains { $0.name.hasSuffix("Diagnostic") },
                      "kein einziger Messlauf erkannt — Scanner oder Konvention kaputt")
    }

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

    private func gatesOnMeasurement(_ body: String) -> Bool {
        SourceProbe(body, language: .swift).codeLinesWithoutStrings.contains { line in
            line.trimmingCharacters(in: .whitespaces)
                .range(of: #"^try\s+skipUnlessMeasuring\s*\([^()]*\)$"#,
                       options: .regularExpression) != nil
        }
    }

    private func testSources() throws -> [(file: String, source: String)] {
        let own = URL(fileURLWithPath: #filePath).lastPathComponent
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let names = try XCTUnwrap(try? FileManager.default.contentsOfDirectory(atPath: dir.path),
                                  "Testquellen unter \(dir.path) nicht lesbar")
        return try names.filter { $0.hasSuffix(".swift") && $0 != own }.sorted().map {
            ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))
        }
    }

}
