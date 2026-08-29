import XCTest
@testable import SimCore

/// Wächter für den WERKZEUG-Vertrag zwischen Game-Layer und `BrushTool`
/// (Issues #53, #79).
///
/// Über die Brücke geht nur eine ZAHL (`SimNode.brush(mode:)`). Die Bedeutung
/// dieser Zahl steht zwangsläufig doppelt — als `case` von `BrushTool` (seit #79
/// in SimCore) und als `"mode"` in der Werkzeug-Tabelle von `Main.gd`. Die
/// GDScript-Seite ist headless nicht ausführbar und bleibt Text-Match (dasselbe
/// Verfahren wie bei den Render-Verträgen, s. `RepoSource`); die Swift-Seite ist
/// seit dem Umzug AUSFÜHRBAR: das Routing jedes `case` wird als Wirkung auf
/// einem echten Terrain geprüft, nicht mehr per Quelltext-Parsing des `switch`.
///
/// Was die Tests verhindern: eine Zeile in der Tabelle ohne `case` — vorher fiel
/// der `switch` auf `default: break`, das Werkzeug malte einfach nichts, und im
/// Spiel sah das wie ein Physik-Bug aus — und ein `case`, das auf die falsche
/// Terrain-Operation zeigt oder ihre Argumente vertauscht (dieselbe
/// Failure-Mode, nur eine Zeile weiter).
final class ToolContractTests: XCTestCase {

    func testBrushToolCasesMatchTheGameToolTable() throws {
        let main = try RepoSource.file("game/scripts/Main.gd")
        let tableModes = try integers(in: main, pattern: "\"mode\": ([0-9]+)")
        XCTAssertFalse(tableModes.isEmpty,
                       "Werkzeug-Tabelle in Main.gd nicht gefunden — trägt jede Zeile \"mode\"?")
        XCTAssertEqual(tableModes, BrushTool.allCases.map(\.rawValue),
                       "Werkzeug-Tabelle (Main.gd) und BrushTool (SimCore) sind "
                       + "auseinandergelaufen: \(tableModes) gegen "
                       + "\(BrushTool.allCases.map(\.rawValue))")
        // Die Zahl IST der Rohwert der Aufzählung: lückenlos ab 0, in derselben
        // Reihenfolge. Sonst müsste der Game-Layer die Zuordnung kennen, und
        // genau das soll die Tabelle abschaffen.
        XCTAssertEqual(tableModes, Array(0..<tableModes.count),
                       "Werkzeug-Modi müssen lückenlos ab 0 in Tabellen-Reihenfolge stehen")
    }

    // MARK: - Verhaltens-Tests (die zweite Hälfte des Vertrags, Issue #79)
    //
    // Die ZAHL stimmt, aber tut ihr `case` auch das Gemeinte? Früher las das ein
    // Quelltext-Parser aus dem `switch`; der sah vertauschte Argumente nicht und
    // brach bei jeder Umformung ohne Verhaltensänderung. Jetzt läuft jedes
    // Werkzeug auf einem echten Terrain und seine charakteristische WIRKUNG wird
    // geprüft — auf seed-gleichen Terrains, damit nur das Werkzeug den
    // Unterschied macht.

    /// Klein genug für flinke Terrain-Bauten (jeder Test generiert frisch),
    /// groß genug, dass der 6-Zellen-Pinsel samt Außenrand aufs Gitter passt.
    private let n = 64

    private var cfg: SimConfig {
        var c = SimConfig(); c.n = n; c.world = calibrationWorld; return c
    }

    /// Frisches Terrain mit fixem Seed; zwei Aufrufe liefern bit-gleiche Welten
    /// (Determinismus-Invariante), also ist jede Differenz die Werkzeug-Wirkung.
    private func makeTerrain() -> Terrain { Terrain(config: cfg, seed: 7) }

    /// Strich-Zentrum in Gitterkoordinaten und Pinselradius in Welteinheiten.
    private var gx: Double { Double(n) / 2 }
    private var gz: Double { Double(n) / 2 }
    private var radius: Double { 6 * cfg.cellSize }   // 6 Zellen

    /// Wendet `tool` auf ein frisches Terrain an und liefert (vorher, nachher).
    private func heights(after tool: BrushTool, strength: Double = 1.0,
                         target: Double = 0.0, radiusWorld: Double? = nil)
        -> (before: [Double], after: [Double]) {
        let t = makeTerrain()
        let before = t.h
        tool.apply(to: t, gx: gx, gz: gz, radiusWorld: radiusWorld ?? radius,
                   strength: strength, target: target)
        return (before, t.h)
    }

    private var centerIndex: Int { Int(gz) * n + Int(gx) }

    /// Rauheit im Pinselkreis dieses Strichs (geteilter Helfer, `BrushTestSupport.swift`).
    private func brushRoughness(_ h: [Double]) -> Double {
        roughness(h, center: (gx, gz), radiusWorld: radius, cfg: cfg)
    }

