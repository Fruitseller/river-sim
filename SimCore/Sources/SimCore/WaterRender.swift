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

    /// Saum-Intensität des Ribbon-Korridors (Issue #31,
    /// `SimRender.WaterFieldRenderer`): im Ribbon-Modus rendert die Band-Geometrie
    /// das Wasser, das Feld stempelt den Korridor nur noch als Nass-Halo. Der Wert
    /// MUSS zwischen `shoreLo` und `riverMaskLo` liegen — darunter fiele der Halo
    /// aus, darüber malte das Feld unter dem Band eine zweite, sprenklige
    /// Fluss-Version.
    public static let ribbonHaloIntensity = 0.14

    // MARK: Schutzmaske (Issue #154)

    // `SimRender.WaterProtectMask` sperrt Kronendach und Verschiebung an
    // Wasser. „Sichtbar" heißt dabei dasselbe wie im Shader: die beiden
    // Wasser-Schwellen SIND die unteren smoothstep-Kanten oben, keine eigene
    // Kalibrierung. Gepinnt in `WaterRenderTests`.

    /// Fluss sichtbar ab der Unterkante von `riverMask` (R-Kanal).
    public static let protectRiverThreshold = riverMaskLo
    /// See sichtbar ab der Unterkante von `lake_gate_at` (G-Kanal).
    public static let protectLakeThreshold = lakeGateLo
    /// Band gilt als gebaut, sobald es an der Zelle überhaupt deckt. Nicht 0:
    /// `bandCoverage` ist ein Maximum über Alpha-Verläufe, und die
    /// auslaufenden Enden (Alpha → 0) sind unsichtbar; 0.01 ≈ 3/255, also
    /// unter jeder darstellbaren Deckkraft eines 8-Bit-Ziels.
    public static let protectBandThreshold = 0.01
    /// Saum in Zellen (Chebyshev). 2, weil (a) #154 „etwa zwei Zellen"
    /// verlangt (Ufer dürfen nicht über ein Band wachsen) und (b) die Rohbytes
    /// des `RS_WATER_GPU`-Pfads ungeblurt sind: der See-Kanal wird CPU-seitig
    /// zweimal geblurt (`blurMax`, 1 Zelle je Pass), der Saum deckt genau das.
    /// Der Shader (`protect.gdshaderinc`) legt KEINEN zweiten Saum darüber.
    public static let protectSeamCells = 2

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
    // der GPU. Die Zahlen reisen als Uniforms zum Shader (`SimRender.
    // WaterUniforms`, #91/#92); der Struktur-Vertrag in `WaterRenderTests` hält
    // fest, welche Shader-Stelle welches Fenster liest.

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
        let s = stream.isFinite ? stream : 0
        let l = lakeGateChannel.isFinite ? lakeGateChannel : 0
        let wet = max(riverMask(stream: s), lakeMask(channel: l, pond: pond))
        let dry = 1 - smoothstep(pondContourLo, pondContourHi, pond)
        return smoothstep(shoreLo, shoreHi, max(s, l)) * (1 - wet) * dry
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
    // (`SimRender.WaterFieldRenderer`): dessen Deckkraft wird im Shader mit
    // dieser Kontur multipliziert, also darf das Overlay nur so tief stempeln,
    // wie die Kontur noch zeichnet — sonst sind gerade die seichten
    // Altarm-Enden unsichtbar. Wer den Fuß verschiebt, verschiebt beides.
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
    /// (`rawWet` in `SimRender.WaterFieldRenderer`). Seichteres Ponding bleibt
    /// dort bewusst trocken („zu viele Seen"), und genau darum ist dieser Wert die
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
    /// Mindestabstand (Zellen) zweier Delta-Fächer: münden mehrere Kanäle so
    /// dicht beieinander, bekommt nur der größte einen Fächer. Vorher lagen an
    /// einer Mündung bis zu vier identische Fächer übereinander (Seed 1337,
    /// Jahr 230.000) und addierten sich zu einem dunklen Block.
    public static let deltaFanSpacingCells = 3.0
    /// Verdeckungs-Fenster der Bänder untereinander (`RiverRibbonRenderer.
    /// emitRibbon`): ein Band blendet über der Deckung FRÜHER gebauter Bänder
    /// aus — ab 0,3 beginnend, ab 0,9 ganz. Zwei halbtransparente Bänder
    /// übereinander malten sonst dunkle Blöcke und Stöße an Zusammenflüssen.
    public static let ribbonOcclusionLo = 0.3
    /// s. `ribbonOcclusionLo`.
    public static let ribbonOcclusionHi = 0.9

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

    // MARK: Kanalbreiten der Band-Geometrie (Issue #31, zentralisiert mit #51)

    /// Halbbreite (Zellen) eines Fluss-Bands am Referenz-Abfluss
    /// `SimConfig.renderMinCells`: dort ≈ die Optik des alten Raster-Stempels.
    public static let ribbonHalfWidthAtReference = 0.8
    /// Boden der Halbbreite — hält Oberläufe als feine Fäden sichtbar.
    public static let ribbonHalfWidthFloorCells = 0.12
    /// Deckel der Halbbreite: verhindert Ströme-als-Seen auf den verknäulten
    /// Ebenen (Lehre aus dem Blob-Felder-Rückbau des Stempels).
    public static let ribbonHalfWidthCapCells = 3.2

    /// Maximale QUER-Neigung eines Land-Bands (Welt-Y je Welt-Breite): jede
    /// Kante folgt ihrer eigenen Geländehöhe (sanfte Quergefälle schneiden das
    /// Band sonst ins Terrain), aber nur bis zu dieser Neigung um die
    /// Zentrums-Höhe. Ohne die Klemme drapierte sich ein Band, das breiter als
    /// die Schluchtsohle ist, die WÄNDE hoch — aus der Nähe als große blaue
    /// Platten/Dreiecke an den Felswänden sichtbar (User-Screenshots, frische
    /// Steilwelt). Eine Wasserfläche steht quer zur Fließrichtung praktisch
    /// eben; 0.4 (≈ 22°) lässt Auen-Schrägen durch und begräbt Wand-Kanten im
    /// Fels — sichtbar bleibt die Sohlenbreite.
    public static let ribbonMaxCrossSlope = 0.4

    /// Halbbreite (Zellen) eines Fluss-Bands aus dem Abfluss `dischargeCells`
    /// (Zellen Einzugsgebiet), bezogen auf `referenceCells`
    /// (= `SimConfig.renderMinCells`).
    ///
    /// Hydraulische Geometrie w ∝ √Q (Leopold/Maddock, Exponent b ≈ 0.5) statt
    /// des 1-Zellen-Deckels des Stempels — dieselbe Kurve speist die
    /// Band-Geometrie UND den Radius des Nass-Halos im Wasserfeld, damit der
    /// Halo das Band immer ganz umfasst.
    @inline(__always)
    public static func ribbonHalfWidthCells(dischargeCells: Double,
                                            referenceCells: Double) -> Double {
        guard referenceCells > 0 else { return ribbonHalfWidthFloorCells }
        let w = ribbonHalfWidthAtReference
            * (max(0, dischargeCells) / referenceCells).squareRoot()
        return min(ribbonHalfWidthCapCells, max(ribbonHalfWidthFloorCells, w))
    }

    /// Rand (Zellen), den der Halo-Korridor im Wasserfeld über die Band-
    /// Halbbreite hinaus stempelt — ohne ihn endete der Nass-Saum an der
    /// Bandkante statt sie zu umfassen.
    public static let ribbonHaloMarginCells = 1.0

    /// Halbbreite des Altarm-Bands (Zellen). Ein Altarm ist der verlassene Bogen
    /// EINES Laufs — knapp unter dem Ribbon-Deckel und über dem Boden, also
    /// bewusst konstant statt abflussabhängig: Abfluss hat ein Altarm per
    /// Definition keinen mehr.
    public static let oxbowHalfWidthCells = 1.0

    /// Mindest-Halbbreite eines Delta-Arms (Zellen): ein Delta-Arm ist BREITER
    /// als der Lauf, aus dem er kommt (der Strom verliert an der Mündung seine
    /// Tiefe, nicht sein Wasser). Ohne dieses Mindestmaß wurden aus schmalen
    /// Mündungen drei nadeldünne Strahlen (A/B-Screenshot).
    public static let deltaArmMinHalfWidthCells = 1.5
    /// Breiten-Profil eines Delta-Arms über seine Länge f ∈ [0,1]:
    /// `armWidth * (deltaArmWidthAtMouth − deltaArmWidthTaper · f)` — an der
    /// Mündung etwas breiter als der Lauf, zur Front hin schmaler.
    public static let deltaArmWidthAtMouth = 1.2
    /// s. `deltaArmWidthAtMouth`.
    public static let deltaArmWidthTaper = 0.6
    /// Rang-Dämpfung eines Delta-Arms: der Fächer ist Flachwasser, seine
    /// Tiefenfarbe darf nicht die des Hauptlaufs sein.
    public static let deltaArmRankFactor = 0.35

    // MARK: Enden, Taper und Sichtbarkeits-Gates der Bänder

    /// Quellen-Taper eines Fluss-Bands (Zellen Bogenlänge): der Oberlauf wächst
    /// aus dem Nichts, statt mit voller Breite anzufangen.
    public static let ribbonSourceTaperCells = 4.0
    /// Enden-Taper (Zellen Bogenlänge) — gilt für den im Land versickernden
    /// Lauf, den Überlappungs-Deckel an der Mündung und die Delta-Arme.
    public static let ribbonTailTaperCells = 2.0
    /// Mindestlänge der beiden LAND-Taper (Quelle und versickerndes Ende) in
    /// Vielfachen der Halbbreite dort: ein Band endet spitz statt stumpf.
    /// Mit den festen 4 bzw. 2 Zellen lief ein Hauptlauf am Deckel
    /// (Halbbreite 3,2) auf weniger als seiner halben Breite von voll auf null
    /// aus: ein rechtwinklig abgeschnittenes Band, wo die Sim den Lauf vor
    /// einer Steilstrecke enden lässt und das Raster weitermalt (Review #181).
    /// Bei 3 Halbbreiten liegt Deckkraft 0,5 eineinhalb Halbbreiten vor dem
    /// Ende. Mündungen behalten `ribbonTailTaperCells`: dort endet das Band
    /// im Wasser, und die Übergabe regelt die Wassersäule.
    /// GEMESSEN: `docs/river-belt-render-measurements.md` §C.
    public static let ribbonLandTaperHalfWidths = 3.0
    /// Größte Änderung der gemalten Halbbreite je Zelle Bogenlänge (Zellen je
    /// Zelle). Der Krümmungs-Deckel (`ribbonCurvatureWidthFactor`) greift je
    /// Stützpunkt; auf der Mündungs-Kette (D8, ganze Zellen, dazwischen ein
    /// Mittelpunkt) wechselten gedeckelte Knickpunkte und ungedeckelte
    /// Mittelpunkte ab, die Breite sprang zwischen 6,4 und 1,3 Zellen: das Band
    /// zerfiel in versetzte Rechteck-Blöcke. Die Grenze senkt nur ab (wie
    /// `ribbonMaxAlphaStep`), der Krümmungs-Deckel bleibt also eingehalten.
    /// GEMESSEN (Seed 42, Jahr 20.000, Segmente mit Breitensprung > 0,75
    /// Zellen von 1928): ohne Grenze 68, 1,0 → 10, 0,5 → 7. 0,5 verengte die
    /// Bänder um einen Knick aber über bis zu 4 Zellen je Seite (Band-Zellen
    /// mit Deckung ≥ 0,7, Seed 1337: 12.318 gegen 12.664 bei 1,0).
    public static let ribbonMaxHalfWidthSlope = 1.0
    /// Deckkraft, unter der ein Stützpunkt als unsichtbar gilt: Bänder ohne
    /// einen einzigen Punkt darüber werden gar nicht erst emittiert.
    public static let ribbonMinimumAlpha = 0.02
    /// Größter Deckkraft-Sprung zwischen zwei benachbarten Stützpunkten eines
    /// Bands. Der Glattheits-Vertrag (`river_ribbons.gd`,
    /// `WaterRendererTests`) erlaubt 0.40 je Segment; der Deckel steht mit
    /// Abstand darunter, damit Float-Rundung ihn nicht reißt. Er SENKT nur
    /// (s. `RiverRibbonRenderer.limitAlphaSteps`): eine quer liegende
    /// Ein-Zellen-Pfütze ließ die See-Übergabe sonst in EINEM halben
    /// Zellschritt von 0.69 auf 0.25 fallen (Seed 1337, Jahr 4000, macOS).
    public static let ribbonMaxAlphaStep = 0.35
    /// Radius (Stützpunkte à ~0,5 Zellen) der Längs-Glättung der See-/Meer-
    /// Übergabe (`RiverRibbonRenderer.erodeAndSmooth`): Minimum, dann Mittel
    /// über ±1 Zelle. Eine Zentrumslinie, die an einer Uferlinie entlangläuft,
    /// wechselte vorher je Stützpunkt zwischen nass und trocken, und die
    /// Deckkraft sprang mit — Querstreifen im Band (Befund #174, Seed 1337).
    public static let ribbonHandoverSmoothSamples = 2
    /// Normierung des Strahler-Rangs für den Farbkanal (`COLOR.b` des
    /// Vertex-Vertrags, gelesen von `water.gdshader` als `v_rank`): Rang/6, auf
    /// 1 geklemmt. Ändert sich der Divisor, verschiebt sich die Tiefenfarbe
    /// ALLER Bänder — und `ribbonMinimumRank` mit.
    public static let ribbonRankDivisor = 6.0
    /// Kartografische Hierarchie: nur Zentrumslinien, die wenigstens Strahler 3
    /// erreichen, bekommen ein Band (der Rang kommt als Rang/6 im Farbkanal, 3/6
    /// = 0.5 > 0.48). Von Strahler 4 gesenkt (Aug 2026): seit der Korridor nur
    /// noch unter ECHTEN Bändern stempelt, fielen die Ordnung-3-Hauptläufe ins
    /// Zell-Raster und zeichneten sich als Treppen-Zickzack (ein 1-Zellen-
    /// Raster kann Diagonalen nicht glätten; gemessen Jahr 0/Seed 1337: 289
    /// der 1036 sichtbaren Kanäle erreichen genau Ordnung 3). Das damalige
    /// Gegenargument — „Ordnung 3 ließ im fokussierten 20k-A/B hunderte
    /// überlagerte Mäander auf der Ebene sichtbar werden" — stammt von VOR dem
    /// kanalweisen Kohärenz-Gate (`ribbonSupport*`): verknäulte Altpfade
    /// blenden heute als Einheit aus. Das 20k-A/B wurde mit Ordnung 3 neu
    /// gefahren (Aug 2026, Seed 1337, RS_STEP=20000, Ebenen-Ausschnitt
    /// RS_TARGET="-40,-20") und blieb ruhig — Bänder bei Jahr 0: 229 → 434.
    public static let ribbonMinimumRank = 0.48

    /// Wasser fließt nicht bergauf (Issue #174, Befund im Zeitraffer um Jahr
    /// 230.000: „als würden die Flüsse hochfließen, während sie einen Bogen
    /// bilden"). Ein Land-Band liegt auf dem Gelände unter seiner
    /// Zentrumslinie, und nichts hält dieses Gelände stromab fallend: die
    /// Lagrange-Linie ist nicht an die D8-Entwässerung gebunden. Seit dem
    /// Mäandergürtel (#174 B) trägt sie zudem den Abfluss als laufendes
    /// Maximum, eine abgekoppelte Linie bleibt damit breit und sichtbar.
    /// Liegt das Gelände unter dem Band um mehr als `ribbonUphillFadeStart`
    /// (Sim-Höhe) über dem tiefsten Punkt stromauf, blendet das Band aus, voll
    /// ab `ribbonUphillFadeEnd`; dort malt das Raster das echte D8-Wasser
    /// (`bandCoverage`). Die Höhen bleiben unangetastet (Vertrag
    /// `river_ribbons.gd`: jede Kante auf ihrem Gelände).
    /// 0,004 ≈ 10 m bei 1 Sim-Höhe ≈ 2,4 km, rund zwei Bankfull-Tiefen des
    /// Hauptlaufs (`SimConfig.meanderBeltDepthPerWidth`): Kolke und Schwellen
    /// des Gürtel-Stempels bleiben sichtbar, der Bogen, der eine Talwand oder
    /// einen Hügel hinaufläuft, nicht.
    /// GEMESSEN: `docs/zielbild-measurements.md` § Flüsse laufen bergauf.
    public static let ribbonUphillFadeStart = 0.004
    /// s. `ribbonUphillFadeStart` (≈ 19 m).
    public static let ribbonUphillFadeEnd = 0.008

    /// Deckkraft-Faktor eines Band-Stützpunkts, dessen Gelände `rise`
    /// (Sim-Höhe) über dem tiefsten Punkt stromauf liegt: 1 bis
    /// `ribbonUphillFadeStart`, 0 ab `ribbonUphillFadeEnd`.
    @inline(__always)
    public static func ribbonUphillFade(rise: Double) -> Double {
        1 - smoothstep(ribbonUphillFadeStart, ribbonUphillFadeEnd, rise)
    }

    /// Kaskaden-Übergabe Band → Raster (Aug 2026): ein Band ist ein ruhender
    /// Wasserspiegel — an Kaskaden gibt es keinen. Ab dieser LÄNGS-Neigung
    /// (Sim-Höhe je Welt-Einheit; × heightScale 24 ≈ 26° sichtbare Neigung)
    /// blendet das Band aus, und der Raster-Deckel unter dem Band entfällt,
    /// damit das D8-Feld die Strecke malt. Grund: ein 3D-Band verliert an
    /// Steilstrecken gegen das Render-Mesh (taucht ein, ragt an Dreieckskämmen
    /// als blaue Zacken heraus — auf JEDER Gitterauflösung, gemessen im
    /// Steillauf-A/B Seed 1337, RS_TARGET="-23,41"), während die aufgemalte
    /// Textur der sichtbaren Oberfläche per Definition folgt.
    public static let cascadeSlopeLo = 0.02
    /// s. `cascadeSlopeLo` — volle Raster-Übergabe ab Lo + Span (≈ 50°
    /// sichtbar). Als Spanne notiert wie `trackMaskSpan`.
    public static let cascadeSlopeSpan = 0.03

    /// Gewicht der Kaskaden-Übergabe: 0 = ruhiger Spiegel (Band malt),
    /// 1 = Kaskade (Raster malt). BEIDE Seiten müssen dieselbe Entscheidung
    /// lesen, sonst entsteht im Übergang doppeltes Wasser oder ein Loch: das
    /// Band blendet über diese Funktion aus, und der Raster-Deckel liest seit
    /// #174 C2 genau diese Blende über die Band-Deckung (`bandCoverage`)
    /// statt einer eigenen Zell-Neigung.
    @inline(__always)
    public static func cascadeWeight(slope: Double) -> Double {
        min(1, max(0, (abs(slope) - cascadeSlopeLo) / cascadeSlopeSpan))
    }

    /// Kohärenz-Fenster eines ganzen Bands: gemittelte Track-Maske über den
    /// Kanal (`corridorMask`, abfluss-gewichtet). Darunter ist die Zentrumslinie
    /// verwaist/verknäult und das Band blendet als EINHEIT aus — lokale
    /// Raster-Spitzen als Alpha zu übernehmen erzeugte isolierte Dreiecksfächer.
    public static let ribbonSupportLo = 0.35
    /// s. `ribbonSupportLo` (Spanne, s. Begründung bei `trackMaskSpan`).
    public static let ribbonSupportSpan = 0.3

    /// Abfluss-Vertrauen (Issue #174, Paket C Teil 2): ab diesem Abfluss (in
    /// Vielfachen des Referenz-Abflusses `SimConfig.renderMinCells`) braucht
    /// ein Band die Stream-Map-Stütze nicht mehr, ab `ribbonTrustHiReferences`
    /// gar nicht. Die Stütze filtert verwaiste Zentrumslinien; ein Lauf mit
    /// so viel Abfluss ist nicht verwaist — seit dem Gürtel (Paket B) liest
    /// die Sim den Abfluss je Knoten frisch aus dem Einzugsgebiet unter ihm
    /// (`Terrain.refreshBeltDischarge`), eine verlassene Linie fällt also auf
    /// wenige Zellen. GEMESSEN (Jahr 20.000, Hauptlauf per D8):
    /// die Stream-Map trackt die großen Läufe der neuen Großform kaum (Stütze
    /// 0,09–0,35 bei bis zu 26.000 Zellen Abfluss), auf Seed 20 fiel der ganze
    /// Hauptlauf weg (0 % Band, 85 % Lücke), auf Seed 42 die Hälfte.
    /// Gilt auch für das Raster (`WaterFieldRenderer`, Track-Maske), sonst
    /// blieb die Lücke dort, wo der Hauptlauf keine Zentrumslinie hat — dort
    /// aber nur in den Lücken des Bands (`ribbonTrustBandClearanceCells`).
    /// GEMESSEN (Seeds 1337/42/20, Lücke im Hauptlauf in %, in Klammern
    /// Band-Zellen ohne großen D8-Lauf in 3 Zellen, Gegenprobe Doppelwasser):
    /// ohne Vertrauen 5,6/50,3/85,2 (10,6/10,8/11,5); 6×…16× 3,0/27,4/16,6;
    /// 3×…10× 3,0/19,6/6,9 (10,2/14,2/13,5); 2×…8× 3,0/18,7/3,9. 3×…10×
    /// nimmt den Großteil der Lücken und malt weniger zusätzliche Läufe als
    /// 2×…8× (Band-Zellen Seed 1337: 14.166 ohne, 18.123 mit 3×, ~19.900 mit
    /// 2× — „zu viele Flüsse" war eine frühere Klage). Den Strahler-Rang
    /// braucht auch ein vertrauter Lauf: eine Ausnahme davon änderte keine
    /// Lücke (gemessen) und hätte den Wächter in `river_ribbons.gd`
    /// aufgeweicht. Messreihe: `docs/river-belt-render-measurements.md`.
    public static let ribbonTrustLoReferences = 3.0
    /// s. `ribbonTrustLoReferences`.
    public static let ribbonTrustHiReferences = 10.0

    /// 0 … 1: wie weit ein Band-Stützpunkt mit diesem Abfluss ohne
    /// Stream-Map-Stütze sichtbar bleibt.
    @inline(__always)
    public static func ribbonTrust(dischargeCells: Double, referenceCells: Double) -> Double {
        guard referenceCells > 0, dischargeCells.isFinite else { return 0 }
        return smoothstep(ribbonTrustLoReferences * referenceCells,
                          ribbonTrustHiReferences * referenceCells, dischargeCells)
    }

    /// Das Abfluss-Vertrauen im RASTER gilt nur in den Lücken des Bands: es
    /// wird mit (1 − größte Band-Deckung im Quadrat ±diesem Abstand, in
    /// Zellen) gewichtet. Ohne die Schranke malte das Raster jeden großen
    /// D8-Lauf voll, auch dort, wo ein Band ihn schon trägt: D8-Pfad und
    /// Zentrumslinie liegen bis zu einigen Zellen auseinander, und neben bzw.
    /// unter dem glatten Band stand die D8-Treppe als zweites Wasser (Review
    /// #181, Draufsicht Seed 42, Jahr 20.000). Anteilig statt binär: wo das
    /// Band an Kaskaden oder Enden ausblendet, kehrt das Vertrauen zurück.
    /// GEMESSEN (Seeds 1337/42/20, Jahr 20.000, zusammen mit dem Raster-Deckel
    /// ohne eigene Kaskaden-Ausnahme in `WaterFieldRenderer`; Lücke im
    /// Hauptlauf in %, Raster-Fluss unter Band-Deckung ≥ 0,7 in %, Raster-Fluss
    /// ohne Band in ±3 Zellen eines Bands in Zellen):
    ///   vorher       3,0/19,6/6,9 | 37,9/32,0/26,9 | 1295/677/651
    ///   0 Zellen     3,0/19,6/6,9 | 11,8/9,3/10,4  | 901/508/439
    ///   1 Zelle      3,0/19,6/6,9 | 11,6/8,8/10,0  | 863/480/427
    ///   2 Zellen     3,0/19,8/6,9 | 11,5/8,2/9,6   | 827/408/398
    ///   4 Zellen     3,3/25,7/8,7 | 11,2/7,6/9,2   | 706/261/326
    /// 1 Zelle ist der größte Abstand ohne neue Lücke: ab 2 Zellen nimmt die
    /// Schranke dem Raster auch Strecken hinter einem Bandende, die das Band
    /// nicht mehr malt. Den Großteil des Doppelwassers nimmt der Deckel.
    /// Messreihe: `docs/river-belt-render-measurements.md` §C.
    public static let ribbonTrustBandClearanceCells = 1

    // MARK: Altarm-Filter (gemeinsam für Geometrie und Raster-Stempel)

    // Beide Pfade müssen DIESELBEN Schleifen meinen: im Geometrie-Modus nimmt
    // das Wasserfeld genau die Zellen aus dem See-Kanal, die die Geometrie malt
    // — driften die Filter, entsteht doppeltes Wasser oder ein Loch.

    /// Nur substanzielle Schleifen sind Altarme; die Migration schnürt auch
    /// kleine Schlingen ab, die als Blobs die Ebenen sprenkeln.
    ///
    /// 10 → 20 (Aug 2026, User: „Altarm-Teppich"): bei `meanderNodeSpacing`
    /// 1.5 Zellen ist eine 10-Knoten-Schleife ~15 Zellen Bogen ≈ 2.3
    /// Welt-Einheiten — kaum länger als das Band breit ist, also ein Kringel,
    /// keine Schleife. GEMESSEN (Seed 1337, Jahr 20 000, n = 832): von 5946
    /// Altarmen erreichen 1322 zehn Knoten, aber nur **204** zwanzig, 40
    /// dreißig, 2 fünfzig. Die 1118 dazwischen waren der Teppich.
    public static let oxbowMinimumNodes = 20
    /// Die Cutoff-Enden (Hals) liegen eng beieinander — ungetrimmt schlösse sich
    /// der Altarm zu einem unnatürlichen Wasserring.
    public static let oxbowMaximumTrimmedNodes = 3
    /// Knoten, über die die Deckkraft an den Bogen-Enden einblendet.
    public static let oxbowEndFadeSteps = 3.0
    /// Deckkraft eines frischen Altarms (blendet über `oxbowVisibleYears` aus).
    public static let oxbowMaximumOpacity = 0.7

    /// Sicht-Horizont eines Altarms als offene Wasserfläche (Jahre).
    ///
    /// Getrennt von `SimConfig.oxbowMaxAge` (25 000 = wann er aus der
    /// Mäander-LISTE fällt) und bewusst viel kürzer: die Liste ist Sim-Zustand
    /// für die Bett-Verlandung (`oxbowFillYears` = 5500), die Sichtbarkeit ist
    /// Optik. Ein Altarm ist nur solange offenes Wasser, wie sein Bett noch
    /// nicht zugesedimentet ist — mit dem Listen-Alter als Blende blieben
    /// Altarme 25 000 Jahre als glänzende Flächen stehen und akkumulierten zum
    /// Teppich. GEMESSEN (Seed 1337, Jahr 20 000): von 1322 gemalten Altarmen
    /// sind 466 jünger als 6000 Jahre, 249 jünger als 3000, 102 jünger als
    /// 1000. Zusammen mit `oxbowMinimumNodes` = 20 bleiben ~70 statt 1322.
    ///
    /// An `oxbowFillYears` orientiert (Bett verlandet exponentiell mit τ = 5500
    /// → nach 6000 Jahren ist das Defizit auf ~1/e abgebaut): die Fläche
    /// verschwindet, wenn die Senke weg ist, nicht vorher.
    public static let oxbowVisibleYears = 6000.0

    /// Deckel der Band-Halbbreite am lokalen KRÜMMUNGSRADIUS der Zentrumslinie
    /// (Anteil des Radius, in denselben Einheiten — Zellen).
    ///
    /// Ein Band ist eine extrudierte Polylinie: wird es breiter als der Radius
    /// der Kurve, auf der es liegt, überschlagen sich seine Quads an der
    /// Kurveninnenseite. Sichtbar wurde das als FÄCHER spitzer Dreiecke in der
    /// Tiefebene, wo die Läufe am engsten mäandern (User: „das Wasser der
    /// Flüsse besteht teilweise aus hässlichen Dreiecken"; A/B-belegt gegen
    /// `RS_DIAG_RIBBON=norivers`, Seed 1337 / Jahr 20 000). Die Zentrumslinie
    /// ist Catmull-Rom-geglättet, ihre Stützpunkte stehen aber nur
    /// `meanderNodeSpacing` = 1.5 Zellen auseinander, während die Halbbreite
    /// bis `ribbonHalfWidthCapCells` = 3.2 Zellen geht — die Faltung ist damit
    /// die Regel, nicht der Ausnahmefall.
    ///
    /// 0.5 = das Band darf höchstens so breit wie sein Krümmungsradius werden
    /// (Halbbreite ≤ r/2). Das ist zugleich die konservative Seite der
    /// Naturbeobachtung: bei Leopold/Wolman liegt der Krümmungsradius eines
    /// Mäanders bei 2–3 Gerinne-BREITEN, hier fordern wir nur ≥ 1.
    public static let ribbonCurvatureWidthFactor = 0.5

    /// Suchweite der Mündungs-Verlängerung (Zellen). Reicht das Wasser nicht so
    /// weit, endet der Lauf im Land (Versickerung/Trockental) und bekommt seinen
    /// weichen Enden-Taper statt einer Mündung.
    public static let mouthSearchCells = 8

    // MARK: Raster-Feld: Track-Maske, Abstufung, Verbreiterung

    // Der dendritische Teil des Wassers (alles unterhalb der Mäander-Entitäten)
    // entsteht als Raster: Stream-Map × MFD-Abfluss → Intensität → Verbreiterung.
    // Die Zahlen standen bis #51 als Literale in `SimNode.waterFieldBytes` und
    // waren damit nur mit einem ~20-Minuten-Build prüfbar; hier sind sie
    // headless gepinnt (`SimCoreTests/WaterRenderTests.swift`).

    /// Ponding-Toleranz des Abfluss-Stempels: über echten Wasserflächen malt der
    /// See-Kanal, das Fluss-Feld hält sich an nahezu ungeflutete Zellen.
    public static let streamPondTolerance = 0.01

    /// Track-Maske (Stream-Map = zeitgemittelte Tropfenpfade): unter `trackMaskLo`
    /// bleibt eine Zelle trocken, ab `trackMaskLo + trackMaskSpan` zählt sie voll.
    /// Von 0.12..0.35 angehoben: Zufallspfad-Speckle bleibt drunter, konsistente
    /// Läufe drüber.
    public static let trackMaskLo = 0.18
    /// Spanne der Track-Maske (Obergrenze = `trackMaskLo + trackMaskSpan` = 0.42).
    /// Als SPANNE notiert, nicht als Obergrenze: `0.42 − 0.18` ist in Double
    /// nicht exakt `0.24`, ein aus lo/hi berechneter Divisor würde das Feld also
    /// gegenüber dem Stand vor #51 verschieben (wie `lakeDepthSpan`).
    public static let trackMaskSpan = 0.24
    /// Grundanteil, den eine Zelle trägt, sobald sie die Track-Maske überhaupt
    /// passiert — der Rest skaliert linear mit der Maske.
    public static let trackWeightFloor = 0.35
    /// s. `trackWeightFloor`.
    public static let trackWeightSpan = 0.65

    /// Abstufung der Fluss-Intensität mit dem Abfluss (Breiten-/Farbhierarchie):
    /// `min(1, base + log(q/creek + 1) / divisor)`.
    public static let streamIntensityBase = 0.4
    /// s. `streamIntensityBase`.
    public static let streamIntensityLogDivisor = 4.0

    /// Track-Maske einer Zelle aus ihrem Stream-Map-Wert.
    @inline(__always)
    public static func trackMask(streamMap: Double) -> Double {
        min(1, max(0, (streamMap - trackMaskLo) / trackMaskSpan))
    }

    /// Gewicht der Track-Maske auf die Intensität (nie ganz 0: eine Zelle, die
    /// die Maske passiert, ist ein echter Lauf). NaN oder negative Maskenwerte
    /// fallen defensiv auf den Bodenwert, +∞ wird auf 1.0 geklemmt.
    @inline(__always)
    public static func trackWeight(mask: Double) -> Double {
        trackWeightFloor + trackWeightSpan * min(1, max(0, mask))
    }

    /// Intensität des Fluss-Kanals aus dem Abfluss (Zellen Einzugsgebiet),
    /// bezogen auf die Render-Schwelle `creekCells` (= `SimConfig.renderMinCells`).
    ///
    /// Der Abfluss wird wie bei den Geschwister-Funktionen selbst geklemmt: ohne
    /// `max(…, 0)` liefert `log` unter `−creekCells` NaN, und ein solcher Wert
    /// wanderte als Byte ins Wasserfeld. Der heutige Aufrufer filtert vorher
    /// (`cu < creek → continue`) — die Klemme hält den Vertrag aber auch für den
    /// nächsten.
    @inline(__always)
    public static func streamIntensity(dischargeCells: Double, creekCells: Double) -> Double {
        guard creekCells > 0 else { return streamIntensityBase }
        return min(1, streamIntensityBase
                      + log(max(0, dischargeCells) / creekCells + 1) / streamIntensityLogDivisor)
    }

    /// Kontinuität: die Intensität wird dem D8-Empfänger entlang bergab
    /// propagiert und verliert je Zelle diesen Betrag — ohne den Pass zerfielen
    /// gealterte Läufe zu Punktketten, wo die Track-Maske Lücken lässt.
    public static let continuityDecayPerCell = 0.015
    /// Boden-Intensität der Kette: der Abfall wird hierauf GEKLEMMT und die
    /// Kette läuft bis zum offenen Wasser durch — vorher ENDETE sie an dieser
    /// Grenze, womit eine Quelle knapp über dem Boden nur ≈ 7 Zellen weit trug
    /// und sichtbare Läufe abrissen („kein zusammenhängender Lauf"). Muss über
    /// `riverMaskLo` bleiben, sonst wird die garantierte Kette unsichtbar.
    /// Quellen UNTER dem Boden propagieren nicht (kein Speckle-Verstärker).
    public static let continuityFloor = 0.3

    // Abfluss-Modulation der kosmetischen Shader-Rinnen (Detail-Layer im
    // terrain.gdshader): der Layer allein degeneriert auf der gealterten Welt
    // zu einem uniformen Tapeten-Muster, weil er nirgends an echte Struktur
    // gebunden ist (Nutzer-Abnahme 2026-09-02, PR #106). Das R8-Feld
    // `WaterFieldRenderer.flowDetailField` trägt deshalb die log-normierte
    // MFD-Abflussdichte UNTERHALB der Sichtbarkeits-Schwelle des Wassers, und
    // der Shader konzentriert seine Rinnen dort, wo Wasser wirklich abfließt.

    /// Untergrenze (Zellen Einzugsgebiet): darunter bleibt das Feld 0 —
    /// Einzelzellen-Abfluss ist Rauschen, keine Rinne.
    public static let flowDetailFloorCells = 3.0
    /// Stärke-Fenster der Shader-Modulation: `mix(lo, hi, flow)` auf
    /// `detail_strength`. Abseits der Abflussbahnen sinkt das Detail unter den
    /// bisherigen Uniform-Look, in den Bahnen bündelt es sich. Die Literale im
    /// Shader pinnt `RenderContractTests`.
    public static let flowDetailGainLo = 0.3
    /// s. `flowDetailGainLo`.
    public static let flowDetailGainHi = 1.8

    /// Intensität des Abfluss-Felds fürs Shader-Detail: 0 unter
    /// `flowDetailFloorCells`, log-normiert bis 1 an der Render-Schwelle
    /// `creekCells` (= `SimConfig.renderMinCells`) — ab dort malt das sichtbare
    /// Wasser selbst, das Detail muss nicht weiter wachsen.
    @inline(__always)
    public static func flowDetailIntensity(dischargeCells: Double, creekCells: Double) -> Double {
        guard dischargeCells > flowDetailFloorCells else { return 0 }
        // Konstante zuerst: fängt NaN/nicht-endliche Werte in creekCells ab
        // (in Swift liefert max(c, .nan) die Konstante c, während max(.nan, c) NaN propagieren würde).
        let ceiling = max(flowDetailFloorCells * 2, creekCells)
        return min(1, max(0, log(dischargeCells / flowDetailFloorCells)
                             / log(ceiling / flowDetailFloorCells)))
    }

    /// Verbreiterung: je Schwelle EIN Dilatations-Pass, der nur Läufe ÜBER der
    /// Schwelle weiter verbreitert → Breiten-Hierarchie (Bäche bleiben fadendünn).
    public static let widenThresholds = [0.55, 0.8]
    /// Intensitäts-Verlust je Dilatations-Schritt (die Breite bleibt sichtbar
    /// gestuft statt als Fläche zu verlaufen).
    public static let widenFalloff = 0.09
    /// WASSERSPIEGEL-Toleranz der Dilatation: Wasser verbreitert sich nur auf
    /// Zellen, die nicht nennenswert über dem Spiegel des Nachbarlaufs liegen —
    /// Mittelbänke (Braiding!) und Ufer-/Talkanten bleiben trocken.
    public static let widenBarTolerance = 0.004

    /// Track-Maske des gestempelten Mäander-Korridors: wo dem gestempelten Bett
    /// real kein Wasser folgt (verwaiste/verknäulte Linien), verblasst der
    /// Stempel, statt voll zu leuchten. Eigenes, tieferes Fenster als
    /// `trackMask` — der Korridor IST per Definition ein echter Lauf.
    public static let corridorTrackLo = 0.1
    /// s. `corridorTrackLo` (Spanne, s. Begründung bei `trackMaskSpan`).
    public static let corridorTrackSpan = 0.2
    /// s. `trackWeightFloor` — für den Korridor.
    public static let corridorWeightFloor = 0.3
    /// s. `corridorWeightFloor`.
    public static let corridorWeightSpan = 0.7

    /// Track-Maske des Korridor-Stempels.
    @inline(__always)
    public static func corridorMask(streamMap: Double) -> Double {
        min(1, max(0, (streamMap - corridorTrackLo) / corridorTrackSpan))
    }

    /// Gewicht der Korridor-Maske auf die Stempel-Intensität. NaN oder negative
    /// Maskenwerte fallen defensiv auf den Bodenwert, +∞ wird auf 1.0 geklemmt.
    @inline(__always)
    public static func corridorWeight(mask: Double) -> Double {
        corridorWeightFloor + corridorWeightSpan * min(1, max(0, mask))
    }

    // MARK: Legacy-Stempelpfad (`RS_WATER_STAMP`, A/B-Vergleich)

    // Ohne Band-Geometrie malt das Wasserfeld die Mäander selbst. Der Pfad ist
    // seit #34 nicht mehr Standard, aber der einzige A/B-Vergleich gegen die
    // Geometrie — seine Kalibrierung gehört deshalb genauso in den Vertrag.

    /// Halbbreite (Zellen) des Mäander-Stempels: `base + log(q/creek + 1)/divisor`,
    /// gedeckelt auf `stampHalfWidthCapCells`. Der Deckel war 3 — über 10k+ Jahre
    /// verknäulen die migrierten Linien auf den Ebenen, breite Stempel machten
    /// aus den Knäueln blaue Blob-Felder („zu viele Flüsse").
    public static let stampHalfWidthBase = 0.3
    /// s. `stampHalfWidthBase`.
    public static let stampHalfWidthLogDivisor = 2.6
    /// s. `stampHalfWidthBase`.
    public static let stampHalfWidthCapCells = 1.0
    /// Intensität des Mäander-Stempels (Abstufung wie beim Abfluss-Feld, nur
    /// höherer Sockel: eine Zentrumslinie IST ein Fluss).
    public static let stampIntensityBase = 0.6
    /// s. `stampIntensityBase`.
    public static let stampIntensityLogDivisor = 4.0

    /// Halbbreite (Zellen) des Mäander-Stempels aus dem Abfluss. Der Abfluss ist
    /// hier auf ≥ 1 Zelle geklemmt: der Stempel folgt einer Zentrumslinie, und
    /// die trägt auch am Oberlauf-Ende noch Wasser. Nicht-endliche (NaN) Abflüsse
    /// oder ungültige Schwellen (creekCells ≤ 0 oder NaN) fallen defensiv auf die
    /// Basis-Halbbreite; unendlicher Abfluss sättigt auf den Deckel (`stampHalfWidthCapCells`).
    @inline(__always)
    public static func stampHalfWidthCells(dischargeCells: Double, creekCells: Double) -> Double {
        guard creekCells > 0, !dischargeCells.isNaN else { return stampHalfWidthBase }
        return min(stampHalfWidthCapCells,
                   max(0.0,
                       stampHalfWidthBase
                       + log(max(1.0, dischargeCells) / creekCells + 1) / stampHalfWidthLogDivisor))
    }

    /// Intensität des Mäander-Stempels aus dem Abfluss (Klemmung s. o.). Nicht-endliche
    /// (NaN) Abflüsse oder ungültige Schwellen (creekCells ≤ 0 oder NaN) fallen defensiv
    /// auf die Basis-Intensität; unendlicher Abfluss sättigt auf 1.0.
    @inline(__always)
    public static func stampIntensity(dischargeCells: Double, creekCells: Double) -> Double {
        guard creekCells > 0, !dischargeCells.isNaN else { return stampIntensityBase }
        return min(1.0, max(0.0, stampIntensityBase
                                 + log(max(1.0, dischargeCells) / creekCells + 1) / stampIntensityLogDivisor))
    }

    // MARK: Gemeinsame Wasser-Optik aller drei Shader (Issue #51)

    // `terrain.gdshader` (Raster-Wasser), `water.gdshader` (Band-Geometrie) und
    // `ocean.gdshader` malen DASSELBE Wasser. Fresnel, Himmels-Spiegelung und
    // Glanz müssen zusammenfallen, sonst zerfallen Mündung und Küste sichtbar in
    // verschiedene Materialien. Die Werte reisen als `water_*`-Uniforms über die
    // Brücke (`SimRender.WaterUniforms`, #91/#92); `WaterRenderTests` pinnt als
    // Struktur, welche Shader welche Uniforms lesen. Seicht/Tief-Farbe und
    // Strömungs-Schimmer gelten seit #155 nur fürs Binnenwasser: das Meer färbt
    // nach der Schelf-Tiefe (s. „Offenes Meer" unten), die abgenommene
    // Flusstal-Studie hat den Farbsprung an der Mündung so bestätigt.

    /// Farbe seichten Wassers (das Bett scheint grünlich getrübt durch).
    public static let waterShallowColor = (r: 0.18, g: 0.37, b: 0.42)
    /// Farbe tiefen Wassers (opak dunkelblau).
    public static let waterDeepColor = (r: 0.03, g: 0.12, b: 0.26)
    /// Himmels-Ton der Fresnel-Spiegelung (wie die Environment-Farbe).
    public static let skyReflectColor = (r: 0.62, g: 0.7, b: 0.76)
    /// Schlick-Näherung: `pow(1 − n·v, fresnelExponent)`.
    public static let fresnelExponent = 5.0
    /// Anteil, mit dem der Himmels-Ton bei streifendem Blick einmischt.
    public static let fresnelSkyMix = 0.55
    /// Deckkraft seichten Wassers (das Bett scheint durch) …
    public static let waterOpacityShallow = 0.55
    /// … und tiefen Wassers.
    public static let waterOpacityDeep = 0.95
    /// Rauheit bei steilem Blick — matter, sonst spiegelt der graue Himmel die
    /// Farbe milchig weg …
    public static let waterRoughnessSteep = 0.34
    /// … und bei streifendem Blick (glasklar spiegelnd).
    public static let waterRoughnessGrazing = 0.08
    /// Specular bei steilem Blick …
    public static let waterSpecularSteep = 0.55
    /// … und bei streifendem Blick.
    public static let waterSpecularGrazing = 1.0
    /// Strömungs-Schimmer stromab (Bewegung im Zeitraffer ablesbar).
    public static let flowShimmerColor = (r: 0.012, g: 0.018, b: 0.025)
    /// Trübungsfahne eines Delta-Arms: heller und wärmer als das Becken, sonst
    /// läse sich der Fächer als zweite Wasserfläche (`water.gdshader`).
    public static let deltaPlumeColor = (r: 0.34, g: 0.38, b: 0.33)
    /// Stehendes, trübes Auwasser eines Altarms — grünlicher als der klare Lauf
    /// (`water.gdshader`).
    public static let oxbowWaterColor = (r: 0.16, g: 0.28, b: 0.24)

    // MARK: Offenes Meer (Issue #155)

    // Übernommen aus dem abgenommenen Hebel `frame` der Flusstal-Studie (#121).
    // Vorher bauten drei Sinuswellen und ein Sinus-Schimmer die Normalen; aus
    // der Übersicht wurde daraus ein regelmäßiges Streifenmuster bis zum
    // Horizont, und die Insel las sich als Modell auf einem Tisch. Jetzt:
    // Rausch-Wellen, die mit ihrer Pixelgröße ausblenden, und Farbe aus der
    // echten Wassertiefe über dem Sim-Schelf mit gebrochenem Brandungssaum.
    // Fresnel, Himmels-Spiegelung und Glanz bleiben die gemeinsame Optik oben.
    // Nur `ocean.gdshader` liest diese Werte.

    /// Wassertiefe (Sim-Höheneinheiten unter `seaLevel`), ab der das Meer voll
    /// tief gefärbt ist. 0.06 ≈ 1,4 Welteinheiten ≈ 140 m.
    public static let oceanDepthSpan = 0.06
    /// Farbe über dem flachen Schelf direkt an der Küste (türkis).
    public static let oceanShallowColor = (r: 0.09, g: 0.27, b: 0.27)
    /// Farbe am Knick zwischen Schelf und Hang …
    public static let oceanMidColor = (r: 0.030, g: 0.125, b: 0.165)
    /// … und im tiefen Wasser sowie außerhalb des Sim-Quadrats (dunkelblau).
    public static let oceanDeepColor = (r: 0.012, g: 0.050, b: 0.082)
    /// Lage des Knicks auf der normierten Tiefe 0…1.
    public static let oceanMidDepth = 0.25
    /// Breite des Brandungssaums auf der normierten Tiefe (nur der äußerste
    /// Küstenrand).
    public static let oceanSurfDepth = 0.045
    /// Farbe der Brandung …
    public static let oceanSurfColor = (r: 0.80, g: 0.85, b: 0.86)
    /// … und ihr höchster Anteil an der Wasserfarbe.
    public static let oceanSurfStrength = 0.55
    /// Rausch-Fenster, das den Saum bricht (nur Rauschwerte darüber schäumen).
    public static let oceanSurfNoiseLo = 0.35
    public static let oceanSurfNoiseHi = 0.75
    /// Rausch-Frequenz der Brechung (je Welteinheit) …
    public static let oceanSurfScale = 3.1
    /// … und ihre Drift (Rausch-Zellen je Sekunde).
    public static let oceanSurfDrift = 0.6
    /// Rausch-Wellen: Frequenz (je Welteinheit) und Normalen-Gradient der
    /// ersten Oktave …
    public static let oceanWaveFrequency = 0.55
    public static let oceanWaveAmplitude = 0.045
    /// … je Oktave feiner (Lacunarity) und schwächer (Gain).
    public static let oceanWaveLacunarity = 2.3
    public static let oceanWaveGain = 0.7
    /// Ausblenden einer Oktave über `Pixelgröße · Frequenz` (Rausch-Zellen je
    /// Pixel). Ohne dieses Fenster flimmern feine Oktaven in der Ferne und
    /// bilden Moiré.
    public static let oceanWaveFadeLo = 0.2
    public static let oceanWaveFadeHi = 0.8
    /// Drift der Wellen (Rausch-Zellen je Sekunde, Welt-x und Welt-z) …
    public static let oceanWaveDriftX = 0.21
    public static let oceanWaveDriftZ = 0.13
    /// … je Oktave um diesen Anteil schneller (feine Wellen laufen schneller).
    public static let oceanWaveOctaveSpeedup = 0.35

    // MARK: Nasse Wiese statt Tümpel-Teppich (Issue #174, Paket C)

    // Die Übersicht zeigte in den Tälern Matten kleiner blauer Flecken: Tümpel
    // des Raster-Felds, über Bäche und Pfützen zu Komponenten verbunden, die
    // der Komponenten-Fade oben (ab 50 Zellen voll) zeigt, einzeln aber zu
    // klein, um als See zu lesen. Unter
    // `wetMeadowMaxCells` malt das Raster sie nicht mehr als Wasserspiegel,
    // sondern meldet sie als nasse Wiese; `RenderState` tönt das Material
    // dort dunkelgrün und hält Wald und Verschiebung fern (Schutzmaske).
    // Ausgenommen sind Komponenten an einem Band- oder Altarm-Korridor: dort
    // malt die Geometrie, und die Übergabe Band ↔ Raster (`lakeRawWetDepth`,
    // Mündungs-Überlappung) darf keine Lücke bekommen.

    /// Tümpel (Zellen stehenden Wassers über `lakeRawWetDepth`,
    /// 4er-Nachbarschaft, OHNE ihre Zubringer) unter dieser Größe werden
    /// nasse Wiese. Messreihe: `docs/river-coast-render-measurements.md` §A.
    public static let wetMeadowMaxCells = 200

    /// Wird ein Tümpel als nasse Wiese gemalt? Nur ohne Band-Korridor
    /// (`banded`); den Fluss-Kanal seiner Zellen regelt weiter `streamGate`.
    @inline(__always)
    public static func isWetMeadow(pondCells: Int, banded: Bool) -> Bool {
        !banded && pondCells < wetMeadowMaxCells
    }

    /// Vegetationsgewicht (R-Kanal der Materialgewichte), auf das eine nasse
    /// Wiese mindestens gehoben wird: dunkles Grün der Vegetations-Farbe statt
    /// des hellen Wiesen-Tons aus #168.
    public static let wetMeadowVegetation = 0.85
    /// Makrofarbe der nassen Wiese (dunkler und satter als trockenes Grasland) …
    public static let wetMeadowColor = (r: 0.07, g: 0.16, b: 0.06)
    /// … und ihr Anteil an der Makrofarbe der Zelle.
    public static let wetMeadowColorMix = 0.7

    // MARK: Strand und Felsküste (Issue #174, Paket C)

    // Bisher trug jede Küste dieselbe Bodenfarbe bis an die Wasserlinie. Jetzt
    // wird eine Landzelle in Reichweite der Brandung (`coastReachCells`) Sand,
    // wenn sie flach ist und knapp über dem Meer liegt — genau dort arbeitet
    // `Terrain.wavePass` (|h − sea| ≤ `SimConfig.waveBand`) Material auf ein
    // Strandprofil. Steile Küste in derselben Reichweite wird Fels: die
    // Brandung räumt den Bewuchs ab, der Saum im Ozean-Shader (#155) bleibt.
    // Ableitung: `SimRender.CoastMaterial`, Gewichte im `TerrainColorRenderer`.
    // Messreihe: `docs/river-coast-render-measurements.md` §B.

    /// Reichweite der Brandung landeinwärts (Zellen, Chebyshev-Abstand zur
    /// nächsten Meereszelle). 3 Zellen ≈ 47 m.
    public static let coastReachCells = 3
    /// Höhe über dem Meeresspiegel (Sim-Einheiten), bis zu der eine flache
    /// Küstenzelle voll Sand ist …
    public static let beachHeightLo = 0.008
    /// … und ab der sie kein Sand mehr ist. Muss innerhalb des Wellenbands
    /// `SimConfig.waveBand` liegen (Wächter: `CoastMaterialTests`).
    public static let beachHeightHi = 0.018
    /// Makro-Steigung (`Terrain.macroSlope`), bis zu der eine Küstenzelle voll
    /// Sand ist … GEMESSEN (§B, drei Matrix-Seeds, Jahr 0 bis 100.000): die
    /// Brandung hält die Küste nahe am Wellen-Talus, Küstenzellen liegen bei
    /// p50 ≈ 0,0035…0,0045 und p90 ≈ 0,005…0,006. Steil ist an dieser Küste
    /// also schon, was über p90 liegt; ein Fenster an der allgemeinen
    /// Klippen-Schwelle (0,004…0,026 im `TerrainColorRenderer`) fände keine
    /// einzige Felsküste.
    public static let beachSlopeLo = 0.0042
    /// … und ab der sie kein Sand mehr ist.
    public static let beachSlopeHi = 0.0058
    /// Makro-Steigung, ab der eine Küstenzelle Felsküste wird …
    public static let cliffCoastSlopeLo = 0.006
    /// … und ab der sie voll Fels ist. Die Fenster von Strand und Fels
    /// überlappen nicht (Wächter): eine Zelle ist Strand ODER Fels.
    public static let cliffCoastSlopeHi = 0.011

    // MARK: Sedimentfahne im Meer (Issue #174, Paket C)

    // Jede Mündung ins Meer bekommt eine Trübungsfahne. SimRender
    // (`SedimentPlume`) schreibt EINE Zelle je Mündung in eine Float-Textur,
    // gewichtet nach Abfluss und Fracht; `ocean.gdshader` zeichnet sie über die
    // Mip-Stufen der Textur weich und zieht sie mit der Küstenströmung stromab.
    // Die Strömung ist die Drift der Ozean-Wellen (`oceanWaveDriftX/Z`), damit
    // Fahne und Wellen in dieselbe Richtung ziehen.
    //
    // Fracht: es gibt im Sim-Kern kein Frachtfeld. Stellvertreter ist das
    // Relief des Einzugsgebiets (höchster Punkt über dem Meer): nach Milliman &
    // Syvitski (1992) steigt die Schwebstofffracht eines Flusses mit Fläche
    // UND maximaler Höhe seines Einzugsgebiets — Gebirgsflüsse trüben das
    // Meer, Tieflandbäche kaum. Messreihe: §C.

    /// Mündungen unter diesem Einzugsgebiet (Zellen) bekommen keine Fahne.
    public static let plumeMinDischargeCells = 2000.0
    /// Einzugsgebiet (Zellen), ab dem das Abfluss-Gewicht voll ist (log-Rampe
    /// zwischen `plumeMinDischargeCells` und diesem Wert).
    public static let plumeFullDischargeCells = 40000.0
    /// Relief des Einzugsgebiets (Sim-Höhe über dem Meer), ab dem das
    /// Fracht-Gewicht voll ist …
    public static let plumeFullRelief = 0.5
    /// … und der Anteil, den auch ein flaches Einzugsgebiet behält.
    public static let plumeReliefFloor = 0.3
    /// So weit (Zellen) setzt SimRender die Quelle in Fließrichtung ins Meer
    /// hinaus: der Fleck soll vor der Mündung liegen, nicht halb an Land.
    public static let plumeOffshoreCells = 4

    /// Länge der Fahne entlang der Küstenströmung (Welteinheiten).
    public static let oceanPlumeLength = 5.0
    /// Mip-Stufe der Weichzeichnung an der Mündung (2^lod Zellen) …
    public static let oceanPlumeLod = 3.0
    /// … und um so viele Stufen breiter am Ende der Fahne.
    public static let oceanPlumeSpread = 2.0
    /// Verstärkung der normierten Fahnen-Dichte vor der Sättigung.
    public static let oceanPlumeGain = 2.5
    /// Höchster Anteil der Trübung an der Wasserfarbe.
    public static let oceanPlumeOpacity = 0.6
    /// Farbe der Trübung (Schwebstoff, lehmig-hell).
    public static let oceanPlumeColor = (r: 0.42, g: 0.38, b: 0.27)

    // MARK: Mäandergürtel im Render (Issue #174, Paket C Teil 2)

    // Paket B hat den Gürtel als Physik gebaut: Kanalbreite, asymmetrisches
    // Querprofil, Gleithang-Bänke mit Alter (`Terrain.barAge`), Altarme. Diese
    // Werte machen ihn sichtbar, ohne die Physik anzufassen. Zwei Leser:
    //  - `SimRender.BarMaterial` (CPU, je Terrain-Update): Sand auf frischen
    //    Bänken, Scroll-Bars über Isolinien des Bankalters, Verlandung der
    //    Altarme. Diese Schwellen erreichen keinen Shader.
    //  - `water.gdshader` und `terrain.gdshader`: Tiefenfarbe im Band nach dem
    //    Querprofil und das Bank-Material. Diese Werte reisen als
    //    `water_*`-Uniforms (`SimRender.WaterUniforms`).
    // Messreihe: `docs/river-belt-render-measurements.md`.

    /// Sand auf einer frischen Bank: voll bis `barSandYearsLo` Jahre nach der
    /// letzten Ablagerung, weg ab `barSandYearsHi`. Danach liest die Bank als
    /// Wiese (die Sim-Vegetation wächst auf ihr nach, `Terrain.veg`).
    /// GEMESSEN (`testBarAgeDiagnostic`, Jahr 20.000): Bänke tragen 8–9 % des
    /// Landes, aber nur 3–4 % davon sind jünger als 300 Jahre, 6–8 % jünger
    /// als 1000 und 10–18 % jünger als 3000. Mit 150/600 lag der Sand als
    /// 1-Zellen-Saum am Innenufer, fast ganz unter dem Band; mit 800/3000
    /// stehen an den Gleithängen Sichelbänke (Draufsicht Seed 20).
    public static let barSandYearsLo = 800.0
    /// s. `barSandYearsLo`.
    public static let barSandYearsHi = 3000.0

    /// Sprenkel-Filter: Sand bleibt nur, wo von den 8 Nachbarn mindestens
    /// `barSandNeighboursLo` selbst Sand tragen (voll ab `…Hi`). Feste Läufe
    /// stempeln je Schritt einzelne Zellen frisch; ohne Filter lagen sie als
    /// helle Pünktchen über der ganzen Aue (Draufsicht Seed 20, Jahr 20.000).
    public static let barSandNeighboursLo = 1.5
    /// s. `barSandNeighboursLo`.
    public static let barSandNeighboursHi = 3.5

    /// Sandgewicht einer Bank aus ihrem Alter (`Terrain.barAge`, −1 = keine).
    @inline(__always)
    public static func barSand(age: Double) -> Double {
        guard age >= 0 else { return 0 }
        return 1 - smoothstep(barSandYearsLo, barSandYearsHi, age)
    }

    /// Scroll-Bars: Periode der Rippen im BANKALTER (Jahre). Die Höhe kann sie
    /// auf diesem Gitter nicht tragen (eine Rippe ist schmaler als eine Zelle),
    /// das Alter schon: jede Isolinie ist eine frühere Lage des Gleithangs.
    /// Rücken (trocken, heller) und Senken (feucht, grüner) wechseln je Periode.
    public static let barScrollPeriodYears = 400.0
    /// Rippen-Abstand in Zellen, unter dem das Muster ausblendet (Aliasing:
    /// unter ~2 Zellen je Periode ist es Rauschen), und ab dem es voll steht.
    public static let barScrollMinSpacingLo = 2.0
    /// s. `barScrollMinSpacingLo`.
    public static let barScrollMinSpacingHi = 3.5
    /// Alter, ab dem die Rippen verflachen, und ab dem sie verschwunden sind
    /// (Auelehm überdeckt sie).
    public static let barScrollFadeYearsLo = 8000.0
    /// s. `barScrollFadeYearsLo`.
    public static let barScrollFadeYearsHi = 20000.0
    /// Hub der Rippen: im Sand (Senke = feuchter, dunkler Sand) und als
    /// Verschiebung des Vegetationsgewichts in der Wiese (Senke grüner).
    public static let barScrollSandDepth = 0.35
    /// s. `barScrollSandDepth`.
    public static let barScrollVegGain = 0.22

    /// Rippe −1 … +1 (−1 = Rücken, +1 = Senke, 0 = keine Rippe) aus Alter und
    /// örtlichem Altersgradienten (Jahre je Zelle), mit Aliasing- und
    /// Alters-Blende. Ohne Gradient (einzelne Bankzelle) gibt es keine
    /// Isolinie und damit keine Rippe.
    @inline(__always)
    public static func barScroll(age: Double, gradientYearsPerCell: Double) -> Double {
        guard age >= 0, barScrollPeriodYears > 0, gradientYearsPerCell > 1e-9,
              gradientYearsPerCell.isFinite else { return 0 }
        let spacing = barScrollPeriodYears / gradientYearsPerCell
        let amp = smoothstep(barScrollMinSpacingLo, barScrollMinSpacingHi, spacing)
            * (1 - smoothstep(barScrollFadeYearsLo, barScrollFadeYearsHi, age))
        return -amp * cos(2 * Double.pi * age / barScrollPeriodYears)
    }

    /// Schutzmaske (#154): ab diesem Sandgewicht trägt eine Bank weder Wald
    /// noch Render-Verschiebung.
    public static let barProtectSand = 0.25

    /// Altarm-Lebenszyklus (Vorlage D: offen → verlandend → Bogen in der
    /// Vegetation). Das Band blendet über `oxbowVisibleYears` aus wie bisher;
    /// auf dem Gelände liegt darunter von Anfang an Ried (feuchte Senke), das
    /// zwischen 1,5 und 2,5 × `oxbowVisibleYears` einem Vegetationsbogen weicht.
    /// Das Ried beginnt bewusst sofort und nicht erst mit dem Ausblenden des
    /// Bands: auf dem Gürtel (Paket B) sind junge Altarme selten wassergefüllt
    /// (gemessen 0–1 gleichzeitig, Seed 1337), und ein Altarm-Band entsteht nur
    /// über offenem Wasser. Ohne Ried wäre ein trockener junger Altarm
    /// unsichtbar; wo Wasser steht, deckt das Band das Ried ab.
    /// Alle Alter als Anteil von `oxbowVisibleYears`.
    public static let oxbowReedStart = 0.0
    /// s. `oxbowReedStart`.
    public static let oxbowReedFull = 0.15
    /// s. `oxbowReedStart`.
    public static let oxbowArcStart = 1.5
    /// s. `oxbowReedStart`.
    public static let oxbowArcFull = 2.5
    /// Der Bogen blendet vor dem Listen-Horizont der Sim aus
    /// (`SimConfig.oxbowMaxAge`), ab diesem Anteil davon.
    public static let oxbowArcFadeShare = 0.6
    /// Ried färbt die Makrofarbe olivbraun …
    public static let oxbowReedColor = (r: 0.27, g: 0.29, b: 0.14)
    /// … mit diesem Anteil, und hebt das Vegetationsgewicht leicht (Röhricht,
    /// kein Wald) …
    public static let oxbowReedTint = 0.6
    /// s. `oxbowReedTint`.
    public static let oxbowReedVeg = 0.12
    /// … der Vegetationsbogen hebt es deutlich (dichter Auwald im alten Bett).
    public static let oxbowArcVeg = 0.40

    /// Ried- und Bogengewicht eines Altarms aus seinem Alter (Jahre).
    @inline(__always)
    public static func oxbowStages(age: Double, maxAge: Double) -> (reed: Double, arc: Double) {
        let v = oxbowVisibleYears
        guard age >= 0, v > 0 else { return (0, 0) }
        let arcIn = smoothstep(oxbowArcStart * v, oxbowArcFull * v, age)
        let reed = smoothstep(oxbowReedStart * v, oxbowReedFull * v, age) * (1 - arcIn)
        let arcOut = maxAge > 0 ? 1 - smoothstep(oxbowArcFadeShare * maxAge, maxAge, age) : 1
        return (reed, arcIn * arcOut)
    }

    /// Bank-Material im Terrain-Shader: trockener und feuchter Sand (gemischt
    /// über Rauschen), Rauheit. Seit der Vereinigung von #174 C und C2 malt
    /// derselbe Sand-Block auch den Strand (`CoastMaterial`): der A-Kanal der
    /// Makrofarbe trägt `max(Strand, Bank)` und unterscheidet die Quellen
    /// nicht. Der Strand hatte vorher fest (0,56|0,51|0,41)…(0,68|0,62|0,50)
    /// und Rauheit 0,88 im Shader, also nur wenige Hundertstel daneben.
    public static let barSandColor = (r: 0.70, g: 0.65, b: 0.54)
    /// s. `barSandColor`.
    public static let barSandWetColor = (r: 0.52, g: 0.48, b: 0.40)
    /// s. `barSandColor`.
    public static let barRoughness = 0.86

    /// Tiefenfarbe im Band nach dem Querprofil (Vorlage E): `UV2.y` trägt die
    /// signierte Bogenstärke (`MeanderState.bendStrength`, −1 … +1). Am
    /// Prallhang (außen) wird die Tiefe um bis zu diesen Betrag tiefer, am
    /// Gleithang (innen) seichter; im Wendepunkt bleibt das Profil symmetrisch.
    public static let ribbonBendDepth = 0.55
    /// Seichtes Wasser über der Bank: Sand scheint durch.
    public static let ribbonShoalColor = (r: 0.46, g: 0.50, b: 0.42)
    /// Anteil der Sand-Tönung am Gleithang-Ufer bei voller Bogenstärke.
    public static let ribbonShoalMix = 0.45

    /// Tiefen-Verschiebung im Band: `across` = UV.x (0 … 1), `bend` = UV2.y.
    /// Positiv = tiefer. Spiegel der Formel in `water.gdshader`.
    @inline(__always)
    public static func ribbonBendShift(across: Double, bend: Double) -> Double {
        ribbonBendDepth * ribbonOutward(across: across, bend: bend)
    }

    /// −1 … +1: +1 = Prallhang-Ufer, −1 = Gleithang-Ufer. Die Bandkante bei
    /// UV.x = 1 liegt auf der LINKEN Normalen der Fließrichtung (wie
    /// `BeltGeometry.nx/nz`); bei positiver Krümmung (Linksbogen) ist die
    /// Außenseite rechts, also UV.x = 0 — dieselbe Konvention wie der
    /// Gürtel-Stempel (`Terrain.beltStamp`).
    @inline(__always)
    public static func ribbonOutward(across: Double, bend: Double) -> Double {
        -(2 * across - 1) * max(-1, min(1, bend))
    }
}
