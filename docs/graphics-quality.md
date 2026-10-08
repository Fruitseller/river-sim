# Landschaftsqualität: Flusstal-Studie #116

Stand: 8. Oktober 2026, zweite Runde. Ausführbarer Prototyp, visuelle Abnahme
noch offen. Teil 2, Issue #117, beginnt erst nach ausdrücklicher Bestätigung
des Bildsprungs.

## Abgestimmtes Ziel

Der Projekteigner hat ein felsiges, dramatisches Tal nach dem Vorbild der Soča
gewählt. Helle gebrochene Felsflächen sollen sich von dunkleren Waldgruppen
absetzen, der Fluss muss auch aus der normalen Übersicht lesbar sein. Das ist
eine Bildstudie auf einer unveränderten Simulationswelt.

Zielmaschine ist der Apple M4 Max mit 40 GPU-Kernen und 64 GB RAM. Verbindlich
sind **3456×2104 Viewport-Pixel im maximierten Fenster** (internes Display,
Panel 3456×2234 abzüglich Fensterrahmen und Menüleiste), bei höchstens
**33,3 ms pro gerendertem Frame**.

## Warum eine zweite Runde

Die erste Runde (Commits bis `6c62e26`) tauschte im Wesentlichen die
Oberflächenfarbe: zwei PBR-Texturen, mehrteilige Kronen, handgesetzte Wald- und
Felsgruppen, etwas seitlicheres Licht. Der Projekteigner fand die Richtung gut,
den Unterschied aber zu klein. Die Analyse der A/B-Bilder ergab drei Ursachen,
die alle außerhalb der Oberflächenfarbe liegen:

1. **Form.** Das Mesh verschob ein 384er-Gitter (`balanced`) bilinear aus dem
   720er-Sim-Raster. Das feine Erosionsdetail wirkte nur auf Normalen, warf
   weder Silhouette noch Schatten und blendete ab ~120 Einheiten Abstand aus,
   in der Übersicht also fast ganz. Die Berge sahen aus wie Knete.
2. **Maßstab.** Eine Baumkrone war ~1 Einheit breit, das sind 7 Sim-Zellen oder
   bei einem Alpenrelief rund 90 m. Zusammen mit dem gestreiften Ozean las sich
   die Insel als Modell auf einem Tisch.
3. **Licht.** Hohe Sonne, kaum Luftperspektive, wenig Hell-Dunkel-Struktur.

Die zweite Runde setzt genau dort an, mit vier einzeln schaltbaren Hebeln.
Alle sind prozedural aus den Sim-Feldern abgeleitet. Die Handplatzierung der
ersten Runde ist entfallen, deshalb gilt die Studie für jeden Seed und bleibt
im Zeitraffer, nach Pinselstrichen und nach dem Laden aktiv.

## Die vier Hebel

`RS_STUDY_LEVERS` (Komma-Liste, Standard: alle) schaltet sie für die
Wirkungsleiter einzeln.

| Hebel | Was er tut | Wo |
| --- | --- | --- |
| `geometry` | Render-Gitter in Sim-Auflösung (720 statt 384). Grobe Erosionsrinnen (dieselbe runevision-Funktion wie das feine Detail, Skala 0.022 UV ≈ 2,5 km Wellenlänge) und einseitig geschärfte Grate als **echte Verschiebung**. Einmal je Terrain-Update in eine 1440²-Float-Textur gebacken; der Vertex-Shader liest die Höhe, der Fragment-Shader Steigung und Rinnen-Schattierung. | `relief_bake.gdshader`, `landscape.gdshaderinc` |
| `canopy` | Weltmaßstab 1 Einheit ≈ 100 m. Wald als **Kronendach im Terrain-Shader**: ~20 m angehobenes Volumen (Waldkanten werfen Schatten), Voronoi-Kronen von ~11 m (Laubbaum als Kuppel, Nadelbaum als Kegel, Anteil nach Höhenband), dunkle Lücken, Selbstschatten zum Kronenrand. Lichtungen aus Rauschen, kein Wald in Wänden, auf Schnee oder an Wasser. Ersetzt die Instanzbäume. | `landscape.gdshaderinc` |
| `light` | Seitenlicht von links quer zur Studienkamera (Azimut −50°, Höhe 28°, warm), 8192er-Schattenatlas mit vier Kaskaden, AgX-Tonemapping, Luftperspektive (exponentieller Nebel mit Himmelsanteil), Talnebel über dem Meer, Wolkenschatten über Land, Bändern und Meer, ein Drittel neutral-warmes Umgebungslicht gegen blaue Schattenseiten. | `Flusstal.gd`, `clouds.gdshaderinc` |
| `frame` | Ozean ohne Streifenmuster: Rausch-Wellen, die mit ihrer Pixelgröße ausblenden, statt drei Sinuswellen. Farbe aus der echten Wassertiefe über dem Sim-Schelf (türkis → tiefblau), gebrochener Brandungssaum. | `ocean.gdshaderinc` |

