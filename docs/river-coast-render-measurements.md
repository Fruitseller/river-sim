# Fluss, Delta, Küste sichtbar machen — Messreihe (Issue #174, Paket C)

Headless gemessen, Produktions-Config (`SimConfig.production`, n = 720,
Einlauf 3000 Jahre), Matrix-Seeds 1337, 42, 20, Alterung in 1000er-Schritten.
Maschine: Apple M4 Max. Reproduzieren:

```sh
RS_MEASURE=1 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter testRiverCoastRenderDiagnostic
```

Umfang dieses Pakets ist nur der von der Mäander-Physik unabhängige Teil von C:
Tümpel-Teppich, Sedimentfahne, Strand und Felsküste. Die Bildpunkte 25, 27
und 28 des Abnahmebogens nimmt der Projekteigner ab; hier stehen nur die
Kennzahlen, auf denen die Kalibrierung beruht.

## §A Tümpel-Teppich

Erste Annahme (Issue-Text): die blauen Fleckenmatten sind kleine
**See**-Komponenten des Raster-Felds. Gemessen stimmt das kaum. Stehendes
Wasser (`rawWet`) als 4er-Komponenten, ohne Band-Korridor, vor #174 sichtbar:

| Seed | Jahr 0 | Jahr 2000 | Jahr 20.000 | Jahr 100.000 |
| ---: | :--- | :--- | :--- | :--- |
| 1337 | 2 Seen (783 / 1726 Zellen, bleiben) | 1 × 39 Zellen | — | ≤ 3 Tümpel, zusammen ≤ 5 Zellen |
| 42 | — | — | — | — |
| 20 | — | 8 Tümpel, 7…188 Zellen (462 Zellen) | — | — |

(„—" = keiner. Die Läufe mit und ohne Stufe „Jahr 0" weichen ab Jahr 2000
leicht voneinander ab, weil die Messung bei Jahr 0 `computeFlow` aufruft.)

Die Flecken kommen stattdessen aus dem **Fluss**-Kanal: sichtbare Raster-
Fragmente (R ≥ `riverMaskLo`, Komponenten nach Blur und EWMA) unter 50 Zellen,
und davon liegen fast alle höchstens zwei Zellen neben einem Band:

| Seed | Jahr | Fragmente < 50 vor #174 | davon am Band | nach #174 | zurückgenommene Rest-Flecken |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1337 | 0 | 173 | 149 | 160 | 124 / 180 Zellen |
| 1337 | 2000 | 195 | 183 | 178 | 243 / 359 Zellen |
| 1337 | 20.000 | 406 | 389 | 328 | 735 / 1254 Zellen |
| 1337 | 100.000 | 430 | 412 | 286 | 376 / 963 Zellen |
| 20 | 2000 | 203 | 195 | 184 | 240 / 433 Zellen |
| 20 | 20.000 | 226 | 213 | 166 | 289 / 528 Zellen |
| 20 | 100.000 | 332 | 331 | 163 | 270 / 708 Zellen |

Ursache: Korridor-Zellen eines Bands sind vom Kohärenz-Gate des Fluss-Kanals
ausgenommen, und wo das Band nur anteilig deckt, behält das Raster
(`sd += (halo − sd) · cover`) sichtbares Wasser. Diese Reste stehen als
Flecken neben dem Band.

Umsetzung, beide Regeln mit derselben Schwelle `WaterRender.wetMeadowMaxCells`
(200 Zellen):

1. **Tümpel** (stehendes Wasser ohne seine Zubringer) ohne Band-/Altarm-
   Korridor unter 200 Zellen: kein See-Gate, sondern nasse Wiese.
2. **Rest-Flecken am Band**: eine Wasser-Komponente unter 200 Zellen, die nur
   aus anteilig gedeckelten Korridor-Zellen besteht und kein stehendes Wasser
   enthält, fällt auf die Saum-Intensität zurück und wird nasse Wiese.

Nicht angefasst, mit Absicht: Kaskaden-Zellen (es IST dort das Wasser;
seit die Kaskaden-Ausnahme beim Deckeln entfallen ist, zählt eine Zelle erst
ab `WaterRender.remnantMinBandCoverage` = 0,5 Banddeckung als Rest-Fleck,
s. Nachtrag unten), Korridor-Zellen ohne Banddeckung (Band-Enden,
Kohärenz-Fade: dort ist das Raster das einzige Wasser), Tümpel und Seen am
Korridor (Mündungs-Überlappung). Die Übergabe Band ↔ Raster
(`lakeRawWetDepth`) bleibt damit unverändert; die Wächter
`WaterRendererTests.testBuiltBandsAndRasterHandOverWithoutGapOrDoubleWater`
und die Godot-Verträge prüfen das weiter.

