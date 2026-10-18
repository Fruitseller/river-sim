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

/// Kopplungs-Takt der alten Aging-Realisierung: je Aufruf, vor der Korrektur
/// des Zeitraffer-Takts in #174. `TerrainAging` prüft das Abklingen der Hebung
/// auf seiner alten Großform, nicht die Gürtel-Kalibrierung. Bei dt 500
/// verschiebt der feste 1000-Jahr-Takt die Kurve dort auf robust 0,1157 bei
/// 50k → 0,1133 bei 100k, die zweite Hälfte fällt nur noch um 2,1 %.
/// Die Produktions-Gürtel-Statistik hat ihren eigenen dt-Wächter.
let calibrationBeltCouplingYears: Double = 0

/// Kalibrierung des kleinen Kopplungs-dt-Wächters, wie die bereits gepinnte
/// Migrationsnumerik in MeanderBeltTests: das Wachstum steigt mit Rate/L².
/// Die Produktionspaarung 0,03/0,9 wächst rund viermal schneller und streut
/// auf n=128 stark mit der libm (Linux: Sinuosität 1,11/1,16/1,33).
/// Die Produktions-Abnahme läuft getrennt auf n=720 über 24 Seeds.
let calibrationBeltDtRate: Double = 0.02
let calibrationBeltDtKernelWidths: Double = 1.5

/// Render-Paarung vor der neuen Gürtel-Kalibrierung, nur für die Waldsperre
/// (`CanopyTests.testNoForestOverRiversLakesOrBands`): die Produktionspaarung
/// 0,85/geteilt füllt auf ihrer kleinen Testwelt den See (0 sichtbare
/// Seezellen), der Test braucht die Wasserfläche als Prüffläche, keine
/// bestimmte Gürtel-Realisierung. Der Mündungs-Wächter läuft dagegen auf der
/// ausgelieferten Konfiguration.
let calibrationBeltRenderKernelWidths: Double = 1.0
/// Bisherige Profil-Integration der Render-Paarung und der alten Aging-Welt.
/// Aging mit geteiltem Profil: robust 0,1182 → 0,1143 von 50k bis 100k,
/// statt der bisherigen 0,1318 → 0,1177; der Hebungs-Wächter bleibt gepinnt.
let calibrationBeltSymmetricStamp = false

/// Gleichgewichtslinien-Temperatur des Eises (°C) der Testwelten, gegen die die
/// Eis-WÄCHTER dieser Suite kalibriert sind: der Stand vor der Entkopplung der
/// Firn-Grenze von der 0-°C-Isotherme in Issue #174 (Produktion seitdem
/// `SimConfig.iceFirnTemp`, kälter als 0 °C).
///
/// Dieselbe Doktrin wie `calibrationRangeLandform`: mit 0 °C liegt die Firn-Grenze
/// bei 0.5731, knapp unter den Gipfeln der alten Großform, an der Eis, V→U-
/// Kennzahl und Aging gemessen wurden. Mit der Produktions-Grenze (≈ 0.65) trägt
/// dieselbe Testwelt (n = 96…384, alte Großform, gealterte Gipfel bei ~0.6) kein
/// Eis mehr, die Wächter hätten nichts zu messen. Schnee, Waldgrenze und
/// Niederschlagsphase hängen NICHT daran (die 11 °C Meeresspiegel-Temperatur sind
/// unverändert). Die PRODUKTIONS-Kalibrierung hat ihren eigenen Wächter
/// (`GlacierCrestShape.testProductionCrestCarriesGlaciersNotACap`).
let calibrationIceFirnTemp: Double = 0

/// Delta-Schüttung der Testwelten (`SimConfig.deltaTrapFraction`, Issue #174,
/// Punkt 26): aus, der Stand vor dem Pass (0 = bit-identisch zum Stand davor).
///
/// Dieselbe Doktrin wie `calibrationRangeLandform`: der Pass baut an den
/// Mündungen neues Land knapp über dem Meer und verschiebt damit die
/// Realisierung jeder Testwelt mit großer Mündung. Auf dem Mac blieben die
/// Mechanik-Wächter grün, auf dem Linux-Runner (andere System-libm, andere
/// Realisierung) kippten mit dem Pass drei, alle knapp und keiner an seiner
/// Mechanik: `testLeversKeepTheChannelIncised` (Summe ×1,19 statt > 1,20),
/// `testGlaciatedValleysWidenTowardsU` (Breiten-Kennzahl 1,213 gegen 1,194
/// ohne Eis, gefordert + 0,1) und `testHardnessContrastHoldsSlopeBreak`
/// (Referenzarm 0,085 statt < 0,08). Gepinnt sind diese drei plus die Tests,
/// die schon mit dem Pass eigene Gründe dafür hatten (`grep
/// calibrationDeltaTrapFraction`). Die Delta-Mechanik selbst prüfen
/// `DeltaTests` und `RiverDelta` auf der Produktions-Kalibrierung.
let calibrationDeltaTrapFraction: Double = 0

/// Lawinen-Abgang des Firns (`SimConfig.iceAvalancheSlopeHi`) der Testwelten, gegen
/// die die Eis-WÄCHTER dieser Suite kalibriert sind: aus (0), der Stand vor dem
/// Abgang (Issue #174, `docs/glacier-measurements.md` §M).
///
/// Dieselbe Doktrin wie `calibrationIceFirnTemp`: die Mechanik-Wächter laufen auf
/// der alten Großform mit Firn-Grenze 0.5731, auf der FAST JEDE Zelle über der
/// Grenze steil ist (die Gipfel der alten Grate); mit dem Abgang wandert dort die
/// gesamte Zufuhr an den Hangfuß, Eis- und Sediment-Bilanz sind eine andere Welt
/// (gemessen: 8 Wächter kippten, u. a. Zungenlänge, Moränen-Aus, Schrittpaar-Fläche
/// 11 %). Die PRODUKTION hat ihre eigenen Wächter
/// (`GlacierCrestShape.testProductionPeaksStandAboveTheFirnLine`,
/// `Glacier.testIceIsFramerateIndependentInProduction`).
let calibrationIceAvalancheSlopeHi: Double = 0

extension SimConfig {
    /// Eis-Physik der Mechanik-Testwelten: der Stand VOR dem Lawinen-Abgang
    /// (`calibrationIceAvalancheSlopeHi`) UND vor der breiteren Schleifspur
    /// (`iceErodeSwathRadius` 2 statt 4, `iceErodeK` 1e-4 statt 1.05e-4, #174 §M).
    /// Die Schleifspur gehört zur selben Änderung: auf Linux (andere System-libm,
    /// andere Realisierung) kippten `testMeanderOxbowSiltsUp` und
    /// `BarMaterialTests.testRibbonEndsTaperToAPointAndKeepAContinuousWidth` mit
    /// den neuen Standardwerten, auf dem Mac blieben sie grün — Realisierungs-Glück
    /// kleiner Testwelten, nicht ihre Mechanik.
    mutating func pinIceBeforeAvalanche() {
        iceAvalancheSlopeHi = calibrationIceAvalancheSlopeHi
        iceErodeSwathRadius = 2
        iceErodeK = 1e-4
    }
}

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
    config.iceFirnTemp = calibrationIceFirnTemp
    config.pinIceBeforeAvalanche()
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
