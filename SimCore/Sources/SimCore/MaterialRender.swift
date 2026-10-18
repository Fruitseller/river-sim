/// Kalibrierung der geomorphologischen Materialverteilung (Issue #174, Paket D).
///
/// Wie `CanopyRender` eine reine Render-Ableitung ohne Sim-Zustand: nichts
/// hier ändert Physik, `simperf --hash` bleibt gleich. Das Land bekommt die
/// Materialien, die die Vorlagen tragen: grauer Fels auf steilen, konvexen
/// Formen, Schutthalden darunter, Gletschereis getrennt vom Schnee, brauner
/// Rohboden nur auf frisch gestörten Flächen und eine helle Talboden-Wiese.
///
/// Zwei Hälften mit getrennten Lesern, wie beim Kronendach:
///  - WO ein Material liegt, rechnet `SimRender.TerrainColorRenderer` auf der
///    CPU als Gewicht je Sim-Zelle (`surfaces` und `covers`), einmal je
///    Terrain-Update. Deterministisch und headless prüfbar; diese Schwellen
///    erreichen keinen Shader.
///  - WIE es aussieht (Klüftung, Körnung, Spalten, Moränen, Feinverteilung an
///    Rinnen und Rippen), rechnet `game/shaders/terrain.gdshader` je Pixel.
///    Diese Zahlen reisen über `SimRender.MaterialUniforms` → `SimNode` →
///    `Main.gd`, default-frei im Shader (Muster #92).
///
/// Steigungen sind WELTsteigungen (dy/dx in Welteinheiten, mit
/// `RenderContract.heightScale`), gemessen über `Terrain.macroSlope` (±2
/// Zellen, die EINE Quelle der Makro-Steigung, AGENTS.md) und umgerechnet wie
/// in `ForestCanopyMask`; damit sind die Winkel unten dieselben, die man im
/// Bild sieht.
///
/// Wächter: `SimCoreTests/MaterialTests.swift`; Flächenanteile auf den
/// Matrix-Welten: `testMaterialCoverageDiagnostic`
/// (`docs/graphics-quality.md` § Material, Schnee, Wolken).
public enum MaterialRender {

    // MARK: Fels (CPU, G-Kanal von `surfaces`)

    /// Weltsteigung, ab der Fels durchbricht, und ab der er die Zelle deckt
    /// (1,50 ≈ 56°, 2,60 ≈ 69°). Die Matrix-Welten sind steil (Median der
    /// Weltsteigung 0,9–1,3, p90 2,2–2,8); so trifft der Fels die steilsten
    /// 13–24 % des Landes (`testMaterialCoverageDiagnostic`). Mit 0,70/1,20
    /// waren es 52–63 %, und der Wald fiel auf ein Viertel. Vor #174 setzte
    /// der Fels erst bei `macroSlope` 0,004 ein und lag UNTER der Vegetation,
    /// die bis fast in die Senkrechte gewichtet war: unter 1,5 % des Landes
    /// trugen Fels, die Hänge lasen sich als brauner Boden mit grünem Schleier.
    public static let rockSlopeLo = 1.50
    public static let rockSlopeHi = 2.60

    /// Konvexität: Sim-Höhe der Zelle minus Mittel der vier Nachbarn im Abstand
    /// 2 (dieselbe Stencil-Weite wie `macroSlope`), in Welteinheiten. Positiv
    /// auf Graten und Rippen, negativ in Rinnen und Hangfüßen. Bei
    /// `convexRef` verschiebt sie die Fels-Schwellen um den vollen
    /// `convexSlopeShift`: auf Graten bricht Fels früher durch, in Rinnen
    /// später (dort sammelt sich Schutt).
    public static let convexRef = 0.12
    public static let convexSlopeShift = 0.50

    // MARK: Schutthalden (CPU, R-Kanal von `covers`)

    /// Reichweite der Halde unter einer Felswand in Zellen (3 ≈ 47 m): so weit
    /// wird der Fels quer verbreitert (Maximum-Filter), bevor die Halde ihn
    /// als Quelle sieht.
    public static let screeReachCells = 3

    /// Verbreiterter Felsanteil, ab dem eine Halde entsteht, und ab dem sie
    /// voll ist.
    public static let screeSourceLo = 0.55
    public static let screeSourceHi = 0.90

