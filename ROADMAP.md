# river-sim — Stand, Roadmap & offene Punkte

Kern ist eine **Simulation** (Zeit vergeht → Erosion/Tektonik/Sediment formen die Welt),
kein Generator. Architektur und Grundentscheidungen: `PLAN.md`.

Ziel-Look: https://nickmcd.me/2020/04/15/procedural-hydrology/ — feine dendritische
Erosions-Rinnen, grauer Fels, moosgrüne Täler, weiße Gipfel, dezentes teal-Wasser.
Der Verhaltens-Abgleich mit dieser Referenz steht in
`docs/nickmcd-behavior-verification.md`.

## Aktueller Stand (Kurzfassung)

- **Erosion/Terrain:** Droplet-Hydraulik (`Hydraulic.swift`, Lague/nickmcd) legt die
  feine Textur, Flächen-Stream-Power (`outletIncision`) trägt die Makro-Täler, lineare
  Hangdiffusion (`hillslopeDiffusion`) rundet die Grate. Prozess-Reihenfolge LEM-konform:
  Uplift → Flow → SPL/Auslass → Braiding → Droplet → Diffusion → Wave.
  Pre-Erosion + Shader-Detail-Layer nach runevision (`ErosionFilter.swift`).
- **Anti-Runaway / Anti-Verflachung:** `isoHighClamp` deckelt das Relief, niedrige
  Hebung (`upliftPer100y`) lässt Berge erodieren statt wachsen, der **Relief-Servo**
  (`reliefServoPer100y`, nur bei Relief-Defizit und nur auf Land) verhindert das
  „immer flacher" über 100k+ Jahre.
- **Hydrologie:** Priority-Flood + D8 für Erosion, MFD (Freeman/Quinn) für Render und
  Braiding, EWMA-geglättete Stream-Map, Pool-Kopplung (Descend→Flood→Drain),
  Becken-Breach bei der Generierung (Becken entwässern zum Meer).
- **Flüsse:** Mäander als persistente Lagrange-Zentrumslinie (`Meander.swift`, Migration
  ∝ Krümmung × Abfluss, Cutoff → Altarm, Sinuositäts-Deckel), Braiding nach
  Murray & Paola (`braidPass`), Wasser-Optik im Shader (eigene Wasser-Normale,
  Fresnel, Tiefenfarbe, distanz-gefadet).
- **Karte:** n = 832 bei worldSize 130 (cellSize ≈ 0.156 — Auflösung und Weltgröße
  immer ZUSAMMEN ändern, sonst brechen alle per-Zell-Kalibrierungen).
- **Vegetation:** `veg` (Dichte 0..1, τ=250a) + Klassen `vegClass` (kahl/Gras/Wald/
  Auwald, aus veg + Flussnähe + Makro-Steigung; Flussnähe aus dem D8-Netz `area`,
  nicht aus `areaMFD` — die Klassen gehen über `vegDamp` in die Erosion).
  Klassen gewichten die 0.6-Erosions-
  Dämpfung (Gras 1.0 = Alt-Verhalten, Wald 1.1, Auwald 1.3), Auwald bremst die
  Mäander-Migration (`meanderCohesion`). Störung: Flood-Kill (τ_kill=20a) +
  Ufer-Kill (Mäander-Bett → veg=0); Regrünung per Sukzessions-Samen-Druck
  (Dispersal-Radius 2, nur bewohnbare Standorte). Rendering: 3D-Bäume als
  MultiMesh (`treeInstanceBuffer`, deterministischer Hash-Jitter, ~26k Instanzen,
  Rebuild nur bei Max-Δveg > 0.1).

## Offene Punkte

**Braiding-Kalibrierung (behoben, weiter beobachten):**
Die Kapazität des Murray-&-Paola-`braidPass` wurde auf `5e-6` gesenkt. Damit
lagern überlastete, flache Reaches wieder Bänke ab: `testBraidingBuildsBars`
(n=256, seed 1337) misst Insel-Summe an=9 vs. aus=4 und Splits-Max 336 vs.
260. Die Insel-Metrik bleibt bei einstelligen Zählwerten empfindlich; bei
künftigen Änderungen zusätzlich Bank-Fläche innerhalb nasser Läufe und Splits
pro Trunk-Länge über mehrere Seeds messen.

