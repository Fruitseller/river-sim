# Raster-Wasser unter Bändern: nur in Band-Lücken, Deckel folgt nur der Band-Deckung

Review #181 hat drei Fehler im Zusammenspiel von Raster-Wasser und Band-Geometrie beseitigt; die Regeln daraus:

- Das Abfluss-Vertrauen (`ribbonTrust`) malte einen großen Lauf im Raster auch dort, wo ein Band ihn trägt. Die D8-Treppe stand als zweites Wasser unter und neben dem glatten Band. Das Vertrauen gilt deshalb nur noch in den Lücken des Bands. Ein kleiner Lauf ohne Stream-Map-Stütze bleibt unsichtbar; die Stütze filtert weiter verwaiste Linien.
- Der Raster-Deckel unter einem Band hatte eine eigene Kaskaden-Ausnahme über die Zell-Neigung. Die sah auch das Quergefälle einer Talflanke und ließ das Raster unter einem voll deckenden Band stehen (doppeltes Wasser in Zellblöcken). Die Kaskade blendet jetzt das Band selbst aus, der Deckel folgt nur noch der Band-Deckung, auch am Steilhang.
- Wo die Sim einen Lauf vor einer Steilstrecke enden lässt, malt das Raster weiter; das Band endete dort mit voller Breite über 2 Zellen, also rechtwinklig abgeschnitten. Auf der Mündungs-Kette sprang die Breite zwischen Knick- und Mittelpunkten (versetzte Blöcke). Ein Band läuft an Land deshalb spitz aus, seine Halbbreite ändert sich je Zelle höchstens um `ribbonMaxHalfWidthSlope`. An der Mündung regelt die Übergabe über die Wassersäule.

Betrifft: `WaterFieldRenderer`, `RiverRibbonRenderer`, `WaterRender.ribbonTrust`, `WaterRender.ribbonMaxHalfWidthSlope`, `WaterRender.cascadeSlopeLo`
