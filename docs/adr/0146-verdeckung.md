# Große Läufe zuerst, keine Bänder übereinander

Bänder werden in absteigender Reihenfolge des Spitzen-Abflusses gebaut, bei Gleichstand nach Kanal-Index (der Bau bleibt deterministisch). Jedes Band blendet dort aus, wo ein FRÜHER gebautes schon deckt (`bandCoverage` hält während des Baus nur die früheren; `WaterRender.ribbonOcclusionLo/Hi`). Zwei halbtransparente Bänder addierten sich sonst zu dunklen Blöcken und Stößen an Zusammenflüssen, Delta-Fächern und Stummel-Kanälen auf demselben Bett. In Abfluss-Reihenfolge endet so der Zubringer am Hauptlauf statt umgekehrt, und Stummel-Kanäle auf demselben Bett verschwinden unter dem Lauf, den sie doppeln.

Betrifft: `RiverRibbonRenderer.build`, `RiverRibbonRenderer.emitRibbon`, `WaterRender.ribbonOcclusionLo`, `WaterRender.ribbonOcclusionHi`
