import Foundation

@testable import SimCore

/// Weltkantenlänge, gegen die die per-Zell-Erwartungen dieser Suite kalibriert
/// sind.
///
/// **Wer sein eigenes `n` setzt, muss `world` mitsetzen.** `SimConfig.cellSize`
/// ist `world / (n − 1)`; ein Test, der nur `n` pinnt und `world` aus
/// `SimConfig()` erbt, hängt damit still an der PRODUKTIONS-Paarung. Wandert die
/// (n und world wandern laut AGENTS.md immer zusammen), verschiebt sich die
/// Zellgröße dieses Tests — und mit ihr jede per-Zell-Kalibrierung: Braid-Gates,
/// Droplet-Dichte, kappa-Skalierung, Gletscher-Flux, Lithologie-Kontrast.
///
/// Belegt beim Umstieg 832/130 → 720/112,4789: `world` allein (130 → 100 in der
/// Zwischenprobe, −23 % Zellgröße) ließ fünf Tests kippen, an deren `n` nichts
/// geändert wurde — `testFlattenDropsOldMeanderState`,
/// `testGlaciatedValleysWidenTowardsU`, `testIceIsFramerateIndependent` und die
/// beiden Lithologie-Hangknick-Tests. Mit zurückgesetztem `world` und
/// unverändertem `n = 720` waren alle fünf wieder grün: es war nie die
/// Gittergröße, immer die Zellgröße. Die anderen 59 Stellen blieben nur deshalb
/// grün, weil ihr Abstand zur Schwelle größer war — sie testeten trotzdem eine
/// andere Zellgröße als die, für die ihre Zahlen abgeleitet wurden.
///
/// Der Wert bleibt 130, auch wenn die Produktion woanders steht: er ist der
/// Stand, gegen den die Erwartungen dieser Suite gemessen wurden, keine
/// Produktions-Aussage. Wer ihn ändert, kalibriert die Suite neu.
///
/// Tests, die BEWUSST von der Produktions-Zellgröße abweichen wollen, setzen
/// `world` danach weiter selbst (s. `testDeviatingConfigAndSeedTravelWithTheWorld`).
let calibrationWorld: Double = 130

/// Produktionsphysik in kleiner Auflösung, mit der Kalibrier-Paarung dieser
/// Suite: der Standard-Zuschnitt der Render-Wächter (`SimRenderTests`,
/// `RenderStateTests`). Genau der Fall, für den `calibrationWorld` oben steht —
/// `n` gesenkt, `world` bewusst mitgesetzt.
func renderConfig(n: Int = 96) -> SimConfig {
    var config = SimConfig()
    config.n = n
    config.world = calibrationWorld
    return config
}
