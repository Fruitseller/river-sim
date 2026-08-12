import Foundation

/// Kalibrierung des Wasser-Renderings: Kohärenz-Fade der Wasser-Komponenten
/// (Issue #32) und die Fenster, mit denen `game/shaders/terrain.gdshader` die
/// Kanäle des Wasserfelds liest.
///
/// Wie `Strahler` eine reine RENDER-Ableitung ohne Sim-Zustand — und wie dort
/// eine bewusste Ausnahme von „SimCore = Physik". Grund: die Zahlen hängen
/// paarweise zusammen (Komponentengröße ↔ Shader-Smoothstep ↔ Altarm-Stempel),
/// stehen aber sonst verstreut in der GDExtension (nur mit 20-Minuten-Build
/// prüfbar) und im Shader (überhaupt nicht prüfbar). Hier sind sie headless
/// testbar; Wächter: `SimCoreTests/WaterRenderTests.swift`.
///
/// Diese Werte ändern KEINE Physik — sie entscheiden nur, was gemalt wird.
public enum WaterRender {

    // MARK: Kohärenz-Fade über Wasser-Komponenten (Issue #32)

    // Die rauen Braid-Ebenen tragen tausende isolierte Wasser-Fetzen, die als
    // blaue Punktfelder dithern („zu viele Flüsse/Seen"). Zusammenhängende
    // Komponenten (4er-Nachbarschaft) unter `componentFadeLoCells` bleiben
    // unsichtbar, bis `componentFadeHiCells` steigt die Deckkraft linear.
    // FADE statt hartem Cutoff bei 25 Zellen: beim Überschreiten der Schwelle
    // PLOPPTEN wachsende Seen.

    /// Untere Fenstergrenze: Komponenten bis hierher bleiben unsichtbar.
    public static let componentFadeLoCells = 10.0
    /// Obere Fenstergrenze: ab hier volle Deckkraft.
    public static let componentFadeHiCells = 50.0

    /// Deckkraft-Fade einer zusammenhängenden Wasser-Komponente aus ihrer
    /// Zellzahl. Reine Funktion der Größe — die Flood-Fill-Reihenfolge kann das
    /// Ergebnis nicht beeinflussen (Determinismus).
    @inline(__always)
    public static func componentFade(cells: Int) -> Double {
        min(1, max(0, (Double(cells) - componentFadeLoCells)
                      / (componentFadeHiCells - componentFadeLoCells)))
    }

    // MARK: Fenster, mit denen der Shader die Kanäle liest

    // Die beiden Kanäle kommen auf VERSCHIEDENEN Wegen zur Sichtbarkeit, weil
    // der Shader sie verschieden liest — gewollt, aber leicht zu übersehen:
    //   See:   GATE. smoothstep(lakeGateLo, lakeGateHi, fade) — voll ab
    //          Fade ≥ 0.35 (= 24 Zellen), unsichtbar unter 0.04 (≈ 12 Zellen).
    //   Fluss: KEIN Gate. riverMask = smoothstep(riverMaskLo, riverMaskHi, sd)
    //          liest den Kanal als INTENSITÄT, der Fade skaliert sie also nur.
    // Die Gate-Kurve NICHT „symmetrisch" auch auf den Fluss-Kanal legen: sie
    // sättigt bei 0.35, riverMask erst bei 0.45 — kombiniert wären 18-Zell-
    // Fetzen VOLL sichtbar, also genau die Sprenkel, die der Fade verhindern
    // soll (nachgerechnet, verworfen).

    /// `lake_gate_at` in `terrain.gdshader`: smoothstep über den G-Kanal.
    public static let lakeGateLo = 0.04
    /// s. `lakeGateLo`.
    public static let lakeGateHi = 0.35
    /// `riverMask` in `terrain.gdshader`: smoothstep über den R-Kanal.
    public static let riverMaskLo = 0.16
    /// s. `riverMaskLo`.
    public static let riverMaskHi = 0.45

    // Ufer-Saum: der Shader tönt den weichen Blur-Halo der Wasserfelder als
    // nassen Sand-/Kies-Streifen. Sein Fenster liegt UNTER dem Wasser-Fenster des
    // Fluss-Kanals (0.09..0.16 gegen 0.16..0.45) — genau deshalb entsteht rund um
    // sichtbares Wasser ein Ufer statt einer harten Farbkante.
    /// `shore` in `terrain.gdshader`: smoothstep über max(R-Kanal, G-Kanal).
    public static let shoreLo = 0.09
    /// s. `shoreLo` — ab hier deckt der Saum voll.
    public static let shoreHi = 0.16

