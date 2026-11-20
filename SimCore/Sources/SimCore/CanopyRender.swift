/// Kalibrierung des Kronendachs (Issue #152).
///
/// Wie `ReliefRender` eine reine Render-Ableitung ohne Sim-Zustand: nichts
/// hier ändert Physik. Wald ist kein Instanz-Modell mehr, sondern eine Schicht
/// im Terrain-Shader im Weltmaßstab 1 Einheit ≈ 100 m: ein angehobenes Dach mit
/// Einzelkronen, dunklen Lücken und Lichtungen.
///
/// Zwei Hälften mit getrennten Lesern:
///  - WO Wald steht (Vegetation, Steigung, Schnee/Eis, Küste, Lichtungen,
///    Schutzmaske), rechnet `SimRender.ForestCanopyMask` auf der CPU, einmal je
///    Terrain-Update. Deterministisch und headless prüfbar; diese Schwellen
///    erreichen keinen Shader.
///  - WIE er aussieht (Kronengröße, Dachhöhe, Ausdünnen am Rand, Ausblenden in
///    der Entfernung), rechnet `game/shaders/terrain.gdshader` je Pixel. Diese
///    Zahlen reisen über `SimRender.CalibrationRegistry` (Gruppe `canopy`) → `SimNode` → `Main.gd`.
///
/// Herkunft: Flusstal-Studie #116, Hebel `canopy`, vom Projekteigner mit
/// PR #121 abgenommen (`docs/graphics-quality.md`). Die Studie rechnete die
/// Waldmaske im Shader; die Schwellen sind dieselben.
///
/// Wächter: `SimCoreTests/CanopyTests.swift`.
public enum CanopyRender {

    // MARK: Waldmaske (CPU, SimRender.ForestCanopyMask)

    /// Vegetationsgewicht (`TerrainColorRenderer`, R-Kanal von `surfaces`,
    /// höchstens 0,78), ab dem Wald einsetzt, und ab dem er geschlossen ist.
    ///
    /// Issue #168: Die Studien-Werte 0,14/0,32 lagen tief im unteren Teil des
    /// Wertebereichs; fast jede bewachsene Zelle wurde Wald (Matrix-Seeds, bis
    /// 43 % des Landes bei Jahr 100.000, Projekteigner: „zuviel Wald").
    /// 0,35/0,55 halbiert den Anteil auf 9–22 %, dazwischen bleibt Wiese
    /// (`meadow*`). Mitgemessen: 0,40/0,60 und 0,45/0,65 nehmen nur 1–6 Punkte
    /// mehr weg; der Ticket-Vorschlag reichte nach den Matrix-Bildern, Bestände
    /// stehen als Gruppen zwischen Wiesen. `clumpGain` 0,60 statt
    /// 0,45 änderte den Anteil um höchstens 0,6 Punkte und bleibt deshalb.
    /// Tabelle: `docs/graphics-quality.md` § Wald und Wiese (#168), Messlauf
    /// `testCanopyCoverageDiagnostic`.
    ///
    /// Issue #174 (Großform): Kamm, Hügelland und Ebene statt einer Gratfläche
    /// bieten mehr bewachsbaren Boden; mit 0,35/0,55 stieg der Wald auf bis zu
    /// 28,6 % des Landes (Seed 42, Jahr 2000; 1337: 15–17 %, 20: 15–25 %).
    /// 0,40/0,60 — die nächste schon in #168 gemessene Stufe — hält 11,8–23,3 %
    /// über alle Matrix-Seeds und Jahre (2000/20.000/100.000), also wieder
    /// „≤ ~22 %" (Abnahmepunkt 40 von #174); 0,45/0,65 hätte 10,4–19,6 %
    /// ergeben und die Hänge sichtbar ausgedünnt.
    ///
    /// Look-Iteration 6 (Hill-Climber Problem 2, Seed 1337, Jahr 20.000,
    /// Messlauf `testCanopyCoverageDiagnostic`-Bauart): Mit 0,40/0,60 stand
    /// Wald fast nur im Tiefland (Vegetation dort am Deckel 0,78, 18 % des
    /// Landes) als geschlossener Teppich; die Hänge tragen 0,1–0,3 und blieben
    /// Wiese, im Diorama war kaum Wald zu sehen. 0,15/0,45 mit `clumpGain`
    /// 0,55 und den großen Lichtungen (`clearing*`) gibt 23 % Wald (Maske
    /// ≥ 0,5) und 32 % mit ausfransendem Saum (≥ 0,2); Hänge tragen
    /// Bestände, das Tiefland hat Lichtungen. Gemessen: 0,22/0,50 18 %,
    /// 0,12/0,42 26 %.
    public static let vegetationLo = 0.15
    public static let vegetationHi = 0.45

