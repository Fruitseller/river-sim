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
}
