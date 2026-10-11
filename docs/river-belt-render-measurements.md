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