Außerdem ist der Kalkstein der ersten Runde dunkler und strukturierter: er lag
mit ~0,5–0,6 Albedo bei Schneeweiß und las sich unter Himmelslicht als Schnee.
Jetzt zwei Texturskalen und Verwitterungsstreifen in Fallrichtung
(`materials.gdshaderinc`).

**Wasser bleibt unangetastet.** Verschiebung und Kronendach enden an einer
Schutzmaske: Rasterwasser plus die Boundingbox jedes gebauten Band-Dreiecks
(der Raster-Deckel entfernt Wasser unter Bändern), über eine Mip-Stufe um etwa
zwei Zellen ausgedehnt. Die Gratschärfung hebt nur, senkt nie: kein Talboden
sinkt unter ein Band. Seen hebt der Vertex-Shader wie bisher auf den Spiegel,
dort gibt es keine Verschiebung. Die Bänder sampeln die sichtbare Oberfläche
des vollen Sim-Gitters (`setRenderGrid(N)`). Die Sim-Felder und
`SimCore` ändern sich nicht.

**Produktion bleibt unverändert.** Alle Studien-Hooks in `terrain.gdshader`,
`ocean.gdshader` und `water.gdshader` stehen hinter `#ifdef FLUSSTAL_STUDY`;
`Flusstal.gd` stellt das Define zur Laufzeit vor die Quelle. Einzige
Strukturänderung am Produktions-Shader: der runevision-Filter liegt jetzt in
`game/shaders/erosion_filter.gdshaderinc` (gleicher Code, Skala als Parameter),
damit der Back-Pass ihn mitbenutzt statt ihn zu kopieren. `NOTICE` führt die
Datei als MPL-2.0.

## Bildvergleich

Wirkungsleiter, jeweils kumulativ (Ausgangsstand → + Geometrie → +
Kronendach → + Licht/Atmosphäre → + Rahmen):

![Leiter Übersicht](screenshots/graphics-quality/ladder-overview.jpg)

![Leiter Ausschnitt](screenshots/graphics-quality/ladder-detail.jpg)

| Ausgangsstand | Prototyp, alle Hebel |
| --- | --- |
| ![Übersicht vorher](screenshots/graphics-quality/baseline-overview.png) | ![Übersicht nachher](screenshots/graphics-quality/prototype-overview.png) |
| ![Ausschnitt vorher](screenshots/graphics-quality/baseline-detail.png) | ![Ausschnitt nachher](screenshots/graphics-quality/prototype-detail.png) |

Verworfene Zwischenstände dieser Runde:

- **1440er-Render-Gitter.** Gleiche Bildwirkung wie 720, sobald Normalen und
  Rinnen aus der Backtextur kommen, aber doppelte Framezeit (s. Leistung).
- **Filter pro Vertex statt gebacken.** Tiefen-Vorpass, Farbpass und vier
  Schattenkaskaden werteten ihn je erneut aus: 35,6 ms je Bild.
