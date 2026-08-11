import XCTest
@testable import SimCore

/// Wächter für die perzentil-gekoppelten Höhenbänder (Issue #4): Schnee-,
/// Hochfels- und Vegetationsgrenze folgen der AKTUELLEN Landhöhenverteilung,
/// statt als absolute Werte aus dem erreichbaren Höhenband herauszualtern.
///
/// Gemessen wird auf Produktions-Defaults (nur `n` gesenkt, wo die Laufzeit es
/// verlangt); die Produktionsauflösung n=832 läuft in
/// `testSnowZoneFollowsTheClimateNotAFixedLandFraction`. Rohdaten:
/// `docs/height-band-measurements.md`.
///
/// **Stand Issue #33:** der SCHNEE ist kein Perzentil mehr — seine Grenze wird
/// aus dem Schneefeld (Massenbilanz aus Temperatur und Niederschlag)
/// zurückgerechnet. Die Wächter hier sind entsprechend umgeschrieben: sie prüfen
/// jetzt, dass die Schneegrenze dem KLIMA folgt und NICHT der Höhenverteilung,
/// während Vegetation/Fels/Nadelband unverändert perzentil-gekoppelt bleiben.
/// Messreihen dazu: `docs/climate-snow-measurements.md`.
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

    /// **Abnahmekriterium 3 von Issue #33 — bewusst umgeschriebener Wächter.**
    ///
    /// Bis #33 hieß die Zusicherung hier: „die Schneezone ist nie leer und bleibt
    /// in einem engen FLÄCHENBAND" (Rampe/voll gemessen 0.0151/0.0015 bei Jahr 0
    /// und 0.0149/0.0015 nach 30k — per Konstruktion konstant, weil
    /// `bandSnowPercentile` einen Flächenanteil festschreibt). Genau das ist
    /// jetzt FALSCH: die Schneegrenze kommt aus der Massenbilanz, also aus einer
    /// Temperatur — und eine Temperatur ist eine HÖHE, keine Fläche. Die
    /// umgekehrte Zusicherung ist die richtige:
    ///
    /// 1. `snowStart` bleibt über den Lauf praktisch KONSTANT (klima-gepinnt),
    /// 2. der Flächenanteil SCHRUMPFT dafür, während die Insel abgetragen wird.
    ///
    /// Gemessen (n=832, Seed 1337, Produktionspfad; Rampe = Landanteil mit
    /// Schnee-Anteil > 0, Rohdaten `docs/climate-snow-measurements.md` §3):
    ///   Jahr 0  Rampe 0.0139  snowStart 0.5721  maxH 0.7457  T(Gipfel) −4.49 °C
    ///   10k     0.0115        0.5716            0.6726       −2.59 °C
    ///   30k     0.0090        0.5716            0.6359       −1.63 °C
    /// Die 0-°C-Isotherme liegt rechnerisch bei `sea + T₀/Γ` = 0.5730 — genau
    /// dort, wo `snowStart` steht.
    func testSnowZoneFollowsTheClimateNotAFixedLandFraction() {
        var c = SimConfig(); c.n = 832
        let t = Terrain(config: c, seed: 1337)
        let atGen = snowFractions(t)
        let startGen = t.heightBands.snowStart
        XCTAssertGreaterThan(atGen.ramp, 0, "Schneezone bei der Generierung leer")
        while t.years < 30_000 { t.step(dtYears: 500) }
        let at30k = snowFractions(t)
        let start30k = t.heightBands.snowStart
        print(String(format: "[#33] n=832 Rampe %.4f → %.4f · snowStart %.4f → %.4f "
                     + "· maxH %.4f", atGen.ramp, at30k.ramp, startGen, start30k,
                     t.maxHeight()))

        // 1) Die Grenze ist eine Temperatur, also eine Höhe: sie darf über 30k
        //    Jahre praktisch nicht wandern (die Rest-Bewegung ist die
        //    Histogramm-Quantisierung von 0.000488 plus die Luv/Lee-Streuung der
        //    Akkumulation). Die Schranke ist bewusst eng — vor #33 fiel
        //    `snowStart` im selben Lauf um über 0.01.
        XCTAssertEqual(start30k, startGen, accuracy: 0.005,
            "Schneegrenze ist nicht klima-gepinnt (\(startGen) → \(start30k))")
        let isotherm = c.sea + c.climateSeaLevelTemp / c.climateLapseRate
        XCTAssertEqual(startGen, isotherm, accuracy: 0.02,
            "Schneegrenze liegt nicht auf der 0-°C-Isotherme (\(startGen) gegen \(isotherm))")

        // 2) Dafür schrumpft die FLÄCHE, während die Gipfel abgetragen werden —
        //    das ist die Ablösung des fixen Landanteils.
        XCTAssertLessThan(t.maxHeight(), 0.70, "Vorbedingung: Insel trägt nicht ab")
        XCTAssertLessThan(at30k.ramp, atGen.ramp * 0.85,
            "Schneefläche folgt der abtragenden Insel nicht (\(atGen.ramp) → \(at30k.ramp))")
        // …und verschwindet dabei nicht: die Gipfel bleiben über der Isotherme.
        XCTAssertGreaterThan(at30k.ramp, 0.002,
            "Schneezone nach 30k Jahren praktisch leer: \(at30k.ramp)")
    }

    /// **Waldgrenze gegen Schneegrenze** (Review-Finding zu PR #28). Die beiden
    /// Bänder ÜBERLAPPEN sich per Konstruktion — `vegNone` (vegFull + Rampenbreite)
    /// liegt über `snowStart` —, die Sim hält also auch in der Schneezone
    /// noch Bewuchs. Baum-GEOMETRIE darf dort trotzdem nicht stehen; die Regel
    /// dafür ist `HeightBands.bearsTrees` (verbraucht von
    /// `SimNode.treeInstanceBuffer`).
    ///
    /// **Seit Issue #33 ist das zugleich der Wächter dafür, dass die WALDGRENZE
    /// am Schneefeld hängt:** `snowStart` kommt aus der Massenbilanz (früher
    /// p98.5), `bearsTrees` liest es unverändert. Die Waldgrenze folgt damit dem
    /// Klima, ohne dass ein Konsument der Höhenband-API etwas ändern musste.
    ///
    /// Der Test prüft beides: dass die Überlappung wirklich existiert (sonst wäre
    /// er stumm) und dass kein Standort in der Schneezone baumtragend ist.
    /// Gemessen (n=832, Seed 1337, Generierung, Stand #4): snowStart 0.5697,
    /// vegNone 0.6844, Höhenfaktor an der Schneegrenze 0.617 — 4 von 31995
    /// Baum-Kandidaten lagen vor dem Fix in der Schneezone, nach 30k Jahren 11
    /// von 56994. Mit dem Klima (#33) liegt `snowStart` auf 0.5721, die
    /// Überlappung ist also unverändert vorhanden.
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

    /// Die PERZENTIL-Bänder ziehen mit: sinkt das Terrain über einen langen Lauf,
    /// sinkt die Vegetationsgrenze mit — genau das, was absolute Schwellen nicht
    /// können. Nachgemessen (n=160, Seed 1337, 60k Jahre, Stand #33):
    /// vegFull 0.4945 → 0.4378, während maxH von 0.6864 auf 0.5762 fällt. (Die
    /// Trajektorie in docs/height-band-measurements.md stammt aus der #4-Zeit
    /// und liegt bei 0.4383 / 0.5807 — die Differenz ist die Physik-Entwicklung
    /// seit #11/#12/#13, nicht das Klima: das koppelt in keinen Pass, Wächter
    /// `ClimateSnow.testDisabledClimateIsBitIdenticalPhysics`.)
    ///
    /// **Der Schnee macht das seit Issue #33 bewusst NICHT mit** und ist deshalb
    /// die Gegenprobe im selben Test: seine Grenze ist eine Temperatur und bleibt
    /// stehen, wo sie ist — die Zone dünnt stattdessen aus. Vor #33 wanderte
    /// `snowStart` hier von 0.5658 auf 0.5072 mit, weil sie ein Perzentil war;
    /// jetzt gemessen 0.5702 → 0.5687.
    func testBandsFollowFlatteningTerrain() {
        var c = SimConfig(); c.n = 160
        let t = Terrain(config: c, seed: 1337)
        let b0 = t.heightBands
        let max0 = t.maxHeight()
        while t.years < 60_000 { t.step(dtYears: 500) }
        let b1 = t.heightBands
        print(String(format: "[#33] n=160 60k: vegFull %.4f → %.4f · snowStart %.4f → %.4f "
                     + "· maxH %.4f → %.4f", b0.vegFull, b1.vegFull,
                     b0.snowStart, b1.snowStart, max0, t.maxHeight()))
        XCTAssertLessThan(t.maxHeight(), max0, "Vorbedingung: Terrain flacht ab")
        XCTAssertLessThan(b1.vegFull, b0.vegFull,
            "Vegetationsgrenze folgt nicht (\(b0.vegFull) → \(b1.vegFull))")
        // Gegenprobe: die Klima-Grenze wandert nicht mit. Entweder sie steht
        // (Gipfel noch über der Isotherme) oder die Zone ist leer und das Band
        // liegt sauber ÜBER dem Land — beides ist „folgt dem Klima, nicht der
        // Verteilung", und beides schließt ein Mitwandern nach unten aus.
        XCTAssertGreaterThanOrEqual(b1.snowStart, b0.snowStart - 0.005,
            "Schneegrenze wandert mit dem Terrain statt mit dem Klima "
            + "(\(b0.snowStart) → \(b1.snowStart))")
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

    /// **Schneefreies Klima** (Issue #33): ein Landanteil von 0 ist ein gültiger
    /// Zustand — warme Welt oder flach erodierte Insel. Das Band muss dann
    /// vollständig ÜBER dem Land liegen, sonst wären ausgerechnet die Gipfel
    /// weiß, obwohl das Klima keinen Schnee trägt (und `bearsTrees` würde sie
    /// grundlos entwalden).
    func testEmptySnowFieldPutsTheBandAboveTheLand() {
        var c = SimConfig(); c.n = 64
        var heights = [Double](repeating: c.sea - 0.1, count: 4000)
        for k in 0..<2000 { heights[k] = c.sea + 0.1 + Double(k) * 0.0002 } // bis 0.65
        let maxLand = heights.max()!
        let bands = HeightBands.fromLandHeights(heights, cfg: c, snowFractions: (0, 0))
        XCTAssertGreaterThan(bands.snowStart, maxLand,
            "leeres Schneefeld: Band liegt im Land (snowStart \(bands.snowStart) ≤ \(maxLand))")
        XCTAssertGreaterThanOrEqual(bands.snowFull - bands.snowStart, c.bandMinRampWidth)
        for v in heights where v > c.sea {
            XCTAssertEqual(bands.snowAmount(v), 0, "Land trägt Schnee ohne Schneefeld")
            XCTAssertEqual(bands.bearsTrees(v), bands.vegetationAltitudeFactor(v) > 0,
                           "Waldgrenze wird ohne Schnee vom Schnee-Band beschnitten")
        }

        // Gegenprobe: mit Schnee schneidet das Band genau den gemessenen Anteil ab.
        let snowy = HeightBands.fromLandHeights(heights, cfg: c, snowFractions: (0.10, 0.02))
        let above = heights.filter { $0 > snowy.snowStart }.count
        let land = heights.filter { $0 > c.sea }.count
        XCTAssertEqual(Double(above) / Double(land), 0.10, accuracy: 0.01,
                       "Band schneidet nicht den gemessenen Landanteil ab")
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
