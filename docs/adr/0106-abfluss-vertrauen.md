# Abfluss-Vertrauen statt Stream-Map-Stütze für große Läufe

Ab `ribbonTrustLoReferences` (3) Vielfachen des Referenz-Abflusses `SimConfig.renderMinCells` braucht ein Band die Stream-Map-Stütze teilweise, ab `ribbonTrustHiReferences` (10) gar nicht mehr (Issue #174, Paket C Teil 2). Die Stütze filtert verwaiste Zentrumslinien; ein Lauf mit so viel Abfluss ist nicht verwaist: seit dem Gürtel (Paket B) liest die Sim den Abfluss je Knoten frisch aus dem Einzugsgebiet (`Terrain.refreshBeltDischarge`), eine verlassene Linie fällt auf wenige Zellen.

Gemessen (Jahr 20.000, Hauptlauf per D8): die Stream-Map trackt die großen Läufe der neuen Großform kaum (Stütze 0,09–0,35 bei bis zu 26.000 Zellen Abfluss); auf Seed 20 fiel der ganze Hauptlauf weg (0 % Band, 85 % Lücke), auf Seed 42 die Hälfte. Seeds 1337/42/20, Lücke im Hauptlauf in %, in Klammern Band-Zellen ohne großen D8-Lauf in 3 Zellen (Gegenprobe Doppelwasser): ohne Vertrauen 5,6/50,3/85,2 (10,6/10,8/11,5); 6×…16× 3,0/27,4/16,6; 3×…10× 3,0/19,6/6,9 (10,2/14,2/13,5); 2×…8× 3,0/18,7/3,9. 3×…10× nimmt den Großteil der Lücken und malt weniger zusätzliche Läufe als 2×…8× (Band-Zellen Seed 1337: 14.166 ohne, 18.123 mit 3×, ~19.900 mit 2×; „zu viele Flüsse“ war eine frühere Klage). Den Strahler-Rang braucht auch ein vertrauter Lauf: eine Ausnahme davon änderte keine Lücke (gemessen) und hätte den Wächter in `river_ribbons.gd` aufgeweicht.

Das Vertrauen gilt auch im Raster (`WaterFieldRenderer`, Track-Maske), sonst blieb die Lücke dort, wo der Hauptlauf keine Zentrumslinie hat; dort aber nur in den Lücken des Bands: es wird mit (1 − größte Band-Deckung im Quadrat ± `ribbonTrustBandClearanceCells`) gewichtet. Ohne die Schranke malte das Raster jeden großen D8-Lauf voll, auch wo ein Band ihn trägt: D8-Pfad und Zentrumslinie liegen bis zu einigen Zellen auseinander, und neben bzw. unter dem glatten Band stand die D8-Treppe als zweites Wasser (Review #181, Draufsicht Seed 42, Jahr 20.000). Anteilig statt binär: wo das Band an Kaskaden oder Enden ausblendet, kehrt das Vertrauen zurück.

Gemessen (Seeds 1337/42/20, Jahr 20.000, mit dem Raster-Deckel ohne eigene Kaskaden-Ausnahme; Lücke im Hauptlauf % | Raster-Fluss unter Band-Deckung ≥ 0,7 % | Raster-Fluss ohne Band in ±3 Zellen eines Bands, Zellen):
- vorher: 3,0/19,6/6,9 | 37,9/32,0/26,9 | 1295/677/651
- 0 Zellen: 3,0/19,6/6,9 | 11,8/9,3/10,4 | 901/508/439
- 1 Zelle: 3,0/19,6/6,9 | 11,6/8,8/10,0 | 863/480/427
- 2 Zellen: 3,0/19,8/6,9 | 11,5/8,2/9,6 | 827/408/398
- 4 Zellen: 3,3/25,7/8,7 | 11,2/7,6/9,2 | 706/261/326

1 Zelle ist der größte Abstand ohne neue Lücke; ab 2 Zellen nimmt die Schranke dem Raster auch Strecken hinter einem Bandende, die das Band nicht mehr malt. Den Großteil des Doppelwassers nimmt der Deckel. Messreihe: `docs/river-belt-render-measurements.md` §C.

Betrifft: `WaterRender.ribbonTrustLoReferences`, `WaterRender.ribbonTrustHiReferences`, `WaterRender.ribbonTrust`, `WaterRender.ribbonTrustBandClearanceCells`, `SimRender.WaterFieldRenderer`, `SimRender.RiverRibbonRenderer`
