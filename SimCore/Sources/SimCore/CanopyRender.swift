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
