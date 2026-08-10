import XCTest
@testable import SimCore

/// Wächter für die perzentil-gekoppelten Höhenbänder (Issue #4): Schnee-,
/// Hochfels- und Vegetationsgrenze folgen der AKTUELLEN Landhöhenverteilung,
/// statt als absolute Werte aus dem erreichbaren Höhenband herauszualtern.
///
/// Gemessen wird auf Produktions-Defaults (nur `n` gesenkt, wo die Laufzeit es
/// verlangt); die Produktionsauflösung n=832 läuft in
/// `testSnowZoneAtProductionResolution`. Rohdaten: `docs/height-band-measurements.md`.
final class HeightBandTests: XCTestCase {

    /// Anteil der Landzellen mit Schnee-Anteil > 0 bzw. voll weiß.
    private func snowFractions(_ t: Terrain) -> (ramp: Double, full: Double) {
        let b = t.heightBands
        var land = 0, ramp = 0, full = 0
        for v in t.h where v > t.cfg.sea {
            land += 1
            let s = b.snowAmount(v)
            if s > 0 { ramp += 1 }
            if s >= 1 { full += 1 }
        }
        guard land > 0 else { return (0, 0) }
        return (Double(ramp) / Double(land), Double(full) / Double(land))
    }

    /// **Abnahmekriterium 2 + 3.** In Produktionsauflösung (n=832, Seed 1337) ist
    /// die Schneezone bei der Generierung UND nach 30.000 Jahren nicht leer — und
    /// sie bleibt dabei in einem engen Flächenband (kein „halbe Insel weiß", wenn
    /// das Terrain abflacht).
    ///
    /// Gemessen (Rampe/voll weiß, Anteil der Landzellen):
    ///   Jahr 0: 0.0151 / 0.0015   ·   30k: 0.0149 / 0.0015
    /// Zum Vergleich die alten absoluten Schwellen: 0 Zellen zu jedem Zeitpunkt
    /// (maxH 0.7457 → 0.6372 gegen eine Schneegrenze bei 1.05).
    func testSnowZoneAtProductionResolution() {
        var c = SimConfig(); c.n = 832
        let t = Terrain(config: c, seed: 1337)
        let atGen = snowFractions(t)
        XCTAssertGreaterThan(atGen.full, 0, "Schneezone bei der Generierung leer")
        while t.years < 30_000 { t.step(dtYears: 500) }
        let at30k = snowFractions(t)
        XCTAssertGreaterThan(at30k.full, 0, "Schneezone nach 30k Jahren leer")
        // Band: die Rampe ist per Konstruktion 1 − bandSnowPercentile = 1.5 % des
        // Landes. Die Grenzen lassen Histogramm-Quantisierung und Höhen-Bindungen
        // Luft, schließen aber jede Größenordnungs-Abweichung aus.
        for (label, f) in [("gen", atGen), ("30k", at30k)] {
            XCTAssertTrue(f.ramp > 0.005 && f.ramp < 0.04,
                          "Schnee-Rampenanteil (\(label)) außerhalb des Bands: \(f.ramp)")
            XCTAssertTrue(f.full > 0.0002 && f.full < 0.01,
                          "Voll-Schnee-Anteil (\(label)) außerhalb des Bands: \(f.full)")
        }
    }

    /// **Waldgrenze gegen Schneegrenze** (Review-Finding zu PR #28). Die beiden
    /// Bänder ÜBERLAPPEN sich per Konstruktion — `vegNone` (vegFull + Rampenbreite)
    /// liegt über `snowStart` (p98.5) —, die Sim hält also auch in der Schneezone
    /// noch Bewuchs. Baum-GEOMETRIE darf dort trotzdem nicht stehen; die Regel
    /// dafür ist `HeightBands.bearsTrees` (verbraucht von
    /// `SimNode.treeInstanceBuffer`).
    ///
    /// Der Test prüft beides: dass die Überlappung wirklich existiert (sonst wäre
    /// er stumm) und dass kein Standort in der Schneezone baumtragend ist.
    /// Gemessen (n=832, Seed 1337, Generierung): snowStart 0.5697, vegNone 0.6844,
    /// Höhenfaktor an der Schneegrenze 0.617 — 4 von 31995 Baum-Kandidaten lagen
    /// vor dem Fix in der Schneezone, nach 30k Jahren 11 von 56994.
    func testSnowZoneBearsNoTrees() {
        var c = SimConfig(); c.n = 256
        let t = Terrain(config: c, seed: 1337)
        let b = t.heightBands
        // Vorbedingung: die Bänder überlappen (sonst testet der Guard nichts).
        XCTAssertGreaterThan(b.vegNone, b.snowStart,
            "Bänder überlappen nicht mehr (vegNone \(b.vegNone) ≤ snowStart \(b.snowStart)) — Test stumm")
        XCTAssertGreaterThan(b.vegetationAltitudeFactor(b.snowStart), 0,
            "Vegetations-Höhenfaktor ist an der Schneegrenze schon 0 — Test stumm")
        // …und in der Schneezone wächst real Bewuchs, den die Baum-Maske sonst nähme.
        var vegetatedSnowCells = 0
        for k in 0..<c.count where t.h[k] > c.sea && b.snowAmount(t.h[k]) > 0 {
            if t.veg[k] > 0.32 { vegetatedSnowCells += 1 }
        }
        XCTAssertGreaterThan(vegetatedSnowCells, 0,
            "keine bewachsene Schneezellen-Kandidaten — Test stumm")
        // Kernaussage: kein Standort in der Schneezone ist baumtragend.
        for k in 0..<c.count where t.h[k] > c.sea && b.snowAmount(t.h[k]) > 0 {
            XCTAssertFalse(b.bearsTrees(t.h[k]),
                "Schneezone trägt Bäume (h = \(t.h[k]), snowStart \(b.snowStart))")
        }
        // Unterhalb der Schneegrenze bleibt die Waldgrenze das Vegetationsband.
        let belowSnow = b.snowStart - 1e-6
        XCTAssertEqual(b.bearsTrees(belowSnow), b.vegetationAltitudeFactor(belowSnow) > 0)
    }

