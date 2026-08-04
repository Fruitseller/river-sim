# river-sim

Interaktive Landschafts-Evolution: ein prozedural erzeugtes Insel-Terrain, das
über Jahrtausende im Zeitraffer erodiert — Flüsse schneiden Täler, Mäander
wandern, Seen entstehen und verlanden. Simulationskern in reinem Swift,
Rendering und Interaktion in Godot 4 (via GDExtension/SwiftGodot).

![Terrain nach 20.000 Jahren](docs/screenshots/terrain-20k.png)

| 100.000 Jahre (gleicher Seed) | anderer Seed |
| --- | --- |
| ![100k Jahre](docs/screenshots/terrain-100k.png) | ![Seed 907](docs/screenshots/terrain-seed907.png) |

## Was drinsteckt

- **Fluviale Inzision** — FastScape-Stream-Power mit implizitem Solver,
  stabil auch bei 10.000-Jahr-Schritten.
- **Droplet-Hydraulik-Erosion** (nickmcd/Lague) — carvt feines dendritisches
  Detail; Stream-Map aus zeitgemittelten Tropfenpfaden.
- **Entwässerung** — Priority-Flood, MFD-Einzugsgebiete, Becken entwässern
  über Auslass-Inzision statt vollzulaufen.
- **Mäander-Migration** — wandernde Zentrumslinien, die ihr eigenes Bett
  carven; Altarm-Seen und Verlandung.
- **Pre-Erosion** — Port des [runevision-Erosionsfilters](docs/references/runevision-erosion/README.md),
  damit das Terrain schon „gealtert" startet.
- **Klima** — orographischer Niederschlag, Vegetation als Erosionsschutz,
  Hangprozesse, Küsten-Wellenerosion.

Details: [SimCore/README.md](SimCore/README.md) und [docs/](docs/).

## Bauen & Starten (macOS)

Voraussetzungen: Swift 6-Toolchain (Xcode), [Godot 4](https://godotengine.org)
(getestet mit 4.7).

```sh
./scripts/build.sh          # baut die GDExtension nach game/bin/ und signiert sie
godot --path game           # oder game/project.godot im Godot-Editor öffnen
```

Steuerung: Linksklick formt das Terrain (Shift kehrt um), Rechtsklick dreht,
`+`/`−` oder Pinch zoomt. Die Zeitraffer-Knöpfe (10/30/60 J/s, +100 bis
+10.000 Jahre) treiben die Simulation.

## Tests

Der Kern ist Godot-frei und headless verifizierbar:

```sh
swift test -c release --package-path SimCore
```

## Lizenz

[0BSD](LICENSE). Ausnahme: `ErosionFilter.swift` und der Referenz-Shader sind
MPL-2.0 (© Rune Skovbo Johansen), Details in [NOTICE](NOTICE).
