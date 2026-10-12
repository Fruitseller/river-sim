# Mäandergürtel im Render (Issue #174, Paket C Teil 2)

Messreihe zu den Render-Werten in `SimCore/WaterRender.swift`
§ „Mäandergürtel im Render" und § Abfluss-Vertrauen. Alle Läufe headless auf
der Produktions-Config (`SimConfig.production`, n 720, Einlauf
`productionSettleYears`), danach 20.000 Jahre in 100-Jahr-Schritten, Seeds
1337/42/20 (Matrix-Seeds). Messrechner: M4 Max (macOS), Swift 6.3.3,
`-c release`.

```sh
RS_MEASURE=1 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 \
    --filter "testBarAgeDiagnostic|testMainStemBandDiagnostic|testBeltRenderMapDiagnostic"
```

(`SimCoreTests/RiverBeltRender.swift`; `RS_SEEDS`, `RS_YEARS`, `RS_OUT` für
die Draufsicht-PPMs.)

Physik unverändert: `simperf --hash` auf der Basis (`origin/t3/issue-174-b`)
und auf diesem Stand gleich, `615a48df5b50668c` (M4 Max).

## A. Bankalter (`testBarAgeDiagnostic`)

| Seed | Bankzellen (% Land) | Alter p25 / p50 / p75 | < 300 J. | < 1000 J. | < 3000 J. | \|∇Alter\| p25 / p50 / p75 (J./Zelle) |
| --- | --- | --- | --- | --- | --- | --- |
| 1337 | 22.249 (8,7 %) | 9100 / 12900 / 18700 | 4 % | 6 % | 10 % | 71 / 112 / 400 |
| 42 | 12.138 (8,5 %) | 7800 / 15400 / 18500 | 3 % | 7 % | 13 % | 71 / 158 / 500 |
| 20 | 12.760 (7,9 %) | 4300 / 11400 / 17900 | 4 % | 8 % | 18 % | 71 / 212 / 500 |

Folgen für die Kalibrierung:

- **Sand-Horizont** `barSandYearsLo/Hi` = 800/3000. Mit 150/600 lag Sand nur
  als 1-Zellen-Saum am Innenufer, fast ganz unter dem Band (Draufsicht
  Seed 20); mit 800/3000 stehen an den Gleithängen Sichelbänke. Zellen mit
  Sand > 0,25: 1040 / 801 / 1142.
- **Sprenkel**: feste Läufe stempeln je Schritt einzelne Zellen frisch; ohne
  Filter lagen sie als helle Pünktchen über der ganzen Aue. Sand bleibt nur
  mit ≥ 2–4 Sand-Nachbarn (`barSandNeighboursLo/Hi`).
- **Scroll-Rippen**: Periode 400 Jahre Bankalter. Beim Median-Gradienten
  (112–212 J./Zelle) sind das 1,9–3,6 Zellen je Rippe, also an der
  Auflösungsgrenze; wo es enger wird (p75 400–500 J./Zelle), blendet das
  Muster über `barScrollMinSpacingLo/Hi` (2/3,5 Zellen) aus, statt zu
  aliasen. Der 71er-Wert im p25 ist das Raster der 100-Jahr-Schritte
  (100/√2), kein Gelände.

## B. Querprofil im Band (`testBeltRenderMapDiagnostic`, Zeile `BEND`)

Vorzeichen-Probe gegen das Bett der Sim: über alle Laufknoten mit
|Bogenstärke| > 0,3 die Bett-Höhe eine halbe Halbbreite neben der Mitte, auf
der Seite, die `WaterRender.ribbonOutward` als Prallhang meldet, gegen die
andere.

| Seed | Knoten | Bett außen − innen (Sim-Höhe, + = außen tiefer) |
| --- | --- | --- |
| 1337 | 1027 | +0,00031 |
| 42 | 383 | +0,00029 |
| 20 | 470 | +0,00020 |

Auf allen drei Seeds ist die als „außen" gefärbte Seite die tiefere: die
Bogenstärke in UV2.y (`MeanderState.bendStrength`, dieselbe Größe wie der
Kolk in `Terrain.beltStamp`) und die Shader-Formel stimmen mit der Physik
überein.

