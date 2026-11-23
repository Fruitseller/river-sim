# Einwachsen und Versiegen von Armen in Sim-Jahren

Die Gürtel-Kopplung (#187) setzt die Läufe neu zusammen. Damit das im Zeitraffer nicht springt, hält der Band-Renderer die Übergänge in Sim-Jahren (Befund Punkt 50, #174): neue Arme wachsen ein (`WaterRender.ribbonGrowYears`), verlassene versiegen als eingefrorener Vor-Kopplungs-Stand (`WaterRender.ribbonGhostYears`). Wächter: `TimelapseTransitionTests`.

Ausgewachsen: `matureCoverage` hält die Deckung des letzten Baus NUR durch ausgewachsene Stücke (Wachstum 1). Ein frisch eingesetzter Knoten, der darin liegt, war schon Wasser und gilt als ausgewachsen. Jedes sichtbare ausgewachsene Stück deckt voll (auch ein schwach deckender Bach war schon Fluss). Auch ausgewachsene, aber unter einem früheren Band verdeckte Stücke tragen ein; sonst zählte ein Knoten, den die Kopplung dort einsetzt, als neu, und seine Deckkraft 0 zöge über die Längs-Glättung die sichtbaren Nachbarn mit herunter.

Übernommene Strecken: Die Kopplung macht auch ÜBERNOMMENE Strecken sichtbar (Rang, Kohärenz und Verdeckung hängen am ganzen Lauf); gemessen um Jahr 21.000, Seed 1337: 1,65 % des Landes neu gedeckt aus übernommenen Knoten, 0,04 % aus eingesetzten. Auch sie wachsen ein; `youngYear` trägt je Zelle das Sim-Jahr der Kopplung durch die folgenden Bauten. Nur nach einer Kopplung (jüngeres `RiverChannel.born` seit dem letzten Bau) wächst ein, was der vorige Bau nicht zeigte; sonst wäre jede vorlaufende Kante eines wandernden Bogens „neu".

Geburtsjahr der Stützpunkte wird wie in `MeanderState.resample` interpoliert: linear, neben −∞ das des näheren Knotens.

Reihenfolge: Das Wachstum wirkt erst NACH der Längs-Glättung der Deckkraft. Ein junger, ohnehin unsichtbarer Stützpunkt zöge sonst ausgewachsene Nachbarn mit herunter (im Wächter 5 % Deckung eines fertigen Flusses). Die Naht glätten danach `limitAlphaSteps` und der Breiten-Begrenzer.

Versiegende Arme werden ZULETZT emittiert, damit die Verdeckung in `emitRibbon` sie überall dort ausblendet, wo heute ein Band liegt; sichtbar bleibt nur, was der neue Stand nicht mehr deckt. Er deckelt das Raster und schützt vor Wald wie jedes Band, solange er zu sehen ist. Ausgegeben werden nur Stücke, die kein heutiges Band verdeckt (dieselbe Verdeckung, vorab geprüft): ein ganzes altes Netz je Bau kostete Bau-Zeit und Mesh-Größe für fast nur unsichtbare Dreiecke.

Solange ein Band einwächst oder versiegt (`inTransition`), baut `RenderState` auch ohne Knoten-Bewegung neu, sonst blieben die Übergänge stehen.

Betrifft: `RiverRibbonRenderer.matureCoverage`, `RiverRibbonRenderer.youngYear`, `RiverRibbonRenderer.ghosts`, `RiverRibbonRenderer.inTransition`, `RiverRibbonRenderer.build`, `RiverRibbonRenderer.emitRibbon`, `RiverRibbonRenderer.stampCoverage`, `WaterRender.ribbonGrowYears`, `WaterRender.ribbonGhostYears`, `WaterRender.ribbonGrowVisibleCoverage`, `RenderState`