- **Gegenlicht (Azimut −130°).** Dramatischer, mit Glanz auf dem Meer, legte
  aber alle der Kamera zugewandten Wände in den Schatten; dort verschwand das
  Relief.
- **Breite Schutzmaske** (Mip 3,5, Faktor 6): sperrte ganze Talböden für
  Verschiebung und Wald.

## Reproduktion

Ausgangscommit (main): `e56fb18074e6faed0c3eb5a600a4188dfabdbe06`, der Branch
ist darauf rebased. Godot 4.7.2 (Steam-Build, Metal Forward+); CI pinnt dieselbe
Version über `scripts/fetch-godot.sh`. Extension lokal mit
`scripts/build.sh release` gebaut, Build-Stempel geprüft.

`scripts/graphics-study.sh` legt Seed 1337, 20.000 Vorlaufjahre in Schritten von
1000 Jahren und `balanced` fest. Beide Varianten starten eine neue,
deterministisch identische Welt.

| Kamera | Ziel X/Z | Distanz | Yaw | Pitch |
| --- | --- | ---: | ---: | ---: |
| `overview` | 0 / 0 | 151.846515 | 0.7 | 0.85 |
| `detail` | -12 / -25 | 42 | 0.7 | 0.85 |

```sh
export GODOT=/pfad/Godot.app/Contents/MacOS/Godot
scripts/build-stamp.sh --check
"$GODOT" --headless --path game --import
scripts/graphics-study.sh prototype detail interactive
scripts/graphics-study.sh baseline detail interactive

# Der letzte Parameter ist ein absoluter Ausgabepfad ohne .png.
scripts/graphics-study.sh baseline overview shot /tmp/baseline-overview
scripts/graphics-study.sh prototype overview shot /tmp/prototype-overview

# Wirkungsleiter: einzelne Hebel
RS_STUDY_LEVERS=geometry,canopy scripts/graphics-study.sh prototype detail shot /tmp/gc

# Getrennte Echtzeitmessungen, immer maximiert.
scripts/graphics-study.sh prototype overview still /tmp/still
scripts/graphics-study.sh prototype overview orbit /tmp/orbit
scripts/graphics-study.sh prototype overview simulation /tmp/simulation
```

Weitere Schalter, alle in `Flusstal.gd`: `RS_STUDY_SUN="azimut,höhe"` (Grad),
`RS_STUDY_GRID` (Render-Gitter, für Messungen), `RS_STUDY_RELIEF="skala,stärke,schärfung"`
(Kalibrierung der groben Verschiebung) und `RS_STUDY_DEBUG=protect|forest|cavity`
(Schutzmaske, Waldmaske, Rinnen/Rippen als Falschfarbe). Ein unbekannter
Hebelname bricht wie eine ungültige Variante mit Fehler ab.

`shot` friert die Wasser-Animationsphase ein und speichert nach 60 gerenderten
Bildern. Ein normal gestartetes Spiel aktiviert die Studie nicht.

## Bewegung

Bewegungsaufnahmen mit Godots MovieWriter bei festen 30 Bildern pro Sekunde,
maximiert. Reproduzierbare Bewegungsbelege, keine FPS-Messungen.

```sh
RS_STUDY_MOVIE=/tmp/prototype-orbit.avi \
  scripts/graphics-study.sh prototype detail orbit /tmp/prototype-orbit
ffmpeg -i /tmp/prototype-orbit.avi -c:v libx264 -preset fast -crf 22 \
  -maxrate 20M -bufsize 40M -pix_fmt yuv420p \
  -an -movflags +faststart /tmp/prototype-orbit.mp4
```

| Aufnahme, jeweils 12 Sekunden bei 3456×2104 | Baseline | Prototyp |
| --- | --- | --- |
| Kamerafahrt im Ausschnitt | [MP4](screenshots/graphics-quality/baseline-orbit.mp4) | [MP4](screenshots/graphics-quality/prototype-orbit.mp4) |
| Simulationsfortschritt im Ausschnitt | [MP4](screenshots/graphics-quality/baseline-simulation.mp4) | [MP4](screenshots/graphics-quality/prototype-simulation.mp4) |

