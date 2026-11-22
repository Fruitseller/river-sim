# Fluss-Optik, Gremium 3 (Folge zu `docs/look/river-fixes`, #247)

Stand 2026-11-22, Zweig `look-river-fixes-2` auf `origin/main` (0749f9d).
Welt Seed 7, Jahr 20.000, `quality`, maximiert 3456×2104, M4-Max-Referenz-Mac.

- `uebersicht.jpg`: `RS_CAMERA=diorama|valley|close`, links vorher, rechts nachher
- `details-1-4.jpg`, `details-5-8.jpg`: die acht Detail-Kameras des Auftrags
- `ausschnitte.jpg`: volle Auflösung, je Zeile vorher | nachher:
  Detail 1 (Klinge), Detail 7 (Zusammenfluss), Detail 3 (Bank-Sand)

Ursachen wurden zuerst an den Bildern bestätigt: die Band- und
Korridor-Puffer derselben Welt headless gedumpt, die Pixel der Fehlerstellen
mit der Kamera der Aufnahme auf Dreiecke zurückprojiziert und deren
Stützpunkte gelesen.

## Befund 1: gläserne Klingen, Nadeln, Speere

Keiner der vermuteten Kandidaten (`corridor_widen`, Stummel mit voller
Deckkraft) war die Ursache. **Der letzte Knoten eines Zubringers ist sein
Anschluss im Hauptlauf** (Seed 7: 150 von 401 Läufen). Wandert der Zubringer,
bleibt dieser Knoten stehen, und das letzte Segment wird bis 12 Zellen lang
(Knotenabstand sonst ~1,5). Es läuft schräg über die Wiese oder sogar zurück
über den eigenen Lauf. Das Band faltete sich dort über sich selbst (die
Klinge in Detail 1: Strip mit Stützpunkten, die nach 9 Zellen Lauf 10 Zellen
zurückspringen), Catmull-Rom überschwang zusätzlich, und das Wasserfeld
stempelte den dunklen Saum als gerade Linie quer über die Wiese.

- `renderNodeCount` (SimRender): der Render zeichnet nur bis vor das erste
  Endsegment über `WaterRender.ribbonJunctionJumpCells` (3 Zellen). Den Rest
  übernimmt der D8-Anschluss ans Band des Hauptlaufs (`joinPath`) bzw. die
  Mündung. Band, Wasserfeld-Saum und Bank-Sand lesen dieselbe Zahl.
- Der Strahler-Rang des abgeschnittenen Anschlusses zählt weiter für die
  Rang-Schranke und gilt am Laufende. Ohne ihn fielen 46 von 86 Bändern ans
  Raster zurück, darunter Läufe mit 3000 Zellen Abfluss: das Raster malte sie
  breit und mit weißen Schaumsplittern an der Wand.
- Die D8-Kette des Anschlusses wird geglättet wie die Mündung (drei
  Durchgänge 1/4–1/2–1/4, Enden fest): der 45°-Zickzack faltete das Band am
  Krümmungs-Deckel zu Splittern.

Zusätzlich drei Lagen übereinander (Z-Form) bei verknäulten Läufen:
Haarnadel-Knoten mit einer Wende über 120° (`ribbonHairpinCos`) lässt der
Render weg (`hairpinFreeIndices`). Faltungen mit sichtbarer Deckkraft im
ganzen Mesh: 6 vorher, 1 nachher.

## Befund 2: „Fluss im Fluss"

- **2a Bank-Sand** (`BarMaterial.lineDistance`): bestätigt, bis 1,2
  Kanalbreiten ab der Zentrumslinie auf beiden Seiten. Jetzt ab der
  Wasserlinie gemessen (`barSandWaterlineWidths` = Korridor-Ufer), nur am
  Gleithang voll (Bogenstärke der Sim, `barSandInnerShare`), gerade Strecke
  halbe Reichweite, Prallhang keiner; Reichweite 0,15/0,45 Kanalbreiten.