Ehrlicher Rest: zwei Drittel bis vier Fünftel der kleinen Fragmente bleiben
stehen, weil sie Teil größerer Komponenten sind oder an ungedeckten
Korridor-Zellen hängen. Sie ohne Lücken zu entfernen, braucht die echte
Kanalbreite aus Paket B (Bandbreite = Bettbreite); dann deckt das Band dort,
wo heute das Raster nachhilft.

Nachtrag Review #174 C (Oktober 2026): die Regel 2 setzte „gedeckelt"
schon ab jeder Banddeckung über 0. An einer Steilstufe, wo das Band
ausblendet (0 < Deckung < 1), fiel damit ein kleines Raster-Stück auf den
Saum zurück und wurde nasse Wiese: ein halbtransparentes Band über einem
grünen Streifen statt Wasser. Seitdem zählt erst Deckung ≥ 0,5, und ein
Bach läuft durch einen Tümpel, der nasse Wiese wurde, weiter
(`WaterFieldStreamTests`). Gegenprobe mit diesem Messlauf, Seed 1337, alter
gegen neuen Stand:

| Jahr | Fluss-Fragmente < 50 | Rest-Flecken zurückgenommen | nasse Wiese (Zellen) |
| ---: | :--- | :--- | :--- |
| 0 | 6 / 6 | 379 → 116 | 1566 → 809 |
| 2000 | 6 / 6 | 305 → 115 | 1496 → 698 |
| 20.000 | 7 / 7 | 282 → 127 | 1221 → 453 |
| 100.000 | 7 / 7 | 200 → 63 | 615 → 229 |

Der Tümpel-Teppich kommt nicht zurück (kleine Fragmente unverändert); die
Raster-Komponenten mit 50–99 Zellen nehmen um 1–4 zu, das sind die
Kaskaden-Stücke, die wieder Wasser zeigen.

Nasse Wiese: Vegetationsgewicht mindestens `wetMeadowVegetation` (0,85),
Makrofarbe zu 70 % `wetMeadowColor`, und die Zellen gehen in die Schutzmaske
(kein Kronendach, keine Verschiebung).

## §B Strand und Felsküste

Landzellen höchstens zwei Zellen vom Meer:

| Seed | Jahr | macroSlope p10 / p50 / p90 | Höhe über NN p50 / p90 | Sand ≥ 0,5 (% Land) | Fels ≥ 0,5 an der Küste |
| ---: | ---: | :--- | :--- | ---: | ---: |
| 1337 | 0 | 0,0029 / 0,0043 / 0,0059 | — | 0,70 | 10 |
| 1337 | 2000 | 0,0028 / 0,0040 / 0,0058 | 0,0079 / 0,0163 | 0,77 | 2 |
| 42 | 20.000 | 0,0026 / 0,0036 / 0,0047 | 0,0069 / 0,0137 | — | 0 |
| 42 | 100.000 | 0,0016 / 0,0023 / 0,0034 | — | 3,28 | 0 |
| 20 | 0 | 0,0030 / 0,0045 / 0,0061 | — | 0,95 | 21 |
| 20 | 20.000 | 0,0021 / 0,0035 / 0,0051 | 0,0065 / 0,0143 | 1,60 | 0 |
| 20 | 100.000 | 0,0011 / 0,0023 / 0,0033 | — | 2,27 | 0 |

Befund: `wavePass` hält jede Küste nahe am Wellen-Talus. Die allgemeine
Klippen-Schwelle des `TerrainColorRenderer` (0,004…0,026) fände an der Küste
keine einzige Felszelle; die Küsten-Fenster stehen deshalb an der Verteilung
selbst: Strand voll bis 0,0042, aus ab 0,0058; Fels ab 0,006, voll ab 0,011.
Auch damit gibt es auf den heutigen Matrix-Welten kaum Felsküste (0…21
Zellen), weil die Großform keine Steilküsten hat. Das ändert erst Paket A
(Gebirgskamm, der bis ans Meer reicht).

## §C Mündungen und Sedimentfahne

(Stand der ersten Fassung; Schwelle und Stärke-Rampe stehen seit §F anders,
die Mündungs-Zahlen gelten weiter.)

