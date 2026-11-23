# Fels, Schutthalden, Bewuchs und Talboden im Material-Render

Issue #174 (Paket D) gibt dem Land die Materialien der Vorlagen: grauer Fels auf steilen, konvexen Formen, Schutthalden darunter, brauner Rohboden nur auf frisch gestörten Flächen, eine helle Talboden-Wiese. Die Schwellen sind gegen Flächenanteile auf den Matrix-Welten gemessen (`testMaterialCoverageDiagnostic`).

## Fels (`rockSlopeLo/Hi` = 1,50/2,60 ≈ 56°/69°, Weltsteigung)

Die Matrix-Welten sind steil (Median der Weltsteigung 0,9–1,3, p90 2,2–2,8); so trifft der Fels die steilsten 13–24 % des Landes. Mit 0,70/1,20 waren es 52–63 %, und der Wald fiel auf ein Viertel. Vor #174 setzte der Fels erst bei `macroSlope` 0,004 ein und lag UNTER der Vegetation, die bis fast in die Senkrechte gewichtet war: unter 1,5 % des Landes trugen Fels, die Hänge lasen sich als brauner Boden mit grünem Schleier. Konvexität (Sim-Höhe minus Mittel der vier Nachbarn im Abstand 2, Welteinheiten) verschiebt die Schwellen bei `convexRef` um `convexSlopeShift`: auf Graten bricht Fels früher durch, in Rinnen später.

## Schutthalden

Die Halde braucht eine Hohlform (`screeConcavity`): ohne diese Bedingung lagen 11–22 % des Landes als Halde da, weil auf den steilen Welten fast jeder Hang in Reichweite einer Wand liegt.

## Bewuchs weicht Mineral (`vegYieldLo/Hi` = 0,4/0,9)

Erst ab diesem Fels- plus Haldenanteil geht die Vegetation zurück; darunter füllen Fels und Schutt nur den unbewachsenen Rest (wie vor #174 der Fels). Ohne diese Stufe kostete jeder Teil-Felsanteil auf den steilen Welten Bewuchs, und der Wald fiel auf Seed 1337 bei Jahr 2000 von 8,5 auf 6,0 % des Landes.

## Eine Zahl für den Bewuchs-Deckel (`vegAmountMax` = 0,78)

Ein bewachsener Hang bleibt zu 22 % Grundton. Die Zahl gilt an ZWEI Stellen im `TerrainColorRenderer`: als Bewuchs-Anteil, der Farbe und Gewicht speist, und als Deckel nach dem Gürtel-Zuschlag (`BarMaterial.vegShift`: Pionier-Grün darf das Gewicht nicht über das heben, was der Bewuchs selbst erreicht). Bis zum Review von #174 standen dort zwei Literale; wer eines änderte, verschob den Deckel gegen den Anteil.

## Makrofarbe unter Fels (`mineralTint`)

Je Gewicht `rock + scree` wandert die Makrofarbe zu diesem Ton, sonst trüge jede Felswand den Grünstich des Habitats (der Shader mischt die Makrofarbe nur zu 28 % unter). Im Ton des Shader-Felses (Befund #174 „Fels zu hell"): mit 0,37 hob die Beimischung allein jede Wand um ein Drittel über ihren eigenen Grauton.

## Relief der Felswände (`rockReliefGain` = 2,5)

Auf Fels verstärkt der Shader die feinen Erosionsrinnen (runevision-Detail, Normale und Abdunklung der Rinnenböden) um diesen Faktor (Befund #174 „Fels zu hell und glatt"). Vorher lag das Detail auf Fels so schwach wie auf Wiese; die Wände lasen sich als glatt verputzte Fläche.

## Talboden-Wiese

Talboden = flach (Weltsteigung unter `valleySlopeLo` voll, ab `valleySlopeHi` nicht mehr) und unterhalb des Nadelwald-Bands (`HeightBands.coniferLow/High`). Zweite Quelle (Maximum): die Aue, also Bänke, deren Sand-Fenster vorbei ist (`Terrain.barAge` über `WaterRender.barSandYearsLo/Hi`), ohne Steigungs- und Höhentor, weil der Gürtel zu 83–97 % über `coniferLow` liegt (`testBarMeadowDiagnostic`).

Betrifft: `MaterialRender.rockSlopeLo`, `MaterialRender.convexRef`, `MaterialRender.screeConcavity`, `MaterialRender.vegYieldLo`, `MaterialRender.vegAmountMax`, `MaterialRender.mineralTint`, `MaterialRender.rockReliefGain`, `MaterialRender.valleySlopeLo`, `SimRender.TerrainColorRenderer`, `BarMaterial.vegShift`