    /// Weltsteigung der Halde: steigend von `screeSlopeLo` (≈ 30°) bis
    /// `screeSlopeHi` (≈ 39°), dem Schüttwinkel; steiler übernimmt der Fels.
    /// Auf flachem Boden unter der Wand läuft die Halde aus.
    public static let screeSlopeLo = 0.58
    public static let screeSlopeHi = 0.80

    /// Hohlform der Halde: Konkavität (−Konvexität, Welteinheiten), ab der
    /// die Halde voll steht. Gerade Hänge und Rippen tragen keine Halde.
    /// Ohne diese Bedingung lagen 11–22 % des Landes als Halde da, weil auf
    /// den steilen Welten fast jeder Hang in Reichweite einer Wand liegt.
    public static let screeConcavity = 0.06

    /// Wann Bewuchs dem Mineral weicht: Fels- plus Haldenanteil, ab dem die
    /// Vegetation zurückgeht, und ab dem sie fehlt. Darunter füllen Fels und
    /// Schutt nur den unbewachsenen Rest (wie vor #174 der Fels). Ohne diese
    /// Stufe kostete jeder Teil-Felsanteil auf den steilen Matrix-Welten
    /// (Median-Weltsteigung 0,9–1,3) Bewuchs, und der Wald fiel auf Seed 1337
    /// bei Jahr 2000 von 8,5 auf 6,0 % des Landes.
    public static let vegYieldLo = 0.4
    public static let vegYieldHi = 0.9

    // MARK: Gletschereis (CPU, G-Kanal von `covers`)

    /// Blankes Eis liegt nur im Zehrgebiet: Temperatur (`Terrain.temperature`,
    /// °C), ab der das Eis aus dem Firn tritt, und ab der es voll blank ist.
    /// Die Gleichgewichtslinie liegt dort, wo `updateIce` zu schmelzen beginnt
    /// (0 °C). Darüber ist der Gletscher Firn und liest sich als Schnee (weiß),
    /// darunter als bläuliche Zunge; so ist er vom Schnee unterscheidbar
    /// (Vorlage B/C). Gemessen (Seed 1337, Jahr 2000): ohne diese Trennung war
    /// jede kalte Zelle „blankes Eis", weil der Schnee im Nährgebiet zu Eis
    /// wird und die Schneedeckung dort klein bleibt.
    ///
    /// Seit der Entkopplung der Eis-Firn-Grenze (`SimConfig.iceFirnTemp`, −2 °C,
    /// Issue #174) gelten beide Werte RELATIV zu ihr: die Gleichgewichtslinie
    /// des Gletschers ist dort, wo `updateIce` Firn bildet, nicht mehr an der
    /// 0-°C-Isotherme des Schnees. Mit dem festen 0 °C lag die Zunge zwischen
    /// −2 und 0 °C als Firn unter dem Schnee, und im Bild war kein Gletscher vom
    /// Schneefeld zu unterscheiden (Abnahmepunkt 36).
    public static let firnTempLo = -1.0
    public static let firnTempHi = 1.0

    /// Wie stark frischer Schnee das Eis zusätzlich zudeckt: blankes Eis ×
    /// (1 − `iceSnowHide` × Schneedeckung × (1 − Zehranteil)). Im Zehrgebiet
    /// schmilzt der Winterschnee auf dem Gletscher jeden Sommer ab; die
    /// Schneedecke der Sim ist ein Jahresmittel und deckte dort sonst die
    /// Zunge zu. Im Nährgebiet (Zehranteil 0) bleibt der Gletscher Firn.
    public static let iceSnowHide = 0.85

    // MARK: Schnee an Steilflanken (CPU, B-Kanal von `surfaces`)

    /// Weltsteigung, ab der Schnee von einer Flanke abgleitet, und ab der sie
    /// schneefrei ist (1,4 ≈ 55°, 2,2 ≈ 66°, Weltsteigung samt Höhenskala, also die
    /// Steigung, die man im Bild sieht). Steile Wände halten keinen
    /// Schnee, er geht als Lawine ab (dieselbe Physik wie der Firn-Abgang
    /// des Eises, `SimConfig.iceAvalancheSlopeLo/Hi`, dort in Sim-Steigung).
    /// Ohne das deckte die Kälte jede Wand über der Schneegrenze weiß zu, und
    /// Hörner, Grate und Karwände lasen sich als weiße Tafeln (Befund #174,
    /// Seeds 1337/20, Nahansicht des Kamms). Gemessen (Seed 1337, Jahr 20.000,
    /// Zellen über 0,5): Schnee liegt mit einer mittleren Weltsteigung von 1,36,
    /// 44 % über 1,5. Verworfen: 0,8/1,5 (Diorama fast nur graue Gipfel) und
    /// 1,2/2,0 (Grate in der Diorama-Kamera grauer als die Vorlagen von #174;
    /// mit 1,4/2,2 hält der Kamm sichtbar mehr Schnee, die Wände bleiben Fels).
    public static let snowShedSlopeLo = 1.4
    public static let snowShedSlopeHi = 2.2