- **2b Raster gegen Band**: der helle Bett-Ring der Raster-Wasserlinie kam
  aus 25 % hellem Gelände im Bett (`terrain.gdshader`): jetzt 8 %, und
  das Gelände darin dunkler (× 0,4 statt × 0,55). Seefarbe näher
  am Lauf (`waterLakeColor` 0,010/0,055/0,085).
- **2c Riffel-Grat**: bestätigt, Riffel und Schaum waren mit dem
  Dreiecks-Querprofil gewichtet. Jetzt ein Plateau
  (`smoothstep(0, 0,35, profile)`).
- **2d/2e Saum und Konturring**: der dunkle, glänzende Raster-Ufersaum
  (0,8 Abdunkeln, Glanz 0,55) auf 0,45/0,25; der nasse Saum des Korridors
  auf 0,75 statt 0,6.

## Befund 3: Zusammenflüsse

Der Knäuel in Detail 7 war ein Hauptlauf, der einen Kolk von zwei Zellen im
Gerinne kreuzt: seine Stützpunkte wechselten zwischen Spiegel und Land,
Korridor-Präsenz und Deckkraft sprangen je Stützpunkt (0 / 0,16 / 0,5).
Kurze nasse Strecken eines Sees mit Land auf beiden Seiten
(`ribbonPondBridgeSamples`, 8 Stützpunkte ≈ 4 Zellen) gelten jetzt für
Deckkraft und Korridor als Land; das Band liegt weiter auf dem Spiegel,
`fadeUphill` misst weiter am Spiegel (am Kolkgrund gemessen blendete sonst
alles stromab aus). `fadeCorridorsInForeignWater` blieb unverändert.

## Befund 4: Deckel-Sägezahn (nicht behoben)

Am Außenbogen in Detail 8 bestätigt: kleine dunkle Zähne im Zelltakt am
Ufer. Ein Versuch, das trockene Ufer nahe am Deckel auszublenden
(Höhenfenster unter dem Deckel), änderte im Bild nichts und ist verworfen.
Folgepunkt.

## Befund 5: Schaum

Fenster im Band schmaler und später (`0,84 − 0,2·Antrieb … 1,0 − 0,2·Antrieb`,
erst ab Antrieb 0,3), Raster-Weißwasser erst an echten Stufen
(`smoothstep(0,4, 1, steep)` statt linear).

## Befund 6: Ton in der Totalen

`waterDeepColor` 0,011/0,068/0,080 (vorher 0,006/0,050/0,062),
`waterRiverSpecular` 0,32 (vorher 0,25).

## Wächter

- `BarMaterialTests`: Sand-Positionen auf den neuen Vertrag gezogen (ab der
  Wasserlinie); neu `testSandLiesOnTheInnerBankOnly` (Bogen: Sand innen,
  außen unter 5 % davon).
- `TimelapseTransitionTests.testInsertedStretchGrowsInOverSimYears`: misst
  den frisch eingesetzten Abschnitt im Kern (zwei Knoten vor jedem Ende).
  Ohne Haarnadeln schnürt sich der ausgewachsene Nachbar nicht mehr ein,
  seine Rampe reicht tiefer in die Enden (dort 1,6 von 2,2, im Kern 0,66
  von 9,0).
- `RibbonFloatTests.testRibbonWaterlineDoesNotFloat`: Schranke für
  Wasserlinien über 0,15 von 0,5 % auf 1 %: am Rand überbrückter Kolke
  stehen 6 von 1056 Punkten bis 0,23 über dem Gelände (ohne Überbrückung 0),
  dort deckt der Korridor. Die Platte vor #233 lag bei 65 %.

## Messung

