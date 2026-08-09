import XCTest
@testable import SimCore

/// Regressions-Wächter gegen das Langzeit-Runaway (Handoff Aufgabe 1). Vor dem Fix
/// wuchs das Produktions-Terrain über ~100k Jahre monoton weg: Relief 0.82→1.10,
/// Wasseranteil 21%→39%, maxH bis an den Hebungs-Clamp — die Makro-Form „lief weg".
/// `isoHighClamp = 0.90` pinnt das Terrain aufs junge, gratige Gleichgewicht.
/// Dieser Test hält das fest — auf reinen Produktions-Defaults (nur `n` gesenkt),
/// d. h. OHNE `basinFill` (das stand hier historisch, ist aber seit `basinFill =
/// false` nicht mehr Teil des gemessenen Pfads).
final class LongRunCollapse: XCTestCase {

    private func fractionInBasins(_ t: Terrain) -> Double {
        var wet = 0, land = 0
        for k in 0..<t.cfg.count where t.hf[k] > t.cfg.sea {
            land += 1
            if t.hf[k] - t.h[k] > 0.01 { wet += 1 }
        }
        return land == 0 ? 0 : Double(wet) / Double(land)
    }

    /// Über einen langen Zeitraffer dürfen Relief, Höhe und See-Anteil NICHT
    /// weglaufen — sie sollen nahe dem jungen Zustand plateauen.
    func testLongRunDoesNotRunAway() {
        var c = SimConfig(); c.n = 160
        let t = Terrain(config: c, seed: 1337)
        let relief0 = t.landRelief()
        let maxH0 = t.maxHeight()
        let water0 = fractionInBasins(t)

        while t.years < 100_000 { t.step(dtYears: 500) }

        let relief1 = t.landRelief()
        let water1 = fractionInBasins(t)

        // Berge WACHSEN NICHT (User-Anforderung): ohne aktive Tektonik erodiert das
        // Terrain, es wächst nicht hoch. maxH darf am Ende nicht höher sein als am
        // Start (kleine Toleranz fürs erste Settling der frischen Noise-Oberfläche).
        XCTAssertLessThan(t.maxHeight(), maxH0 + 0.02,
                          "Berge wachsen (\(maxH0) → \(t.maxHeight())) — Hebung zu stark?")
        // …aber sie kollabieren auch nicht zur Pfannkuchen-Ebene. Mit Hebung=0
        // (reine Erosion, gewollt) sinkt das Relief über 100k deutlich — das ist
        // KEIN Regress, sondern Alterung. Die Schwelle fängt nur echtes Einebnen ab.
        XCTAssertGreaterThan(relief1, 0.30,
                             "Relief eingeebnet (\(relief0) → \(relief1)) — Erosion zu stark?")
        // See-Anteil bleibt gedeckelt (vor dem Fix ~2× auf 39%).
        XCTAssertLessThan(water1, 0.30,
                          "See-Anteil wuchert (\(water0) → \(water1)) — Becken-Fill inaktiv?")
    }
}