    /// Saum-Intensität des Ribbon-Korridors (Issue #31, `SimNode.waterFieldBytes`):
    /// im Ribbon-Modus rendert die Band-Geometrie das Wasser, das Feld stempelt den
    /// Korridor nur noch als Nass-Halo. Der Wert MUSS zwischen `shoreLo` und
    /// `riverMaskLo` liegen — darunter fiele der Halo aus, darüber malte das Feld
    /// unter dem Band eine zweite, sprenklige Fluss-Version.
    public static let ribbonHaloIntensity = 0.14

    // MARK: Kohärenz-Gate des Fluss-Kanals

    // Der Fluss-Kanal verträgt KEINEN weichen Fade. Der Shader liest ihn als
    // Intensität, und sein Unter-Wasser-Bereich IST das Saum-Fenster: ein voller
    // Lauf (sd ≈ 1) in einer Komponente mit Fade 0.15 landet bei stream = 0.15 —
    // riverMask 0 (kein Wasser), shore aber ≈ 0.94 (voller Sandstreifen). Eine
    // 14–16-Zell-Komponente malte damit einen sandbraunen Fleck ohne Wasser
    // darin, wo der alte harte Cutoff exakt 0 lieferte. Deshalb bleibt der
    // Fluss-Kanal ein GATE: unter `streamGateFade` trägt die Komponente nichts,
    // darüber ihre volle Intensität.
    //
    // Das Gate liegt bei `riverMaskHi`, also bei der Fade-Höhe, ab der ein voller
    // Lauf bereits deckendes Wasser ist (riverMask = 1 → shore = 0 im Kern) —
    // beim Einschalten kann also per Konstruktion kein Saum ohne Wasser stehen.
    // In Zellen: 10 + 0.45·40 = 28 (alter harter Cutoff: 25).
    //
    // Der SEE-Kanal behält den weichen Fade: dort lag der Auslöser von #32
    // (wachsende Seen PLOPPTEN), und er wird über ein Gate gelesen, dessen
    // Fenster (0.04..0.35) vor dem Saum-Fenster sättigt.
    public static let streamGateFade = riverMaskHi

    /// Faktor, mit dem der Fluss-Kanal einer Komponente skaliert wird: 1 ab
    /// `streamGateFade`, sonst 0.
    @inline(__always)
    public static func streamGate(componentFade fade: Double) -> Double {
        fade >= streamGateFade ? 1 : 0
    }

    /// Kleinste Komponente (Zellen), deren Fluss-Kanal überhaupt gemalt wird.
    public static var streamGateCells: Int {
        var cells = Int(componentFadeLoCells)
        while Double(cells) <= componentFadeHiCells,
              streamGate(componentFade: componentFade(cells: cells)) == 0 {
            cells += 1
        }
        return cells
    }

    // MARK: Shader-Lesarten als reine Funktionen

    // Nachbau der Stellen aus `terrain.gdshader`, die diese Kalibrierung lesen —
    // damit die REGRESSION (Saum ohne Wasser) headless prüfbar ist statt nur auf
    // der GPU. Der Textvergleich in `WaterRenderTests` hält beide Seiten synchron.

    @inline(__always)
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    /// `riverMask` — Wasserdeckung aus dem R-Kanal.
    public static func riverMask(stream: Double) -> Double {
        smoothstep(riverMaskLo, riverMaskHi, stream)
    }

    /// `lake_gate_at` — Sichtbarkeits-Gate aus dem G-Kanal.
    public static func lakeGate(channel: Double) -> Double {
        smoothstep(lakeGateLo, lakeGateHi, channel)
    }

    /// `lakeMask` — Gate × Per-Pixel-Uferkontur der Wassersäule.
    public static func lakeMask(channel: Double, pond: Double) -> Double {
        smoothstep(pondContourLo, pondContourHi, pond) * lakeGate(channel: channel)
    }

    /// `shore` — Ufer-Saum. Er ist ein LAND-Effekt: der Faktor über der
    /// Wassersäule hält ihn aus allem heraus, wo real Wasser steht. Ohne ihn
    /// tönte eine halb eingeblendete Seefläche (Gate 0.16 → lakeMask 0.29) ihren
    /// eigenen Grund zu 71 % sandbraun, bevor das Wasser sichtbar wird. Auf dem
    /// Uferring ist pond = 0, der gemessene Saum bleibt also unverändert
    /// (docs/lake-shore-contour-measurements.md).
    public static func shore(stream: Double, lakeGateChannel: Double, pond: Double) -> Double {
        let wet = max(riverMask(stream: stream), lakeMask(channel: lakeGateChannel, pond: pond))
        let dry = 1 - smoothstep(pondContourLo, pondContourHi, pond)
        return smoothstep(shoreLo, shoreHi, max(stream, lakeGateChannel)) * (1 - wet) * dry
    }

    // MARK: Per-Pixel-Uferkontur (Issue #32)