D8-Mündungen ins Meer ab 2000 Zellen Einzugsgebiet: 9…13 je Welt, davon
1…4 über 20.000 Zellen. Relief der Einzugsgebiete 0,29…0,51. Stärke
(Abfluss-Rampe log 2000…40.000 × Fracht 0,3 + 0,7 · Relief/0,5) für die drei
größten Mündungen je Welt:

| Seed | Jahr | Stärken |
| ---: | ---: | :--- |
| 1337 | 2000 | 0,96 / 0,68 / 0,51 |
| 42 | 20.000 | 0,89 / 0,67 / 0,40 |
| 20 | 20.000 | 0,85 / 0,74 / 0,74 |

Kleine Mündungen (2000…5000 Zellen) liegen bei 0,07…0,3: sichtbar schwach,
der Hauptfluss deutlich.

## §D Kosten

Median über 15 Läufe, Seed 1337, Jahr 20.000, M4 Max, CPU-seitig:

| Pass | ms |
| :--- | ---: |
| `CoastMaterial.seaDistance` (in `TerrainColorRenderer.buffers` enthalten) | 1,07 |
| `TerrainColorRenderer.buffers` gesamt | 1,72 |
| `SedimentPlume.field` | 3,08 |
| `WetMeadow.apply` | 0,25 |
| `WaterFieldRenderer.bytes` gesamt (mit zweitem Flood-Fill) | 12,78 |

Alle laufen nur bei Overlay-Frames (im Zeitraffer höchstens alle 0,30 s).
Ein interleaved A/B gegen den Stand vor #174 für `WaterFieldRenderer.bytes`
fehlt; die Zahl oben ist die absolute Laufzeit, keine Differenz. Die
Shader-Kosten der Fahne (sechs `textureLod`-Abgriffe je Meeres-Pixel im
Sim-Quadrat) und des Sand-Blocks sind NICHT gemessen: Agenten bauen die
GDExtension nicht lokal, und CI misst keine Bildrate. (Seit §F liest der
Ozean-Shader die Fahne mit einer Abfrage; die CPU-Kosten der neuen Küsten- und
Fahnen-Ableitung stehen in §G.)

## §E Strand-Ring um die ganze Insel (Befund und Umbau)

Reproduzieren (Welt-Cache `RS_CACHE`, Standard `/tmp/river-sim-coast-cache`, die
Welt entsteht beim ersten Lauf; `RS_OUT` hängt die Ausgabe an eine Datei,
`RS_MAP` schreibt Küstenkarten als PPM):

```sh
RS_MEASURE=1 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter testCoastShapeDiagnostic
```

Produktions-Config (`SimConfig.production`, n = 720, Einlauf 3000 Jahre), Seeds
1337 / 42 / 20 bei Jahr 20.000, Apple M4 Max. Die Welten dieses Messlaufs
kommen wie bei `simperf` direkt aus `Terrain` und sind nicht bit-gleich mit der
Welt, die die Brücke im Spiel erzeugt; für die Verteilungen ist das ohne Belang,
Flussmündungen liegen im Spiel an anderen Stellen.

**Befund.** Auf der Insel im Diorama lief ein beiger Streifen von nahezu
konstanter Breite um fast die ganze Küste, auch unter Felswänden und
Steilhängen; die Vorlagen zeigen Strände in Buchten, an Mündungen und auf
Küstenebenen, Landzungen und Steilhänge kommen mit Fels oder Bewuchs bis ans
Wasser. Das Küstenmaterial (§B) las nur Höhe über dem Meer und lokale
Steigung. Gemessen an der Küstenlinie (Landzellen mit Meer in der 3×3-
Nachbarschaft):

| Seed | Küstenzellen | Sand ≥ 0,5 | Abschnitte | Sandbreite 2 / 3 Zellen | macroSlope p50 | Höhe über NN p50 |
| ---: | ---: | ---: | ---: | :--- | ---: | ---: |
| 1337 | 2520 | 100 % | 1 | 347 / 2173 | 0,0020 | 0,0019 |
| 42 | 1929 | 100 % | 2 | 399 / 1529 | 0,0023 | 0,0023 |
| 20 | 2232 | 100 % | 1 | 748 / 1481 | 0,0026 | 0,0024 |

