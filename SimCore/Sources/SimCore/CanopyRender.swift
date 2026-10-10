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
///    Zahlen reisen über `SimRender.CanopyUniforms` → `SimNode` → `Main.gd`.
///
/// Herkunft: Flusstal-Studie #116, Hebel `canopy`, vom Projekteigner mit
/// PR #121 abgenommen (`docs/graphics-quality.md`). Die Studie rechnete die
/// Waldmaske im Shader; die Schwellen sind dieselben.
///
/// Wächter: `SimCoreTests/CanopyTests.swift`.
public enum CanopyRender {

    // MARK: Waldmaske (CPU, SimRender.ForestCanopyMask)

    /// Vegetationsgewicht (`TerrainColorRenderer`, R-Kanal von `surfaces`), ab
    /// dem Wald einsetzt, und ab dem er geschlossen ist.
    public static let vegetationLo = 0.14
    public static let vegetationHi = 0.32

    /// Lichtungen und Waldränder: Rauschen verschiebt die Vegetationsschwelle,
    /// der Wald bildet so Gruppen statt einer gleichmäßigen Fläche. Frequenz in
    /// 1/Welteinheit (0.45 ≈ 220 m Grundwellenlänge, 14 Sim-Zellen), Mittelwert
    /// des Rauschens (wird abgezogen) und Gewicht. Das Rauschen ist das
    /// Value-Noise-fBm der Studie (`ForestCanopyMask.clumpNoise`); mit
    /// Simplex-Rauschen gleicher Frequenz streute der Wald auf mageren Hängen
    /// sichtbar mehr kleine Flecken als im abgenommenen Bild.
    public static let clumpFrequency = 0.45
    public static let clumpMean = 0.47
    public static let clumpGain = 0.45

    /// Keine Bäume in Wänden: Weltsteigung (dy/dx in Welteinheiten, mit
    /// `RenderContract.heightScale`), ab der der Wald ausdünnt und ab der er
    /// fehlt. 1.2 ≈ 50°, 1.8 ≈ 61°. Gemessen über `Terrain.macroSlope`
    /// (±2 Zellen, AGENTS.md: die EINE Quelle der Makro-Steigung); die
    /// Per-Zell-Steigung der Studie stanzte Rinnen-Textur als Löcher in den
    /// Wald.
    public static let wallSlopeLo = 1.2
    public static let wallSlopeHi = 1.8

    /// Kein Wald auf Schnee und Eis (Kältegewicht, B-Kanal von `surfaces`).
    public static let coldLo = 0.15
    public static let coldHi = 0.40

    /// Kein Wald im Strand- und Ufersaum über dem Meer: Höhe über dem
    /// Meeresspiegel (Sim-Einheit), ab der der Wald einsetzt.
    public static let shoreLo = 0.012
    public static let shoreHi = 0.03

    // MARK: Kronen (Terrain-Shader)

    /// Rasterweite der Kronen in Welteinheiten (0.11 ≈ 11 m).
    public static let crownCell = 0.11

    /// Höhe des Dachs in Welteinheiten (0.20 ≈ 20 m): die Waldkanten werfen
    /// Schatten auf Wiesen und Lichtungen.
    public static let canopyHeight = 0.20

    /// Waldmaske, ab der das Dach anhebt, und ab der es voll steht.
    public static let liftLo = 0.2
    public static let liftHi = 0.65

    /// Waldmaske, ab der der Wald in der Entfernung (Mittelwert statt Kronen)
    /// die Fläche deckt, und ab der voll.
    public static let coverLo = 0.25
    public static let coverHi = 0.6

    /// Waldmaske, ab der die Lücken zwischen den Kronen dunkel sind (nur im
    /// Bestand, am Rand scheint der Boden durch), und ab der voll.
    public static let gapLo = 0.35
    public static let gapHi = 0.75

    /// Eine Krone steht nur, wo die Waldmaske ihre eigene Schwelle übertrifft
    /// (`crownMid ± crownSpread`, je Krone zufällig, also 0.25 … 0.85): am Rand
    /// dünnt der Wald so kronenweise aus statt an einer weichen Linie.
    public static let crownMid = 0.55
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
