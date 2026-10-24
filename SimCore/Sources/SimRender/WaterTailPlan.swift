/// Pass-Plan des Wasserfeld-Schwanzes (Issue #95): die STRUKTUR der
/// Schwanzstufen — räumlicher Blur, zeitliche EWMA, Priming — als Daten, eine
/// Quelle für den CPU-Pfad (`WaterFieldRenderer.bytes`) UND die GPU-Kette
/// (`game/scripts/WaterGpuTail.gd`).
///
/// Bis #95 stand dieser Plan dreifach implizit im Code: die Pass-Zahlen als
/// Literale in `WaterFieldRenderer.bytes` (CPU-Pfad), die Kanal-Masken als
/// Literal-Tabelle in `Main.gd._setup_water_gpu` (GPU-Kette) und das Priming
/// des ersten Ticks als dortiges `1.0`. Damit war die GPU-Kette eine zweite,
/// ungedeckte Implementierung: kein Test las die beiden Rechen-Shader, und
/// weil `RS_WATER_GPU` standardmäßig aus ist, fuhr sie auch kein Laufzeitpfad.
///
/// Der Plan liegt jetzt HIER einmal: der CPU-Pfad liest seine Pass-Zahlen aus
/// ihm, die Brücke reicht ihn nach GDScript, und der Godot-Vertragstest
/// `game/tests/water_gpu_tail.gd` vergleicht CPU- und GPU-Feld nach demselben
/// Lauf (Wächter für die Struktur: `SimCoreTests/WaterTailPlanTests.swift`).
/// GDScript und die beiden Rechen-Shader halten keine eigene Kalibrierzahl;
/// die Shader deklarieren ihre Uniforms default-frei (dasselbe Verfahren wie
/// bei den `water_*`-Uniforms seit #92: ein Literal-Default wäre wieder die
/// Kopie).
///
/// Keine dieser Zahlen ist ein Physik-Regler: Sie beschreiben, WIE das Feld
/// geglättet wird, nicht, wo Wasser ist. Die Schwellen des Wasserfelds bleiben
/// im Vertrag `SimCore.WaterRender` und wirken CPU-seitig, BEVOR das Feld
/// entsteht (Begründung am Kopf von `water_field_blur.gdshader`).
public enum WaterTailPlan {

    /// Blur-Pässe des FLUSS-Kanals (R = Intensität): EIN Pass. Die Kern-
    /// Intensität dünner Läufe muss voll bleiben — max(Kern, Blur) statt reinem
    /// Blur —, nur die Ränder bekommen den weichen Saum, den `terrain.gdshader`
    /// smoothstept; ein zweiter Pass würde auch den Kern verbreitern.
    public static let streamBlurPasses = 1

    /// Blur-Pässe des SEE-Kanals (G = Sichtbarkeits-Gate): ZWEI Pässe. Das Gate
    /// muss den seichten Ufersaum überdecken (Wassersäule unter der
    /// `rawWet`-Schwelle), damit die per-Pixel-Kontur im Shader dort nicht vom
    /// Gate abgeschnitten wird; der Überstand aufs Trockene ist unsichtbar, weil
    /// `pond` dort 0 ist (Begründung am Aufruf in `WaterFieldRenderer.bytes`).
    /// Der Saum der Schutzmaske (`WaterRender.protectSeamCells`) deckt genau
    /// diese zwei Pässe — auch im GPU-Betrieb, wo die CPU sie auslässt.
    public static let lakeBlurPasses = 2

    /// Länge der Blur-Kette: der größere der beiden Kanal-Werte. Ein Pass, der
    /// für einen Kanal über seinem Einzelwert liegt, trägt für ihn die leere
    /// Maske und reicht ihn unverändert durch die Kette.
    public static var blurPassCount: Int { max(streamBlurPasses, lakeBlurPasses) }

    /// Kanal-Maske eines Blur-Passes: x = Fluss-Kanal (R), y = See-Kanal (G).
    /// 1 = dieser Pass glättet den Kanal, 0 = er reicht ihn unverändert weiter.
    /// Die Fließrichtung (BA) wird NIE geglättet — sie ist eine Richtung, kein
    /// Deckungsgrad; ihre zeitliche Glättung macht erst die EWMA.
    public static func blurMask(pass: Int) -> (Double, Double) {
        (pass < streamBlurPasses ? 1.0 : 0.0,
         pass < lakeBlurPasses ? 1.0 : 0.0)
    }

    /// Flache Masken-Tabelle für die Brücke: 2 Werte je Pass (R, G) in Pass-
    /// Reihenfolge. GDScript baut daraus die SubViewport-Kette, ohne eine
    /// eigene Maske zu kennen.
    public static func blurMasks() -> [Double] {
        (0..<blurPassCount).flatMap { pass in
            [blurMask(pass: pass).0, blurMask(pass: pass).1]
        }
    }

    /// Blende des ERSTEN Ticks der GPU-Kette: 1.0 = das erste Feld sofort
    /// übernehmen. Die CPU-Fassung erreicht dieselbe Regel über den Aufrufer —
    /// Neugenerieren, Laden und Sprünge liefern blend 1.0 (nicht-timelapse
    /// Auslöser, `RenderState.frame`), und die CPU-EWMA übernimmt das erste
    /// Feld vollständig; blende sie aus ihrem 0-Zustand heraus, fiele das
    /// erste Bild auf einen Bruchteil der Deckkraft. Die GPU-Kette kann den
    /// ersten Takt nicht beim Aufrufer primen (ihr Gedächtnis sind die
    /// Zustands-Targets, kein Funktionsargument), deshalb steht die Regel
    /// hier als DATEN: die Kette setzt sie am ersten Update statt am Blend-
    /// Argument. Der Godot-Vertragstest hält den Beleg, dass ein erster Takt
    /// mit kleiner Blende trotzdem das volle Feld übernimmt.
    public static let primeBlend = 1.0
}
