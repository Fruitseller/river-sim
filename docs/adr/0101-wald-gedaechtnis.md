# Gedächtnis der Waldmaske in Sim-Jahren

Die Waldmaske springt nicht mit jedem Takt auf ihr Ziel (Issue #167, `ForestCanopyMask.regrow`). Kommt Wasser, ist der Wald sofort weg (kein Kronendach über Wasser); zieht es sich zurück, wächst er mit einer Zeitkonstante in Sim-Jahren nach. Verschwindet er ohne Wasser, weicht er mit einer kurzen eigenen Zeitkonstante.

## Nachwachsen (`regrowYears` = 800)

Gemessen mit `testCanopyChurnDiagnostic` (Seed 1337, Jahr 100.000, Schwellen nach #168, Maske alle 25 J., Bänder im Produktionsdeckel, Umkippen über 0,5 je 100-Jahr-Takt in % Land): τ = 0 (vor #167) 0,64 %, 300 J. 0,38 %, 500 J. 0,32 %, 800 J. 0,26 %, 1200 J. 0,23 %; ganz ohne Schutzmaske und ohne Gedächtnis 0,30 % (nur die Sim-Vegetation). Das Gedächtnis dämpft also auch das Nachwachsen der Sim-Vegetation, nicht nur die wandernden Bänder. 800 J. kostet 1,3 Punkte Waldanteil (19,2 → 17,9 %); darüber wird es kaum ruhiger, der Auengürtel nur breiter. Ticket-Ziel: höchstens die Hälfte von vorher (≤ 0,32 %). Bei 60 J/s sind 800 J. gut 13 s Zeitraffer. Vor #168, mit mehr Wald: 0,91 % → 0,40 %. Ufernah gilt die kürzere `riparianRegrowYears` (s. Galeriewald).

## Rückzug ohne Wasser (`retreatYears` = 60)

Vor allem unter einem frisch eingesetzten Arm rodet die Sim das Bett sofort (`veg = 0` im Gürtel-Stempel), während das Band erst über `WaterRender.ribbonGrowYears` einwächst. Sofort weg war der Wald dort im Kopplungstakt fleckweise auf einen Schlag (Befund Punkt 50: Wald 11–18× eines normalen Takts). Wo die Schutzmaske Wasser meldet, weicht er weiter sofort. 60 J. ist etwa ein Drittel des Einwachsens: der Wald geht, bevor das Band seine volle Breite hat.

## Schwelle für sofortiges Weichen (`retreatInstantBandCoverage` = 0,35)

Die Schutzmaske schützt schon ab `WaterRender.protectBandThreshold` (0,01) plus Saum; für das Ziel richtig, für das sofortige Weichen zu früh: ein frisch eingesetzter, noch unsichtbarer Arm rodete sonst den ganzen Korridor im Kopplungstakt. Erst ab 0,35 Band-Deckung gilt eine Zelle für den Rückzug als Wasser.

Betrifft: `CanopyRender.regrowYears`, `CanopyRender.retreatYears`, `CanopyRender.retreatInstantBandCoverage`, `ForestCanopyMask.regrow`, `RenderState`