    /// Dasselbe für die EIS-Deckung im Bild, steiler angesetzt (1,6 ≈ 58°,
    /// 2,6 ≈ 69°): Hängegletscher halten sich steiler als Schnee, darüber bricht Eis
    /// in Séracs ab. Die Sim behält ihr Eis (die Maske `underIce` und der
    /// Abtrag bleiben unberührt), nur die Kältedeckung im Render weicht dem
    /// Fels. Gemessen (Seed 1337, Jahr 20.000, Zellen über 0,5): Eis liegt mit
    /// einer mittleren Weltsteigung von 1,31, 42 % davon über 1,5 — ohne diese
    /// Abstufung blieben die Wände weiß, auch wenn der Schnee abglitt.
    public static let iceShedSlopeLo = 1.6
    public static let iceShedSlopeHi = 2.6

    // MARK: Rohboden (CPU, B-Kanal von `covers`)

    /// Störungsgrad (`Terrain.disturb`, Pinsel), ab dem brauner Rohboden
    /// sichtbar wird, und ab dem er die Zelle deckt. Er klingt mit der
    /// Regeneration der Sim ab (`disturbanceRecoveryYears`). Anderswo ist
    /// unbewachsener Boden kein Braun mehr, sondern Trockenrasen bzw. in der
    /// Höhe steiniger Grund (Shader).
    public static let rawDisturbLo = 0.04
    public static let rawDisturbHi = 0.30

    // MARK: Bewuchs und Makrofarbe (CPU, `colors` und R-Kanal von `surfaces`)

    /// Höchstes Vegetationsgewicht eines Standorts: ein bewachsener Hang
    /// bleibt zu 22 % Grundton. Eine Zahl für ZWEI Stellen im
    /// `TerrainColorRenderer`: den Bewuchs-Anteil, der Farbe und Gewicht
    /// speist, und den Deckel nach dem Gürtel-Zuschlag
    /// (`BarMaterial.vegShift`: Pionier-Grün darf das Gewicht nicht über das
    /// heben, was der Bewuchs selbst erreichen kann). Bis zum Review von #174
    /// stand sie dort als zwei Literale; wer eines änderte, verschob den
    /// Deckel gegen den Anteil.
    public static let vegAmountMax = 0.78

    /// Makrofarbe unter Fels und Halde: je Gewicht `rock + scree` wandert
    /// die Farbe zu diesem Ton, sonst trüge jede Felswand den Grünstich des
    /// Habitats darunter (der Shader mischt die Makrofarbe nur zu 28 % unter).
    /// Im Ton des Shader-Felses (Befund #174 „Fels zu hell"): mit 0,37 hob die
    /// Beimischung allein jede Wand um ein Drittel über ihren eigenen Grauton.
    public static let mineralTint = (r: 0.13, g: 0.13, b: 0.135)

    // MARK: Talboden-Wiese (CPU, A-Kanal von `covers`)

    /// Talboden = flach (Weltsteigung unter `valleySlopeLo` voll, ab
    /// `valleySlopeHi` nicht mehr) UND unterhalb des Nadelwald-Bands
    /// (`HeightBands.coniferLow/High`, #152). Dort ist die Wiese hell und
    /// saftig statt des Hangtons. Zweite Quelle (Maximum): die Aue, also
    /// Bänke, deren Sand-Fenster vorbei ist (`Terrain.barAge` über
    /// `WaterRender.barSandYearsLo/Hi`, ohne Steigungs- und Höhentor: der
    /// Gürtel liegt zu 83–97 % über `coniferLow`, s. `testBarMeadowDiagnostic`).
    public static let valleySlopeLo = 0.10
    public static let valleySlopeHi = 0.30

    // MARK: Shader (terrain.gdshader, über `MaterialUniforms`)