Die Kamerafahrt beginnt nach zwei Sekunden und dreht mit 0,08 rad/s. Im
Zeitraffer läuft stattdessen die Simulation mit 60 Jahren/s. Anders als in der
ersten Runde bleibt der Prototyp im Zeitraffer vollständig: Verschiebung,
Schutzmaske und Kronendach folgen jedem Terrain-Update. Die Encoderauflösung
legen die `movie`-Viewport-Einträge in `project.godot` fest (der MovieWriter
öffnet den Encoder vor dem Maximieren und ignoriert `--resolution` dafür).

## Leistung

`STUDY_TIMING` misst Intervalle zwischen tatsächlichen `frame_post_draw`-
Signalen, nach zwei Sekunden Einlauf für weitere zehn Sekunden, VSync und
FPS-Deckel aus, Renderloop auch bei stehender Kamera an. Mittelwert und
Perzentile sind Frameintervalle einschließlich CPU-Arbeit, keine
GPU-Zeitstempel.

Normale Übersicht, je ein sequenzieller Lauf ohne parallele Last, 8. Oktober
2026. Millisekunden; Rohdaten in
[measurements.json](screenshots/graphics-quality/measurements.json).

| Variante / Betrieb | Mittel | p95 | p99 | Maximum | Frames über 33,3 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Baseline, Standbild | 8,73 | 9,12 | 9,39 | 10,49 | 0 / 1147 |
| Prototyp, Standbild | 16,52 | 17,16 | 17,44 | 17,93 | 0 / 607 |
| Baseline, Kamerafahrt | 8,70 | 9,12 | 9,29 | 9,83 | 0 / 1150 |
| Prototyp, Kamerafahrt | 19,40 | 21,05 | 21,42 | 23,02 | 0 / 517 |
| Baseline, Zeitraffer | 10,96 | 11,21 | 70,08 | 79,35 | 39 / 913 |
| Prototyp, Zeitraffer | 22,11 | 51,86 | 98,49 | 105,90 | 38 / 453 |

Standbild und Kamerafahrt bleiben vollständig unter dem Budget, mit rund 40 %
Reserve. Der Zeitraffer überschreitet es in beiden Varianten bei derselben
Zahl von Frames (38 bzw. 39, die Simulationsschritte). Beim Prototyp sind diese
Spitzen höher, und weil insgesamt weniger Frames entstehen, ist ihr Anteil
doppelt so groß (p95 51,9 statt 11,2 ms). Ein durchgehend eingehaltenes
33,3-ms-Budget ist im Zeitraffer damit **nicht** nachgewiesen, in keiner
Variante.

Woher die Mehrkosten kommen (gemessen):

| Messung | ms/Bild, Standbild |
| --- | ---: |
| Render-Gitter 720 / 1080 / 1440, alle Hebel | 16,1 / 23,7 / 32,3 |
| Filter pro Vertex statt gebacken, 1440er-Gitter | 35,6 |
| nur `canopy` / nur `light` / nur `frame` (384er-Gitter) | 10,0 / 10,7 / 11,7 |

Die Kosten folgen der Vertexzahl. Die Hebel `canopy`, `light` und `frame` sind
im Vergleich billig. Im Zeitraffer kommen je Textur-Update ~1,4 ms
GDScript für die Schutzmaske dazu, je Fluss-Rebuild (höchstens 1 Hz) ~20 ms für
das Rastern der Band-Dreiecke. Für #117 ist das der erste Kandidat: die Maske
gehört als Ableitung in SimRender oder als GPU-Pass.

## Grenzen dieser Studie

- Die Verschiebung ist kosmetisch und nicht Teil der Sim-Höhe: Pinsel-Picking,
  Baum-Instanzen (hier ausgeschaltet) und alles, was `heightsBytes()` liest,
  sehen die glatte Sim-Fläche. Gemessen reicht der Zuschlag von −0,25 bis
  +1,0 Einheiten (Grate), meist deutlich weniger.
