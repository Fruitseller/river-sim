# SimCore

Der plattform-unabhängige Simulationskern von **river-sim** — reines Swift, **keine
Godot-Abhängigkeit**, damit headless mit `swift test` verifizierbar.

## Modell

Landschaftsentwicklung als Kombination aus:

- **Entwässerung** — Priority-Flood (Barnes et al.) füllt Senken, D8-Routing auf der
  gefüllten Oberfläche, O(n)-Einzugsgebiets-Akkumulation. Seen = Füllhöhe > Gelände.
  Zusätzlich ein Multi-Flow-Netz (Freeman/Quinn, `areaMFD`) — das speist **nur**
  Rendering und Braiding, nie die Erosion.
- **Fluviale Makro-Inzision** — `outletIncision`: flächenbasierte Stream-Power
  `dz/dt = −K·Aᵐ·S` (n = 1) über das **gesamte** D8-Entwässerungsnetz (nicht nur an
  den Auslässen — der Name ist historisch), impliziter Solver in Empfänger-Reihenfolge
  → **unbedingt stabil**, auch bei 100k-Jahr-Schritten. Trägt damit das kohärente
  Talnetz und schneidet nebenbei die Becken-Sillen durch, sodass Seen zum Meer
  entwässern. Erodierbarkeit hängt von der Sedimentdecke ab (Cover-Effekt: Sediment
  weicher als Fels).
- **Droplet-Erosion** — partikelbasierte Hydraulik (`Hydraulic.erode`) legt die feine
  dendritische Textur in die Makro-Täler.
- **Stream-Map** — zeitgemittelte Tropfen-Pfade (EWMA der Besuchs-RATE, dt-invariant):
  wo Wasser wirklich fließt. Koppelt in die Droplets zurück (River Sharpening) und ist
  die Render-Maske für Flüsse.
- **Mäander** — Lagrange-Zentrumslinien, die mit Krümmung × Abfluss lateral wandern,
  ins Höhenfeld carven und sich zu Altarmen abschnüren (Cutoff).
- **Braiding** — super-linearer Bedload-Transport auf dem MFD-Netz (Murray & Paola)
  baut Mittelbänke/Inseln, um die sich der Lauf teilt und wiedervereint.
- **Hangprozesse** — **lineare** Hangdiffusion `dh/dt = D·∇²h` (Bodenkriechen) mit
  räumlich variablem kappa: soil-mantled Hänge runden aus, hoher steiler Kahlfels
  bleibt scharf. Konvexe Kuppen statt der planaren Facetten der Talus-Methode.
- **Tektonik** — fixes Hebungsfeld je Terrain, mit Isostasie-Dämpfung gegen Weglaufen;
  Relief-Servo gegen langfristige Verflachung.
- **Küste** — Wellenerosion in der Uferzone.
- **Klima/Vegetation** — orographischer Niederschlag (Wind aus Westen), Vegetation als
  Erosionsschutz.

Die Reihenfolge der Pässe pro Zeitschritt ist LEM-Konvention und nicht beliebig — sie
steht im Klassenkopf von `Terrain` und in `AGENTS.md` (§ SimCore-Aufbau).

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