    /// Lichtungen und Waldränder: Rauschen verschiebt die Vegetationsschwelle,
    /// der Wald bildet so Gruppen statt einer gleichmäßigen Fläche. Frequenz in
    /// 1/Welteinheit (0.45 ≈ 220 m Grundwellenlänge, 14 Sim-Zellen), Mittelwert
    /// des Rauschens (wird abgezogen) und Gewicht. Das Rauschen ist das
    /// Value-Noise-fBm der Studie (`ForestCanopyMask.clumpNoise`); mit
    /// Simplex-Rauschen gleicher Frequenz streute der Wald auf mageren Hängen
    /// sichtbar mehr kleine Flecken als im abgenommenen Bild.
    public static let clumpFrequency = 0.45
    public static let clumpMean = 0.47
    public static let clumpGain = 0.55

    /// Lichtungen in großer Skala (Look-Iteration 6, Hill-Climber Problem 2):
    /// ein zweites Value-Noise-fBm (Frequenz in 1/Welteinheit, 0.10 ≈ 1 km
    /// Grundwellenlänge) zieht das Lichtungs-Rauschen dort, wo es unter
    /// `clearingLo … clearingHi` fällt, um bis zu `clearingDepth` nach unten.
    /// Das schneidet auch in geschlossene Tieflandbestände (Vegetation am
    /// Deckel 0,78, wo das feine Rauschen allein nie eine Lücke ließ: der
    /// „Noppenteppich“) unregelmäßige Lichtungen in mehreren Größen. Mit
    /// Tiefe 0,8 dünnten sie das Tiefland nur aus (Maske fiel praktisch nie
    /// unter 0,5); 1,3 öffnet es (Wächter `testClearingsCutIntoDenseVegetation`).
    /// Schwellen 0,24/0,30 statt 0,26/0,33: mit den höheren legten die
    /// Lichtungen ganze Halbinseln kahl (Bewerter-Einwand im Hill-Climber).
    public static let clearingFrequency = 0.10
    public static let clearingLo = 0.24
    public static let clearingHi = 0.30
    public static let clearingDepth = 1.3

    /// Keine Bäume in Wänden: Weltsteigung (dy/dx in Welteinheiten, mit
    /// `RenderContract.heightScale`), ab der der Wald ausdünnt und ab der er
    /// fehlt. 1.2 ≈ 50°, 1.8 ≈ 61°. Gemessen über `Terrain.macroSlope`
    /// (±2 Zellen, AGENTS.md: die EINE Quelle der Makro-Steigung); die
    /// Per-Zell-Steigung der Studie stanzte Rinnen-Textur als Löcher in den
    /// Wald.
    ///
    /// Look-Iteration 6: 1.4 ≈ 54°, 2.0 ≈ 63°, damit steile Talflanken
    /// Bestände tragen; reine Wände bleiben frei (dort ist die Vegetation
    /// ohnehin nahe 0).
    public static let wallSlopeLo = 1.4
    public static let wallSlopeHi = 2.0

    /// Kein Wald auf Schnee und Eis (Kältegewicht, B-Kanal von `surfaces`).
    public static let coldLo = 0.15
    public static let coldHi = 0.40

