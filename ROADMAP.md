# river-sim — Roadmap & offene Ideen

Stand: nach dem echten Fluss-Netz (variable Breite + Render-Mäander). Kern ist eine
**Simulation** (Zeit vergeht → Erosion/Tektonik/Sediment formen die Welt), kein Generator.

## ✅ Umgesetzt — Mäander-Migration (M1–M4)

Flüsse *wandern* jetzt über die Zeit: Prallhang erodiert, Gleithang lagert ab, Schlingen
schnüren sich ab und hinterlassen **Altarme / river-history** im Höhenfeld. Echtes
Simulations-Feature, gekoppelt ans Terrain (kein Render-Trick mehr).

**Architektur:**
- `Meander.swift`: Fluss als persistente Lagrange-Zentrumslinie (`MeanderState`), Migration
  ∝ Krümmung × Abfluss (Howard–Knutson, zum Außenufer), Resample, Cutoff → Altarm.
- `Terrain.step()`: `migrateMeander` (Abfluss/Mobilität aus D8) → `meanderStamp` (Bett-Carve,
  der Kanal carvt sein eigenes Bett self-reinforcing mit D8; laterale Prallhang/Gleithang-
  Bewegung; Cutoff-Pfropf → Altarm-See über den bestehenden `hf>h`-Mechanismus) →
  `transportLimited` (auf Kanalzellen gedämpft, Reconciliation).
- `SimNode.buildRivers`: Rendering aus den echten Zentrumslinien + Altarmen.
- Golden-Tests: Sinuosität wächst→sättigt (~2.3), Masse/Relief erhalten, keine weiträumige
  Selbst-Durchdringung, Bett unter Aue, Altarm-See nach Cutoff. Alle 18 grün.

**Kalibrierung (Erkenntnisse):** Mobilitäts-Gate auf die *Längs*neigung (nicht Quer-, die an
eingetieften Kanälen die Migration selbst abschaltet); kMig = 5e-5; Displacement-Clamp (CFL).

**Offene Feinschliff-Punkte:**
- Terrain wirkt bei ~80k Jahren stellenweise „ersäuft" (viel Wasser in den Tälern) — prüfen,
  ob Carve/Damp die Talsohlen zu breit flutet.
- Altarm-Verlandung über `oxbowAge` sichtbar machen (Rendering + langsames Zuwachsen).
- Downstream-Skew via Upstream-gewichteter Krümmung (Ikeda–Parker–Sawai) für realistischere,
  asymmetrische Schlingen — bewusst nach der lokalen Variante.

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