Ursache: `Terrain.wavePass` zieht jede Küste im Wellenband (`waveBand` 0,06)
auf denselben Talus (`waveTalus` 0,002 je Zelle). Steigung und Höhe der
Küstenzellen liegen damit alle weit unter den Sand-Fenstern (Steigung p90
≤ 0,0039 gegen 0,0042…0,0058, Höhe p90 ≤ 0,0053 gegen 0,008…0,018); sie
unterscheiden Bucht, Landzunge und Steilküste nicht. Fels ≥ 0,5 an der Küste:
0 Zellen. Die Unterschiede liegen im größeren Zusammenhang:

| Größe (an der Küstenlinie) | Seed 1337 p10 / p50 / p90 | Seed 42 | Seed 20 |
| :--- | :--- | :--- | :--- |
| Rückland-Relief, Radius 8 (max h im Fenster − h) | 0,018 / 0,032 / 0,064 | 0,028 / 0,037 / 0,082 | 0,026 / 0,042 / 0,100 |
| Rückland-Relief, Radius 16 | 0,041 / 0,081 / 0,146 | 0,059 / 0,102 / 0,169 | 0,062 / 0,126 / 0,206 |
| Meeresanteil im Fenster, Radius 10 | 0,41 / 0,47 / 0,53 | 0,42 / 0,47 / 0,52 | 0,41 / 0,47 / 0,53 |

Das Rückland-Relief streut um den Faktor 3…4 (Küstenebene gegen Steilhang);
der Meeresanteil streut zwischen Bucht (0,41) und Landzunge (0,53), eine
gerade Küste liegt bei 0,47 (der Küstenpunkt selbst ist Land). Radius 8
(≈ 125 m) trennt das Relief schon deutlich und bleibt nahe am Brandungssaum;
die größeren Radien verschieben nur die Skala.

**Änderung** (`SimRender.CoastMaterial`, Kalibrierung `WaterRender` § Strand
und Felsküste): je Küstenzelle ein Strandpotenzial aus vier Größen, die
Saumzellen erben es von ihrer Küstenzelle (Breitensuche, `origin`):

1. Rückland-Relief (`beachReliefLo/Hi` 0,020…0,042): Ebene trägt Strand, Hang nicht.
2. Offenheit (`beachOpenLo/Hi` 0,40…0,50, Meeresanteil im Radius 10): Stellvertreter
   für Wellenenergie; die Sim kennt kein Wellenfeld (`wavePass` ist lokal, ohne
   Richtung oder Fetch). Bucht sammelt Sand, die offene Landzunge nur noch
   `beachExposedShare` (0,2).
3. Sedimentzufuhr nahe Flussmündungen (D8-Empfänger = Meer, Einzugsgebiet ab
   300 Zellen, log-Rampe bis 6000, Reichweite 16 Zellen): hebt das Potenzial,
   zählt das Rückland um die Hälfte weniger (das Tal öffnet es) und dämpft das
   Rauschen.
4. Wertrauschen entlang der Küste (Wellenlänge 30 Zellen, nur Zellenlage, damit
   nichts im Zeitraffer springt): bricht den Strand auf.

Breite = `beachMaxWidthCells` (5 Zellen ≈ 78 m) × Rampe 0,3…0,9 des Potenzials,
also stetig 0…5 statt „0 oder voll" (mit einer Rampe 0,25…0,55 gab der Sweep
auf Seed 1337 1053 Küstenzellen ohne, 1178 mit vollem und nur 289 mit
dazwischenliegendem Strand; jetzt 1400 / 426 / 694). Höhen- und Steigungsfenster
je Zelle bleiben als Gate (die Breite im Bild reicht deshalb selten über 4
Zellen). Steiles Rückland (`cliffReliefLo/Hi` 0,045…0,075, offene Landzungen
um 30 % steiler) wird Felsküste: der Fels kommt bis ans Wasser und räumt den
Bewuchs ab. Dazu beendet `TerrainColorRenderer` die Küstenfarbrampe an der
Wasserlinie (`v ≤ sea` statt `sea + 0,012`): Land ohne Strand läuft als
Bewuchs oder Fels bis ans Wasser, statt als nackter Ring. Das Abstandsfeld
(Chebyshev, Deckel 6) kommt jetzt aus einer Breitensuche von der Küste aus
(siehe §G).

**Ergebnis** (fertige Material-Puffer, Sand-Byte ≥ 128 bzw. Fels-Byte ≥ 128 an
der Küstenlinie):

