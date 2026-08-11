import XCTest
@testable import SimCore

/// Wächter für die Render-Kalibrierung des Wasserfelds (Issue #32, `WaterRender`).
///
/// Warum hier: die Kalibrierung wirkt in der GDExtension
/// (`SimNode.waterFieldBytes`) und im Shader (`game/shaders/terrain.gdshader`) —
/// beides ist headless nicht ausführbar (Extension-Build ~20 min, Shader läuft nur
/// auf der GPU). Die Zahlen selbst sind aber reine Arithmetik, und genau ihre
/// PAARUNGEN sind das Fragile: Komponenten-Fade ↔ Shader-Smoothstep ↔
/// Altarm-Stempel. Diese Tests pinnen die Paarungen, damit spätere Änderungen die
/// Kalibrierung nicht still verschieben.
final class WaterRenderTests: XCTestCase {

    // MARK: Kohärenz-Fade: reine Funktion der Komponentengröße

    func testComponentFadeWindow() {
        // Fenster 10 → 50 Zellen, linear; außerhalb geklemmt.
        XCTAssertEqual(WaterRender.componentFadeLoCells, 10.0)
        XCTAssertEqual(WaterRender.componentFadeHiCells, 50.0)
        XCTAssertEqual(WaterRender.componentFade(cells: 0), 0.0)
        XCTAssertEqual(WaterRender.componentFade(cells: 10), 0.0)
        XCTAssertEqual(WaterRender.componentFade(cells: 11), 0.025, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.componentFade(cells: 30), 0.5, accuracy: 1e-12)
        XCTAssertEqual(WaterRender.componentFade(cells: 50), 1.0)
        XCTAssertEqual(WaterRender.componentFade(cells: 100_000), 1.0)
    }

    func testComponentFadeIsMonotonicAndBounded() {
        var previous = -1.0
        for cells in 0...200 {
            let fade = WaterRender.componentFade(cells: cells)
            XCTAssertGreaterThanOrEqual(fade, previous, "Fade darf nicht fallen")
            XCTAssertGreaterThanOrEqual(fade, 0.0)
            XCTAssertLessThanOrEqual(fade, 1.0)
            previous = fade
        }
    }

    func testFadeReplacesHardCutoffWithoutJump() {
        // Kern der Umstellung (#32): kein Sprung mehr an der alten harten Schwelle
        // 25 Zellen — dort PLOPPTEN wachsende Seen. Der größte Schritt zwischen
        // benachbarten Größen ist eine Zelle Fenster-Breite.
        let step = 1.0 / (WaterRender.componentFadeHiCells - WaterRender.componentFadeLoCells)
        for cells in 0..<200 {
            let delta = WaterRender.componentFade(cells: cells + 1)
                - WaterRender.componentFade(cells: cells)
            XCTAssertLessThanOrEqual(delta, step + 1e-12)
        }
        XCTAssertGreaterThan(WaterRender.componentFade(cells: 25), 0.0)
        XCTAssertLessThan(WaterRender.componentFade(cells: 25), 1.0,
                          "25 Zellen liegen MITTEN im Fade — nicht wieder als Kante")
    }

    // MARK: Wo die Shader-Fenster den Fade schneiden (Sichtbarkeits-Grenzen)

    func testLakeGateVisibilityThresholds() {
        // See-Kanal = GATE: smoothstep(0.04, 0.35, fade). Unsichtbar bis ~11,
        // voll ab 24 Zellen (Herleitung im WaterRender-Kommentar).
        XCTAssertLessThanOrEqual(WaterRender.componentFade(cells: 11), WaterRender.lakeGateLo)
        XCTAssertGreaterThan(WaterRender.componentFade(cells: 12), WaterRender.lakeGateLo)
        XCTAssertLessThan(WaterRender.componentFade(cells: 23), WaterRender.lakeGateHi)
        XCTAssertGreaterThanOrEqual(WaterRender.componentFade(cells: 24), WaterRender.lakeGateHi)
    }

