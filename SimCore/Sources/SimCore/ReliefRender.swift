/// Kalibrierung der Render-Verschiebung von Rinnen und Graten (Issue #153).
///
/// Wie `WaterRender` und `RenderContract` eine reine Render-Ableitung ohne
/// Sim-Zustand: nichts hier ändert Physik. Die Verschiebung selbst rechnet die
/// GPU (`game/shaders/relief_bake.gdshader`), einmal je Terrain-Update in eine
/// Textur; der Terrain-Shader liest daraus Höhe (Vertex), Steigung und
/// Rinnen-Schattierung (Pixel). Die Zahlen reisen über den Uniform-Weg
/// (`SimRender.CalibrationRegistry` (Gruppe `relief`) → `SimNode` → `Main.gd`) und stehen in keinem
/// Shader als Kopie.
///
/// Herkunft: Flusstal-Studie #116, Hebel `geometry`, vom Projekteigner mit
/// PR #121 abgenommen (Messreihe und Bilder: `docs/graphics-quality.md`).
///
/// Wächter: `SimCoreTests/ReliefUniformsTests.swift`, End-to-End
/// `game/tests/relief.gd`.
public enum ReliefRender {

    /// Skala der groben Erosionsrinnen in UV. 0.022 ≈ 16 Sim-Zellen ≈ 2,5 km
    /// Wellenlänge der größten Rinne; das feine Detail des Terrain-Shaders
    /// läuft mit derselben Funktion bei 0.006.
    public static let scale = 0.022

    /// Höhenamplitude der Rinnen relativ zur Skala (wie `detail_strength`
    /// beim feinen Detail).
    public static let strength = 0.55

    // Feines Rinnen-Detail des Terrain-Shaders (dieselbe runevision-Funktion
    // je Pixel, nur als Normale und Schattierung, keine Verschiebung). Bis
    // zum Review zu #174 standen diese drei Zahlen als Literal-Defaults im
    // Shader, Main.gd setzte sie nie. Die Stärke `detail_strength` fährt
    // Main.gd mit dem Geländealter (`terrain_detail_strength`) und behält
    // ihren Jahr-0-Default (RenderContractTests).

    /// Skala in UV: 0.006 ≈ 4 Sim-Zellen Wellenlänge der größten feinen Rinne.
    public static let detailScale = 0.006
    /// Albedo-Abdunklung in den Rinnenböden. 0.20 bis Look-Iteration 7; seit
    /// das Detail je Pixel nur noch zwei statt drei Oktaven rechnet
    /// (Bildzeit), gleichen Abdunklung und Normalen-Anteil die fehlende
    /// feinste Oktave aus (Bewerter: „kräftigere Reliefschattierung" am
    /// Stand mit drei Oktaven).
    public static let detailShade = 0.26
    /// Anteil der Normal-Perturbation (1.0 bis Look-Iteration 7, s. o.).
    public static let detailNormal = 1.35

    /// Gratschärfung: Faktor auf den positiven Teil von „Höhe minus Ringmittel".
    /// Nur Kuppen und Grate werden angehoben, Mulden bleiben, wo sie sind;
    /// damit sinkt kein Talboden unter ein Flussband. Auf Graten reicht das bis
    /// etwa +1 Welteinheit (≈ 100 m).
    public static let sharpen = 2.2

    /// Weicher Deckel der Gratschärfung in Welteinheiten (`cap · tanh(x / cap)`).
    /// Ohne ihn hob die Schärfung auf jungem, steilem Relief (Jahr 0) einzelne
    /// Gipfel um bis zu 3,6 Einheiten an (Projekteigner: „viel zu spiky");
    /// mit 0.8 bleibt es dort bei 1,0, und das bei Jahr 20.000 abgenommene
    /// Bild ändert sich kaum (p99 der Anhebung 0,54 → 0,50, Maximum
    /// 1,17 → 0,89). 0.5 drückte auch die reifen Grate sichtbar (Maximum 0,71).
    public static let ridgeCap = 0.8

    /// Alter (Sim-Jahre), bis zu dem die echte Verformung einblendet
    /// (Smoothstep ab Jahr 0). Rinnen und Grate wirken in Schattierung und
    /// Normalen von Anfang an voll, die Vertex-Verschiebung erst mit dem Alter:
    /// auf jungem, steilem Relief zog jede Verformung die Grate zu Sägezähnen
    /// (Projekteigner, 10. Oktober 2026: „viel zu spiky"). Weder ein kleinerer
    /// Gratdeckel noch schwächere Rinnen noch eine weichere Abtastung halfen,
    /// jeder der beiden Anteile allein reichte schon. Bei 20.000 Jahren steht
    /// das abgenommene Studienbild unverändert. Vorbild: das feine Shader-Detail
    /// blendet ebenso mit dem Alter ein (`Main.terrain_detail_strength`).
    public static let geometryAgeYears = 20_000.0

