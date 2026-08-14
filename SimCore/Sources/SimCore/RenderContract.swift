/// Zahlen, die MEHRERE Schichten unabhängig voneinander festlegen mussten und
/// deshalb still auseinanderdriften konnten (Issue #51).
///
/// Wie `WaterRender` und `Strahler` eine reine RENDER-/Präsentations-Ableitung
/// ohne Sim-Zustand — sie ändern keine Physik. Der Unterschied: hier steht
/// nichts Wasser-Spezifisches, sondern das, was Godot-Schicht (`game/`),
/// GDExtension und Shader gemeinsam annehmen müssen, damit sie dieselbe Welt
/// zeigen.
///
/// Gefundene Drift, die dieser Vertrag beendet:
///   - `hscale`: `Main.gd` setzt 24.0, `terrain.gdshader` stand als Default auf
///     26.0. Sichtbar wurde das nur, wenn der Shader OHNE gesetzten Uniform
///     lief (Editor-Vorschau, Material ohne `SimNode`) — dann war das ganze
///     Terrain 8 % zu hoch.
///   - Start-Seed: `Main.gd` (1337) und der Terrain-Default der GDExtension
///     (1337) legten dieselbe Zahl doppelt fest; die Anzeige „Seed" und die
///     tatsächlich gezeigte Welt hätten sich lautlos trennen können.
///
/// Wächter: `SimCoreTests/RenderContractTests.swift` vergleicht diese Werte
/// gegen die ECHTEN Quelltexte von `game/scripts/Main.gd` und den Shadern.
public enum RenderContract {

    /// Vertikale Überhöhung des Render-Meshes: Sim-Höhe (0…1) × `heightScale`
    /// = Godot-Welt-Y. Von 30 gesenkt — weniger vertikale Überhöhung, sanfterer
    /// Look, ergänzt das gesenkte `baseRelief`.
    ///
    /// Kennen müssen ihn: `Main.gd` (Mesh, Kamera-Sampling, Bäume, Bänder),
    /// `terrain.gdshader` (Displacement + Normalen) und `SimNode`
    /// (`treeInstanceBuffer`, `buildRiverRibbons` — beide bekommen ihn als
    /// Parameter, legen ihn also NICHT selbst fest).
    public static let heightScale = 24.0

    /// Anhebung der Wasser-Bänder über das Gelände (Godot-Welt-Y): deckt den
    /// Chord-Fehler des gröberen Render-Gitters im Talgrund ab (384er-Gitter auf
    /// 832er-Feld). Über Wasser gilt er NICHT — dort tritt
    /// `WaterRender.ribbonLakeSurfaceLift` / `ribbonSeaSurfaceSink` an seine
    /// Stelle, und beide müssen deutlich kleiner bleiben als dieser Wert.
    public static let riverLift = 0.35

    /// Start-Seed der Welt. Zwei Schichten legen ihn fest: `Main.gd` zeigt und
    /// verwürfelt ihn („Neue Welt"), die GDExtension baut ihr erstes `Terrain`
    /// damit. Beide lesen dieselbe Zahl, damit die angezeigte Welt und der
    /// angezeigte Seed dieselben bleiben.
    public static let defaultSeed: UInt32 = 1337
}
