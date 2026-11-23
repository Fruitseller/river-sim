# Nach-Strich-Auffrischung gehört zu Terrain und ist kein Zeitschritt

Die feste Aufruf-Reihenfolge nach einem Pinselstrich (Abfluss → Seespiegel → Klima mit `dt = 0` → Höhenbänder) stand bis Issue #93 in der GDExtension und liegt jetzt als `Terrain.recomputeFlowAfterEdit()` bei ihrem Besitzer, weil sie ausschließlich `Terrain`-Pässe taktet. Nur dort ist prüfbar, dass sie genau diese Reihenfolge fährt: das Ergebnis muss bit-gleich zu den vier Aufrufen von Hand sein (Fingerabdruck über das ganze Zustands-Inventar, `Terrain.fingerprint`).

Der Strich ist kein Zeitschritt: Entwässerung neu, Seespiegel gesnappt, Höhenbänder nachgezogen, aber Sim-Zeit und Schneebilanz bleiben unangetastet (`dt = 0` lässt die Bilanz exakt stehen).

Betrifft: `Terrain.recomputeFlowAfterEdit`, `TerrainAPITests`
