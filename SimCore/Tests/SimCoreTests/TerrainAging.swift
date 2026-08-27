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
    /// Gemessene Referenz (n=160, Seed 1337, alle 20k Jahre), Stand vor #35:
    ///   relief     0.5335 0.4706 0.4252 0.4138 0.4016 0.3883
    ///   ridgeCurv −0.0453 −0.0290 −0.0253 −0.0225 −0.0226 −0.0219
    ///   maxH       0.6836 0.6206 0.5752 0.5639 0.5516 0.5383
    /// Dieselbe Reihe mit dem Gletscher (Issue #35, Produktions-Default):
    ///   relief     0.5364 0.4509 0.4366 0.4320 0.4301 0.4289
    ///   robust     0.1802 0.1504 0.1260 0.1152 0.1104 0.1084
    ///   maxH       0.6864 0.6010 0.5866 0.5821 0.5801 0.5789
    /// `relief` (max − min) hängt am Gipfel, und den hält das Eis an der
    /// Firn-Grenze fest — die Begründung steht bei Kriterium 3, die Messreihe in
    /// `docs/glacier-measurements.md` §H.
    /// Derselbe Lauf mit dem alten Relief-Servo als Haupt-Hebung lief dagegen
    /// nach 30k WIEDER HOCH (relief 0.4569 → 0.5097) und die Gratkrümmung blieb
    /// ab 10k flach bei ≈ −0.030 — genau das Plateau, das dieser Test ausschließt.
    func testAgingTrajectoryOver100k() {
        var c = SimConfig(); c.n = 160; c.world = calibrationWorld
        let t = Terrain(config: c, seed: 1337)

        let relief0 = t.landRelief()
        let robust0 = t.landReliefRobust()
        let maxH0 = t.maxHeight()
        var maxHPeak = maxH0
        var servoFired = 0

        // Die Gratkrümmung wird NACH dem Einschwingen der frischen Noise-Ober-
        // fläche referenziert (s. `ridgeCurvature`-Doku): bei t=0 dominiert die
        // Zell-Rauigkeit, nicht die Grat-Form.
        var curv20k = 0.0, relief50k = 0.0, robust50k = 0.0
        while t.years < 100_000 {
            if t.reliefServoRate() > 0 { servoFired += 1 }
            t.step(dtYears: 500)
            maxHPeak = max(maxHPeak, t.maxHeight())
            if t.years == 20_000 { curv20k = t.ridgeCurvature() }
            if t.years == 50_000 { relief50k = t.landRelief(); robust50k = t.landReliefRobust() }
        }
        let relief1 = t.landRelief()
        let robust1 = t.landReliefRobust()
        let curv1 = t.ridgeCurvature()
        print(String(format: "[#13] 100k Jahre, n=160: Relief %.4f → %.4f (50k %.4f), "
                     + "robust %.4f → %.4f (50k %.4f), maxH %.4f → %.4f",
                     relief0, relief1, relief50k, robust0, robust1, robust50k,
                     maxH0, t.maxHeight()))

        // 1) Berge wachsen NICHT — auch nicht vorübergehend. Über alle 5
        //    gemessenen Seeds ist der Spitzenwert des Laufs exakt der Startwert.
        XCTAssertLessThanOrEqual(maxHPeak, maxH0,
            "Gipfel wuchs über den Startwert (\(maxH0) → Peak \(maxHPeak)) — U₀ zu hoch?")

        // 2) Das Relief SINKT deutlich (gemessen −27 %), statt zu plateauen.
        XCTAssertLessThan(relief1, relief0 * 0.85,
            "Relief altert nicht (\(relief0) → \(relief1)) — hebt etwas nach?")

        // 3) …und es sinkt in der ZWEITEN Hälfte weiter (gemessen 0.1191 → 0.1084,
        //    also −9.0 %).
        //    Genau hier lief der alte Servo-Betrieb wieder hoch.
        //
        //    GEMESSEN auf dem ROBUSTEN Relief (p95 − Median), nicht auf
        //    `landRelief()` (max − min). Grund ist der Gletscher (Issue #35), und
        //    zwar als PHYSIK, nicht als Rauschen: das Eis legt den fluvialen
        //    Abtrag auf den vergletscherten Zellen still, und vergletschert ist
        //    genau das, was über der Firn-Grenze (h = 0.5731) steht — der
        //    GIPFEL. Der sinkt bis dorthin und bleibt dann dort stehen (gemessen
        //    n=160/Seed 1337 über 100k Jahre: maxH 0.6864 → 0.5789 mit Eis gegen
        //    → 0.5430 ohne, bei zuletzt 17 vergletscherten Zellen). Das ist der
        //    Buzzsaw/Protection-Gleichgewichtszustand aus der Literatur — Gipfel
        //    pendeln sich knapp über der Schneegrenze ein —, und `landRelief()`
        //    ist per Konstruktion die Kennzahl, die eine EINZELNE Zelle bewegen
        //    kann (s. Doku von `landReliefRobust`). Die FLÄCHE altert davon
        //    unbeeindruckt weiter, und praktisch gleich schnell wie ohne Eis
        //    (`docs/glacier-measurements.md` §H):
        //      robust, Eis an : 0.1802 → 0.1504 (20k) → 0.1260 (40k) → 0.1084
        //      robust, Eis aus: 0.1802 → 0.1479 (20k) → 0.1289 (40k) → 0.1069
        //    Deshalb misst dieses Kriterium die FLÄCHE. Die relative Schwelle
        //    (−5 %) hat gegen die gemessenen −9.0 % knapp Faktor 2 Luft; sie ist
        //    relativ statt absolut, weil das robuste Relief eine Größenordnung
        //    kleiner ist als max − min und die alte 0.01 dort ein Fünftel des
        //    Werts wären.
        XCTAssertLessThan(robust1, robust50k * 0.95,
            "Relief plateaut nach 50k (robust \(robust50k) → \(robust1)) statt weiter zu altern")

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
        var c = SimConfig(); c.n = 48; c.world = calibrationWorld
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

    /// Der Übergangsfall: U(t) SCHNEIDET die Servo-Untergrenze mitten im Schritt.
    /// Genau hier wäre `max(∫U dt, U_servo·dt)` schrittweiten-abhängig — der große
    /// Schritt liefe noch komplett auf der U-Kurve, viele kleine Schritte lägen im
    /// hinteren Teil schon auf der Untergrenze. `upliftAmount` zieht das max unter
    /// das Integral und teilt am Schnittpunkt, deshalb müssen beide Wege exakt
    /// dasselbe ergeben. Größenordnung des alten Fehlers in genau diesem Aufbau:
    /// der Sprung trug 0.09897 statt korrekt 0.10582 ein (−6.5 %).
    func testServoFloorCrossingIsFramerateIndependent() {
        var c = SimConfig(); c.n = 48; c.world = calibrationWorld
        // Untergrenze so wählen, dass der Schnittpunkt MITTEN im groben Schritt
        // liegt: U(t) = floor bei t = −τ·ln((s−U_floor)/(U₀−U_floor)).
        let floorRate = c.upliftDecayFloorPer100y
            + (c.upliftDecayStartPer100y - c.upliftDecayFloorPer100y) * exp(-1.5)
        let tStar = 1.5 * c.upliftDecayYears // = 60.000 Jahre
        let span = 40_000.0                  // Schritt(e) von 40k bis 80k → Schnitt bei 60k

        func total(dt: Double) -> Double {
            let t = Terrain(config: c, seed: 4242)
            var sum = 0.0
            while t.years < 40_000 { t.step(dtYears: 10_000) } // an den Startpunkt
            let end = t.years + span
            while t.years < end {
                sum += t.upliftAmount(dt: dt, floorPer100y: floorRate)
                t.step(dtYears: dt)
            }
            return sum
        }
        let oneJump = total(dt: span)
        let manySteps = total(dt: 250)
        XCTAssertEqual(manySteps, oneJump, accuracy: oneJump * 1e-9,
            "Hebung am Servo-Schnittpunkt hängt von der Schrittweite ab (\(oneJump) vs \(manySteps))")

        // Gegenprobe, dass der Fall wirklich ein Übergang ist: die Untergrenze
        // liegt zwischen U(Start) und U(Ende) des Sprungs.
        let t = Terrain(config: c, seed: 4242)
        while t.years < 40_000 { t.step(dtYears: 10_000) }
        let rate = { (y: Double) in
            c.upliftDecayFloorPer100y + (c.upliftDecayStartPer100y - c.upliftDecayFloorPer100y)
                * exp(-y / c.upliftDecayYears)
        }
        XCTAssertGreaterThan(rate(40_000), floorRate)
        XCTAssertLessThan(rate(80_000), floorRate)
        XCTAssertEqual(rate(tStar), floorRate, accuracy: floorRate * 1e-12)

        // …und dass die Zerlegung im Übergangsschritt wirklich etwas ändert: das
        // korrekte ∫max(U, Boden) ist STRIKT größer als beide Einzelzweige — genau
        // die beiden Werte, zwischen denen die alte `max(…)`-Fassung gewählt hätte.
        let pureDecay = t.upliftDecayAmount(dt: span)
        let pureFloor = floorRate * span / 100
        XCTAssertGreaterThan(oneJump, pureDecay)
        XCTAssertGreaterThan(oneJump, pureFloor)
        XCTAssertLessThan(oneJump, pureDecay + pureFloor)
    }
}