**Terrain-Alterung (aus `docs/research-terrain-aging.md` §6):**
- `isoHighClamp` (0.90) testweise lockern/entfernen — laut Recherche mit der
  Hangdiffusion überflüssig; aktuell pinnt der Deckel das Relief aufs junge Niveau
  statt echte Alterung zuzulassen. Per Headless-Messung prüfen (LongRunCollapse).
- Optional/größer: abklingende Hebung `U(t) = U_floor + (U₀−U_floor)·e^(−t/τ)` für ein
  dramatischeres „jung → alt". Bewusst NICHT gemacht, weil U₀ > heute einen
  Wachstums-Puls einführt (User will kein Wachsen).
- Diagnose-Messgrößen fehlen: mittlere Grat-Krümmung (∇²z auf Gratzellen) und
  hypsometrische Kurve. Sie trennen „spitz/jung" von „rund/alt" objektiv.

**Politur / Rendering:**
- **Deltas** an Fluss-Mündungen in Meer/Seen sichtbar machen (das Transport-Modell baut
  sie schon, das Rendering hebt sie nicht hervor).
- See-Ränder minimal gezackt (per-Zelle-Quads) — zu einer Kontur glätten.
- Steile Oberläufe der Fluss-Geometrie leicht segmentiert — feinere Glättung oder
  adaptive Unterteilung.
- Optik-Feinschliff: Grün-Anteil in den Tälern, Schnee-Schwelle, Küstensaum-Breite.

**Toter/geparkter Code (aufräumen oder bewusst behalten):**
- `thermalPass` (Talus) ist implementiert, wird aber nirgends aufgerufen — Talus macht
  planare Facetten, keine Rundung; nur für Steilfels-Kappen sinnvoll.
- `floodplainAggradation` liegt deaktiviert als Referenz herum (`floodplainEnabled=false`):
  per-Zell-Aggradation fügte gemessen 2.7× Zerklüftung/Krusten hinzu. Die Auen kommen
  jetzt über sanfteres Relief (`baseRelief` 0.78).

**Backlog (nicht priorisiert):**
- Gletscher / glaziale Erosion → U-Täler, Kare, Moränen.
- Gekachelte Welt mit LOD + GPU-Compute für die Grid-PDEs (1024²+ in Echtzeit).
- Klima-Jahreszeiten → schwankender Abfluss, Schneedecke, Hochwasser.
- Speichern/Laden von Welten.
- Gameplay (falls gewünscht): Ziele/Szenarien statt reinem Sandbox.

## Verifikation

- **Headless-Tests:** `cd SimCore && swift test -c release` (Debug ist bei n=832 zu
  langsam). Beim Iterieren `--filter <methodName>` — **nicht** den Klassennamen, der
  matcht 0 Tests. Wächter: `LongRunCollapse.swift` (kein Runaway/Kollaps),
  `RiverDynamicsTests.swift` (MFD-Splits, Braiding-Bänke, Becken→Meer, Stream-Map,
  Mäander in Produktion).