    /// Kein Wald im Strand- und Ufersaum über dem Meer: Höhe über dem
    /// Meeresspiegel (Sim-Einheit), ab der der Wald einsetzt.
    public static let shoreLo = 0.012
    public static let shoreHi = 0.03

    // MARK: Auwald (Look-Iteration 12, Hill-Climber Problem 1)

    /// Abstand zum Wasser (Chebyshev, Zellen), innerhalb dessen kein Wald
    /// steht. Die Schutzmaske (`WaterRender.protectSeamCells` 2) bleibt für
    /// die Render-Verschiebung; für das Kronendach reicht eine Zelle: genau
    /// der Filterabstand der linear gelesenen Textur (Wächter
    /// `testNoForestOverRiversLakesOrBands`). Mit zwei Zellen plus
    /// Lichtungs-Rauschen lag jeder Lauf in einem kahlen Korridor, der sich
    /// in der Totalen als Straße las; in den Referenzbildern steht Gehölz bis
    /// ans Ufer.
    ///
    /// An Bändern zählt als Wasser die äußerste Lage der verrauschten
    /// Wasserlinie (`RiverRibbonRenderer.bandVisibleCoverage`): die Maske
    /// läuft so genau an der gemalten Wasserfläche auf null aus. Bis zum
    /// Review Neon Nr. 1 zog der Bandkern davon noch eine Zelle ab und ließ
    /// das Rauschen weg; die interpolierte Maske reichte damit in 2 % der
    /// sichtbaren Wasserpunkte hinein (Testwelt n = 192, bis 0,79).
    public static let waterSeamCells = 1