    /// Die Bänder ZIEHEN MIT: sinkt das Terrain über einen langen Lauf, sinken
    /// Schnee- und Vegetationsgrenze mit — genau das, was absolute Schwellen nicht
    /// können. Gemessen (n=160, Seed 1337, 60k Jahre): snowStart 0.5658 → 0.5072,
    /// vegFull 0.4945 → 0.4383, während maxH von 0.6864 auf 0.5807 fällt — der
    /// Flächenanteil der Schneezone bleibt dabei bei 1.5 % (siehe Trajektorie in
    /// docs/height-band-measurements.md).
    func testBandsFollowFlatteningTerrain() {
        var c = SimConfig(); c.n = 160
        let t = Terrain(config: c, seed: 1337)
        let b0 = t.heightBands
        let max0 = t.maxHeight()
        while t.years < 60_000 { t.step(dtYears: 500) }
        let b1 = t.heightBands
        XCTAssertLessThan(t.maxHeight(), max0, "Vorbedingung: Terrain flacht ab")
        XCTAssertLessThan(b1.snowStart, b0.snowStart,
            "Schneegrenze folgt dem sinkenden Terrain nicht (\(b0.snowStart) → \(b1.snowStart))")
        XCTAssertLessThan(b1.vegFull, b0.vegFull,
            "Vegetationsgrenze folgt nicht (\(b0.vegFull) → \(b1.vegFull))")
        // …und sie bleibt UNTER dem Gipfel: sonst wäre die Zone wieder leer.
        XCTAssertLessThan(b1.snowStart, t.maxHeight())
    }

    /// Ordnung und Wohlgeformtheit der Bänder: monoton und mit echter Rampenbreite
    /// (sonst harte Farbkante statt Verlauf).
    func testBandsAreWellOrdered() {
        var c = SimConfig(); c.n = 160
        let t = Terrain(config: c, seed: 1337)
        let b = t.heightBands
        XCTAssertLessThan(b.coniferLow, b.coniferHigh)
        XCTAssertLessThan(b.vegFull, b.vegNone)
        XCTAssertLessThan(b.rockStart, b.rockFull)
        XCTAssertLessThan(b.snowStart, b.snowFull)
        XCTAssertGreaterThanOrEqual(b.vegNone - b.vegFull, c.bandMinRampWidth)
        XCTAssertGreaterThanOrEqual(b.snowFull - b.snowStart, c.bandMinRampWidth)
        // Schnee liegt über dem Beginn der Fels-Graurampe (Fels → Firn → Schnee).
        XCTAssertGreaterThan(b.snowStart, b.rockStart)
        // Ausgewertete Rampen: unten 0, oben 1.
        XCTAssertEqual(b.snowAmount(b.snowStart), 0)
        XCTAssertEqual(b.snowAmount(b.snowFull), 1, accuracy: 1e-12)
        XCTAssertEqual(b.vegetationAltitudeFactor(b.vegFull), 1)
        XCTAssertEqual(b.vegetationAltitudeFactor(b.vegNone), 0, accuracy: 1e-12)
    }

    /// Entartete Eingaben dürfen keine Sprungfunktion und keine NaN erzeugen:
    /// ohne auswertbares Land greift der Rückfall, ein spiegelglattes Plateau
    /// bekommt Mindest-Rampenbreiten.
    func testDegenerateFields() {
        var c = SimConfig(); c.n = 64
        let flooded = HeightBands.fromLandHeights([Double](repeating: c.sea - 0.1, count: 100), cfg: c)
        XCTAssertEqual(flooded, HeightBands.legacyAbsolute)
        let plateau = HeightBands.fromLandHeights([Double](repeating: c.sea + 0.3, count: 1000), cfg: c)
        XCTAssertGreaterThanOrEqual(plateau.snowFull - plateau.snowStart, c.bandMinRampWidth)
        XCTAssertGreaterThanOrEqual(plateau.vegNone - plateau.vegFull, c.bandMinRampWidth)
        XCTAssertTrue(plateau.snowAmount(c.sea + 0.3).isFinite)
        XCTAssertTrue(plateau.vegetationAltitudeFactor(c.sea + 0.3).isFinite)
    }

    /// Die Perzentile kommen aus DERSELBEN Quantil-Funktion wie das Relief-Signal
    /// (`Terrain.landHeightQuantiles`) — und die liefert nach dem Umbau exakt das,
    /// was `landReliefRobust` vorher selbst gerechnet hat.
    func testQuantileSourceMatchesReliefSignal() {
        var c = SimConfig(); c.n = 160
        let t = Terrain(config: c, seed: 1337)
        let q = Terrain.landHeightQuantiles(heights: t.h, sea: c.sea, probs: [0.5, 0.95])
        XCTAssertNotNil(q)
        XCTAssertEqual(q![1] - q![0], t.landReliefRobust(), accuracy: 0)
        // Aufsteigende Perzentile → aufsteigende Quantile, ein Durchlauf für alle.
        let many = Terrain.landHeightQuantiles(heights: t.h, sea: c.sea,
                                               probs: [0.1, 0.5, 0.9, 0.99])!
        XCTAssertEqual(many, many.sorted())
    }
}