    /// Heben und Senken sind DERSELBE Aufruf mit gespiegeltem `dir`: ein Helfer,
    /// zwei Tests — `sign` ist die erwartete Wirkrichtung auf Höhe UND Tektonik
    /// (die Kopplung unterscheidet `sculpt` von jedem anderen Werkzeug und pinnt
    /// das `dir`-Vorzeichen).
    private func assertSculpt(_ tool: BrushTool, sign: Double,
                              file: StaticString = #filePath, line: UInt = #line) {
        let t = makeTerrain()
        let before = t.h, u0 = t.upliftBase[centerIndex]
        tool.apply(to: t, gx: gx, gz: gz, radiusWorld: radius, strength: 1, target: 0)
        XCTAssertGreaterThan((t.h[centerIndex] - before[centerIndex]) * sign, 0,
                             "\(tool) muss das Zentrum in Richtung \(sign) bewegen",
                             file: file, line: line)
        XCTAssertGreaterThan((t.upliftBase[centerIndex] - u0) * sign, 0,
                             "\(tool) muss in die Tektonik koppeln (sculpt, dir: \(sign))",
                             file: file, line: line)
        assertUntouchedOutside(t.h, before: before, center: (gx, gz),
                               radiusWorld: radius, cfg: cfg, file: file, line: line)
    }

    func testRaiseLiftsTheCenterAndCouplesIntoTectonics() throws {
        assertSculpt(.raise, sign: 1)
    }

    func testLowerDigsTheCenterAndCouplesIntoTectonics() throws {
        assertSculpt(.lower, sign: -1)
    }

    func testSmoothReducesLocalRoughness() throws {
        let (before, after) = heights(after: .smooth)
        XCTAssertLessThan(brushRoughness(after), brushRoughness(before),
                          "Glätten muss die lokale Rauheit im Pinsel senken")
    }

    func testFlattenPullsTowardTheGivenTarget() throws {
        // Ziele RELATIV zum Gelände statt absoluter Höhen: der Test überlebt so
        // eine Rekalibrierung der Höhenskala. Ziel über dem Zentrum hebt, Ziel
        // darunter senkt — das unterscheidet Einebnen von Glätten und beweist,
        // dass `target` ankommt.
        let h0 = makeTerrain().h[centerIndex]
        let high = heights(after: .flatten, target: h0 + 0.5)
        XCTAssertGreaterThan(high.after[centerIndex], h0,
                             "Einebnen mit hohem Ziel muss Richtung Ziel heben")
        // Zwei Ziele, zwei Ergebnisse: ein hartkodiertes oder mit `strength`
        // vertauschtes Ziel fällt hier auf.
        let low = heights(after: .flatten, target: h0 - 0.5)
        XCTAssertLessThan(low.after[centerIndex], high.after[centerIndex],
                          "Verschiedene Ziele müssen verschieden einebnen")
        XCTAssertLessThan(low.after[centerIndex], h0,
                          "Einebnen mit tiefem Ziel muss Richtung Ziel senken")
    }

    func testRoughenAddsReliefInBothDirections() throws {
        // Erst glätten, dann aufrauen: auf der geglätteten Fläche muss das
        // fraktale Rauschen die Rauheit wieder HEBEN (Gegenrichtung zu smooth)
        // und dabei in beide Richtungen auslenken (kein reines Heben/Senken).
        let t = makeTerrain()
        BrushTool.smooth.apply(to: t, gx: gx, gz: gz, radiusWorld: radius,
                               strength: 1, target: 0)
        let smoothed = t.h
        BrushTool.roughen.apply(to: t, gx: gx, gz: gz, radiusWorld: radius,
                                strength: 1, target: 0)
        XCTAssertGreaterThan(brushRoughness(t.h), brushRoughness(smoothed),
                             "Aufrauen muss die lokale Rauheit heben")
        let deltas = zip(t.h, smoothed).map { $0 - $1 }
        XCTAssertTrue(deltas.contains { $0 > 0 } && deltas.contains { $0 < 0 },
                      "Aufrauen ist Rauschen, kein gerichtetes Heben oder Senken")
    }

    func testPickaxeDigsDeeperThanLowerAndCapsItsRadius() throws {
        let lower = heights(after: .lower)
        let pickaxe = heights(after: .pickaxe)
        XCTAssertLessThan(pickaxe.after[centerIndex] - pickaxe.before[centerIndex],
                          lower.after[centerIndex] - lower.before[centerIndex],
                          "Die Spitzhacke muss bei gleicher Stärke tiefer schlagen als Absenken")
        // Der Radius-Deckel (Terrain.pickaxeMaxCells): auch ein riesiger Pinsel
        // reißt keinen Krater — im doppelten Deckel-Abstand bleibt alles stehen.
        let wide = heights(after: .pickaxe, radiusWorld: Double(n) * cfg.cellSize)
        let sideIndex = centerIndex + Int(Terrain.pickaxeMaxCells) * 2
        XCTAssertEqual(wide.after[sideIndex], wide.before[sideIndex],
                       "Spitzhacken-Radius muss auf wenige Zellen gedeckelt bleiben")
    }

    /// Sechs Werkzeuge, sechs verschiedene Wirkungen: kein `case` darf still auf
    /// die Operation eines anderen zeigen (z. B. Glätten ruft Aufrauen — die
    /// Failure-Mode, für die früher der Switch-Parser da war).
    ///
    /// BEWUSST redundant zu den Einzeltests oben: die pinnen je Werkzeug eine
    /// charakteristische Wirkung, dieser Vergleich schließt die Lücke dazwischen
    /// (zwei Cases auf DERSELBEN Operation erfüllen unter Umständen beide
    /// Einzel-Zusicherungen und fallen erst hier auf).
    func testEachToolLeavesADistinctFootprint() throws {
        let results = BrushTool.allCases.map { tool in
            heights(after: tool, strength: 1, target: 1.2).after
        }
        for a in results.indices {
            for b in results.indices where b > a {
                XCTAssertNotEqual(results[a], results[b],
                                  "\(BrushTool.allCases[a]) und \(BrushTool.allCases[b]) "
                                  + "wirken identisch — Routing prüfen")
            }
        }
    }
}