    /// Galeriewald: entlang von Flüssen und Seen steht ein Gehölzband, auch
    /// wo die Vegetation sonst Wiese trägt. Seine Breite in Zellen ab dem
    /// Wasser schwankt mit dem Auwald-Rauschen zwischen `riparianWidthLo`
    /// und `riparianWidthHi` (Zelle ≈ 16 m: 80–220 m; schmaler blieb der
    /// von der Sim gerodete Mäandergürtel als blasser Streifen neben dem
    /// Gehölzband stehen), wo das Rauschen unter
    /// `riparianGapLo … riparianGapHi` fällt, reißt es ab (Lücken). Weiter
    /// als `riparianReachCells` misst die Abstandskarte nicht.
    ///
    /// Look-Iteration 13: 3–7 statt 5–14 Zellen (Reichweite 8 statt 16),
    /// Lücken ab 0,30/0,38 statt 0,22/0,30. Mit 2–6 und 0,38/0,46 (rund die
    /// Hälfte des Ufers frei) urteilte der Bewerter fast nur GLEICH zu keep4
    /// (A 1 B 5 GLEICH 9), mit 3–7 A 2 B 8 GLEICH 5.
    /// Das breite, fast geschlossene Band fraß in `diorama` und `tal` die
    /// Lichtungen und Grasrücken des Wald-Stands auf (Bewerter Nr. 12:
    /// „Baumkugeln gleichmäßig über nahezu alle Hänge").
    ///
    /// Look-Iteration 14: 2,5–5 statt 3–7, Lücken ab 0,34/0,42 statt
    /// 0,30/0,38, und nur noch an Bändern und Seen
    /// (`WaterProtectMask.canopyGuard`): in `tal` war die Talmitte gegen
    /// keep4 zugewachsen.
    public static let riparianWidthLo = 2.5
    public static let riparianWidthHi = 5.0
    public static let riparianReachCells = 6
    /// Frequenz des Auwald-Rauschens in 1/Welteinheit (0.8 ≈ 125 m
    /// Grundwellenlänge, 8 Zellen): Lücken und Breitenwechsel im Abstand
    /// weniger Flussbreiten, kein gleichmäßiger Saum. Mittel ≈ 0,47.
    public static let riparianFrequency = 0.8
    public static let riparianGapLo = 0.34
    public static let riparianGapHi = 0.42
    /// Stärke des Galeriewalds vor der Klemme auf 0 … 1: über 1, damit die
    /// Maske im Kern des Bands auch bei voller Breite und weichem Rauschen
    /// sättigt. Der Shader setzt eine Krone erst ab `crownMid` plus bis zu
    /// `crownSpread` × 1,5 (lichte Bestände: ~0,95); mit 1,0 lag die Maske am
    /// Ufer bei 0,6–0,9 und zeigte Wiese statt Kronen (Debug-Aufnahme der
    /// Maske gegen das Bild, Seed 1337, Jahr 20.000).
    public static let riparianDensity = 1.5
    /// Kein Galeriewald auf Fels (Fels-Gewicht, G-Kanal von `surfaces`);
    /// Strand und junge Bank sperrt das Sandgewicht (A-Kanal der Makrofarbe)
    /// ab `riparianSandLo … Hi`. Gemessen (Produktion, Seed 1337, Jahr
    /// 20.000, Zellen 2–5 vom Wasser ohne Wald): mit 0,15/0,40 sperrte der
    /// Fels ein Drittel davon, meist Schotter im Talboden; 0,45/0,75 lässt
    /// Wände und Schutt frei, nicht aber den Talboden (0,30/0,60 sperrte
    /// noch ein Fünftel).
    public static let riparianRockLo = 0.45
    public static let riparianRockHi = 0.75
    /// Ufersaum des Galeriewalds zum Meer (Höhe über dem Meeresspiegel,
    /// Sim-Einheit), flacher als `shoreLo/Hi`: an Mündungen liegen die
    /// Ebenen kaum über dem Meer; mit 0,002/0,010 fiel ein Viertel der
    /// ufernahen Zellen ohne Wald dort heraus, mit 0,0005/0,003 noch ein
    /// Zehntel. Den Strand sperrt das Sandgewicht.
    public static let riparianShoreLo = 0.0005
    public static let riparianShoreHi = 0.003
    /// Sandgewicht, ab dem der Galeriewald ausdünnt, und ab dem er fehlt:
    /// dieselbe Schwelle wie die Bank-Sperre (`WaterRender.barProtectSand`
    /// 0,25), darunter liegt nur der auslaufende Rand einer Bank. Mit
    /// 0,05/0,20 sperrte der Rand ein Fünftel der ufernahen Zellen.
    public static let riparianSandLo = 0.15
    public static let riparianSandHi = 0.30
    /// Wand-Gate des Galeriewalds (Weltsteigung wie `wallSlopeLo/Hi`):
    /// `Terrain.macroSlope` mittelt über ±2 Zellen und schließt am Ufer das
    /// eingetiefte Gerinne ein; gemessen (Produktion, Seed 1337, Jahr
    /// 23.000) fiel so knapp die Hälfte der Zellen 2–3 vom Wasser ohne Wald
    /// unter das Wand-Gate. 2,4 ≈ 67°, 3,2 ≈ 73°: Uferböschungen tragen
    /// Gehölz, echte Wände bleiben frei.
    public static let riparianWallSlopeLo = 2.4
    public static let riparianWallSlopeHi = 3.2