| Seed | Sand ≥ 0,5 vorher → nachher | Abschnitte | größter Abschnitt am Sand | Fels ≥ 0,5 vorher → nachher |
| ---: | :--- | :--- | ---: | :--- |
| 1337 | 100 % → 45,8 % | 1 → 54 | 8 % | 0 → 12,7 % |
| 42 | 100 % → 42,4 % | 2 → 36 | 10 % | 0 → 18,1 % |
| 20 | 100 % → 30,7 % | 1 → 39 | 12 % | 0 → 35,0 % |

Sandbreite an der Küstenlinie (größter Abstand einer Sandzelle im 5×5-Fenster,
Histogramm 0…3+ Zellen): Seed 1337 vorher `[0, 0, 347, 2173]`, nachher
`[1076, 194, 277, 973]`. Seed 20 ist die schroffste Welt (Rückland-Relief p50
0,042) und hat am wenigsten Strand, am meisten Fels.

Bildbelege (maximiert, `balanced`, Jahr 20.000, oben vorher, unten nachher,
Spalten Diorama / Tal / Nah): `docs/screenshots/zielbild-174/coast-plume_seed1337.jpg`,
`…_seed42.jpg`, `…_seed20.jpg`.

Wächter (`SimCoreTests/CoastMaterialTests`): Steilflanke ohne Strand und mit
Fels ≥ 90 %, Küstenebene mit Strand; Strand liegt in Buchten, nicht auf
Landzungen; die Breite wechselt (≥ 4 verschiedene Breiten, 15…85 % der Küste
mit Strand, ≥ 3 getrennte Abschnitte); eine Mündung liefert Sand an sonst
steiler Küste, fern davon keiner; die Strandfunktion ist monoton in Relief,
Offenheit und Zufuhr; die Kalibrier-Fenster überlappen nicht.

## §F Breite Rauchfächer der Sedimentfahnen (Befund und Umbau)

**Befund.** Im Diorama lagen an mehreren Mündungen breite, braun-orange Fächer,
die weit ins Meer reichten. Die Vorlagen zeigen dezente Trübung nahe der
Mündung, die an der Küste klebt und rasch abklingt. Die alte Fahne war eine
einzelne Quellzelle je Mündung, die der Shader über eine Mip-Kette
(Stufe 3 → 5, also 8 → 32 Zellen breit) und eine feste Strömung aufzog; Breite
und Reichweite wuchsen mit jeder Stufe, unabhängig von der Küste, bei
lehmbraunem Ton (0,42 0,38 0,27) und 60 % Deckung. Gemessen mit denselben
Quellen und derselben Shader-Formel (CPU-Nachbau, Trübungsanteil ab 10 % der
Wasserfarbe gilt als sichtbar):

| Seed | Fahnen (≥ 2000 Zellen) | sichtbare Fläche | Anteil Meeresfläche | größte Entfernung zur Mündung | Abstand zur Küste max / Ø |
| ---: | ---: | ---: | ---: | ---: | :--- |
| 1337 | 21 | 6374 Zellen | 2,44 % | 54 Zellen | 40 / 17,6 Zellen |
| 42 | 10 | 4585 Zellen | 1,23 % | 54 Zellen | 26 / 8,5 Zellen |
| 20 | 13 | 3177 Zellen | 0,90 % | 50 Zellen | 30 / 9,0 Zellen |

**Änderung** (`SimRender.SedimentPlume`, Kalibrierung `WaterRender` § Sedimentfahne):

* Nur die großen Flüsse: ab `plumeMinDischargeCells` 9000 Zellen (vorher 2000);
  die Stärke steigt log-förmig bis 18.000 Zellen (vorher 40.000) und mit dem
  Relief des Einzugsgebiets (Fracht-Stellvertreter wie bisher). Das sind 7 / 4 / 4
  Mündungen statt 21 / 10 / 13; die größte liegt bei Stärke 0,93 / 0,80 / 0,56,
  die übrigen zwischen 0,05 und 0,53.
