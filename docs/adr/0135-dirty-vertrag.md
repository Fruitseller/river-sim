# Dirty-Vertrag der Bänder: Knotenpositionen, `nil` als Sentinel

Ob die Bänder neu gebaut werden müssen, entscheidet die maximale Knoten-Verschiebung (Zellen) der Mäander-Zentrumslinien seit dem letzten Bau (`maxDelta`). Verglichen werden Knotenzahlen und Positionen; Abfluss ändert sich nur zusammen mit Positionen (Migration, `computeFlow`), Positionen genügen.

Kein Vergleichspunkt ist `nil`, bewusst NICHT das leere Array: eine Welt ohne Zentrumslinien flacht ebenfalls auf `[]` ab. Mit dem leeren Array als Sentinel meldete `maxDelta` nach einem Weltwechsel auf genau so eine Welt „0 = unverändert", der Rebuild blieb aus, auf dem Schirm standen die Bänder der vorigen Welt, und `bandCoverage` deckelte das Raster-Wasserfeld entlang ihrer Korridore (Löcher im Feld).

`maxDelta` meldet einen „riesigen" Wert (`rebuildSentinel`, weit über `RenderState.ribbonRebuildDelta`) bei Struktur-Änderung (Cutoff, Resample, Neu-Saat, Laden), vor dem ersten Bau und bei nicht-endlicher Differenz: `max(maxD, NaN)` liefert `maxD` und verschluckte NaN sonst. Bleiben Koordinaten nicht-endlich, bleibt der Zustand dirty.

Erwartung: Während die Sim läuft, triggert das praktisch jeden Schritt (`Meander.migrate` resampelt bedingungslos, die Knotenzahl ändert sich). Der Vertrag spart im Pause-, Leerlauf- und Pinsel-Zustand (kein Schritt, Delta exakt 0, kein Rebuild). Im Zeitraffer deckelt `RenderState` den Band-Bau auf 1 Hz (`RenderState.ribbonRebuildSeconds`; gemessen: ein Takt von 0,30 s kostete ~4 % FPS).

Betrifft: `RiverRibbonRenderer.maxDelta`, `RiverRibbonRenderer.markBuilt`, `RiverRibbonRenderer.invalidateSnapshot`, `RiverRibbonRenderer.rebuildSentinel`, `RenderState.ribbonRebuildSeconds`, `RenderState.ribbonRebuildDelta`
