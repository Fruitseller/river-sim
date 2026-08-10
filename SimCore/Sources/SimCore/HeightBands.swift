import Foundation

/// Höhengrenzen für Vegetation, Hochfels und Schnee — abgeleitet aus **Quantilen
/// der aktuellen Landhöhen** statt aus absoluten Höhenwerten (Issue #4). Die
/// Grenzen selbst sind Perzentile; nur die Breite der Vegetations-Rampe ist eine
/// Quantil-SPANNE (s. `vegNone`).
///
/// **Warum relativ.** Absolute Schwellen altern mit jeder Neukalibrierung aus dem
/// erreichbaren Höhenband heraus. Gemessen (n=832, Seed 1337, Produktions-Defaults,
/// `docs/height-band-measurements.md`): die Landhöhen enden bei maxH 0.7457 (Jahr 0)
/// bzw. 0.6372 (30k Jahre) — die alte Schnee-Schwelle 1.05 lag also IMMER über dem
/// höchsten Punkt der Insel (0 Zellen, zu jedem Zeitpunkt), die Graurampe ab 0.58
/// traf 1.1 % → 0.6 % des Landes. Perzentile können das nicht passieren: die Zone
/// ist als FLÄCHENANTEIL definiert, nicht als Höhe. Sie zieht mit der abklingenden
/// Hebung (Issue #13) mit, ohne dass jemand die Farben nachziehen muss.
///
/// **Warum das die Gipfelzone auch nach oben begrenzt.** Der Anteil über
/// `snowStart` ist per Konstruktion `1 − bandSnowPercentile` — flacht das Terrain
/// ab, wird der Schnee nicht großflächig (kein „halbe Insel weiß"), er wandert nur
/// auf die dann höchsten Grate. Wächter:
/// `HeightBandTests.testSnowZoneAtProductionResolution`.
///
/// **Eine Quelle für Sim und Färbung.** `updateVegetation` (SimCore) und die
/// Biom-Färbung (`SimNode.terrainColorBytes`) hielten bis Issue #4 zwei Kopien
/// derselben Höhen-/Hang-/Feuchte-Logik mit auseinanderlaufenden Konstanten
/// (Höhenabfall ab 0.5 bzw. 0.6, Regenfaktor 1.3 bzw. 1.2). Beide lesen jetzt
/// `Terrain.heightBands` und `Terrain.vegetationSuitability`.
public struct HeightBands: Equatable, Sendable {
    /// Bis hier ist die Höhe für Bewuchs voll geeignet (Perzentil `bandVegFullPercentile`).
    public var vegFull: Double
    /// BREITE der Vegetations-Rampe, `bandVegRampSpanFactor · (p95 − p50)` —
    /// Begründung siehe `SimConfig.bandVegRampSpanFactor`: die obere
    /// Vegetationsgrenze lag früher bei 0.68 und damit über dem 99.99-Perzentil;
    /// ein Perzentil, das diese Rampenbreite trifft, hinge an den obersten paar
    /// Zellen. Die robuste Relief-Spanne (dasselbe Quantilpaar wie
    /// `Terrain.landReliefRobust`) ist die natürliche Skala dafür und kommt aus
    /// zehntausenden Zellen.
    ///
    /// Gespeichert wird die BREITE, nicht die obere Grenze: `vegetationAltitudeFactor`
    /// teilt durch sie, und eine als Differenz gerechnete Breite ist in Double
    /// nicht dasselbe wie der Literalwert (`0.68 − 0.5 == 0.18000000000000005`).
    /// Genau diese eine ulp reichte, um `EndorheicEvaporation`-Wächter zu kippen
    /// (Beckenrollen wechseln diskret, s. deren Doku) — mit der Breite als Wert
    /// reproduziert `legacyAbsolute` die Vor-#4-Arithmetik exakt.
    public var vegRamp: Double
    /// Ab hier wächst nichts mehr (Höhenwüste) — abgeleitet aus `vegFull + vegRamp`.
    public var vegNone: Double { vegFull + vegRamp }
    /// Beginn der Hochlagen-Graurampe (neutral-grauer Fels).
    public var rockStart: Double
    /// Ab hier ist der Fels voll ausgegraut.
    public var rockFull: Double
    /// Beginn des Schnees.
    public var snowStart: Double
    /// Ab hier voll weiß.
    public var snowFull: Double
    /// Höhenband, über das die Baum-Variante von Laub nach Nadel dreht.
    public var coniferLow: Double
    public var coniferHigh: Double

    /// Die historischen ABSOLUTEN Schwellen von vor Issue #4. Zwei Rollen:
    ///
    /// 1. Rückfall ohne auswertbare Landverteilung (< 20 Landzellen — frisch
    ///    geflutete Welt, synthetische Testfelder): eine wohldefinierte Antwort
    ///    auf „es gibt kein Land zu befragen".
    /// 2. Pin für Wächter, die an EINEM konkreten Becken/Lauf hängen
    ///    (`SimConfig.heightBandsOverride`) — dort muss die Vegetation exakt wie
    ///    vor #4 rechnen, deshalb sind die Werte Literale und die Rampenbreite
    ///    ist als Wert (0.18) hinterlegt statt als Differenz (s. `vegRamp`).
    public static let legacyAbsolute = HeightBands(
        vegFull: 0.50, vegRamp: 0.18,
        rockStart: 0.58, rockFull: 0.98,
        snowStart: 1.05, snowFull: 1.13,
        coniferLow: 0.26, coniferHigh: 0.48)

