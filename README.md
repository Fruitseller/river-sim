# river-sim

Ein Landschafts-Sandkasten: Du siehst eine Insel und drehst die Zeit um das
Tausendfache schneller. Flüsse graben Täler, schlängeln sich durchs Land,
Seen entstehen und verschwinden wieder, Berge flachen ab. Wo du willst,
greifst du ein und formst das Terrain selbst mit der Maus.

Es ist keine vorgetäuschte Animation: Die Landschaft entsteht aus einer
echten Erosions-Simulation: dieselbe Eingabe führt also immer zum selben
Verlauf, und kleine Eingriffe können sich über Jahrtausende auswirken.

![Terrain nach 20.000 Jahren](docs/screenshots/terrain-20k.png)

| 100.000 Jahre (gleicher Seed) | anderer Seed |
| --- | --- |
| ![100k Jahre](docs/screenshots/terrain-100k.png) | ![Seed 907](docs/screenshots/terrain-seed907.png) |

## Was macht man da?

- **Zeitraffer drücken** und zusehen, wie sich das Land selbst verändert:
  Flüsse werden länger und schlängeln sich, Täler werden tiefer,
  Flussbetten verlagern sich.
- **Eingreifen:** Mit dem Linksklick-Pinsel formst du Berge oder senkst Land
  ab (Shift dreht um). Der Fluss sucht sich danach seinen eigenen neuen Weg.
- **Zeit springen:** Von langsam (10 Jahre pro Sekunde) bis +10.000 Jahre
  auf einen Schlag.
- **Welten aufheben:** **F5** speichert die Welt, **F9** lädt sie zurück
  (Knöpfe 💾/📂 im Panel „WELT"). Eine gespeicherte Welt läuft exakt
  dort weiter, wo sie aufgehört hat.

Steuerung: Linksklick formt das Terrain, Rechtsklick dreht die Kamera,
`+`/`−` oder Pinch zoomt.

## Was steckt dahinter?

Der Anspruch ist, dass die Landschaft nach den Regeln funktioniert, nach
denen echte Flüsse und Berge sich formieren: Regen sammelt sich in
Abflussrinnen, Wasser trägt Material ab, wo es schnell fließt und lagert es
ab, wo es langsam wird, Vegetation bremst die Erosion, Schnee und Klima
bestimmen, wie viel Wasser überhaupt fließt. Darauf aufbauend entstehen
Schleifen von selbst: wandernde Flussschlingen, Altarme, Verlandungen,
Küsten, die von Wellen geglättet werden.

Wer es genauer wissen will: Der Simulationskern ist ein eigenes Swift-Paket
ohne Abhängigkeit zur Engine ([SimCore/README.md](SimCore/README.md)), die
Darstellung läuft in der [Godot](https://godotengine.org)-Engine (GDExtension
via SwiftGodot). Die Physik-Methoden und deren Quellen sind in
[docs/](docs/) dokumentiert, u. a. Stream-Power-Erosion (FastScape),
Droplet-Hydraulik, Mäander-Migration, Gletscher und Klima.

## Bauen & Starten

### macOS

Voraussetzungen: Swift 6-Toolchain (Xcode), [Godot 4](https://godotengine.org)
(getestet mit 4.7).

```sh
./scripts/build.sh          # baut die GDExtension nach game/bin/ und signiert sie
godot --path game           # oder game/project.godot im Godot-Editor öffnen
```

### Debian / Linux

Swift 6 wird benötigt (z. B. über Swiftly); Godot holt sich das Repo selbst in
der gepinnten Version nach `.tools/`:

```sh
./scripts/fetch-godot.sh    # Godot herunterladen und Prüfsumme verifizieren
./scripts/build.sh
./scripts/start.sh
```

`GODOT=/pfad/zu/godot ./scripts/start.sh` nutzt eine andere Godot-Installation.
Auf einer Maschine ohne Vulkan-Unterstützung startet
`./scripts/start.sh --rendering-method gl_compatibility`; ohne Display ist nur
der headless Modus sinnvoll.

### Leistung und Diagnose

Standard ist `RS_QUALITY=balanced`: Die Simulation bleibt bei 720×720, das
Terrain-Displacement nutzt aber ein 384×384-Gitter. `RS_QUALITY=quality` nutzt
die volle Geometrie; `RS_QUALITY=performance` verwendet 256×256, deaktiviert
SSAO, Glow und den kostspieligen Detail-Erosionsshader. `RS_RENDER_GRID=512`
überschreibt nur die Gittergröße. `RS_DIAG=1` gibt die Zeit eines 60-Jahr-
Simulationsschritts und zehn Texture-Updates aus.

Die Diagnosekarte im Spiel zeigt Höhenbereich, Landrelief (Spanne max − min und
daneben das robuste Servo-Regelsignal p95 − Median) sowie Höhen- und
Netto-Volumenabweichungen gegenüber einer frei setzbaren Referenz und den Zustand der
Relief-Servo. Die umschaltbare Δ-Karte färbt Abtrag blau und Aufbau rot. Nach
dem Einebnen sollte **Referenz setzen** gedrückt werden; dadurch wird sichtbar,
ob anschließend Täler eingeschnitten oder tatsächlich Berge aufgebaut werden.
`RS_DEBUG_DIFF=1` aktiviert die Δ-Karte für automatisierte Screenshots.

## Tests

Der Sim-Kern läuft ohne Godot und ohne Grafik, getestet wird headless:

```sh
swift test -c release --package-path SimCore
```

## Lizenz

[0BSD](LICENSE). Ausnahme: `ErosionFilter.swift` und der Referenz-Shader sind
MPL-2.0 (© Rune Skovbo Johansen), Details in [NOTICE](NOTICE).
