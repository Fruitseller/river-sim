import XCTest
@testable import SimCore

/// Wächter für den ALTERUNGS-VERLAUF (Issue #13): die Landschaft altert von
/// selbst, statt von einem Regler auf dem jungen Zustand festgehalten zu werden.
/// Mechanismus ist die abklingende Hebung `U(t) = U_floor + (U₀ − U_floor)·e^(−t/τ)`
/// (docs/research-terrain-aging.md §3) zusammen mit der linearen Hangdiffusion.
///
/// Gemessen wird auf reinen Produktions-Defaults (nur `n` gesenkt), damit der Test
/// den Pfad prüft, der real läuft. Alle Schwellen stammen aus der Messreihe in
/// `docs/terrain-aging-measurements.md`; das Kalibrier-Logbuch (U₀, U_floor, τ,
/// verworfene Varianten) steht in `Config.swift` bei `upliftDecayStartPer100y`.
final class TerrainAging: XCTestCase {

    /// Der Alterungsverlauf über 100.000 Jahre: Relief sinkt, die Grate runden
    /// aus, und der Gipfel wächst zu KEINEM Zeitpunkt über den Startwert.
    ///
    /// Gemessene Referenz (n=160, Seed 1337, alle 20k Jahre):
    ///   relief     0.5335 0.4706 0.4252 0.4138 0.4016 0.3883
    ///   ridgeCurv −0.0453 −0.0290 −0.0253 −0.0225 −0.0226 −0.0219
    ///   maxH       0.6836 0.6206 0.5752 0.5639 0.5516 0.5383
    /// Derselbe Lauf mit dem alten Relief-Servo als Haupt-Hebung lief dagegen
    /// nach 30k WIEDER HOCH (relief 0.4569 → 0.5097) und die Gratkrümmung blieb
    /// ab 10k flach bei ≈ −0.030 — genau das Plateau, das dieser Test ausschließt.
    func testAgingTrajectoryOver100k() {
        var c = SimConfig(); c.n = 160
        let t = Terrain(config: c, seed: 1337)

        let relief0 = t.landRelief()
        let maxH0 = t.maxHeight()
        var maxHPeak = maxH0
        var servoFired = 0

        // Die Gratkrümmung wird NACH dem Einschwingen der frischen Noise-Ober-
        // fläche referenziert (s. `ridgeCurvature`-Doku): bei t=0 dominiert die
        // Zell-Rauigkeit, nicht die Grat-Form.
        var curv20k = 0.0, relief50k = 0.0
        while t.years < 100_000 {
            if t.reliefServoRate() > 0 { servoFired += 1 }
            t.step(dtYears: 500)
            maxHPeak = max(maxHPeak, t.maxHeight())
            if t.years == 20_000 { curv20k = t.ridgeCurvature() }
            if t.years == 50_000 { relief50k = t.landRelief() }
        }
        let relief1 = t.landRelief()
        let curv1 = t.ridgeCurvature()

        // 1) Berge wachsen NICHT — auch nicht vorübergehend. Über alle 5
        //    gemessenen Seeds ist der Spitzenwert des Laufs exakt der Startwert.
        XCTAssertLessThanOrEqual(maxHPeak, maxH0,
            "Gipfel wuchs über den Startwert (\(maxH0) → Peak \(maxHPeak)) — U₀ zu hoch?")

        // 2) Das Relief SINKT deutlich (gemessen −27 %), statt zu plateauen.
        XCTAssertLessThan(relief1, relief0 * 0.85,
            "Relief altert nicht (\(relief0) → \(relief1)) — hebt etwas nach?")

        // 3) …und es sinkt in der ZWEITEN Hälfte weiter (gemessen 0.415 → 0.388).
        //    Genau hier lief der alte Servo-Betrieb wieder hoch.
        XCTAssertLessThan(relief1, relief50k - 0.01,
            "Relief plateaut nach 50k (\(relief50k) → \(relief1)) statt weiter zu altern")

        // 4) …aber es ebnet nicht ein (gleiche Schwelle wie LongRunCollapse).
        XCTAssertGreaterThan(relief1, 0.30,
            "Relief eingeebnet (\(relief0) → \(relief1)) — U_floor zu klein?")

        // 5) Die Grate RUNDEN: |∇²z| auf Gratzellen fällt gegen 0
        //    (gemessen −0.0290 bei 20k → −0.0219 bei 100k = −24 %).
        XCTAssertLessThan(abs(curv1), abs(curv20k) * 0.85,
            "Grate runden nicht aus (Gratkrümmung \(curv20k) → \(curv1))")
        XCTAssertLessThan(curv1, 0, "Grate müssen konvex bleiben, nicht Mulden werden")

        // 6) Der Relief-Servo ist nur noch UNTERGRENZE und darf im normalen
        //    Alterungsfenster gar nicht anspringen (gemessen: 0 von 200 Schritten).
        XCTAssertEqual(servoFired, 0,
            "Relief-Servo sprang \(servoFired)× an — er soll nur noch Notboden sein")
    }

    /// Die abklingende Hebung muss framerate-unabhängig sein: viele Mini-Schritte
    /// und ein großer Sprung müssen exakt dieselbe Hebung eintragen. Das leistet
    /// die geschlossene Integration in `upliftDecayAmount` (die Summe der
    /// e-Funktions-Differenzen teleskopiert), nicht ein „Rate × dt" am
    /// Schrittanfang — letzteres würde bei kleinem dt systematisch zu VIEL heben.
    func testDecayingUpliftIsFramerateIndependent() {
        var c = SimConfig(); c.n = 48
        func total(dt: Double, steps: Int) -> Double {
            let t = Terrain(config: c, seed: 4242)
            var sum = 0.0
            for _ in 0..<steps { sum += t.upliftDecayAmount(dt: dt); t.step(dtYears: dt) }
            return sum
        }
        let coarse = total(dt: 10_000, steps: 10)
        let fine = total(dt: 250, steps: 400)
        XCTAssertEqual(fine, coarse, accuracy: coarse * 1e-12,
            "Hebungs-Eintrag hängt von der Schrittweite ab (\(coarse) vs \(fine))")
        XCTAssertGreaterThan(coarse, 0)
    }
}