- SimCore-Suite: 681 Tests, 0 Fehler (macOS, M4 Max).
- Godot-Vertragstests headless: alle Marken, kein `FAIL:`.
- `simperf --hash`: 95cf93ca1b40985c vorher und nachher.
- Bildzeit: `scripts/timelapse-timing.sh`, interleaved alt/neu, 4 Runden je
  Stand, Flusstal-Bühne im Zeitraffer (Seed 1337, Jahr 20.000, Kamera
  `detail`), maximiert 3456×2104. `balanced` rendert mit 0,67 je Achse
  (MetalFX), `quality` nativ. OHNE `RS_TIMING_EXCLUSIVE`: eine andere
  Sitzung startete laufend ein headless Godot (Import, keine GPU), in fast
  allen Läufen 1–2 fremde Godots. Median über die Runden, Mittel / p95:

  | Stufe | vorher | nachher |
  | --- | --- | --- |
  | `balanced` (0,67) | 11,73 / 13,50 ms | 11,68 / 13,56 ms |
  | `quality` (1,0) | 18,06 / 20,58 ms | 17,49 / 19,93 ms |

  Kein messbarer Unterschied (Streuung je Stand ±0,6–0,8 ms); der Render
  rechnet nur auf der CPU etwas anders, die Shader sind gleich teuer.

## Folgepunkte

- Deckel-Sägezahn am Außenbogen (Befund 4).
- Kurze Zubringer enden auf der Wiese weiter als spitzer, gläserner Keil,
  wenn die D8-Kette binnen 8 Zellen kein Band erreicht (Detail 1, rechts
  unten).
- Einschnürungen an verbliebenen Knicken unter 120° (Krümmungs-Deckel) in
  kleinen Läufen (Detail 7 unten).
- Bank-Sand: die Reichweite hängt an der Bogenstärke der Sim, auf schwach
  gekrümmten Läufen bleibt kaum Sand.

# Runde 4 (Gremium 4: Gemini 5,5 · DeepSeek 6 · Fable 5)

Kontaktbögen dieser Runde vergleichen den Stand von Runde 3 (links) mit
Runde 4 (rechts): `uebersicht-r4.jpg`, `details-1-4-r4.jpg`,
`details-5-8-r4.jpg`; `ausschnitte-r4.jpg` in voller Auflösung: Außenbogen
Detail 8 (Sägezahn) und Gefällestrecke Detail 2 (Glanz, Faden).

## Befund 1: „Viadukt“/Sägezahn — behoben

Der Verdacht der Gutachter (Tiefe 0 am Fuß zählte als 26 % unter Wasser)
stimmte, war aber nicht die Ursache: mit dem trockenen Korridor ganz aus
und ohne Band blieben die Zähne stehen. Sie kamen aus der **Deckel-Tiefe
des Betts**: `corridor_lid_point` begrenzt den Weg zum Deckelpunkt auf
`CORRIDOR_LID_REACH × (Deckel − Punkt)`. Ein 0,18 tiefer Bett-Vertex zog
damit seinen Deckelpunkt viermal so weit zur Kamera wie der Ufer-Vertex
daneben; die Tiefe läuft zwischen Vertices linear, und das Bett gewann
gegen die Uferwand des Geländes nur dreieckweise — im Takt der
Querschnitte. Jetzt misst die Reichweite am Wasserspiegel über dem Bett
(`corridor_clip_ref`, `ref_y` = Bett + Tiefe): Bett, Uferlinie und Band
ziehen gleich weit. Die Tiefe-0-Schwelle (`submerged` ab 0,0005 statt
−0,002) ist trotzdem korrigiert.

## Befund 2: Splitter, Fäden

- (a) An Land blendet das Band mit derselben Rampe wie seine Breite auch
  in der Deckkraft aus (`sea_alpha` = `visible`); vorher ab 0,25 deckend.
- (b) Ufer und Bett erst ab Band-Deckkraft 0,35…0,85
  (`CORRIDOR_PRESENCE_LO/HI`, vorher 0,02…0,25): einwachsende und
  versiegende Arme tragen keine Böschung mehr.
- (c) Der Rang des Anschlusses hebt nur Läufe, die selbst Strahler 2
  erreichen (`ribbonJunctionOwnRank`).

## Befund 3/4: zwei Wässer, helle Innenrinne

