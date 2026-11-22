# Fluss-Optik: Befunde des Gremiums 1–3 (Folge zu Look E, #239)

Stand 2026-11-22, Zweig `look-river-fixes` auf `origin/main` (3a42e41).

Ein Gremium aus drei Modellen bewertete Screenshots der Flüsse mit 4, 4 und
5 von 10: die Totale trägt, aus der Nähe zerfallen die Läufe. Dieser Stand
behebt den Fluss-Cluster (Befunde 1–3) und prüft Befund 4 (Mündungen).
Welt Seed 7, Jahr 20.000, `quality`, maximiert 3456×2104.

- `uebersicht.jpg`: `RS_CAMERA=diorama|valley|close`, vorher | nachher
- `details-1-4.jpg`, `details-5-8.jpg`: die acht Detail-Kameras des Auftrags
- `ausschnitte.jpg`: Ausschnitte aus Detail 2 und 7 in voller Auflösung

## Befund 1: „Fluss im Fluss"

Am Bild bestätigt, drei Ursachen:

- **Zwei Wasserkanten.** Mit Korridor reichte das Wasser des Bands bis 92 %
  der Bandbreite, die Uferlinie des Korridors lag bei 65 % der
  Wasser-Halbbreite. Dazwischen lag ein halbtransparenter Wasserfilm über der
  trockenen Böschung (der helle türkise Streifen). Jetzt endet das Band genau
  an der Uferlinie des Korridors, je Seite und im Bogen verschoben.
  Anteil und Bogen-Verschiebung stehen als `WaterRender.corridorShoreFraction`
  und `corridorShoreBendShift` im Kalibrier-Register (`water_corridor_shore*`)
  und werden von `CorridorProfile`, `water.gdshader` und
  `corridor.gdshaderinc` gelesen.
- **Zwei Wässer.** Der Korridor malte den Wasserkörper selbst nach
  Beer-Lambert mit eigenen Konstanten (`WATER_ABSORB`, `WATER_INSCATTER`):
  fast schwarzer Kern, heller Rand, ein anderer Ton als Seen und Zubringer.
  Jetzt deckt das Band nach der gemeinsamen Deckkraft-Rampe
  (`water_opacity_shallow/deep`), darunter zeigt der Korridor das gemeinsame
  Bett (`water_bed_color`, im Flachwasser am Gleithang Kies).
- **Doppelte helle Bänder.** Die Korridor-Kiesbank lag neben dem Sand der
  Bank im Gelände (`BarMaterial`). Der Korridor malt seine trockene Bank nicht
  mehr selbst, dort scheint das Gelände samt Sand durch. Der nasse Saum ist
  ein schmales Band jenseits der Uferlinie (Querversatz, höchstens 0,05 Welt),
  kein Höhenfenster mehr, das auf flacher Aue die ganze Böschung deckte.

Der dunkle Raster-Ufersaum des Terrain-Shaders unter Korridoren war in den
Ausschnitten nicht mehr als eigene Kante zu sehen und blieb unverändert.

## Befund 2: Splitter, Falten, Querwände

- **Ufersuche ohne Glättung**: die gefundene Uferkante wird längs geglättet
  (Median über 5, dann Kastenmittel über 5 Stützpunkte,
  `CorridorSections.smoothEdges`).
- **Innenbogen**: die Reichweite der Innenseite ist auf 0,85 × Krümmungsradius
  gedeckelt (`CorridorSections.innerReachShare`), mit Platz für Böschung und
  Fuß jenseits der Uferlinie.
- **Bandenden**: das Profil läuft über 4 Stützpunkte aus statt abrupt zu enden.
- **Zusammenflüsse**: Korridor-Dreiecke im Wasser eines anderen Bands fallen
  weg (`RiverRibbonRenderer.fadeCorridorsInForeignWater`): im Wasser eines
  früher gebauten Bands jeder Teil, im Wasser eines später gebauten nur das
  trockene Ufer außerhalb des eigenen Wassers (die Mündung des Zubringers).
