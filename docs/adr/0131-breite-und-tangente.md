# Bandbreite am Krümmungsradius gedeckelt, Tangente mit Rückfallkette

Die gemalte Halbbreite je Stützpunkt wird am Krümmungsradius (Menger-Krümmung durch drei Stützpunkte, × `WaterRender.ribbonCurvatureWidthFactor`) gedeckelt, sonst falten sich die Quads an engen Schlingen zu Dreiecks-Fächern. Danach wird die Änderung je Bogenlänge begrenzt, nur nach unten (`ribbonMaxHalfWidthSlope`): sonst wechselten gedeckelte Knick- und ungedeckelte Mittelpunkte der Mündungs-Kette ab, und das Band zerfiel in versetzte Blöcke.

Die Tangente kommt aus der zentralen Differenz, die die Richtung über den Stützpunkt glättet. Sie degeneriert aber an Haarnadeln: Vorgänger und Nachfolger liegen fast aufeinander, die Differenz ist ~0 und mit ihr die Quer-Richtung. Beide Bandkanten fielen auf die Mittellinie, die anschließenden Quads strahlten als Fächer spitzer Dreiecke weg (Nutzer: „das Wasser der Flüsse besteht teilweise aus hässlichen Dreiecken"; reproduziert an verknäulten Läufen der Tiefebene, Seed 1337, Jahr 20 000). Daher die Rückfallkette: vorwärts, rückwärts, zuletzt eine feste Richtung. Ein Band hat immer eine Quer-Richtung.

Betrifft: `RiverRibbonRenderer.emitRibbon`, `RiverRibbonRenderer.curvatureRadiusCells`, `WaterRender.ribbonCurvatureWidthFactor`, `WaterRender.ribbonMaxHalfWidthSlope`