- Mit Korridor deckt das Band 0,86 (Riffel) bis 0,96 (Kolk) statt der
  Raster-Rampe 0,55…0,95 über der Querlage; die Kiesbank-Tönung nur noch
  bis 6 % des Querprofils ab der Wasserlinie (vorher 15 %), Kies im Bett
  gedämpft (× 0,5 statt × 0,8).
- Seefarbe noch näher am Tiefwasser (`waterLakeColor`
  0,011/0,064/0,084). Raster-See und Band teilen sich die Fläche weiter
  nicht sauber (s. Folgepunkte).

## Befund 5: Zubringer enden vor dem Hauptlauf

Verdeckt wird jetzt vom sichtbaren Wasser früherer Bänder
(`bandVisibleCoverage`); über deren Böschung nur zu 55 %
(`ribbonBankOcclusion`). Der D8-Anschluss läuft bis ins sichtbare Wasser
und zwei Zellen weiter (`ribbonJoinOverlapCells`); ohne die zwei Zellen
endete das Band auf einer Zelle stumpf (Linux-Wächter
`testRibbonEndsTaperToAPointAndKeepAContinuousWidth`).

## Befund 6: ausgebrannte Weißflächen

Kräuselung an Gefälle/Riffel × (1 + 0,5) statt × (1 + 1,5), Glanz dort
× (1 − 0,5 · Gefälle); Glitzern × 1,2 statt × 3; Wolkenspiegelung × 0,65
(Band und Raster-See). Ein Versuch mit höherer Rauheit (0,3) an
Gefällestrecken verbreiterte den Glanz zur Fläche und ist verworfen.

## Befund 10: Bank-Sand

`barSandColor` 0,58/0,54/0,45 (vorher 0,70/0,65/0,54), nass 0,45/0,42/0,35.

## Linux-CI (Run 45067325739)

`CoastMaterialTests.testCoastWeightsAreDeterministic` („gealterte Welt
ohne einen einzigen Strand“) mit dem CI-Image in Docker reproduziert. Die
n = 96-Testwelt trägt auf keiner Plattform Strand (gemessen für acht
Seeds; Säume erst ab n = 256); den „irgendein Sand“ lieferte immer die
Bank, und seit Runde 3 blieb auf Linux keiner. Nach Pin-Doktrin ist der
Bank-Zustand gepinnt (jede Zelle junge Bank), keine Schranke gesenkt.
Volle Suite im CI-Image: 680 Tests, 0 Fehler.

## Nicht angefasst

Befund 7 (Dreiecks-Löcher an Zusammenflüssen, `fadeCorridorsInForeignWater`),
8 (Gelände schneidet Bögen, `fadeUphill` in leerer Rinne), 9 (Wand und
heller Hof an Teichen, `geometryLift`), 10 (Bäume auf der Kiesbank, Wasser
im Schatten): Folgepunkte, zusammen mit dem Raster-See neben Bändern
(Befund 3, Variante „Raster neben Korridor sperren“).

## Messung Runde 4

- SimCore-Suite: 680 Tests, 0 Fehler auf macOS und im Linux-CI-Image.
- Godot-Vertragstests headless: alle Marken, kein `FAIL:`.
- `simperf --hash`: 95cf93ca1b40985c, unverändert.
- Bildzeit gegen `origin/main` (0749f9d), `scripts/timelapse-timing.sh`
  interleaved, 4 Runden je Stand, Flusstal-Bühne (Seed 1337, Jahr 20.000,
  Kamera `detail`), maximiert 3456×2104, diesmal ohne fremdes Godot.
  Median Mittel / p95:

  | Stufe | `origin/main` | Runde 4 |
  | --- | --- | --- |
  | `balanced` (0,67, MetalFX) | 11,10 / 12,10 ms | 10,94 / 11,89 ms |
  | `quality` (1,0) | 17,73 / 20,17 ms | 16,96 / 19,31 ms |

  Kein Mehraufwand; eher etwas schneller (Korridor erst ab höherer
  Deckkraft, weniger Fäden), innerhalb von ±0,8 ms.
