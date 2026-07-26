import XCTest
@testable import SimCore

/// Regressions-Wächter gegen das Langzeit-Runaway (Handoff Aufgabe 1). Vor dem Fix
/// wuchs das Produktions-Terrain über ~100k Jahre monoton weg: Relief 0.82→1.10,
/// Wasseranteil 21%→39%, maxH bis an den Hebungs-Clamp — die Makro-Form „lief weg".
/// `basinFill` (Becken-Verlandung im Droplet-Pfad) + `isoHighClamp = 0.90` pinnen
/// das Terrain aufs junge, gratige Gleichgewicht. Dieser Test hält das fest.
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
        let water0 = fractionInBasins(t)

        while t.years < 100_000 { t.step(dtYears: 500) }

        let relief1 = t.landRelief()
        let water1 = fractionInBasins(t)

        // Relief bleibt in der Nähe des Startwerts (Runaway wäre +30% Richtung Clamp).
        XCTAssertLessThan(relief1, relief0 * 1.15,
                          "Relief läuft weg (\(relief0) → \(relief1)) — Runaway zurück?")
        // maxH bleibt unter dem Clamp (Berge wachsen nicht ins Dach).
        XCTAssertLessThan(t.maxHeight(), 1.0,
                          "maxH \(t.maxHeight()) — Berge wachsen in den Clamp.")
        // See-Anteil bleibt gedeckelt (vor dem Fix ~2× auf 39%).
        XCTAssertLessThan(water1, 0.30,
                          "See-Anteil wuchert (\(water0) → \(water1)) — Becken-Fill inaktiv?")
    }
}
