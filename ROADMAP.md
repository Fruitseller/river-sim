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
  Gehölz (Wald wie Auwald) sitzt am UFER, nicht im BETT: die Wasserlauf-Zellen
  selbst bleiben Gras (sonst panzert die Wurzel-Kohäsion den Talboden —
  s. Braiding unten).
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
lagern überlastete, flache Reaches wieder Bänke ab. `testBraidingBuildsBars`
misst seit Aug 2026 MULTI-SEED: die Einzel-Seed-Zählung flippte unter jeder
kleinen Physik-Störung (gemessen 9v3 → 2v4 durch das Verlandungs-Gate).

Nach dem Vegetations-Merge (PR #1) war der Wächter rot (Inseln an=7 vs. aus=14).
Headless-Diagnose (12 Seeds, an/aus): der Pass war NICHT schwächer geworden
(Braiding-Arm 36 → 37 Inseln), der KONTROLLARM ohne Braiding sammelte
Fehlalarme (19 → 31), obwohl dort nie ein Bänke-Pass läuft. Ursache: die
Auwald-Klasse landete auch auf den Wasserlauf-Zellen SELBST, womit die
kohäsivste Erosions-Dämpfung (1.3) auf Gerinne und Talboden lag — der Talboden
panzerte sich, stehen gebliebene Knubbel im breiten MFD-Lauf zählten als
„Insel". Korrektur in `updateVegClass`: GEHÖLZ (Wald wie Auwald) ist Ufer-,
keine Bett-Klasse — Bett-Zellen bleiben Gras (Faktor 1.0 = exakt die
Vor-Merge-Dämpfung), dieselbe Doktrin wie der Bett-Kill in `meanderStamp`.
Nur Auwald auszuschließen reichte nicht: dichte Bett-Zellen fielen dann auf
Wald (1.1) und blieben teil-gepanzert (an 79 vs. aus 50, Seeds 6:3 — ein Flip
von der Kante); erst die vollständige Entpanzerung gibt klaren Abstand.
Verworfen (gemessen): die Klassen-Dämpfung im `braidPass` selbst zurückzunehmen
— das machte den Kontrast SCHLECHTER (an 7→5 bei aus 14) und hätte einen realen
Effekt gelöscht (Ufer-Vegetation stabilisiert Bänke, Tal & Paola 2007).

Der ehemals offene Punkt „Bank-Fläche als robustere Metrik" ist damit erledigt:
der Wächter misst Bank-FLÄCHE über 16 Seeds und fordert zusätzlich einen
Mindestabstand von 3 Seeds (an 160 vs. aus 81 = 1.98×, Seeds dafür 9 /
dagegen 3, Inseln 62 vs. 33, Splits 3352 vs. 3059, ~33 s). Am Regressions-Stand
trennte die Insel-ZAHL nur 1.19×, die Fläche 1.77× — eine echte Mittelbank ist
mehrzellig, ein Ufer-Knubbel ein bis zwei Zellen. Optional weiter offen:
Splits pro Trunk-Länge als zusätzliche Metrik.

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
- ERLEDIGT (Aug 2026): „Hüpfende" See-/Schwemmflächen — Deposition am Becken-Auslass
  (Droplets+Braiding+Mäander gemeinsam, keine Einzelquelle) schüttet den Sill zu,
  Priority-Flood hebt `hf` instantan fürs ganze Becken, outletIncision schneidet in
  ~100 J. zurück (Sägezahn). Fix: ratenbegrenzter Darstellungs-Seespiegel
  `Terrain.waterLevel` (`lakeLevelResponseYears`, 250 J.), Physik bleibt auf `hf`;
  Wächter: `LakeLevelStability`.
- ERLEDIGT (Aug 2026): „Wachsender Boden ohne Wasser" — die Pfützen-Verlandung hob
  die kilometerbreiten Sub-0.06-Ufersäume der großen Seen als Ganzes an (90% der
  Tiefland-Hebung; ΔVol über 20k J. halbiert: +131→+68). Fix: `fillShallowPonds`
  verlandet nur noch Wasser-Komponenten OHNE See-Kern (< `puddleLakeCoreCells`
  tiefe Zellen); See-Ufer verlanden nur noch physisch über Droplet-Deltas.
  Ein träges Verlandungs-Ziel (waterLevel) und Größen-Schwellen waren gemessene
  Sackgassen (wirkungslos bzw. Braid-Bänke beschädigt, s. Config-Kommentare).
- **Deltas** an Fluss-Mündungen in Meer/Seen sichtbar machen (das Transport-Modell baut
  sie schon, das Rendering hebt sie nicht hervor).
- See-Ränder minimal gezackt (per-Zelle-Quads) — zu einer Kontur glätten.
- Steile Oberläufe der Fluss-Geometrie leicht segmentiert — feinere Glättung oder
  adaptive Unterteilung.
- Optik-Feinschliff: Grün-Anteil in den Tälern, Schnee-Schwelle, Küstensaum-Breite.

**Toter/geparkter Code (aufräumen oder bewusst behalten):**
- ERLEDIGT (Aug 2026): `streamPower` (detachment-limitierte Grid-Inzision) und
  `thermalPass` (Schwellen-Talus) ENTFERNT — beide waren seit ihrer Ablösung
  unreferenziert. Im Produktionspfad übernimmt die fluviale Makro-Inzision
  `outletIncision` + `Hydraulic.erode` (Droplet); `transportLimited` ist NICHT
  der Nachfolger, sondern ein Testpfad (siehe unten, Commit `eaa3425`).
  `thermalPass` → lineare Diffusion, Commit `cf83874`. Mit `thermalPass` sind die
  nur von ihm gelesenen Config-Schalter `talus`/`thermalRelax`/`rockCrumble`
  entfallen (Küsten-Talus `waveTalus` bleibt). Talus machte planare Facetten statt
  konvexer Kuppen — falls je wieder gewünscht (Steilfels-Kappen), aus `cf83874^`
  holen.
- `transportLimited` + `diffusionPass` laufen NUR im Nicht-Droplet-Zweig
  (`hydraulicEnabled = false`). Kein toter Code: die isolierten Mäander-
  Kopplungstests (`meanderCfg()` in `SimCoreTests.swift`) prüfen darauf Carve/
  Altarm/Altern ohne Droplet-Rauschen. Als Testpfad im Code kenntlich gemacht.
- `fillLakes` (Becken-Verlandung) hängt an `basinFill = false` und läuft damit derzeit
  NIRGENDS (auch in keinem Test) — bewusst GEPARKT, nicht vergessen: AUS, seit die
  Hebung niedrig ist (Auslass-Inzision hält den See-Anteil von allein bei ~15%
  diskreten Seen), aber der dokumentierte Rückfall für Konfigurationen mit hoher
  Hebung. Begründung im Config-Kommentar.
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