    // Die FORM der Uferlinie rechnet der Shader je Pixel aus der Wassersäule
    // `pond = waterLevel − h` (volles Sim-Gitter, bilinear) — der G-Kanal ist
    // nur noch das Sichtbarkeits-Gate. Dieses Fenster ist der Fuß/Sattel der
    // Farb-Kontur; es liegt bewusst UNTER der Hebe-Schwelle der Wasser-
    // Geometrie (0.015), damit die Farbe bis fast an die echte Uferlinie
    // reicht, während die Geometrie erst später sanft hebt.
    //
    // Der Fuß ist zugleich die Präsenz-Schwelle des Altarm-Overlays
    // (`SimNode.waterFieldBytes`): dessen Deckkraft wird im Shader mit dieser
    // Kontur multipliziert, also darf das Overlay nur so tief stempeln, wie
    // die Kontur noch zeichnet — sonst sind gerade die seichten Altarm-Enden
    // unsichtbar. Wer den Fuß verschiebt, verschiebt beides.
    public static let pondContourLo = 0.003
    /// Wassersäule, ab der die Farb-Kontur voll deckt.
    public static let pondContourHi = 0.02

    // MARK: Weitere Fenster über derselben Wassersäule

    // Drei Fenster lesen `pond` — Farb-Kontur, Geometrie-Hub und Tiefen-Rampe —
    // und ihre REIHENFOLGE ist die Kalibrierung: erst Farbe (ab 0.003), dann
    // Geometrie (ab 0.015), die Tiefe füllt dazwischen. Verschiebt man eines
    // allein, löst sich die Farbe von der gehobenen Wasserfläche.

    /// `lift` in `terrain.gdshader`: ab hier hebt die Wasser-Geometrie.
    /// Bewusst ÜBER `pondContourLo` — die Farbe reicht bis fast an die echte
    /// Uferlinie, die Geometrie hebt erst danach sanft.
    public static let geometryLiftLo = 0.015
    /// s. `geometryLiftLo` — ab hier hebt sie voll.
    public static let geometryLiftHi = 0.05

    /// `lake_depth` in `terrain.gdshader`: Fuß der Tiefen-Rampe fürs Blau.
    public static let lakeDepthLo = 0.004
    /// Spanne der Tiefen-Rampe: volle Sättigung bei `lakeDepthLo + lakeDepthSpan`.
    public static let lakeDepthSpan = 0.05

    // MARK: Geometrie-Wasser (Issue #34): Mündungen, Deltas, Altarme

    // Mit #34 rendert die BAND-GEOMETRIE das bewegte Wasser (Mäander, Deltas,
    // Altarme), das Raster-Feld nur noch das stehende (Seen/Meer über
    // `pond`/Gate) plus die dendritischen Zubringer unterhalb der Mäander-
    // Schwelle. Die drei Zahlen unten sind die NAHTSTELLE zwischen beiden:
    // wo das Band endet, wo das Feld übernimmt, und was als Delta gilt.

    /// Typ-Kennung im Vertex-Vertrag (`UV2.x`, gelesen von `water.gdshader`):
    /// fließendes Fluss-Band.
    public static let ribbonKindRiver = 0.0
    /// s. `ribbonKindRiver` — Delta-Distributär (Flachwasser über dem
    /// Ablagerungskörper, trüb statt tiefblau).
    public static let ribbonKindDelta = 0.5
    /// s. `ribbonKindRiver` — Altarm: STILLWASSER, keine Fließrichtung
    /// (der Shader schaltet Strömungs-Schimmer aus und dämpft die Kräuselung).
    public static let ribbonKindOxbow = 1.0

    /// Mündung: so weit (Zellen) läuft ein Fluss-Band in die Wasserfläche
    /// hinein, bevor seine Deckkraft auf 0 ist.
    ///
    /// Beide Enden dieses Werts sind ein Fehlerbild: 0 lässt zwischen Bandende
    /// und Uferkontur einen SPALT (die Kontur liegt per-Pixel auf der
    /// Wassersäule, das Band auf der zell-gerundeten Zentrumslinie — sie treffen
    /// sich nie exakt), zu groß malt das Band eine zweite, hellere Wasserfläche
    /// ÜBER den See (Overdraw). 2 Zellen ≈ 0,31 Welteinheiten decken den
    /// Diskretisierungs-Versatz und sind bei Ribbon-Halbbreiten bis 3,2 Zellen
    /// noch kürzer als das Band breit ist.
    public static let mouthOverlapCells = 2.0

    /// Wassersäule, ab der das RASTER-Feld eine Fläche überhaupt als See malt
    /// (`rawWet` in `SimNode.waterFieldBytes`). Seichteres Ponding bleibt dort
    /// bewusst trocken („zu viele Seen"), und genau darum ist dieser Wert die
    /// NAHTSTELLE zur Geometrie: unterhalb malt niemand, oberhalb der Raster-See.
    public static let lakeRawWetDepth = 0.03

