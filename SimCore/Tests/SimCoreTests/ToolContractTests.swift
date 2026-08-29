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

    /// Frisches Terrain mit fixem Seed; zwei Aufrufe liefern bit-gleiche Welten
    /// (Determinismus-Invariante), also ist jede Differenz die Werkzeug-Wirkung.
    private let n = 64

    private func makeTerrain() -> Terrain {
        var c = SimConfig(); c.n = n; c.world = calibrationWorld
        return Terrain(config: c, seed: 7)
    }

    /// Zellgröße dieser Test-Welt — Radien unten stehen in ZELLEN.
    private var cell: Double { calibrationWorld / Double(n) }

    /// Strich-Zentrum in Gitterkoordinaten und Pinselradius in Welteinheiten.
    private var gx: Double { Double(n) / 2 }
    private var gz: Double { Double(n) / 2 }
    private var radius: Double { 6 * cell }   // 6 Zellen

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

    /// Mittlere lokale Rauheit im Pinsel: |h − 3×3-Mittel|, gemittelt.
    private func roughness(_ h: [Double]) -> Double {
        var sum = 0.0, count = 0.0
        let lo = n / 2 - 4, hi = n / 2 + 4
        for j in lo...hi { for i in lo...hi {
            var s = 0.0, c = 0.0
            for dj in (j - 1)...(j + 1) { for di in (i - 1)...(i + 1) {
                s += h[dj * n + di]; c += 1
            }}
            sum += abs(h[j * n + i] - s / c); count += 1
        }}
        return sum / count
    }

    func testRaiseLiftsTheCenterAndCouplesIntoTectonics() throws {
        let t = makeTerrain()
        let h0 = t.h[centerIndex], u0 = t.upliftBase[centerIndex]
        BrushTool.raise.apply(to: t, gx: gx, gz: gz, radiusWorld: radius,
                              strength: 1, target: 0)
        XCTAssertGreaterThan(t.h[centerIndex], h0, "Anheben muss das Zentrum heben")
        XCTAssertGreaterThan(t.upliftBase[centerIndex], u0,
                             "Anheben muss in die Tektonik koppeln (sculpt, dir: 1)")
        // Außerhalb des Pinsels bleibt alles unberührt.
        XCTAssertEqual(t.h[0], makeTerrain().h[0], "Ecke liegt außerhalb des Pinsels")
    }

    func testLowerDigsTheCenterAndCouplesIntoTectonics() throws {
        let t = makeTerrain()
        let h0 = t.h[centerIndex], u0 = t.upliftBase[centerIndex]
        BrushTool.lower.apply(to: t, gx: gx, gz: gz, radiusWorld: radius,
                              strength: 1, target: 0)
        XCTAssertLessThan(t.h[centerIndex], h0, "Absenken muss das Zentrum senken")
        XCTAssertLessThan(t.upliftBase[centerIndex], u0,
                          "Absenken muss in die Tektonik koppeln (sculpt, dir: -1)")
    }

    func testSmoothReducesLocalRoughness() throws {
        let (before, after) = heights(after: .smooth)
        XCTAssertLessThan(roughness(after), roughness(before),
                          "Glätten muss die lokale Rauheit im Pinsel senken")
    }

    func testFlattenPullsTowardTheGivenTarget() throws {
        // Ziel deutlich ÜBER dem Gelände: Einebnen hebt Richtung Ziel — das
        // unterscheidet es von Glätten und beweist, dass `target` ankommt.
        let (before, after) = heights(after: .flatten, target: 1.2)
        XCTAssertGreaterThan(after[centerIndex], before[centerIndex],
                             "Einebnen mit hohem Ziel muss Richtung Ziel heben")
        // Zwei Ziele, zwei Ergebnisse: ein hartkodiertes oder mit `strength`
        // vertauschtes Ziel fällt hier auf.
        let low = heights(after: .flatten, target: 0.1)
        XCTAssertLessThan(low.after[centerIndex], after[centerIndex],
                          "Verschiedene Ziele müssen verschieden einebnen")
        XCTAssertLessThan(low.after[centerIndex], low.before[centerIndex],
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
        XCTAssertGreaterThan(roughness(t.h), roughness(smoothed),
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
        let wide = heights(after: .pickaxe, radiusWorld: Double(n) * cell)
        let sideIndex = centerIndex + Int(Terrain.pickaxeMaxCells) * 2
        XCTAssertEqual(wide.after[sideIndex], wide.before[sideIndex],
                       "Spitzhacken-Radius muss auf wenige Zellen gedeckelt bleiben")
    }

    /// Sechs Werkzeuge, sechs verschiedene Wirkungen: kein `case` darf still auf
    /// die Operation eines anderen zeigen (z. B. Glätten ruft Aufrauen — die
    /// Failure-Mode, für die früher der Switch-Parser da war).
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