* Küstennah und schmal: die Fahne wird nicht mehr im Shader aufgezogen,
  sondern auf der CPU als Dichte je Meereszelle gerechnet. Ein kürzester Pfad
  (Kosten wachsen mit der Schrittlänge und gegen die Küstenströmung, die Drift
  der Ozean-Wellen) läuft ab der ersten Meereszelle hinter der Mündung nur über
  Zellen höchstens `plumeBandCells` (5) vom Land; die Dichte klingt mit
  e^(−Kosten/18 Zellen) ab, endet nach 3,5 Abklinglängen und blendet zum
  Bandrand aus. Stromauf klingt sie auf einem Drittel der Länge ab; wo die
  Küste quer zur Strömung läuft, reicht sie nach beiden Seiten. Ein Strahl
  vor der Mündung (breiteres Band am Anfang) wurde probiert und verworfen: die
  Strömungs-Kosten verhinderten ihn dort, wo das Meer stromauf liegt, und er
  änderte das Bild kaum.
* Weniger gesättigt: Farbe (0,44 0,43 0,32) statt (0,42 0,38 0,27), Deckung
  höchstens 70 % der Dichte (vorher 60 % auf einer sich auf 1 sättigenden
  Summe).
* Der Shader liest nur noch die fertige Dichte, mit EINER Abfrage (zwei während
  der Overlay-Blende) auf Mip-Stufe 1 (`oceanPlumeLod`). Die Uniforms
  `water_ocean_plume_length/_spread/_gain` entfallen. Die Stufe muss ≤ 4
  bleiben, weil die Mip-Kette der Textur bei n = 720 (2⁴ · 45) nur bis dort
  gleichmäßig ist (die alte Spreizung bis Stufe 5 lag darüber); Wächter:
  `CoastMaterialTests.testCalibrationWindowsFitTheWaveBandAndDoNotOverlap`.

**Ergebnis:**

| Seed | Fahnen | sichtbare Fläche | Anteil Meeresfläche | größte Entfernung zur Mündung | Abstand zur Küste max / Ø |
| ---: | ---: | ---: | ---: | ---: | :--- |
| 1337 | 7 | 393 Zellen (−94 %) | 0,15 % | 20 Zellen | 3 / 1,7 Zellen |
| 42 | 4 | 205 Zellen (−96 %) | 0,05 % | 26 Zellen | 3 / 1,8 Zellen |
| 20 | 4 | 131 Zellen (−96 %) | 0,04 % | 19 Zellen | 3 / 1,5 Zellen |

Wächter (`SimCoreTests/SedimentPlumeTests`): die Fahne beginnt auf der Mündungszelle
mit voller Stärke und berührt nie Land; sie liegt in einem Band von höchstens
`plumeBandCells` und lässt offenes Meer klar; sie klingt entlang der Küste
monoton ab und endet nach 3,5 Abklinglängen; stromab reicht sie weiter als
stromauf; die sichtbare Fläche einer vollen Fahne bleibt unter 600 Zellen
(der alte Fächer deckte rund 3000).

## §G Kosten

Median über 25 Läufe, abwechselnd (interleaved), Seed 1337 / 42 / 20 (Jahr
20.000), M4 Max, Maschine sonst ruhig, CPU-seitig:

| Pass | 1337 | 42 | 20 |
| :--- | ---: | ---: | ---: |
| Abstandsfeld alt (Deckel 4, vor §E) | 1,56 ms | 1,12 ms | 1,35 ms |
| Abstandsfeld alt bei Deckel 6 (Gegenprobe) | 2,17 ms | 2,05 ms | 2,07 ms |
| Abstandsfeld neu (Breitensuche, Deckel 6) | 0,87 ms | 0,78 ms | 0,82 ms |
| Küstenfeld neu (`shore`: Abstand, Relief, Offenheit, Zufuhr, Breite) | 2,29 ms | 2,01 ms | 2,13 ms |
| Mündungen (= Etikett-Lauf der alten Fahne) | 2,51 ms | 1,44 ms | 1,58 ms |
| Fahne neu (Mündungen + Pfad) | 3,09 ms | 1,83 ms | 1,90 ms |

Das Küstenfeld kostet gegenüber dem alten Abstandsfeld (Deckel 4) rund
0,7…0,9 ms mehr, die Fahne rund 0,3…0,6 ms; zusammen rund 1,1…1,3 ms je Overlay-Takt (im
Zeitraffer höchstens alle 0,30 s; das Wasserfeld kostet dort 12,8 ms, §D). Die
Breitensuche ist bei gleichem Deckel gut doppelt so schnell wie die alte
Stufen-Erweiterung. Der Ozean-Shader wurde billiger statt teurer (eine Abfrage
statt sechs, während der Overlay-Blende zwei statt zwölf), der Terrain-Shader
ist unverändert; ein Bildraten-A/B wurde deshalb nicht gefahren und ist NICHT
gemessen.