    /// Gedächtnis der Waldmaske (Issue #167, `ForestCanopyMask.regrow`):
    /// Zeitkonstante in Sim-Jahren, mit der der Wald nachwächst, wo Wasser
    /// sich zurückgezogen hat. Kommt Wasser, ist er sofort weg.
    ///
    /// Gemessen mit `testCanopyChurnDiagnostic` (Seed 1337, Jahr 100.000,
    /// Schwellen nach #168, Maske alle 25 J., Bänder im Produktionsdeckel,
    /// Umkippen über 0,5 je 100-Jahr-Takt in % Land): τ = 0 (vor #167)
    /// 0,64 %, 300 J. 0,38 %, 500 J. 0,32 %, 800 J. 0,26 %, 1200 J. 0,23 %;
    /// ganz ohne Schutzmaske, ohne Gedächtnis 0,30 % (nur die Sim-Vegetation).
    /// Das Gedächtnis dämpft also auch deren Nachwachsen, nicht nur die
    /// wandernden Bänder. 800 J. kostet 1,3 Punkte Waldanteil (19,2 → 17,9 %);
    /// darüber wird es kaum ruhiger, der Auengürtel nur breiter. Zielwert des
    /// Tickets: höchstens die Hälfte von heute (≤ 0,32 %). Bei 60 J/s sind
    /// 800 J. gut 13 s Zeitraffer. (Vor #168, mit mehr Wald: 0,91 % → 0,40 %.)
    public static let regrowYears = 800.0
    /// Nachwachsen des Auwalds (Look-Iteration 12): innerhalb der
    /// Galeriewald-Reichweite (`riparianWidthHi` + 1 Zellen vom Wasser)
    /// wächst der Wald über diese Zeitkonstante statt `regrowYears` nach
    /// (Weichholzaue: Weiden und Erlen besiedeln verlassenes Gleithang-Land in
    /// Jahrzehnten). Mit 800 J. lag hinter jedem wandernden Bogen ein kahler
    /// Streifen frisch verlassenen Landes — in der Waldmaske des ersten
    /// Frames stand der Galeriewald, im Zeitraffer nach 20.000 J. nicht.
    /// Der Rest des Landes behält `regrowYears` (Unruhe-Ziel aus #167).
    public static let riparianRegrowYears = 150.0

    /// Zeitkonstante in Sim-Jahren, mit der der Wald dort weicht, wo er im
    /// Ziel verschwindet, OHNE dass Wasser kommt (Schutzmaske leer): vor
    /// allem unter einem frisch eingesetzten Arm, dessen Bett die Sim sofort
    /// rodet (`veg = 0` im Gürtel-Stempel), während das Band erst über
    /// `WaterRender.ribbonGrowYears` einwächst. Sofort weg war der Wald dort
    /// im Kopplungstakt fleckweise auf einen Schlag (Befund Punkt 50: Wald
    /// 11–18× eines normalen Takts). Wo die Schutzmaske Wasser meldet, weicht
    /// er weiter sofort: kein Kronendach über Wasser. Etwa ein Drittel des
    /// Einwachsens: der Wald geht, bevor das Band seine volle Breite hat.
    public static let retreatYears = 60.0
    /// Ab dieser Band-Deckung gilt eine Zelle für den Rückzug als Wasser (der
    /// Wald weicht dort sofort). Die Schutzmaske selbst schützt schon ab
    /// `WaterRender.protectBandThreshold` (0,01) plus Saum — für das Ziel
    /// richtig, für das sofortige Weichen zu früh: ein frisch eingesetzter,
    /// noch unsichtbarer Arm rodete sonst den ganzen Korridor im
    /// Kopplungstakt.
    public static let retreatInstantBandCoverage = 0.35

    // MARK: Wiese (Terrain-Shader)

    /// Bewachsener Boden ohne Wald liest sich als Wiese (Issue #168): ab
    /// `meadowLo` Vegetationsgewicht wird ein Teil des Bodenanteils grün, ab
    /// `meadowHi` der volle Anteil `meadowShare`. Ohne das trug ein Gewicht von
    /// 0,3 nur 30 % Grün; mit den angehobenen Wald-Schwellen standen die
    /// freigewordenen Flächen als Sand da. Fels und Schnee bleiben unberührt.
    public static let meadowLo = 0.08
    public static let meadowHi = 0.35
    public static let meadowShare = 0.75

    // MARK: Kronen (Terrain-Shader)

    /// Rasterweite der Kronen in Welteinheiten (0.11 ≈ 11 m).
    public static let crownCell = 0.11

    /// Höhe des Dachs in Welteinheiten (0.20 ≈ 20 m): die Waldkanten werfen
    /// Schatten auf Wiesen und Lichtungen.
    public static let canopyHeight = 0.20

