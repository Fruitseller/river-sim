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
