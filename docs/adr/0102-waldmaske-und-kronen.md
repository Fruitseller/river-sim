# Waldanteil, Lichtungen und Kronendarstellung

Wie viel Land Wald trägt und wie er am Rand ausläuft, ist über mehrere Iterationen gegen Messläufe (`testCanopyCoverageDiagnostic`) und Bewerter-Urteile eingestellt. Ziel: Bestände als Gruppen zwischen Wiesen, Wald auch an Hängen, Lichtungen im Tiefland, keine eckigen Splitter in der Nahsicht.

## Vegetationsschwellen (`vegetationLo/Hi`)

Gemessen wird das Vegetationsgewicht aus `TerrainColorRenderer` (R-Kanal von `surfaces`, höchstens 0,78).

- Studie: 0,14/0,32 lagen tief im unteren Wertebereich; fast jede bewachsene Zelle wurde Wald (Matrix-Seeds bis 43 % des Landes bei Jahr 100.000, Projekteigner: „zuviel Wald").
- #168: 0,35/0,55 halbierte den Anteil auf 9–22 %, dazwischen bleibt Wiese. 0,40/0,60 und 0,45/0,65 nahmen nur 1–6 Punkte mehr weg. `clumpGain` 0,60 statt 0,45 änderte den Anteil um höchstens 0,6 Punkte. Tabelle: `docs/graphics-quality.md` § Wald und Wiese (#168).
- #174 (Großform): Kamm, Hügelland und Ebene bieten mehr bewachsbaren Boden; mit 0,35/0,55 stieg der Wald auf bis 28,6 % (Seed 42, Jahr 2000; 1337: 15–17 %, 20: 15–25 %). 0,40/0,60 hielt 11,8–23,3 % über alle Matrix-Seeds und Jahre (2000/20.000/100.000), also wieder „≤ ~22 %" (Abnahmepunkt 40); 0,45/0,65 hätte 10,4–19,6 % ergeben und die Hänge sichtbar ausgedünnt.
- Look-Iteration 6 (Hill-Climber Problem 2, Seed 1337, Jahr 20.000): mit 0,40/0,60 stand Wald fast nur im Tiefland (Vegetation am Deckel 0,78, 18 % des Landes) als geschlossener Teppich; Hänge tragen 0,1–0,3 und blieben Wiese. Gewählt 0,15/0,45 mit `clumpGain` 0,55 und großen Lichtungen: 23 % Wald (Maske ≥ 0,5), 32 % mit ausfransendem Saum (≥ 0,2). Gemessen: 0,22/0,50 18 %, 0,12/0,42 26 %.

## Lichtungen

Feines Rauschen (`clump*`) verschiebt die Vegetationsschwelle, damit Wald Gruppen bildet. Frequenz in 1/Welteinheit (0,45 ≈ 220 m, 14 Sim-Zellen), Mittelwert 0,47 wird abgezogen. Es ist das Value-Noise-fBm der Studie (`ForestCanopyMask.clumpNoise`); mit Simplex-Rauschen gleicher Frequenz streute der Wald auf mageren Hängen sichtbar mehr kleine Flecken.

Große Lichtungen (`clearing*`, Look-Iteration 6): ein zweites Value-Noise-fBm (0,10 ≈ 1 km) zieht das Lichtungs-Rauschen unter `clearingLo … clearingHi` um bis zu `clearingDepth` nach unten und schneidet so auch in geschlossene Tieflandbestände (wo das feine Rauschen allein nie eine Lücke ließ, „Noppenteppich"). Tiefe 0,8 dünnte das Tiefland nur aus (Maske fiel praktisch nie unter 0,5); 1,3 öffnet es (Wächter `testClearingsCutIntoDenseVegetation`). Schwellen 0,24/0,30 statt 0,26/0,33: mit den höheren legten die Lichtungen ganze Halbinseln kahl.

## Wände

`wallSlopeLo/Hi` in Weltsteigung über `Terrain.macroSlope`; die Per-Zell-Steigung der Studie stanzte Rinnen-Textur als Löcher in den Wald. Erst 1,2/1,8 (≈ 50°/61°), seit Look-Iteration 6 1,4/2,0 (≈ 54°/63°), damit steile Talflanken Bestände tragen; reine Wände bleiben frei (Vegetation dort ohnehin nahe 0).

## Wiese (#168)

Bewachsener Boden ohne Wald liest sich als Wiese: ab `meadowLo` wird ein Teil des Bodenanteils grün, ab `meadowHi` der volle Anteil `meadowShare`. Ohne das trug ein Gewicht von 0,3 nur 30 % Grün, und mit den angehobenen Wald-Schwellen standen die frei gewordenen Flächen als Sand da. Fels und Schnee bleiben unberührt.

## Dach und Kronen (Shader)

- `liftLo/Hi` 0,7/0,95 statt 0,2/0,65 (Look-Iteration 6): mit dem breiten lichten Saum zog die Anhebung je Sim-Zelle Dreieckswände und Zeltspitzen einzelner Zellen hoch (0,45/0,85 ließ sie noch stehen). Einzelbäume und Gruppen am Rand liegen flach gemalt, nur der dichte Bestand trägt das Dach; seine Seitenwände malt der Shader dunkel. Der Shader hebt nach der über ~4×4 Zellen geglätteten Maske (höchstens der eigenen).
- `liftSmoothTexels` 1,5: Abstand der vier diagonalen Abgriffe der Glättung (bilinear ≈ 4×4 Zellen). `Main._forest_lift_at` rechnet mit demselben Wert nach, damit Pinselkuppel, Raycast und Kameraziel am Bestandsrand auf dem Dach liegen (Review Neon Nr. 2; Wächter `game/tests/canopy.gd`).
- `gapLo/Hi`: 0,35/0,75 malte im breiten Saum dunkle Bodenkacheln mit den geraden Dreieckskanten (Maske je Dreieck linear); 0,55/0,9 ließ mit gruppierten Kronen Gruppen auf heller Wiese als Noppen stehen; 0,45/0,8 schließt sie mit grünem Unterwuchs. Der Shader verwackelt die Maske für Lücken- und Deckungsfenster zusätzlich je Pixel.
- `crownMid/crownSpread`: eine Krone steht nur, wo die Maske ihre eigene Schwelle übertrifft, damit der Wald am Rand kronenweise ausdünnt. Seit Look-Iteration 6 liest der Shader die Maske an der Kronenmitte (vorher je Pixel: Randkronen wurden durchgeschnitten), und die Streuung kommt zu gut zwei Dritteln aus dem Bestands-Rauschen statt je Krone, damit am Rand Gruppen stehen. 0,45 setzte einzelne Noppen auf die Wiese, 0,55 dünnte die Gruppen zu stark aus.

Betrifft: `CanopyRender.vegetationLo`, `CanopyRender.clump*`, `CanopyRender.clearing*`, `CanopyRender.wallSlopeLo`, `CanopyRender.meadow*`, `CanopyRender.liftLo`, `CanopyRender.liftSmoothTexels`, `CanopyRender.gapLo`, `CanopyRender.crownMid`, `SimRender.ForestCanopyMask`, `Main._forest_lift_at`, `game/shaders/terrain.gdshader`
