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
    public static let firnTempLo = -1.0
    public static let firnTempHi = 1.0

    /// Wie stark frischer Schnee das Eis zusätzlich zudeckt: blankes Eis ×
    /// (1 − `iceSnowHide` × Schneedeckung).
    public static let iceSnowHide = 0.85

    // MARK: Rohboden (CPU, B-Kanal von `covers`)

    /// Störungsgrad (`Terrain.disturb`, Pinsel), ab dem brauner Rohboden
    /// sichtbar wird, und ab dem er die Zelle deckt. Er klingt mit der
    /// Regeneration der Sim ab (`disturbanceRecoveryYears`). Anderswo ist
    /// unbewachsener Boden kein Braun mehr, sondern Trockenrasen bzw. in der
    /// Höhe steiniger Grund (Shader).
    public static let rawDisturbLo = 0.04
    public static let rawDisturbHi = 0.30

    // MARK: Talboden-Wiese (CPU, A-Kanal von `covers`)

    /// Talboden = flach (Weltsteigung unter `valleySlopeLo` voll, ab
    /// `valleySlopeHi` nicht mehr) UND unterhalb des Nadelwald-Bands
    /// (`HeightBands.coniferLow/High`, #152). Dort ist die Wiese hell und
    /// saftig statt des Hangtons. Anknüpfungspunkt Paket B: alte Bänke
    /// (`barAge`) gehen hier als zweite Quelle ein (Maximum), sobald das
    /// Feld existiert.
    public static let valleySlopeLo = 0.10
    public static let valleySlopeHi = 0.30

    // MARK: Shader (terrain.gdshader, über `MaterialUniforms`)

    /// Rinnen und Rippen aus dem Relief-Bake (#153, A-Kanal −1 … +1) verteilen
    /// das Material fein: auf Rippen wird Fels um bis zu `ridgeRockGain`
    /// (relativ) verstärkt, in Rinnen wandert bis zu `gullyScreeShare` des
    /// Felsanteils in Schutt.
    public static let ridgeRockGain = 0.6
    public static let gullyScreeShare = 0.7

    /// Klüftung: Kluftabstand in Welteinheiten (0,45 ≈ 45 m, Wandmaßstab) und
    /// wie stark die Klüfte abdunkeln (0 … 1). Ab etwa einer Kluft je Pixel
    /// blendet das Muster in seinen Mittelwert.
    public static let jointSpacing = 0.45
    public static let jointDepth = 0.45

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
