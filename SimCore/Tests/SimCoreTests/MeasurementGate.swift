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
// `Diagnostic` GENAU DANN, wenn die Methode `skipUnlessMeasuring()` aufruft.
// Beide Richtungen sind nötig — sonst schleicht sich entweder ein ungegateter
// Messlauf in die Pflichtsuite, oder ein echter Wächter verschwindet still
// hinter dem Schalter.

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
                let gated = body.contains("skipUnlessMeasuring()")
                if named && !gated {
                    offenders.append("\(file): \(name) heißt „…Diagnostic“, ruft aber "
                        + "kein skipUnlessMeasuring() — der Messlauf hinge in der Pflichtsuite")
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

    // MARK: - Hilfen

    /// Alle `*.swift` neben dieser Datei. `#filePath` zeigt auf die Quelle, nicht
    /// auf das Build-Verzeichnis — der Ordner ist damit direkt der Testbaum.
    ///
    /// Diese Datei selbst ist ausgenommen: ihre Prüf-Methoden nennen
    /// `skipUnlessMeasuring()` als Zeichenkette und wären für den Scanner sonst
    /// gegatete Nicht-Diagnostics. Sie ist der Scanner, sie kann sich nicht selbst
    /// prüfen.
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