## C. Hauptlauf durchgehend (`testMainStemBandDiagnostic`)

Hauptlauf = D8-Pfad vom Land mit dem größten Einzugsgebiet stromauf (je
Zelle der größte Zubringer) bis `renderMinCells`. Eine Zelle zählt als
gemalt, wenn im 3×3 Band-Deckung ab `protectBandThreshold`, Raster-Fluss oder
See über den Schutz-Schwellen liegt.

Vorher (Basis):

| Seed | Zellen | Band | Raster | Lücke | längste Lücke |
| --- | --- | --- | --- | --- | --- |
| 1337 | 302 | 78,1 % | 16,2 % | 5,6 % | 8 |
| 42 | 358 | 39,4 % | 10,3 % | 50,3 % | 67 |
| 20 | 332 | 0,0 % | 14,8 % | 85,2 % | 203 |

Ursache: das Kohärenz-Gate der Bänder (Stream-Map-Stütze) verwarf die großen
Läufe. Die Stream-Map trackt die Hauptläufe der neuen Großform kaum (Stütze
0,09–0,35 bei bis zu 26.000 Zellen Abfluss; s. auch
`docs/zielbild-measurements.md`, 15 % statt > 40 %). Auf Seed 20 wurde der
ganze Hauptlauf (Lauf 4, 248 Knoten, Q bis 16.876) nicht gebaut.

Abfluss-Vertrauen (`WaterRender.ribbonTrust`, im Band je Stützpunkt, im
Raster statt der Track-Maske), Fenster in Vielfachen von `renderMinCells`:

| Fenster | Lücke 1337 / 42 / 20 | längste Lücke | Band ohne D8-Lauf (Gegenprobe) |
| --- | --- | --- | --- |
| aus | 5,6 / 50,3 / 85,2 % | 8 / 67 / 203 | 10,6 / 10,8 / 11,5 % |
| 6×…16× | 3,0 / 27,4 / 16,6 % | 6 / 67 / 20 | 10,0 / 16,5 / 12,0 % |
| **3×…10×** | **3,0 / 19,6 / 6,9 %** | **6 / 39 / 16** | **10,2 / 14,2 / 13,5 %** |
| 2×…8× | 3,0 / 18,7 / 3,9 % | 6 / 39 / 11 | 10,0 / 13,7 / 13,1 % |

Gewählt 3×…10×: fast die Wirkung von 2×…8×, aber weniger zusätzlich gemalte
Läufe (Band-Zellen Seed 1337: 14.166 ohne, 18.123 mit 3×, ~19.900 mit 2×).
Die Gegenprobe (Band-Zellen ohne großen D8-Lauf in 3 Zellen, ein Maß für
Bänder neben dem eigentlichen Abfluss) steigt auf 42/20 um 2–3 Punkte.
Eine Ausnahme vom Strahler-Gate für vertraute Läufe änderte keine einzige
Lückenzelle und ist deshalb nicht drin (der Godot-Wächter
`river_ribbons.gd` prüft das Gate).

Was bleibt (Seed 42): 26 Zellen unter Läufen mit Q 280–980 im Oberlauf
(unter dem Vertrauens-Fenster, ohne Stream-Map-Stütze) und 44 Zellen ohne
Zentrumslinie in der Nähe, je zur Hälfte nahe Quelle und Mündung. Das ist
die Stream-Map selbst, kein Render-Gate mehr.

