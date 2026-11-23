# Makrofarbe und Materialgewichte: Hierarchie mit Summe höchstens 1

`TerrainColorRenderer` liefert drei RGBA8-Puffer. Die Makrofarbe trägt nur großräumige Sim-Signale (Biom, Salz, Eis); der Shader baut daraus mit `surfaces` und `covers` die Oberfläche. So bleiben Materialgrenzen an die Physik gebunden, ohne die Sim-Zellen als verwaschene Textur sichtbar zu machen. Die geomorphologische Verteilung kalibriert `SimCore.MaterialRender` (Issue #174 D).

Kanal-Layout (Vertrag mit `terrain.gdshader`):
- `colors`: RGB Makrofarbe, A Sandgewicht als `max(Strand, Bank)` (Strand aus `CoastMaterial`, frische Bank aus `BarMaterial`; ein Kanal für beides, der stärkere gewinnt).
- `surfaces`: R Vegetation, G freier Fels, B Schnee/Eis, A Lithologie-Härte (−1 … +1 auf 0 … 1).
- `covers` (#174 D): R Schutthalde, G blankes Gletschereis als Anteil an der Kältedeckung (B von `surfaces`, damit der Shader Eis- und Schneefarbe innerhalb von B mischt), B Rohboden, A Talboden-Wiese (Tönung, kein eigenes Gewicht).

Alle drei Puffer entstehen in einem Aufruf, weil sie dieselben teuren Standortwerte brauchen (`macroSlope`, Habitat, Schnee/Eis); getrennte Callables vervielfachten die Arbeit je Textur-Update. Drei Durchgänge (Felsanteil, separierbarer Maximum-Filter als Quelle der Halden, Farbe und Gewichte), jeder schreibt nur seine Zelle und ist parallel bit-identisch.

Die Gewichte werden hierarchisch abgeschwächt und summieren sich auf höchstens 1, der Rest ist Grund (Shader: Trockenrasen, in der Höhe steiniger Grund). Reihenfolge: Kälte deckt alles; Fels (steil-konvex) vor Halde, Halde vor Rohboden, Rohboden vor Vegetation. Bis #174 stand die Vegetation vor dem Fels und deckte ihn auf jedem bewachsbaren Hang zu. `terrain.gdshader` mischt als Gewichtssumme und verlässt sich darauf; wer die Faktoren ändert, prüft `MaterialTests.testWeightsNeverExceedOne`. Bewuchs weicht erst, wenn Fels und Schutt den Standort überwiegend decken; bis dahin füllt Mineral nur die Lücken (der Wald hängt an diesem Gewicht, #168). Felsküste verdrängt den Rest neben der Kälte, nicht neben 0; sonst summierten sich die Gewichte unter teilweiser Schneedeckung über 1 (Review zu #174 C). Die nasse Wiese (`WetMeadow`) folgt derselben Hierarchie: Kälte bleibt, Vegetation wächst darunter, Fels, Halde, Rohboden und Sand teilen sich proportional den Rest (vorher summierten sich die Gewichte bis rund 1,85, nur Fels wurde gekappt). Sie quantisiert nur geänderte Gewichte neu, weil Byte → Double → Byte unveränderte Werte sonst um eine Stufe abrundet. `WetMeadow` ist ein eigener Schritt nach `TerrainColorRenderer`, weil die Maske aus dem Wasserfeld kommt und nicht aus dem Terrain.

Einzelentscheidungen:
- Nur Meeresgrund läuft über die Farbrampe. Land bis an die Wasserlinie nimmt den normalen Weg (Bewuchs und Fels reichen bis ans Wasser, wo kein Strand liegt); die Rampe malte bis `sea + 0.012` einen Küstenring (#174 C, Befund §E).
- Dunkler Grundfels statt der früheren kreidigen 0.38…0.45-Fläche; Materialdetail und Rauheit ergänzt der Shader.
- Die Makrofarbe folgt dem Mineral: der Shader mischt sie zu 28 % unter, sonst trüge jede Felswand den Grünstich des Habitats. Die Mineraltönung liegt im Ton des Shader-Felses; mit 0,37 hob die Beimischung allein jede Wand um ein Drittel über ihren Grauton (Befund #174 „Fels zu hell").
- Blankes Eis nur im Zehrgebiet (wärmer als die Eis-Firn-Grenze `iceFirnTemp`, dort bildet `updateIce` keinen Firn mehr), darüber Firn.
- Talboden-Wiese: flach und unterhalb des Nadelwald-Bands, dazu die Aue (Bänke, die der Fluss verlassen hat, `barAge` ab dem Ende des Sand-Fensters). Die Höhenbänder allein verfehlen sie, der Gürtel liegt zu 83–97 % über `coniferLow` (Review zu #174 D, `testBarMeadowDiagnostic`).
- Weiche Sandkante (Befund #174, Rauten und Treppen am Strand und auf Bänken): bilinear gefiltert knickte die Kante mit Rampe ≤ 1 Zelle je Zelle ab. Ein 3×3-Binomialfilter (1-2-1) über den Sand-Kanal verbreitert sie auf zwei Zellen, gemittelt nur über Land, damit der Strand an der Wasserlinie nicht ausbleicht. Der Kanal mischt im Shader obenauf (`terr = mix(terr, sand, a)`), die Gewichtssumme bleibt unberührt.

Betrifft: `TerrainColorRenderer`, `TerrainColorRenderer.Buffers`, `TerrainColorRenderer.buffers`, `TerrainColorRenderer.softenSand`, `WetMeadow.apply`, `game/shaders/terrain.gdshader`, `MaterialTests.testWeightsNeverExceedOne`