    /// Rinnen und Rippen aus dem Relief-Bake (#153, A-Kanal −1 … +1) verteilen
    /// das Material fein: auf Rippen wird Fels um bis zu `ridgeRockGain`
    /// (relativ) verstärkt, in Rinnen wandert bis zu `gullyScreeShare` des
    /// Felsanteils in Schutt.
    public static let ridgeRockGain = 0.6
    public static let gullyScreeShare = 0.7

    /// Klüftung: Grundabstand des Musters quer zur Fallrichtung in
    /// Welteinheiten (0,30 ≈ 30 m; die Runsen liegen bei etwa dem Doppelten),
    /// Streckung entlang der Fallrichtung (Runsen 1,5-mal so lang wie breit) und
    /// wie stark das Muster höchstens abdunkelt (0 … 1). Ab etwa einem
    /// Kluftabstand je Pixel blendet es in seinen Mittelwert.
    ///
    /// Review zu PR #177: die erste Fassung (zwei gerade Kluftscharen im
    /// Abstand 0,45, Tiefe 0,45, in der Waagerechten) stand auf maximierten
    /// Screenshots als gleichmäßiges Rautennetz über allen Wänden, das sich
    /// wie ein Drahtgitter las. Jetzt Runsen und gestückelte Fugen aus
    /// Rauschen, in Fallrichtung gestreckt, in Breite und Stärke moduliert;
    /// die höhere Tiefe gleicht aus, dass das Muster im Mittel schwächer ist.
    public static let jointSpacing = 0.30
    public static let jointStretch = 1.5
    public static let jointDepth = 0.55

    /// Die zweite Runsen-Oktave und die feinen Facetten kreuzen die erste
    /// Richtung um rund 37°. Kosinus/Sinus einer orthogonalen Drehung;
    /// gemeinsam mit der kurzen Streckung brechen sie lange Vorhanglinien.
    /// Diagnose und A/B: docs/zielbild-measurements.md, Abschnitt Felswände.
    public static let jointTurnCos = 0.8
    public static let jointTurnSin = 0.6

    /// Tiefe der Runsen als FORM (Befund #174 „Fels glatt"), in
    /// Kluftabständen: der Shader kippt die Normale entlang der analytischen
    /// Ableitung des Runsen-Rauschens, dazu feine Grate dazwischen. Bis dahin
    /// waren die Runsen nur Ton; ohne eigenes Licht und Schatten lasen sich
    /// die Wände als glatter Putz. Wie das Muster blendet die Form mit der
    /// Pixelgröße aus.
    public static let jointRelief = 0.35

    /// Kopplung der Klüftung an die Form (Relief-Bake #153, −1 Rinne … +1
    /// Rippe): Breite und Stärke × (1 − `jointGullyGain` × Rinne/Rippe). In
    /// voll ausgeprägten Rinnen also 1,6-fach, auf Rippen 0,4-fach; der Fels
    /// zerfällt dort, wo das Wasser ihn ausräumt.
    public static let jointGullyGain = 0.6

    /// Relief der Felswände (Befund #174 „Fels zu hell und glatt"): auf Fels
    /// verstärkt der Shader die feinen Erosionsrinnen (runevision-Detail,
    /// Normale UND Abdunklung der Rinnenböden) um bis zu diesen Faktor. Bis
    /// dahin lag das Rinnen-Detail auf Fels so schwach wie auf Wiese; die
    /// Wände lasen sich als glatt verputzte Fläche ohne Runsen und Schatten.
    public static let rockReliefGain = 2.5

    /// Körnung der Halden: Blockgröße in Welteinheiten (0,05 ≈ 5 m).
    public static let screeGrain = 0.05

    /// Gletscherspalten: Abstand quer zur Fließrichtung (0,12 ≈ 12 m) und die
    /// Weltsteigung, ab der sie aufreißen, und ab der sie voll stehen
    /// (Spalten entstehen, wo das Eis über Gefälle beschleunigt; flache
    /// Zungenenden bleiben geschlossen).
    public static let crevasseSpacing = 0.12
    public static let crevasseSlopeLo = 0.40
    public static let crevasseSlopeHi = 1.00

    /// Moränen: Kältedeckung (B von `surfaces`) am Rand der blanken Zunge,
    /// in der Schutt liegt. Von 0 bis `moraineLo` steigt der Saum an, bis
    /// `moraineHi` läuft er ins saubere Eis aus; dazu Mittelmoränen als
    /// Streifen in Fließrichtung (Shader).
    public static let moraineLo = 0.30
    public static let moraineHi = 0.80
}