- **Z-Fighting** (ein Gutachter): bestätigt. `CORRIDOR_DEPTH_KEEP_MAX` legte
  per `min()` alles, was mehr als 0,1 unter dem Deckel lag, auf DIESELBE
  Tiefe; Wasser und Bett kämpften. Sichtbar wurde das erst, als der Korridor
  das Wasser nicht mehr selbst malte: das Band riss in Querstreifen auf. Drei
  Ursachen, drei Änderungen:
  - die Kompression ist sättigend statt gekappt (streng monoton);
  - das Band trägt an den Zwischen-Stützpunkten den interpolierten Deckel des
    Korridors, der nur jeden zweiten Querschnitt baut
    (`CorridorBandBuilder.meshLids`), und den vollen Deckel schon ab
    `lidPresence` statt anteilig (Auslauf vor Kaskaden-Tümpeln);
  - das Bett unter Wasser zeichnet in einem eigenen Durchgang OHNE Tiefe
    (`corridor_wet.gdshader`); nur das trockene Ufer schreibt Tiefe. Das Band
    liegt immer über dem Bett, das Bett testet weiter gegen das Gelände.
  - Dazu blendete die See-Maske des Bands („EINE Seite malt") das Band über
    Tümpeln im Gerinne aus, obwohl der Korridor dort den Raster-See verdeckt;
    mit Korridor gilt sie nicht mehr.
- **`corridor_widen`**: geprüft (A/B mit Faktor 1), nicht die Ursache der
  Splitter in den Detail-Kameras; unverändert.
- **Uferwall auf flacher Aue**: unverändert; nach der Glättung nicht mehr
  als eigene Kante zu sehen.

Nicht behoben (s. Folgepunkte): die hellen gläsernen „Klingen" in Detail 1
sind kurze Mäander-Stummel mit voller Deckkraft, die ohne Talung über die
Wiese laufen (Debug-Färbung: Typ Fluss, Deckkraft 1, nicht im Meer; ohne
Verbreiterung und ohne versiegende Arme unverändert).

## Befund 3: Schaum und Glitzern

- Schaum nur noch aus den Lauf-Größen (`flows`: Weißwasser, Riffel), weich
  über ein breites Fenster auf Strömungsstreifen UND einem runden Rauschen;
  der eigene Außenbogen-Schaum (`waterFoamOuter`) ist entfernt.
- Glitzern: Zellgröße in Zweierpotenzen der Pixelgröße, je Zelle ein runder
  Punkt an zufälliger Stelle statt der ganzen Zelle, halbe Emission (3 statt 6).

## Befund 4: Mündungen (geprüft)

- Die Vermutung eines Gutachters stimmt: mit `ribbonSeaSurfaceSink` (−0,06)
  liegt das Band im Meer unter der opaken Ozeanfläche; seine Blende in die
  Schelffarbe (`water_ocean_shallow_color`, `in_sea`) ist nie sichtbar.
- Der Strand quer durch die Mündung in Detail 5 ist aber Raster-Wasser, das
  am Strandwall endet, kein Band (A/B ohne `fadeUphill`: unverändert).
  Beides bleibt Folgepunkt.

## Messung

- SimCore-Suite: 679 Tests, 0 Fehler (macOS, M4 Max).
- `simperf --hash`: 95cf93ca1b40985c vorher und nachher.
- Godot-Vertragstests headless: alle Marken, kein `FAIL:`.
- Bildzeit: `scripts/timelapse-timing.sh`, interleaved alt/neu, 4 Runden je
  Stand, `RS_TIMING_EXCLUSIVE=1` (kein fremdes Godot in allen 32 Läufen),
  Flusstal-Bühne im Zeitraffer (Seed 1337, Jahr 20.000), maximiert 3456×2104
  auf dem M4-Max-Referenz-Mac. `balanced` rendert mit 0,67 je Achse (MetalFX),
  `quality` nativ. Median über die Runden, Mittel / p95:

  | Stufe, Kamera | vorher | nachher |
  | --- | --- | --- |
  | `balanced` (0,67), `detail` | 10,80 / 12,12 ms | 11,28 / 12,71 ms |
  | `balanced` (0,67), `nah` (17,10; 16; 0; 0,55) | 11,73 / 13,40 ms | 11,93 / 13,50 ms |
  | `quality` (1,0), `detail` | 17,45 / 19,72 ms | 17,79 / 20,13 ms |
  | `quality` (1,0), `nah` | 17,45 / 19,78 ms | 18,06 / 20,40 ms |

  +0,2 bis +0,6 ms Mittel (1–4 %), vor allem der zweite Korridor-Durchgang
  (dasselbe Mesh noch einmal, Bett ohne Tiefe). Budget 33,3 ms bleibt weit.

## Folgepunkte

Aus dem Auftrag ausgeklammert: Talnebel als Fleck/Platte,
Sägezahn-Waldkanten (`tree_instances`), Zellraster-Konturen von Teichen und
Sand gegen die 2880²-Fläche, glatte Talwiesen, Ozean-Streifenmuster,
Tilt-Shift-Schlieren, zu viele gleich breite Arme. Dazu aus diesem Stand:

- kurze Mäander-Stummel ohne Talung (gläserne Klingen über der Wiese);
- Mündung: tote Meeres-Blende im Band, Raster-Wasser endet am Strandwall;
- in der Totalen wirken die Läufe mit dem gemeinsamen Tiefwasser-Ton
  dunkler als vorher.
