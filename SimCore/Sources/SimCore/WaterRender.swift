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
        let w = ribbonHalfWidthAtReference
            * (max(dischargeCells, 0) / referenceCells).squareRoot()
        return min(max(w, ribbonHalfWidthFloorCells), ribbonHalfWidthCapCells)
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
    /// Deckkraft, unter der ein Stützpunkt als unsichtbar gilt: Bänder ohne
    /// einen einzigen Punkt darüber werden gar nicht erst emittiert.
    public static let ribbonMinimumAlpha = 0.02
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
    /// 1 = Kaskade (Raster malt). BEIDE Seiten müssen dieselbe Funktion lesen
    /// (Band-Alpha und Raster-Deckel), sonst entsteht im Übergang doppeltes
    /// Wasser oder ein Loch.
    @inline(__always)
    public static func cascadeWeight(slope: Double) -> Double {
        min(max((abs(slope) - cascadeSlopeLo) / cascadeSlopeSpan, 0), 1)
    }

    /// Kohärenz-Fenster eines ganzen Bands: gemittelte Track-Maske über den
    /// Kanal (`corridorMask`, abfluss-gewichtet). Darunter ist die Zentrumslinie
    /// verwaist/verknäult und das Band blendet als EINHEIT aus — lokale
    /// Raster-Spitzen als Alpha zu übernehmen erzeugte isolierte Dreiecksfächer.
    public static let ribbonSupportLo = 0.35
    /// s. `ribbonSupportLo` (Spanne, s. Begründung bei `trackMaskSpan`).
    public static let ribbonSupportSpan = 0.3

    // MARK: Altarm-Filter (gemeinsam für Geometrie und Raster-Stempel)

    // Beide Pfade müssen DIESELBEN Schleifen meinen: im Geometrie-Modus nimmt
    // das Wasserfeld genau die Zellen aus dem See-Kanal, die die Geometrie malt
    // — driften die Filter, entsteht doppeltes Wasser oder ein Loch.

    /// Nur substanzielle Schleifen (≈ 15 Zellen Bogen) sind Altarme; die
    /// Migration schnürt auch 2–4-Knoten-Schlingen ab, die als 3–6-Zell-Blobs
    /// die Ebenen sprenkelten.
    public static let oxbowMinimumNodes = 10
    /// Die Cutoff-Enden (Hals) liegen eng beieinander — ungetrimmt schlösse sich
    /// der Altarm zu einem unnatürlichen Wasserring.
    public static let oxbowMaximumTrimmedNodes = 3
    /// Knoten, über die die Deckkraft an den Bogen-Enden einblendet.
    public static let oxbowEndFadeSteps = 3.0
    /// Deckkraft eines frischen Altarms (blendet mit `SimConfig.oxbowMaxAge` aus).
    public static let oxbowMaximumOpacity = 0.7

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
        min(max((streamMap - trackMaskLo) / trackMaskSpan, 0), 1)
    }

    /// Gewicht der Track-Maske auf die Intensität (nie ganz 0: eine Zelle, die
    /// die Maske passiert, ist ein echter Lauf).
    @inline(__always)
    public static func trackWeight(mask: Double) -> Double {
        trackWeightFloor + trackWeightSpan * mask
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
        min(1, streamIntensityBase
               + log(max(dischargeCells, 0) / creekCells + 1) / streamIntensityLogDivisor)
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
        min(max((streamMap - corridorTrackLo) / corridorTrackSpan, 0), 1)
    }

    /// Gewicht der Korridor-Maske auf die Stempel-Intensität.
    @inline(__always)
    public static func corridorWeight(mask: Double) -> Double {
        corridorWeightFloor + corridorWeightSpan * mask
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
    /// die trägt auch am Oberlauf-Ende noch Wasser.
    @inline(__always)
    public static func stampHalfWidthCells(dischargeCells: Double, creekCells: Double) -> Double {
        max(0.0, min(stampHalfWidthCapCells,
                     stampHalfWidthBase
                     + log(max(dischargeCells, 1) / creekCells + 1) / stampHalfWidthLogDivisor))
    }

    /// Intensität des Mäander-Stempels aus dem Abfluss (Klemmung s. o.).
    @inline(__always)
    public static func stampIntensity(dischargeCells: Double, creekCells: Double) -> Double {
        min(1.0, stampIntensityBase
                 + log(max(dischargeCells, 1) / creekCells + 1) / stampIntensityLogDivisor)
    }

    // MARK: Gemeinsame Wasser-Optik beider Shader (Issue #51)

    // `terrain.gdshader` (Raster-Wasser) und `water.gdshader` (Band-Geometrie)
    // malen DASSELBE Wasser — Farben, Fresnel und Glanz müssen deshalb
    // zusammenfallen, sonst zerfällt eine Mündung sichtbar in zwei Wasser.
    // Beide Shader tragen die Werte als Literal; `WaterRenderTests` vergleicht
    // BEIDE Quelltexte gegen diese Zahlen. Wer eine ändert, ändert sie hier und
    // in beiden Shadern — der Test sagt, welche Stelle fehlt.

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
}