**Doppelwasser durch das Vertrauen (Review #181).** In der maximierten
Abnahme (Seed 42, Jahr 20.000, `close`) lief der Hauptlauf stellenweise als
blockige, versetzte Raster-Segmente in D8-Treppe unter und neben dem glatten
Band. Zwei Ursachen, beide im Raster:

1. Das Vertrauen galt im Raster überall. Es malte jeden großen D8-Lauf voll,
   auch wo ein Band ihn schon trägt; D8-Pfad und Zentrumslinie liegen dort
   einige Zellen auseinander.
2. Der Raster-Deckel unter einem Band hatte eine eigene Kaskaden-Ausnahme
   über das Max-Gefälle zur 8er-Nachbarschaft. Die sah auch das Quergefälle
   an Talflanken und ließ das Raster unter einem voll deckenden Band stehen,
   in Zellblöcken. Die Band-Deckung trägt die Kaskaden-Blende des Bands schon
   (`alpha × (1 − cascadeWeight)`), die Ausnahme war daneben doppelt.

Fix: das Vertrauen im Raster wird mit (1 − größte Band-Deckung im Quadrat
±`ribbonTrustBandClearanceCells`) gewichtet, der Deckel folgt nur noch der
Band-Deckung. Messung mit `testMainStemBandDiagnostic` (Zeilen „Deckung
≥ 0,7" und „neben einem Band"); Lücke im Hauptlauf in %, Raster-Fluss unter
Band-Deckung ≥ 0,7 in % dieser Band-Zellen, Raster-Fluss ohne Band mit einem
kräftigen Band in ±3 Zellen (Zellen), Seeds 1337 / 42 / 20:

| Abstand | Lücke | Raster unter dem Band | Raster neben dem Band |
| --- | --- | --- | --- |
| vorher (#181) | 3,0 / 19,6 / 6,9 | 37,9 / 32,0 / 26,9 | 1295 / 677 / 651 |
| 0 Zellen | 3,0 / 19,6 / 6,9 | 11,8 / 9,3 / 10,4 | 901 / 508 / 439 |
| **1 Zelle** | **3,0 / 19,6 / 6,9** | **11,6 / 8,8 / 10,0** | **863 / 480 / 427** |
| 2 Zellen | 3,0 / 19,8 / 6,9 | 11,5 / 8,2 / 9,6 | 827 / 408 / 398 |
| 4 Zellen | 3,3 / 25,7 / 8,7 | 11,2 / 7,6 / 9,2 | 706 / 261 / 326 |

Gewählt 1 Zelle: der größte Abstand ohne neue Lücke. Ab 2 Zellen nimmt die
Schranke dem Raster auch Strecken hinter einem Bandende (Seed 42: Lücken ohne
Zentrumslinie 44 → 45 → 66). Den Großteil nimmt der Deckel ohne
Kaskaden-Ausnahme (Zeile „0 Zellen"). Der Rest unter dem Band ist
Track-Masken-Raster unter auslaufender Band-Deckung (Enden, Kaskaden), wie
vor dem Vertrauen. Wächter: `BarMaterialTests.testTrustedRasterFillsOnlyTheBandGaps`
und `testRasterUnderAFullBandIsCappedOnASteepCrossSlope` (beide auf dem alten
Stand rot).

Kosten: `WaterFieldRenderer.bytes` auf Seed 42, Jahr 20.000 (1000-Jahr-Schritte
wie `RS_STEP`), alt 6,80 ms, neu 6,83 ms (Median aus 15, alt/neu interleaved
im selben Prozess, M4 Max). Gemessen mit 1 Zelle Abstand; die Ausnahme fällt
weg, die Dilatation kommt dazu, netto gleich.

**Stumpfe Band-Enden und Breiten-Blöcke (Review #181, zweite Runde).** Nach
dem Fix oben zeigte das Bild (Seed 42, Jahr 20.000, `close`) Bänder, die vor
Steilstrecken rechtwinklig abbrachen, und blockig versetzte Bandstücke. Die
Sim lässt Läufe dort enden, das Raster malt weiter. Zwei Ursachen im Band:

1. Der Land-Taper am Ende war fest 2 Zellen (Quelle 4). Ein Hauptlauf am
   Breitendeckel (Halbbreite 3,2) lief damit auf weniger als seiner halben
   Breite von voll auf null aus, oft über nur zwei Stützpunkte, weil das
   letzte Knotensegment 1,4–1,7 Zellen lang ist.
2. Der Krümmungs-Deckel wirkt je Stützpunkt. Auf der Mündungs-Kette (D8,
   ganze Zellen, dazwischen ein Mittelpunkt) wechselten gedeckelte
   Knickpunkte und ungedeckelte Mittelpunkte ab: die Bandbreite sprang
   zwischen 6,4 und 1,3 Zellen.

Fix: Land-Taper an Quelle und Ende mindestens `ribbonLandTaperHalfWidths` = 3
Halbbreiten lang (Mündungen bleiben bei `ribbonTailTaperCells`), und die
gemalte Halbbreite ändert sich je Zelle Bogenlänge höchstens um
`ribbonMaxHalfWidthSlope` = 1 (nur absenkend, der Krümmungs-Deckel bleibt
eingehalten).

Gemessen auf Seed 42 (Bänder; „stumpf" = Deckkraft 0,5 liegt näher am
Land-Ende als die Halbbreite dort):

| | vorher | nachher |
| --- | --- | --- |
| stumpfe Land-Enden (von 101) | 10 | 0 |
| Segmente mit Breitensprung > 0,75 Zellen (von ~1950) | 97 | 10 |

Hauptlauf und Doppelwasser (`testMainStemBandDiagnostic`, Seeds 1337 / 42 / 20):

| | vor dieser Runde | nachher |
| --- | --- | --- |
| Lücke im Hauptlauf | 3,0 / 19,6 / 6,9 % | 3,0 / 19,6 / 6,9 % |
| Raster-Fluss unter Band-Deckung ≥ 0,7 | 11,6 / 8,8 / 10,0 % | 13,9 / 9,1 / 11,1 % |
| Raster-Fluss neben einem Band (±3 Zellen) | 863 / 480 / 427 | 994 / 523 / 536 |

Die beiden unteren Zeilen steigen, weil das Band über die längeren Taper
ausblendet und das Raster dort einblendet. Das ist die gewollte Überblendung
statt einer Kante, kein neuer Geisterlauf. Die Grenze 0,5 statt 1 nahm noch
3 Breitensprünge mehr, verengte die Bänder um einen Knick aber über bis zu
4 Zellen je Seite. Wächter: `BarMaterialTests.testRibbonEndsTaperToAPointAndKeepAContinuousWidth`
(Breitenteil auf dem alten Stand rot; die Testwelt n = 192 hat keine stumpfen
Enden, der End-Teil ist hier nur gemessen).

**Breite (`ribbonHalfWidthCapCells`)**: 52–82 % der Hauptlauf-Zellen liegen
am Deckel 3,2 Zellen. Den Deckel anzuheben hieße die Sim-Kanalbreite
ändern: `MeanderState.beltWidthCells` liest dieselbe Funktion
(`WaterRender.ribbonHalfWidthCells`), also auch `simperf --hash`. Das gehört
zu Paket B, nicht in diesen Render-Teil; der Deckel bleibt.

## D. Delta

Delta-Arm-Bänder je Welt: 56 / 32 / 30. An Mündungen ins MEER liegen sie
unter der opaken Meeresebene (`ocean.gdshader`, `ALPHA = 1.0`,
`ribbonSeaSurfaceSink`) und sind nicht zu sehen; den flachen, türkisen
Mündungsfächer malt dort der Schelf des Ozean-Shaders (#155) und die
Sedimentfahne aus Paket C Teil 1 (PR #178). Mehrere Distributäre mit
Sandinseln dazwischen müsste die Sim liefern (Verzweigung des Laufs auf dem
Ablagerungskörper); die Bänke aus B liegen an Gleithängen, nicht auf dem
Delta. Mit Render allein erfunden wären es Wasserläufe ohne Wasser in der
Sim. Offen.

## E. Kosten

`BarMaterial.field` je Material-Update (Terrain-Änderung, im Zeitraffer
höchstens alle 0,30 s): 0,54–0,76 ms; der Materialpass selbst 0,45–0,57 ms
mit gegen 0,43–0,53 ms ohne Gürtel-Feld (Median aus 7, interleaved, M4 Max,
Jahr 20.000; parallel lief ein SimCore-Build, die Werte sind obere
Schranken). Die Bogenstärke im Band-Bau (`MeanderState.bendStrength` je
Lauf, 1-Hz-Deckel) ist nicht getrennt gemessen. Shader-Kosten (Sand-Zweig im
Terrain-Shader, Querprofil im Wasser-Shader) sind ohne Bildschirm nicht
messbar; sie gehören zu Abnahmepunkt 47 (maximiert, Referenz-Mac).