    /// Waldmaske, ab der das Dach anhebt, und ab der es voll steht.
    ///
    /// Look-Iteration 6: 0.7/0.95 statt 0.2/0.65. Mit dem breiteren lichten
    /// Saum (`vegetationLo` 0,15) zog die Anhebung je Sim-Zelle dort
    /// Dreieckswände und Zeltspitzen einzelner Zellen hoch (eckige Splitter
    /// in der Nahsicht; 0.45/0.85 ließ sie noch stehen). Einzelbäume und
    /// Gruppen am Rand liegen jetzt flach gemalt, nur der dichte Bestand
    /// trägt das Dach; seine Seitenwände malt der Shader dunkel. Der Shader
    /// hebt nach der über ~4×4 Zellen geglätteten Maske (höchstens der
    /// eigenen), damit der Bestandsrand sanft ansteigt statt Zelle für Zelle.
    public static let liftLo = 0.7
    public static let liftHi = 0.95
    /// Abstand der vier diagonalen Abgriffe, über die der Terrain-Vertex-
    /// Shader die Maske vor dem Anhebe-Fenster glättet (Texel = Sim-Zelle):
    /// 1,5 mittelt bilinear über etwa 4×4 Zellen. `Main._forest_lift_at`
    /// rechnet mit demselben Wert nach, damit Pinselkuppel, Raycast und
    /// Kameraziel am Bestandsrand auf dem Dach liegen statt darüber (Review
    /// Neon Nr. 2; Wächter `game/tests/canopy.gd`).
    public static let liftSmoothTexels = 1.5

    /// Waldmaske, ab der der Wald in der Entfernung (Mittelwert statt Kronen)
    /// die Fläche deckt, und ab der voll.
    public static let coverLo = 0.25
    public static let coverHi = 0.6

    /// Waldmaske, ab der die Lücken zwischen den Kronen dunkel sind (nur im
    /// Bestand, am Rand scheint der Boden durch), und ab der voll.
    ///
    /// Look-Iteration 6: 0.55/0.9 statt 0.35/0.75. Mit dem breiteren Saum
    /// malte das Fenster dort dunkle Bodenkacheln mit den geraden Kanten der
    /// Dreiecke (die Maske ist je Dreieck linear); im Saum steht jetzt Wiese
    /// zwischen den Kronen. Der Shader verwackelt die Maske für dieses und das
    /// Deckungs-Fenster zusätzlich je Pixel. Mit den gruppierten Kronen
    /// (s. `crownMid`) standen bei 0.55/0.9 Gruppen auf heller Wiese und
    /// lasen sich als Noppen; 0.45/0.8 schließt sie mit grünem Unterwuchs.
    public static let gapLo = 0.45
    public static let gapHi = 0.8

    /// Eine Krone steht nur, wo die Waldmaske ihre eigene Schwelle übertrifft
    /// (`crownMid ± crownSpread`): am Rand dünnt der Wald so kronenweise aus
    /// statt an einer weichen Linie. Seit Look-Iteration 6 liest der Shader
    /// die Maske an der Kronenmitte (vorher je Pixel: Kronen am Rand wurden
    /// mitten durchgeschnitten), und die Streuung kommt zu gut zwei Dritteln
    /// aus dem Bestands-Rauschen statt je Krone: am Rand stehen Gruppen statt
    /// verstreuter Einzelkronen. 0.45 setzte im lichten Saum der Hänge
    /// einzelne Noppen auf die Wiese; 0.55 dünnte die Gruppen zu stark aus.
    public static let crownMid = 0.50
    public static let crownSpread = 0.30

    /// Kronenradius in Rasterweiten, je Krone zufällig ± Jitter
    /// (0.42 … 0.74, also Kronen von ~9–16 m Durchmesser bei 0.11).
    public static let crownRadius = 0.58
    public static let crownRadiusJitter = 0.16

    /// Kronen je Pixel (`fwidth` der Kronenkoordinate), ab denen das Muster in
    /// seinen Mittelwert übergeht, und ab denen nur noch der Mittelwert steht.
    /// Ohne das flimmert das Dach in der Übersicht.
    public static let detailFootprintLo = 0.35
    public static let detailFootprintHi = 1.1
}
