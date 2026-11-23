# Raster-Wasser im Mäandergürtel: keine Flecken im Band-Korridor, keine Abkürzungen über Bänke

Befund #174 (Seed 1337, Jahr 2.305, `RS_TARGET="13.8,6.8"`): breite, blockige Wasserflächen quer durch die Schlingen und runde blaue Punkte neben den Bändern (`docs/zielbild-measurements.md` § Raster-Abkürzungen im Mäandergürtel).

Fixture: eine gealterte Welt mit Gürtel, Bänken und Bändern, einmal gebaut. Das Wasserfeld wird als `deferTail`-Ausgabe gelesen, also vor Blur und EWMA, genau das, was die Regeln entscheiden (der Blur verbreitert danach jeden Lauf um eine Zelle, auch auf eine Nachbar-Bank). Gebaut direkt am `RiverRibbonRenderer` (#214), weil nur der Band-Bau gebraucht wird, dazu die Abzweig-Marken `waterDeparture`. Die Fixture ist `nonisolated(unsafe)` (#201): `Terrain`/`RibbonMesh` sind nicht `Sendable`, sie wird einmal gebaut und danach nur gelesen, und XCTest ruft die Methoden einer Klasse seriell auf.

Regeln: das Kohärenz-Gate gilt auch im Band-Korridor, nur der Saum ist ausgenommen; vorher standen Ein- bis Drei-Zell-Flecken neben der Bandkante (150 Flecken, 479 Zellen). Auf einer Gleithang-Bank neben einem Band desselben Flusses malt das Raster nur den Saum: dort ist das Band der Fluss, der D8-Lauf nimmt nur die Abkürzung. Abzweige (`waterDeparture > 0`) sind ausgenommen, weil der Lauf nicht zum Band zurückkehrt: echtes Avulsions-Wasser, das `WaterFieldRenderer` bewusst malt. Mit dem Schwellen-Schnitt (#187) kreuzt auf der Linux-Realisierung ein Abzweig die Bank (39 Zellen, Einzugsgebiet 528–1285 Zellen; Mac kein Abzweig); die Abkürzungs-Regel bleibt scharf.

Betrifft: `RasterBeltTests`, `WaterFieldRenderer`, `RiverRibbonRenderer`
