/// Kalibrierung der Render-Verschiebung von Rinnen und Graten (Issue #153).
///
/// Wie `WaterRender` und `RenderContract` eine reine Render-Ableitung ohne
/// Sim-Zustand: nichts hier ändert Physik. Die Verschiebung selbst rechnet die
/// GPU (`game/shaders/relief_bake.gdshader`), einmal je Terrain-Update in eine
/// Textur; der Terrain-Shader liest daraus Höhe (Vertex), Steigung und
/// Rinnen-Schattierung (Pixel). Die Zahlen reisen über den Uniform-Weg
/// (`SimRender.ReliefUniforms` → `SimNode` → `Main.gd`) und stehen in keinem
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

    /// Radius des Rings, gegen den die Gratschärfung misst, in Sim-Zellen.
    public static let sharpenRadiusCells = 2.5

    /// Kodierung der Backtextur: Kanal = Wert × Code + 0.5, damit kein Kanal
    /// negativ wird. Höhe in Welteinheiten (± 2 Einheiten darstellbar) …
    public static let heightCode = 0.25

    /// … und Steigung dh/duv (± 25 darstellbar).
    public static let slopeCode = 0.02

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
}
