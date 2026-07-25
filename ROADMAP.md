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

**Feinschliff (erledigt):**
- ✅ „Ersäufte" Talsohlen diagnostiziert — **kein** Kopplungs-Bug: nasse Land-Zellen (hf>h)
  mit/ohne Mäander praktisch identisch. Wässrige Optik = Basis-Sim (Insel erodiert in
  Meeresspiegel-Nähe) + bewusst fette Fluss-Bänder. (Flag `meanderEnabled` für Diagnose.)
- ✅ Altarm-Verlandung: `fillOxbows` hebt Betten langsam (`oxbowFillYears`), verlandete fallen
  aus der Liste (`pruneOxbows`), Rendering blendet Altarm-Bänder mit dem Alter aus.
- ✅ Downstream-Skew (Ikeda–Parker–Sawai): upstream-gewichtete Krümmung (EMA), stärke-normiert
  → asymmetrische Schlingen ohne die Mäander-Rate zu dämpfen.

**Weiter offen (optional):**
- Falls die wässrige Langzeit-Optik stört: Basis-Sim-Balance (Uplift/Meeresspiegel) über sehr
  lange Läufe nachjustieren — betrifft das Grundterrain, nicht die Mäander.

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