    /// Delta-Front: bis zu dieser Wassersäule gilt eine überflutete Zelle als
    /// Delta-Apron (Ablagerungskörper knapp unter Wasser), darüber beginnt das
    /// offene Becken — dort hören die Distributär-Arme auf.
    ///
    /// GEMESSEN (Seed 1337, Jahr 20.000, `docs/geometry-water-measurements.md`
    /// §A): an den 14 größten Mündungen liegt die Wassersäule direkt vor der
    /// Mündung entweder bei 0.002…0.02 (flacher Ablagerungskörper, der über
    /// mehrere Zellen trägt) oder sofort bei 0.03…0.05 (Steilufer, der Lauf
    /// stürzt ins Becken). Eine eigene Zahl dazwischen wäre eine dritte
    /// Kalibrierung — stattdessen IST die Front die Raster-See-Schwelle:
    /// die Geometrie malt exakt den Saum, den das Raster-Feld nicht malen
    /// kann, und hört auf, wo es übernimmt. Kein Spalt, keine Doppelung.
    public static let deltaFrontDepth = lakeRawWetDepth

    /// Kürzester Distributär-Arm (Zellen Apron zwischen Uferlinie und Front),
    /// der überhaupt gemalt wird — kürzere Aprons sind Steilufer ohne Delta.
    public static let deltaMinArmCells = 3
    /// Längster Distributär-Arm (Zellen). Der Arm endet normalerweise an der
    /// Front; der Deckel begrenzt ihn auf ausgedehnt flachen Aprons — vor
    /// flachen Schelfen lief er sonst über die ganze Bucht (A/B-Screenshot:
    /// drei helle Strahlen ins Meer statt eines Fächers an der Mündung).
    public static let deltaMaxArmCells = 10
    /// Winkel-Aufweitung der äußeren Distributär-Arme gegen die Mündungs-
    /// richtung (Bogenmaß ≈ 25°) — die Auffächerung des Fächers.
    public static let deltaArmSpread = 0.44

    // Höhen-Versatz eines Bands auf einer Wasserfläche, in GODOT-WELT-Y (wie
    // `Main.RIVER_LIFT`, NICHT in Sim-Höhen). Auf Land trägt das Band den vollen
    // `lift`, der den Chord-Fehler des gröberen Render-Gitters im Talgrund
    // abdeckt; über Wasser hob genau der es sichtbar aus der Fläche heraus.
    /// See: ein Hauch ÜBER dem Spiegel — im Apron liegt das Terrain-Gitter noch
    /// unter dem Spiegel (der Vertex-Hub des Shaders greift erst ab
    /// `geometryLiftLo`), das Band darf dort nicht im Grund verschwinden.
    public static let ribbonLakeSurfaceLift = 0.04
    /// Meer: knapp UNTER die Wasser-Ebene — dann liest sich das Band als Trübung
    /// IM Wasser statt als Platte darauf (A/B-Befund, s.
    /// `docs/geometry-water-measurements.md` §C).
    public static let ribbonSeaSurfaceSink = -0.06

    // Wie `water.gdshader` den Typ-Kanal (UV2.x) liest: zwei Smoothsteps statt
    // einer if-Kaskade, damit der Wert über das Band interpoliert werden darf.
    // Die Fenster liegen zwischen den Typ-Werten — wer `ribbonKind*` verschiebt,
    // muss sie mitziehen (Wächter: `WaterRenderTests`).
    public static let ribbonStillLo = 0.75
    /// s. `ribbonStillLo`.
    public static let ribbonStillHi = 1.0
    /// s. `ribbonStillLo`.
    public static let ribbonDeltaLo = 0.25
    /// s. `ribbonStillLo`.
    public static let ribbonDeltaHi = 0.5

    /// `still` im Shader: 1 = Stillwasser (Altarm, keine Fließrichtung).
    public static func ribbonStillWeight(kind: Double) -> Double {
        smoothstep(ribbonStillLo, ribbonStillHi, kind)
    }

    /// `delta` im Shader: 1 = Distributär-Arm (Trübungsfahne, Flachwasser).
    public static func ribbonDeltaWeight(kind: Double) -> Double {
        (1 - ribbonStillWeight(kind: kind)) * smoothstep(ribbonDeltaLo, ribbonDeltaHi, kind)
    }
    /// Deckkraft-Deckel eines Delta-Arms. Bewusst klein: der Fächer liegt im
    /// Wasser des Beckens (am Meer sogar UNTER dessen Wasser-Ebene) und soll als
    /// Trübungsfahne über dem Ablagerungskörper lesen, nicht als zweite
    /// Wasserfläche. 0.55 war messbar zu viel — die Arme standen als helle
    /// Strahlen auf dem Meer.
    public static let deltaArmOpacity = 0.35
}