- Das Kronendach ist eine Oberfläche, keine Geometrie. Bei sehr flachem Blick
  fehlt ihm die Parallaxe einzelner Bäume. Für Nahsicht bräuchte #117
  zusätzlich echte Instanzen an Waldrändern.
- Wolkenschatten wirken als Albedo-Faktor und dunkeln damit auch etwas
  Umgebungslicht ab.
- Die Lichtstimmung ist auf die Studienkamera abgestimmt. In der normalen
  Anwendung dreht der Nutzer die Kamera; welches Licht dort trägt, ist eine
  eigene Entscheidung für #117.
- Großräumige Geländeformen ändert die Studie nicht. Die Frage aus #116, ob sie
  den Realismus begrenzen, beantwortet die Leiter teilweise: die gerenderte
  Verfeinerung trägt bereits den größten Einzelschritt.

## Assets und Lizenzen

Die sechs 1K-JPEGs liegen unverändert unter `game/studies/flusstal/assets/`.
Nach einem Klon ist kein Assetdienst erforderlich. `manifest.json` enthält die
Original-Downloadadressen, die vom Anbieter gelieferten MD5-Werte und
SHA-256-Prüfsummen der eingecheckten Dateien.

| Asset | Urheber | Nutzung |
| --- | --- | --- |
| [Rock Boulder Cracked](https://polyhaven.com/a/rock_boulder_cracked) | Dario Barresi, Dimitrios Savva | Farbe, OpenGL-Normale, Rauheit; Entsättigung im Shader |
| [Forest Ground 01](https://polyhaven.com/a/forrest_ground_01) | Rob Tuytel | Farbe, OpenGL-Normale, Rauheit |

Beide stehen unter [CC0](https://polyhaven.com/license); die freiwillige
Nennung steht hier. Kronen, Wolken, Ozean und Verschiebung sind vollständig
prozedural. Die Referenzfotos der Bildrichtung (Soča-Luftbild,
[soca-valley.com](https://www.soca-valley.com/en/accommodation/); Große
Soča-Schlucht, [pristava-lepena.com](https://pristava-lepena.com/en/attraction/velika-korita);
Isar im Vorkarwendel, [LBV](https://bad-toelz.lbv.de/unsere-arbeit/gebietsbetreuung-moore-und-isar/projektgebiet-isar/))
sind nur verlinkt, keine Spielassets.

## Verifikation und Übergabe

- `graphics_study.gd` (CI-Marke `GRAPHICS_STUDY_OK`) prüft: die Schutzmaske
  übernimmt Raster-Fluss und See, sperrt die ganze Boundingbox jedes
  Band-Dreiecks, lässt trockenes Land frei und verändert das Render-Wasserfeld
  nicht; die Hebel-Liste schaltet einzeln und ein Tippfehler bricht ab; die
  Studien-Fassungen von Terrain-, Ozean- und Band-Shader kompilieren und
  liefern ihre Uniforms, die Produktionsfassungen kennen sie nicht; der
  Back-Pass kompiliert.
- Lokal grün (8. Oktober 2026, macOS): SimCore-Pflichtsuite (392 Tests, 32
  übersprungene Messläufe, 0 Fehler), `smoke.gd`, `water_uniforms.gd`,
  `water_geometry.gd`, `river_ribbons.gd`, `graphics_study.gd`.
- Merge-Gate bleiben `test` und `godot-contract` in CI.
- Die visuelle Bestätigung des Projekteigners steht noch aus.

Für #117 übertragbar: Verschiebung als gebackene Render-Ableitung (gehört nach
SimRender oder als GPU-Pass in die Brücke), Kronendach statt Einzelbäumen in
der Übersicht, Schutzmaske aus Wasserfeld und Bändern, Ozean nach Wassertiefe.
Offen: Kamera-unabhängige Lichtwahl, Instanzbäume an Waldrändern für Nahsicht,
Kosten der Maske im Zeitraffer, Detailstufen jenseits eines festen 720er-Gitters.
