# Produktions-Konfiguration als ein benannter Wert über dem Core-Default

`SimConfig.production` ist die Konfiguration, die in Produktion wirklich läuft: `SimConfig()` plus zwei reine Laufzeit-Schalter (Issue #97). Vorher lag sie in sechs handgepflegten Kopien (Brücke, Mess-Harness, vier Teststellen), nichts verband sie, und `SimConfig()` allein fuhr nirgends.

Die Schalter werden bewusst nicht zu Defaults (AGENTS.md „Drei Konfigurations-Ebenen“):
- `hydraulicSkipWaterSpawns` verwirft Ozean-Start-Tropfen. Das ist NICHT bit-neutral: nur im TIEFEN Wasser (`hf−h > poolDepth`) stirbt ein solcher Tropfen wirkungslos im Pool-Zweig, auf dem flachen Schelf läuft er los und erodiert (sein Pinsel reicht bis auf Küstenzellen). Über das veränderte Abflussfeld erreicht die Abweichung sofort das Land; es entsteht eine andere, statistisch gleichwertige Welt-Realisierung (gemessen und in beide Richtungen gepinnt: `SimCoreTests/PerfFlagAB.swift`, Issue #90). Die Produktion akzeptiert das für die gesparte Laufzeit; die bestehenden Kalibrierungen und Testkonfigs stehen auf dem Core-Default `false`, als Default zöge der Schalter sie alle mit.
- `meanderSpatialCutoffIndex` beschleunigt lange Läufe. Der Referenzpfad bleibt Core-Default, weil seine exakte Cutoff-Reihenfolge die bestehenden Terrain-Metriken kalibriert.

`enableProductionPerformance()` setzt dieselben Schalter auf eine andere Basis-Config, für produktionsnahe Messreihen mit abweichender Auflösung oder eigenem κ (`SimCoreTests/EndorheicEvaporation.swift`); das Delta zum Core-Default bleibt eine Ableitung statt einer siebten Kopie.

`productionSettleYears` 3000: Einlauf der Generierung im Produktionslauf (so viele Jahre echte Sim-Physik direkt nach dem Aufbau, Uhr danach auf 0; Begründung und A/B-Bilder: `Terrain.generate(seed:settleYears:)`, PR #106). Kein Config-FELD, weil der Einlauf einmalig wirkt und nicht im Spielstand weiterlebt; er steht trotzdem hier, damit die gesamte Abweichung der Produktion vom Core-Default an einer Stelle ablesbar ist (`generate`-Default 0: SimCore-Testwelten bleiben unverändert). Der Mess-Harness liest ihn bewusst nicht, er fährt seinen eigenen Einlauf über `--warmup`.

Betrifft: `SimConfig.production`, `SimConfig.enableProductionPerformance()`, `SimConfig.productionSettleYears`, `SimConfig.hydraulicSkipWaterSpawns`, `SimConfig.meanderSpatialCutoffIndex`, `SimCoreTests/PerfFlagAB.swift`