- **Extension bauen** (~3,5 min): `./scripts/build.sh release` — **immer mit absolutem
  Pfad aufrufen.** Relativ aus `game/` heraus schlägt es still fehl, und die Screenshots
  laufen dann mit der ALTEN dylib (hat schon 3 „wirkungslose" Iterationen gekostet).
  Auf die „gebaut + signiert"-Zeile prüfen.
- **Screenshots headless** (Godot via Steam):
  ```
  GODOT="$HOME/Library/Application Support/Steam/steamapps/common/Godot Engine/Godot.app/Contents/MacOS/Godot"
  RS_STEP=<jahre> RS_SHOT=/pfad/shot.png RS_DIST=<kameradistanz> "$GODOT" --path game
  ```
  `RS_STEP` steppt die Sim vor dem Shot (Jahr 0 vs. gesteppt vergleichen!). Das Jahr-Label
  bleibt dabei auf „Jahr 0" (`_ready` ruft `_update_year` nicht) — kein Bug.
  Springen/Dynamik sind nur in BEWEGUNG sichtbar, nicht im Standbild.
- **App interaktiv:** `"$GODOT" --path game` (oder `--editor`).
- **Shader-Debug-Rezept:** ALBEDO im Shader auf `(riverMask, lakeMask, stream)` legen;
  `RS_NO_MEANDER_PAINT=1` schaltet die Mäander-Stempel für A/B ohne Rebuild ab.

## Wichtige Dateien

- `SimCore/Sources/SimCore/Terrain.swift` — `generate()`, `step()`, `computeFlow`,
  `outletIncision`, `braidPass`, `meanderStamp`, `diffusionPass`.
- `SimCore/Sources/SimCore/Hydraulic.swift` — Droplet-Erosion (Textur + Stream-Map + Pools).
- `SimCore/Sources/SimCore/Meander.swift` — Lagrange-Zentrumslinie, Migration, Cutoff.
- `SimCore/Sources/SimCore/ErosionFilter.swift` — runevision-Pre-Erosion (Phacelle Noise).
- `SimCore/Sources/SimCore/Config.swift` — **alle** Stellschrauben, jede mit Begründung.
- `Extension/Sources/RiverSimGD/SimNode.swift` — `terrainColorBytes` (Palette),
  `waterFieldBytes` (Wasser-Feld, EWMA, Render-Schwellen).
- `game/shaders/terrain.gdshader` — Wasser-Overlay, Detail-Layer, Shading.
- `game/scripts/Main.gd` — Licht/Environment, UI, Kamera/Zoom, RS_*-Env-Schalter.

## Arbeitsweise in diesem Projekt (ernst nehmen)

- **Erst headless messen, dann schrauben.** Die visuelle Hypothese war mehrfach falsch
  (der „Kuppel-Kollaps" war ein Runaway; die „Punktfeld-Blobs" waren Mäander-Stempel,
  nicht Seen). Kennzahlen über die Zeit loggen (Relief, Ruggedness, See-Anteil, meanLand).
- **Nicht zaghaft** („MVP vom MVP"), aber auch nicht blind an Details schrauben, wenn das
  Gesamtbild nicht stimmt.
- Bei „30 % besser statt 1 %" auf **echte Recherche mit Primärquellen** gehen (`docs/`),
  nicht weiter am Symptom drehen.
- **Kalibrier-Kaskade beachten:** Änderungen am Droplet-Pfad verschieben die
  Braiding-Kalibrierung, Rinnen-Textur bricht Formeln, die Per-Zell-Steigung als „Hang"
  lesen (Regen/Vegetation/Biom-Farbe brauchen Makro-Steigung über ±2 Zellen).

## Recherche (in den Ansatz eingeflossen)

- `docs/research-braided-meandering-rivers.md` — Freeman/Quinn MFD, Tarboton D-∞,
  Murray & Paola (zelluläres Braiding), Ikeda/Howard (Mäander), Nicholas-Kontinuum.
- `docs/research-terrain-aging.md` — Theodoratos 2018, Whipple & Tucker, Braun & Willett;
  Kennzahl `l_c = D/K` (klein = jung/zerklüftet, groß = alt/rund).
- `docs/river-baseline-metrics.md` — Baseline-Messung vor dem Fluss-Overhaul
  (Churn 0.2725 bei jedem dt = Framerate-Kopplung des alten D8-argmax).
- `docs/references/runevision-erosion/` — kompletter GLSL-Code des Erosionsfilters
  (MPL-2.0), Grundlage von `ErosionFilter.swift` und des Shader-Detail-Layers.
- nickmcd.me (Procedural Hydrology, Meandering Rivers), SebLague/Elumenix (Droplet).
