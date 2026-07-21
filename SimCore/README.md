# SimCore

Der plattform-unabhängige Simulationskern von **river-sim** — reines Swift, **keine
Godot-Abhängigkeit**, damit headless mit `swift test` verifizierbar.

## Modell

Landschaftsentwicklung als Kombination aus:

- **Fluviale Inzision** — FastScape-Stream-Power `dz/dt = U − K·Aᵐ·Sⁿ` (n = 1),
  impliziter Solver in Empfänger-Reihenfolge → **unbedingt stabil**, auch bei
  100k-Jahr-Schritten. Detachment-limited; Erodierbarkeit hängt von der
  Sedimentdecke ab (Cover-Effekt: Sediment weicher als Fels).
- **Entwässerung** — Priority-Flood (Barnes et al.) füllt Senken, D8-Routing auf der
  gefüllten Oberfläche, O(n)-Einzugsgebiets-Akkumulation. Seen = Füllhöhe > Gelände.
- **Hangprozesse** — thermische Erosion / Talus (höhenabhängig, Frostsprengung oben).
- **Tektonik** — fixes Hebungsfeld je Terrain, mit Isostasie-Dämpfung gegen Weglaufen.
- **Küste** — Wellenerosion in der Uferzone.
- **Klima/Vegetation** — orographischer Niederschlag (Wind aus Westen), Vegetation als
  Erosionsschutz.

## Verwendung

```swift
let t = Terrain(config: SimConfig(), seed: 2024)
t.step(dtYears: 10000)      // beliebig große Schritte sind stabil
_ = t.h                      // Höhenfeld (n×n, row-major)
```

## Tests

```
swift test -c release
```

Gesicherte Invarianten: Determinismus je Seed, Entwässerungs-Bilanz (Σ Senken =
Zellzahl), **beschränktes Relief / Fließgleichgewicht** (ersetzt die Masse-Erhaltung
des Droplet-Prototyps), Schicht-Konsistenz `h = rock + sed`, numerische Stabilität
(kein NaN, große Zeitschritte), Fluss-Stabilität zwischen Schritten.

Gemessene Relief-Trajektorie (Seed 2024, 128²): 0.505 → 0.335 → … → **stabil ~0.41**.