    func testRiverIntensityThresholds() {
        // Fluss-Kanal = INTENSITÄT (kein Gate): der Fade skaliert sd, der Shader
        // schwellt mit smoothstep(0.16, 0.45, ·). Für einen kräftigen Lauf (sd ≈ 1)
        // heißt das: unsichtbar bis 16, voll ab 28 Zellen.
        XCTAssertLessThanOrEqual(WaterRender.componentFade(cells: 16), WaterRender.riverMaskLo)
        XCTAssertGreaterThan(WaterRender.componentFade(cells: 17), WaterRender.riverMaskLo)
        XCTAssertLessThan(WaterRender.componentFade(cells: 27), WaterRender.riverMaskHi)
        XCTAssertGreaterThanOrEqual(WaterRender.componentFade(cells: 28), WaterRender.riverMaskHi)
    }

    func testGateSaturatesBeforeRiverMask() {
        // Verworfene Variante festhalten: die Gate-Kurve NICHT auch auf den
        // Fluss-Kanal legen. Sie sättigt früher (0.35 < 0.45) — kombiniert wären
        // 18-Zell-Fetzen voll sichtbar, genau die Sprenkel, die der Fade abwehrt.
        XCTAssertLessThan(WaterRender.lakeGateHi, WaterRender.riverMaskHi)
        XCTAssertLessThan(WaterRender.lakeGateLo, WaterRender.riverMaskLo)
    }

    // MARK: Uferkontur ↔ Altarm-Stempel

    func testPondContourWindowStaysBelowGeometryLift() {
        // Farb-Kontur setzt unter der Hebe-Schwelle der Wasser-Geometrie (0.015)
        // ein, damit die Farbe bis fast an die echte Uferlinie reicht.
        XCTAssertLessThan(WaterRender.pondContourLo, 0.015)
        XCTAssertLessThan(WaterRender.pondContourLo, WaterRender.pondContourHi)
        XCTAssertEqual(WaterRender.pondContourLo, 0.003)
        XCTAssertEqual(WaterRender.pondContourHi, 0.02)
    }

    func testShaderMatchesCalibration() throws {
        // Die Fenster stehen doppelt: hier als Zahl, im Shader als smoothstep. Ohne
        // diesen Vergleich driften sie stumm auseinander — der Shader hat keine
        // andere Testebene. Außerhalb des Repos (Package woanders ausgecheckt)
        // wird der Test übersprungen statt falsch rot zu sein.
        let shader = try shaderSource("game/shaders/terrain.gdshader")
        assertContains(shader, "smoothstep(\(WaterRender.pondContourLo), "
            + "\(WaterRender.pondContourHi), pond)",
            hint: "Kontur-Fuß/Sattel der Uferlinie == WaterRender.pondContour*")
        assertContains(shader, "smoothstep(\(WaterRender.lakeGateLo), "
            + "\(WaterRender.lakeGateHi), texture(water_tex, uv).g)",
            hint: "See-GATE == WaterRender.lakeGate*")
        assertContains(shader, "smoothstep(\(WaterRender.riverMaskLo), "
            + "\(WaterRender.riverMaskHi), stream)",
            hint: "Fluss-INTENSITÄT == WaterRender.riverMask*")
    }

    func testExtensionUsesSharedCalibration() throws {
        // Gegenstück: die GDExtension darf die Werte nicht als lokale Literale
        // zurückkopieren (dann wäre die Kalibrierung wieder ungetestet). Vor allem
        // die Altarm-Präsenz-Schwelle MUSS der Kontur-Fuß sein, sonst sind die
        // seichten Altarm-Enden unsichtbar (Doppel-Rampe: Stempel × Kontur).
        let simNode = try shaderSource("Extension/Sources/RiverSimGD/SimNode.swift")
        assertContains(simNode, "WaterRender.componentFade(cells:",
                       hint: "Komponenten-Fade aus WaterRender beziehen")
        assertContains(simNode, "let minimumPondDepth = WaterRender.pondContourLo",
                       hint: "Altarm-Präsenz-Schwelle == Kontur-Fuß")
    }

    // MARK: Hilfen

    /// Datei relativ zur Repo-Wurzel lesen; `XCTSkip`, wenn sie fehlt.
    private func shaderSource(_ relativePath: String) throws -> String {
        // #filePath = <repo>/SimCore/Tests/SimCoreTests/WaterRenderTests.swift
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("\(relativePath) nicht erreichbar (außerhalb des Repos?)")
        }
        return text
    }

    private func assertContains(_ haystack: String, _ needle: String, hint: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(haystack.contains(needle),
                      "\(hint) — erwartet im Quelltext: \(needle)", file: file, line: line)
    }
}