    /// Höhen-Eignung für Bewuchs: 1 unterhalb `vegFull`, linear auf 0 bei `vegNone`.
    /// (Vor Issue #4: `v < 0.5 ? 1 : max(0, 1 − (v − 0.5)/0.18)` im Sim-Kern und
    /// dieselbe Formel mit 0.6 in der Färbung.)
    @inline(__always) public func vegetationAltitudeFactor(_ v: Double) -> Double {
        v < vegFull ? 1 : max(0, 1 - (v - vegFull) / max(1e-6, vegRamp))
    }

    /// Anteil Hochlagen-Grau (0 … 1).
    @inline(__always) public func rockAmount(_ v: Double) -> Double {
        v <= rockStart ? 0 : min(1, (v - rockStart) / max(1e-6, rockFull - rockStart))
    }

    /// Anteil Schnee (0 … 1).
    @inline(__always) public func snowAmount(_ v: Double) -> Double {
        v <= snowStart ? 0 : min(1, (v - snowStart) / max(1e-6, snowFull - snowStart))
    }

    /// Wahrscheinlichkeit, dass ein Baum an dieser Höhe Nadel- statt Laubbaum ist
    /// (0.1 … 0.9 wie vor Issue #4, nur an das Höhenband gekoppelt).
    @inline(__always) public func coniferShare(_ v: Double) -> Double {
        min(0.9, max(0.1, (v - coniferLow) / max(1e-6, coniferHigh - coniferLow)))
    }

    /// **Waldgrenze**: trägt diese Höhe Baum-GEOMETRIE? Das ist bewusst enger als
    /// `vegetationAltitudeFactor > 0`, weil sich die beiden Bänder überlappen:
    /// `vegNone` (vegFull + Rampenbreite) liegt ÜBER `snowStart` (p98.5): gemessen
    /// n=832, Seed 1337 bei der Generierung 0.6844 gegen 0.5697, und der
    /// Höhenfaktor beträgt an der Schneegrenze noch 0.617. Vor Issue #4 war das
    /// unsichtbar — die Schneegrenze 1.05 wurde nie erreicht, es gab keine
    /// Schneezone. Jetzt ist sie real besetzt, und ohne diese Grenze stellt
    /// `SimNode.treeInstanceBuffer` Bäume auf verschneite Gipfel: gemessen 4 von
    /// 31995 Baum-Kandidaten bei der Generierung und 11 von 56994 nach 30k Jahren
    /// (22 bzw. 49 Schneezellen tragen dort veg > 0.32). Wenige Instanzen, aber
    /// steigend — und jede einzelne steht sichtbar im Weiß.
    ///
    /// Warum die Grenze HIER und nicht in `vegNone`: `veg` geht über `vegDamp` in
    /// die Erosion ein. `vegNone` auf `snowStart` zu ziehen würde die Rampe von
    /// 0.1864 auf ~0.071 stauchen — genau die Änderungsklasse, die gemessen 1.1 %
    /// Relief gekostet und zwei knapp gepinnte Wächter gekippt hat
    /// (`docs/height-band-measurements.md` §5). Das wäre eine eigene, eigens zu
    /// vermessende Kalibrierentscheidung; die Waldgrenze ist dagegen reine
    /// Darstellung und darf sofort korrekt sein.
    @inline(__always) public func bearsTrees(_ v: Double) -> Bool {
        snowAmount(v) <= 0 && vegetationAltitudeFactor(v) > 0
    }

    /// Leitet die Bänder aus den Landhöhen ab. `nil`-Rückgabe der Quantile
    /// (zu wenig Land) → `legacyAbsolute`.
    ///
    /// Zwei Sicherungen halten die Bänder auch auf entartetem Terrain benutzbar:
    /// die Perzentile werden monoton sortiert entnommen, und jede Rampe bekommt
    /// mindestens `cfg.bandMinRampWidth` Breite (eine spiegelglatte Insel hätte
    /// sonst identische Quantile → Sprungfunktion statt Verlauf).
    public static func fromLandHeights(_ heights: [Double], cfg: SimConfig) -> HeightBands {
        // Feste Slot-Reihenfolge; `landHeightQuantiles` will die Perzentile
        // AUFSTEIGEND (ein Histogramm-Durchlauf), deshalb hier sortieren und das
        // Ergebnis zurückverteilen — so darf die Config die Perzentile in jeder
        // Reihenfolge setzen, ohne dass die Bänder still auf `legacyAbsolute` kippen.
        let raw = [cfg.bandVegFullPercentile, 0.5,
                   cfg.bandRockPercentile, cfg.bandRockFullPercentile,
                   cfg.bandSnowPercentile, cfg.bandSnowFullPercentile,
                   cfg.bandConiferLowPercentile, cfg.bandConiferHighPercentile,
                   0.95] // Slots 1 und 8: das Quantilpaar der robusten Relief-Spanne
        let order = raw.indices.sorted { raw[$0] < raw[$1] }
        guard let sorted = Terrain.landHeightQuantiles(heights: heights, sea: cfg.sea,
                                                       probs: order.map { raw[$0] })
        else { return legacyAbsolute }
        var q = [Double](repeating: 0, count: raw.count)
        for (slot, original) in order.enumerated() { q[original] = sorted[slot] }
        let w = max(1e-6, cfg.bandMinRampWidth)
        // Vegetations-Rampe: eine robuste Relief-Spanne (p95 − p50) breit.
        let reliefSpan = cfg.bandVegRampSpanFactor * (q[8] - q[1])
        return HeightBands(vegFull: q[0], vegRamp: max(w, reliefSpan),
                           rockStart: q[2], rockFull: max(q[3], q[2] + w),
                           snowStart: q[4], snowFull: max(q[5], q[4] + w),
                           coniferLow: q[6], coniferHigh: max(q[7], q[6] + w))
    }
}
