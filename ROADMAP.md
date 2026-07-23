# river-sim — Roadmap & offene Ideen

Stand: nach dem echten Fluss-Netz (variable Breite + Render-Mäander). Kern ist eine
**Simulation** (Zeit vergeht → Erosion/Tektonik/Sediment formen die Welt), kein Generator.

## Nächster großer Schritt (Vorschlag) — Mäander-Migration

**Ziel:** Flüsse, die über die Zeit *wandern* wie in Gaea 3 — Prallhang (Außenkurve)
erodiert, Gleithang (Innenkurve) lagert ab → die Schlingen verschieben sich, schnüren
sich ab und hinterlassen **Altarme / „river history"**. Echtes Simulations-Feature,
nicht bloß Render-Sinuosität.

**Warum:** Macht river-sim einzigartig (kaum ein Spiel simuliert das), passt exakt zur
Simulations-Idee, und ist headless testbar (Sinuositäts-/Massen-Metriken).

**Skizze der Umsetzung (SimCore, headless testbar):**
- Flusslauf als Polylinie/Zentrumslinie mit Krümmung pro Segment führen (nicht nur D8).
- Laterale Verschiebung ∝ Krümmung × Abfluss: Außenufer erodieren, Innenufer Sediment
  ablagern (massenerhaltend, koppelt an das bestehende Transport-Modell `transportLimited`).
- Abschnürung (cutoff), wenn zwei Schlingen sich zu nah kommen → Altarm-See.
- Nur in flachen Abschnitten aktiv (Gefälle < Schwelle); steile Oberläufe bleiben gerade.
- Golden-Tests: Sinuosität wächst dann sättigt, Masse erhalten, keine Selbst-Durchdringung.

**Aufwand:** groß (mehrere Iterationen), aber gut abgrenzbar.

## Kleinere offene Punkte (Politur)

- **Steile Oberläufe** der Fluss-Geometrie noch leicht segmentiert — feinere Glättung
  oder adaptive Unterteilung.
- **See-Ränder** minimal gezackt (per-Zelle-Quads) — könnte man zu einer Kontur glätten.
- **Fluss-Übergang** ins Meer/in Seen: echte **Deltas** sichtbar machen (Transport-Modell
  baut sie schon; Rendering hebt sie noch nicht hervor).

## Weitere M3-Feature-Ideen (Backlog, nicht priorisiert)

- **Gletscher / glaziale Erosion** → U-Täler, Kare, Moränen (Höhen-/Temperatur-gekoppelt).
- **Größere / gekachelte Welt** mit LOD + **GPU-Compute** für die Grid-PDEs (1024²+ in Echtzeit).
- **Klima-Jahreszeiten** → schwankender Abfluss, Schneedecke, Hochwasser-Ereignisse.
- **Speichern/Laden** von Welten.
- **Gameplay** (falls gewünscht): Ziele/Szenarien statt reinem Sandbox.

## Recherche-Quellen (gesichtet, in den Ansatz eingeflossen)

- **Bremen CGI22** — „Procedural Generation of Landscapes with Water Bodies Using
  Artificial Drainage Basins" (rivers-first, Breite ∝ Fluss-Stärke). Generierung, nicht Sim.
- **Gaea 3** (QuadSpinner) — Mäander + river-history als visuelles Highlight (Vorbild fürs Ziel oben).
- **nickmcd.me/2020/04/15/procedural-hydrology** — Partikel-Erosion, stream-map (EMA),
  pool-flood, self-reinforcing Flüsse.
- **SebLague/Hydraulic-Erosion & Elumenix/HydroErosion** — Droplet-Methode (= der
  ursprüngliche Prototyp), GPU-Varianten. Algorithmisch nichts Neues für uns.

**Bewusste Entscheidung:** kein Rewrite auf Droplet oder „rivers-first"-Generierung —
river-sim bleibt eine deterministische, headless-testbare Grid-Simulation
(Stream-Power + transport-limitierter Sedimenttransport).
