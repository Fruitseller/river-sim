# Intensität des Raster-Flusses: Track-Maske, Kontinuität, Legacy-Stempel

Der dendritische Teil des Wassers (alles unterhalb der Mäander-Entitäten) entsteht als Raster: Stream-Map × MFD-Abfluss → Intensität → Verbreiterung.

Track-Maske (Stream-Map = zeitgemittelte Tropfenpfade): `trackMaskLo` 0,18 bis 0,42, angehoben von 0,12…0,35, damit Zufallspfad-Speckle darunter bleibt und konsistente Läufe darüber liegen. Die Fenster sind als SPANNE notiert, nicht als Obergrenze: `0.42 − 0.18` ist in Double nicht exakt `0.24`; ein aus lo/hi berechneter Divisor würde das Feld gegenüber dem Stand vor #51 verschieben. Dasselbe gilt für `lakeDepthSpan`, `ribbonSupportSpan`, `corridorTrackSpan` und `cascadeSlopeSpan`.

Der Korridor-Stempel der Mäander hat ein eigenes, tieferes Fenster (`corridorTrackLo` 0,1, Spanne 0,2): der Korridor IST per Definition ein echter Lauf; wo dem gestempelten Bett real kein Wasser folgt (verwaiste/verknäulte Linien), verblasst er nur, statt voll zu leuchten.

Kontinuität: die Intensität wird entlang des D8-Empfängers bergab propagiert und verliert `continuityDecayPerCell` (0,015) je Zelle; ohne den Pass zerfielen gealterte Läufe zu Punktketten, wo die Track-Maske Lücken lässt. Der Abfall wird auf `continuityFloor` (0,3) GEKLEMMT und die Kette läuft bis zum offenen Wasser durch. Vorher endete sie an dieser Grenze; eine Quelle knapp darüber trug nur ≈ 7 Zellen weit, sichtbare Läufe rissen ab („kein zusammenhängender Lauf“). Der Boden muss über `riverMaskLo` bleiben, sonst wird die garantierte Kette unsichtbar. Quellen unter dem Boden propagieren nicht (kein Speckle-Verstärker).

Legacy-Stempelpfad (`RS_WATER_STAMP`): ohne Band-Geometrie malt das Wasserfeld die Mäander selbst. Der Pfad ist seit #34 nicht mehr Standard, aber der einzige A/B-Vergleich gegen die Geometrie; seine Kalibrierung gehört deshalb genauso in den Vertrag. Der Deckel der Stempel-Halbbreite wurde von 3 auf `stampHalfWidthCapCells` 1 gesenkt: über 10k+ Jahre verknäulen die migrierten Linien auf den Ebenen, breite Stempel machten aus den Knäueln blaue Blob-Felder („zu viele Flüsse“).

Betrifft: `WaterRender.trackMaskLo`, `WaterRender.trackMaskSpan`, `WaterRender.trackMask`, `WaterRender.corridorTrackLo`, `WaterRender.corridorMask`, `WaterRender.continuityDecayPerCell`, `WaterRender.continuityFloor`, `WaterRender.stampHalfWidthCapCells`, `WaterRender.stampHalfWidthCells`, `SimRender.WaterFieldRenderer`
