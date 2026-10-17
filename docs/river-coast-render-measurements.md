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
GDExtension nicht lokal, und CI misst keine Bildrate.