    /// Radius des Rings, gegen den die Gratschärfung misst, in Sim-Zellen.
    public static let sharpenRadiusCells = 2.5

    /// Kodierung der Backtextur: Kanal = Wert × Code + 0.5, damit kein Kanal
    /// negativ wird. Höhe in Welteinheiten (± 2,5 Einheiten darstellbar;
    /// bis Look-Iteration 7 ± 2 mit 0.25, die Felsrippen brauchen den Platz,
    /// s. `testHeightCodeCoversTheDisplacement`) …
    public static let heightCode = 0.2

    /// … und Steigung dh/duv (± 33 darstellbar; vorher ± 25 mit 0.02, die
    /// Felsrippen steilen die Flanken zusätzlich auf).
    public static let slopeCode = 0.015

    /// Hell-Dunkel der Rinnen (−) und Rippen (+) auf freien Flächen: Rinnenböden
    /// bis 42 % dunkler, Rippen bis 18 % heller. Erst das macht große
    /// Felsflächen aus der Übersicht als Fels lesbar statt als glatten Sand.
    public static let shadeDark = 0.42
    public static let shadeLight = 0.18

    /// Wie stark Rinnen (normierte Rinnentiefe) und Grate (Höhe über dem
    /// Ringmittel) in diesen Hell-Dunkel-Kanal eingehen, bevor er auf ±1
    /// geklemmt wird.
    public static let cavityGullyGain = 1.6
    public static let cavityRidgeGain = 25.0

    // MARK: Felsrippen (Look-Iteration 7)

    /// Zweite, feinere Rinnenschar im Back-Pass (dieselbe runevision-Funktion
    /// wie die grobe Verschiebung): Skala in UV (0.011 ≈ 8 Sim-Zellen ≈ 120 m
    /// Wellenlänge der größten Rippe) und Stärke relativ zur Skala. Befund des
    /// blinden Bewerters am Stand vor Iteration 7: „glatte Knetlandschaft ohne
    /// Felsstruktur". Das feine Pixel-Detail (`detailScale`) blendet mit der
    /// Kameradistanz aus und fehlt deshalb in Tal- und Diorama-Ansicht; die
    /// gebackene Schar kostet je Bild nichts und trägt in jede Entfernung.
    public static let ribScale = 0.011
    public static let ribStrength = 1.5

    /// Weltsteigung (dy/dx mit `RenderContract.heightScale`), ab der die
    /// Rippen zunehmen, und ab der sie voll stehen. Darunter (Grashänge) nur
    /// der Anteil `ribFloor`: Hangrippen statt glatter Kissen, aber keine
    /// Felswand auf der Wiese.
    public static let ribSlopeLo = 0.8
    public static let ribSlopeHi = 1.8
    public static let ribFloor = 0.5

    /// Wie stark die Rippen in den Hell-Dunkel-Kanal (A) eingehen: Rinnenböden
    /// dunkel, Rippen hell, damit die Schar auch als Ton aus der Ferne trägt
    /// und Schnee in den Rinnen liegen bleibt (Material-Shader).
    public static let cavityRibGain = 2.5

    /// Felsbänke im Back-Pass: Abstand der groben Schichtstufen in Welt-Höhe
    /// (0,8 ≈ 80 m), wie stark die Steigung an der Stufenstirn zu- und auf der
    /// Bank abnimmt (relativ zur Hangneigung), und wie stark die Stirn im
    /// Hell-Dunkel-Kanal abdunkelt. Grob genug, um in der Tal-Ansicht als
    /// Hell-Dunkel aus dem Licht zu tragen; die feinen Klüfte des
    /// Terrain-Shaders bleiben für die Nahsicht. Nur auf Steilflanken (wie die
    /// Rippen über `ribSlopeLo/Hi`, ohne den Grashang-Anteil `ribFloor`).
    /// Je Pixel im Terrain-Shader gerechnet kostete dasselbe gemessen
    /// Bildzeit (Zeitraffer-A/B, Look-Iteration 7).
    public static let benchSpacing = 0.8
    public static let benchRelief = 0.9
    public static let cavityBenchGain = 0.6
}
