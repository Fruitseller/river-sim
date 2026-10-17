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

/// Großform der Testwelten, gegen die die MECHANIK-Wächter dieser Suite
/// kalibriert sind: die Form vor Issue #174 (Grate über die ganze Landfläche).
///
/// Dieselbe Doktrin wie `calibrationWorld` und `meanderCfg()`: Wächter einer
/// Mechanik pinnen die Welt, an der ihre Schranken gemessen wurden, statt mit
/// jeder Produktions-Kalibrierung neu geeicht zu werden. Belegt beim Umstieg
/// auf `rangeLandform` (Issue #174): 27 Tests in 12 Dateien kippten, und zwar
/// nicht an ihrer Mechanik, sondern an ihrem Testaufbau — die neue
/// Seed-1337-Welt entwässert über Täler zum Meer und hat bei n = 96…384 keine
/// abflusslosen Becken mehr („kein nennenswertes Becken", „keine
/// Salzpfanne"), kaum Seen (die Seeanteil-Vergleiche der dt-Wächter teilen
/// dann 0,0001 durch 0,005), keine Schlingen im Lauf, auf n = 96 keine
/// sichtbaren Flussbänder, und ihr Relief plateaut über 100k Jahre früher
/// (`TerrainAging`). Gepinnt sind genau die Konfigurationen dieser Tests
/// (`grep calibrationRangeLandform`); `LongRunCollapse` und alle übrigen
/// Wächter laufen auf der neuen Form.
///
/// Zwei Befunde dabei waren KEIN Testaufbau und stehen in
/// `docs/zielbild-measurements.md` § Offene Befunde: die Eismasse hing in der
/// Produktion schon VOR #174 deutlich an der Schrittweite (dt 100 gegen
/// 1000) — inzwischen behoben, Ursachen und neuer Wächter in
/// `docs/glacier-measurements.md` §L —, und die Stream-Map trackt auf der
/// neuen Form nur 15 % statt > 40 % der großen Läufe
/// (`testStreamMapMarksAndPersists`, n = 256; offen).
///
/// Wer einen Wächter auf die neue Großform umzieht, sucht sich dort einen Seed
/// mit dem gebrauchten Merkmal und misst die Schranke neu — nicht umgekehrt.
/// Die Produktions-Kennzahlen der Großform selbst stehen in
/// `ZielbildMetrics`/`docs/zielbild-measurements.md`, nicht hier.
let calibrationRangeLandform = false

/// Mäander-Mechanik der Testwelten: die Zentrumslinie VOR dem Mäandergürtel
/// (Issue #174, Paket B). Dieselbe Doktrin wie `calibrationRangeLandform`. Der
/// Gürtel zählt Abfluss und Breite in ZELLEN (Breite aus
/// `WaterRender.ribbonHalfWidthCells`, Mindestabfluss `meanderBeltMinCells`),
/// kalibriert auf das Produktionsgitter (Zellgröße 0,156). Auf den Testgittern
/// der Suite (n = 96…256 mit `calibrationWorld`, Zellgröße 0,5–1,4) erreicht
/// kaum ein Lauf den Mindestabfluss: gemessen „Läufe mäandern nicht mehr"
/// (Sinuosität 1,0008), keine Altarme, keine Schlingen. Die Gürtel-Mechanik hat
/// eigene Wächter (`MeanderBeltTests`, `ZielbildBeltTests`).
let calibrationMeanderBelt = false

/// Produktionsphysik in kleiner Auflösung, mit der Kalibrier-Paarung dieser
/// Suite: der Standard-Zuschnitt der Render-Wächter (`SimRenderTests`,
/// `RenderStateTests`). Genau der Fall, für den `calibrationWorld` oben steht —
/// `n` gesenkt, `world` bewusst mitgesetzt.
///
/// Für künstlich leere Test-Terrains (`n <= 1`) liefert `SimConfig.cellSize`
/// defensiv 0; `world` wird hier für `n <= 1` ebenfalls auf 0 gesetzt.
func renderConfig(n: Int = 96) -> SimConfig {
    var config = SimConfig()
    config.n = n
    config.world = n > 1 ? calibrationWorld : 0
    config.rangeLandform = calibrationRangeLandform
    return config
}

/// Testwelt nach `years` Jahren in 1000er-Schritten, Abfluss frisch berechnet:
/// die Altersstufe, ab der Mäander, Bänder und Seen sichtbar sind. Gemeinsam
/// für die Render-Wächter (`WaterRendererTests`, `WaterProtectMaskTests`).
func agedWorld(_ config: SimConfig, years: Double, seed: UInt32 = 1337) -> Terrain {
    let terrain = Terrain(config: config, seed: seed)
    while terrain.years < years {
        terrain.step(dtYears: min(1000, years - terrain.years))
    }
    terrain.computeFlow()
    return terrain
}
