# AGENTS.md

Leitfaden für Coding-Agents (und Menschen) in diesem Repository — werkzeug-unabhängig.
`CLAUDE.md` ist ein Symlink auf diese Datei.

Projektsprache ist **Deutsch**: Code-Kommentare, Doc-Kommentare und alle Dokumente
(`PLAN.md`, `ROADMAP.md`, `docs/`) sind deutsch. Neue Kommentare/Dokumente ebenso.

**Ausnahme: Git-Commit-Nachrichten werden auf Englisch geschrieben.** (Ältere Commits
sind teils deutsch — das ist Altbestand, nicht die Konvention.)

## Befehle

Swift liegt auf diesem Linux-Host nicht im PATH und braucht einen ncurses-Shim.
Vor jedem direkten `swift`-Aufruf:

```sh
source ~/.local/share/swiftly/env.sh
export LD_LIBRARY_PATH="$PWD/.tools/swift-libs:${LD_LIBRARY_PATH:-}"   # aus Repo-Wurzel
```

`scripts/build.sh` erledigt beides selbst.

**Tests** (Sim-Kern, headless, GPU-frei — die eigentliche Verifikationsebene):

```sh
swift test -c release --package-path SimCore -Xswiftc -swift-version -Xswiftc 5
swift test -c release --package-path SimCore -Xswiftc -swift-version -Xswiftc 5 \
    --filter testBraidingBuildsBars       # einzelner Test
```

- `-c release` ist Pflicht: Debug ist bei diesen Grids zu langsam.
- `-Xswiftc -swift-version -Xswiftc 5` ist Pflicht: `SimCore/Package.swift` deklariert
  tools-version 6.0, der Code ist aber Swift-5-Concurrency (u. a. `Terrain.parallel`
  mit nicht-`Sendable`-Closures). Ohne den Schalter bricht der Build mit
  `SendableClosureCaptures` ab.
- `--filter` nimmt den **Methodennamen**, nicht den Klassennamen (der matcht 0 Tests).

**Laufzeit messen** (Issue #43 — Mess-Harness für den Sim-Schritt, headless,
Produktions-Config, n = 832):

```sh
swift build -c release --package-path SimCore -Xswiftc -swift-version -Xswiftc 5
SimCore/.build/release/simperf --repeat 3   # ms/Schritt + Pass-Tabelle
SimCore/.build/release/simperf --hash       # Fingerabdruck aller Zustandsfelder
```

`--hash` ist der Wächter für „Physik unverändert": gleicher Wert vor und nach
einer Optimierung (auf DERSELBEN Maschine) heißt bit-identisch. Die Pass-Tabelle
kommt aus `SimProfile` (Marken in `step()`, standardmäßig aus). Messprotokoll,
Vorher/Nachher und die gemessenen Fehlschläge: `docs/perf-measurements.md`.

**Extension bauen** (M4-Max-Referenz-Mac: No-Op ~1,3 s, SimCore-Edit ~9 s,
Extension-Edit ~5 s, Kaltbau ~10 min in einem Aufruf; **auf Linux gemessen 21,5 min** Kaltbau,
auf einem 4-Kern-Host 27 min — SwiftGodots Codegen dominiert, mehr Kerne helfen
nicht: serielle Modulkette + WMO) — **immer mit absolutem Pfad aufrufen**;
relativ aus `game/` heraus schlägt es still fehl und Godot lädt weiter die ALTE
Library:

```sh
"$(git rev-parse --show-toplevel)"/scripts/build.sh release  # auf die "gebaut"-Zeile am Ende prüfen
```

Baut `Extension` und kopiert `libRiverSimGD.so`/`libSwiftGodot.so` plus die komplette
Swift-Runtime nach `game/bin/` (unter macOS `.dylib` + `codesign`).

`build.sh` führt alle `swift`-Aufrufe unter einer festen Minimal-Umgebung aus:
SwiftPM verschlüsselt sonst die komplette Prozessumgebung in die Plugin-/
Tool-Build-Signaturen, und JEDER Kontextwechsel (anderes Terminal-Pane, Editor,
Agent-Session) kostete real ~10 min Voll-Neubau bei unveränderten Quellen
(Diagnose und Messreihe: `docs/build-invalidation-measurements.md`). Ein
Toolchain-Wechsel wird laut gemeldet statt still neu zu bauen.

**Worktrees** bauen automatisch in den geteilten Cache des Haupt-Repos
(`--scratch-path`): erster Build im frischen Worktree ~3 min statt ~8 min
Kaltbau, danach im selben Worktree Sekunden. Jeder Wechsel des bauenden
Checkouts (Haupt ↔ Worktree) kostet einmalig ~3 min Neuplanung — build.sh
räumt dabei die checkout-eigenen Artefakte selbst weg, der Build-Stempel-Check
verifiziert jedes Ergebnis. Die frühere Handarbeit „`.build` kopieren,
`ModuleCache`-Ordner löschen" entfällt. `RS_NO_SHARED_BUILD=1` erzwingt einen
eigenständigen Build im Worktree.

**SwiftGodot-Pin** (Issue #49): `Extension/Package.swift` hängt an einer **exakten**
Upstream-Version, aktuell `exact: "0.76.1"` (Revision
`be57caa3e81b9ac510bc7cc2e277003c706ab0a5`, Tag `v0.76.1`); `Extension/Package.resolved`
ist eingecheckt und die verbindliche Auflösung, auch für die transitiven Pins
(`swift-syntax` 600.0.1, `swift-argument-parser` 1.8.2). Vorher stand hier
`branch: "main"` — damit konnte jeder frische Klon eine andere Revision ziehen, und
weil SwiftGodots Codegen die ganze Modulkette speist, kostet schon ein
Revisionswechsel einen Voll-Neubau (Linux ~21,5 min, s. o.) und kann die Godot-API
still verschieben.

Der Pin wird **nur bewusst und in einem eigenen Commit** angehoben:

```sh
git ls-remote --tags https://github.com/migueldeicaza/SwiftGodot   # Zielversion wählen
# Extension/Package.swift: exact: "<neue Version>" — Kommentar dort mitpflegen
swift package resolve --package-path Extension        # Package.resolved neu schreiben
git diff Extension/Package.resolved                  # Revisionen prüfen, auch transitive
"$(git rev-parse --show-toplevel)"/scripts/build.sh release   # Voll-Neubau erwarten
"$GODOT" --headless --path game --script res://tests/smoke.gd  # API-Bruch fällt hier auf
```

Ein Update gehört nicht in einen Commit mit Sim- oder Render-Änderungen: bricht die
GDExtension danach, soll der Pin-Commit allein dastehen. `swift package update`
(ohne Argument) hebt bei einem `exact`-Pin nichts an — genau das ist der Zweck.

**Build-Stempel gegen veraltete Libraries:** `scripts/build.sh` hasht die Quellen
unter `Extension/Sources` + `SimCore/Sources` und brennt den Stempel via
`Extension/Sources/RiverSimGD/Generated/BuildStamp.swift` (generiert, gitignoriert) in
die Library ein; `SimNode.buildStamp()` gibt ihn zurück. `scripts/start.sh` und
`game/tests/smoke.gd` vergleichen ihn mit dem Arbeitsverzeichnis und brechen mit dem
Rebuild-Befehl ab, statt still die alte `.so` zu benutzen. Manuell prüfen:

```sh
scripts/build-stamp.sh --check   # Exit 1 + Meldung, wenn game/bin/ veraltet ist
```

Beim Ändern des Verfahrens müssen `scripts/build-stamp.sh` und
`game/scripts/BuildStamp.gd` bytegleich bleiben.

**App starten / Godot-Smoke-Tests:**

```sh
GODOT=…; "$GODOT" --headless --path game --import   # EINMALIG pro Arbeitsverzeichnis
./scripts/start.sh                                   # GODOT=… überschreibt die Binärdatei
./scripts/start.sh --rendering-method gl_compatibility # ohne Vulkan
"$GODOT" --headless --path game --script res://tests/smoke.gd
"$GODOT" --headless --path game --script res://tests/pickaxe_repro.gd
"$GODOT" --headless --path game --script res://tests/river_ribbons.gd
```

Der Import-Lauf ist Pflicht, bevor irgendetwas die GDExtension benutzt: Godot lädt
Extensions ausschließlich aus `game/.godot/extension_list.cfg`, und die entsteht erst
beim Import. `game/.godot/` ist gitignoriert, fehlt also in jedem frischen Klon oder
Worktree — ohne Import bleibt `SimNode` unregistriert, obwohl `game/bin/` korrekt
gefüllt ist. `smoke.gd` erkennt genau diesen Fall und nennt den Befehl.

**Headless-Screenshot** (visuelle Verifikation ohne Auge):

```sh
RS_STEP=20000 RS_SHOT=/pfad/shot.png RS_DIST=90 "$GODOT" --path game
```

`RS_*`-Schalter (alle in `game/scripts/Main.gd`; `RS_NO_MEANDER_PAINT` und
`RS_WATER_STAMP` zusätzlich in `SimNode.swift`):
`RS_SEED`, `RS_STEP`, `RS_SHOT`, `RS_DIST`, `RS_TARGET` (`"x,z"` — Blickpunkt in
Weltkoordinaten, für Ausschnitt-Screenshots), `RS_YAW`, `RS_PITCH`,
`RS_QUALITY` (`performance|balanced|quality`), `RS_RENDER_GRID`, `RS_DIAG`,
`RS_FPS`, `RS_IDLE`, `RS_FLATTEN`, `RS_NO_MEANDER_PAINT`,
`RS_WATER_STAMP` (Issues #31/#34: zurück auf den alten Raster-Stempel-Pfad statt
der Wasser-Geometrie — A/B im selben Build; ohne den Schalter rendert die
Geometrie). `RS_SHOT` blendet zusätzlich die Bedienleiste aus.

## Architektur

Drei Schichten, bewusst getrennt (Begründung: `PLAN.md` §1):

1. **`SimCore/`** — reines Swift-Package, **keine Godot-Abhängigkeit**. Die gesamte
   Physik. Headless mit XCTest verifizierbar.
2. **`Extension/`** — SwiftGodot-GDExtension (`SimNode: Node`). Bewusst dünn: hält einen
   `Terrain`, reicht Felder als `Packed*Array` an Godot, baut Farb-/Wasser-Byte-Puffer
   fürs Rendering. Keine Physik.
3. **`game/`** — Godot-4.7-Projekt: `Main.gd` (Mesh/Textur-Update, UI, Kamera, Input),
   `shaders/terrain.gdshader` + `water.gdshader`.

Datenfluss pro Frame: `Main.gd` ruft `sim.step(years)`, zieht danach `heights()`,
`waterFieldBytes()`, `terrainColorBytes()` etc. und schiebt sie als Texturen ins Mesh.
Alle Felder sind row-major `n×n` (`idx(i,j) = j*n + i`).

### SimCore-Aufbau

`Terrain.swift` (1600+ Zeilen) ist absichtlich **eine** Datei: Klima, Vegetation,
Tektonik, Küste, Braiding, Auslass-Inzision sind Pässe auf denselben Grids und ihre
**Reihenfolge pro Zeitschritt muss zusammen lesbar sein**. Die Reihenfolge in `step()`
ist LEM-Konvention und nicht beliebig:

```
Uplift (+ Relief-Servo) → computeFlow (Priority-Flood, D8, MFD)
→ Gletscher (updateIce: Eisfluss, glaziale Erosion, Moränen)
→ Mäander (migrate + stamp) → outletIncision → Pfützen/Seen → braidPass
→ Droplet-Erosion (Hydraulic.erode) + Stream-Map-EWMA → Hangdiffusion → Wave
→ Klima-Vertikale (Temperatur + Schneebilanz) → Vegetation
```

Die Klima-Vertikale (Issue #33) steht **direkt vor** der Vegetation und damit am
Schrittende: die Temperatur liest die FINALEN Höhen des Schritts, und
`updateVegetation` leitet über `updateHeightBands` die Schneegrenze aus dem
frischen Schneefeld ab.

Seit Issue #36 koppelt das Klima über **einen** Weg in die Erosion: die
Schmelze speist das Abfluss-Gewicht (`Terrain.flowWeight` = Regen + Ablation,
gebaut in `updateRunoffWeight` am Anfang des Schritts aus dem Schneefeld vom
Schrittende davor). Begründung bei `SimConfig.climateEnabled` und
`SimConfig.meltRunoffEnabled`.

Der **Gletscher** (Issue #35, `updateIce`) ist der zweite Weg und bringt sein
eigenes Erosionsgesetz mit (Flux-Modell `E = K·q^m·S`, nicht Stream-Power auf
`area`). Er steht **nach dem Abflussfeld und vor jeder fluvialen
Höhenänderung**, weil seine Maske `Terrain.underIce` den fluvialen Abtrag
gatet: `outletIncision` und `Hydraulic.erode` prüfen sie direkt, alle übrigen
Bett-Bewegungen (Mäander-Carve und -Ufer, Altarme, Braid-Fracht,
Auen-Aggradation, im Testpfad auch `transportLimited`) über ihren gemeinsamen
Funnel `erodeCell`/`depositCell`.
Vergletscherte Zellen rührt damit kein fluvialer Pass an — die Hangdiffusion
dagegen läuft weiter (kein fluvialer Pass, s. `docs/glacier-measurements.md`
§I.1). Wie `isChannel` gilt: **leeres Feld heißt aus**,
und ohne Eis wird es auch geleert; eine eisfreie Welt rechnet damit
bit-identisch zum Stand vor #35. Das Eis liegt **nicht** in `h` (eigene
Auflage über dem Bett), die Entwässerung läuft also unverändert auf dem Bett.
Kalibrier-Logbuch: `SimConfig.iceEnabled` ff., Messreihe
`docs/glacier-measurements.md`.

**Alle drei Abfluss-Konsumenten lesen `flowWeight`** und nie `rain`/`rainWeight`
direkt: `seedFlowAccumulator` (D8 UND MFD) und die Tropfen-Startpunkte in
`Hydraulic.erode`. Wer einen vierten Konsumenten hinzufügt, nimmt dieselbe
Quelle — die Kalibrierung hängt daran, dass Σ Gewicht über Land = Zahl der
Landzellen bleibt (`docs/melt-runoff-measurements.md` §D).

Ausgelagert sind nur Dinge mit eigener Datenstruktur: `Hydraulic.swift` (Droplet-Erosion,
Stream-Map, Pool-Kopplung), `Meander.swift` (Lagrange-Zentrumslinie, Migration, Cutoff),
`ErosionFilter.swift` (runevision-Pre-Erosion, **MPL-2.0** — siehe `NOTICE`),
`Noise.swift`, `MinHeap.swift`.

Drei Dateien in SimCore sind bewusst **Render**-Ableitungen ohne Sim-Zustand — sie
liegen hier, weil sie in der GDExtension bzw. im Shader nicht testbar wären:
`Strahler.swift` (Rang-Hierarchie der Ribbons, Issue #31), `WaterRender.swift`
(Kalibrier-Paarungen des Wasserfelds: Komponenten-Fade ↔ Shader-Smoothstep ↔
Altarm-Stempel, Issue #32; seit #34 auch die Übergabe Band ↔ Raster:
`deltaFrontDepth == lakeRawWetDepth`, `mouthOverlapCells`, Typ-Kanal der Bänder)
und `RenderContract.swift` (Issue #51: `heightScale`, `riverLift`, `defaultSeed` —
Zahlen, die Godot-Schicht, GDExtension und Shader unabhängig voneinander
festlegten). Alle drei sind aus `SimCoreTests` gepinnt; Werte dort ändern heißt
Shader UND `SimNode` mitziehen (der Test sagt, wo).

Seit **Issue #51** liegt die Render-Kalibrierung VOLLSTÄNDIG in diesem Vertrag —
auch Kanalbreiten (`ribbonHalfWidthCells`, Altarm- und Delta-Breiten),
Verbreiterung (`widenThresholds`, `widenFalloff`, `widenBarTolerance`),
Track-Maske (`trackMask`/`corridorMask`) und die Abfluss-Abstufung
(`streamIntensity`, Legacy-`stamp*`) sowie die gemeinsame Wasser-OPTIK beider
Shader (Farben, Fresnel, Rauheit/Specular, Strömungs-Schimmer). `SimNode` und die
Shader dürfen dazu keine eigenen Literale mehr halten: `WaterRenderTests` und
`RenderContractTests` lesen die ECHTEN Quelltexte von `SimNode.swift`, beiden
`.gdshader`, `Main.gd` und den Godot-Wächtern und vergleichen sie gegen diese
Werte (gemeinsamer Helfer: `Tests/SimCoreTests/RepoSource.swift`). Zahlen im
Shader deshalb in **Swift-Schreibweise** notieren (`0.7`, nicht `0.70`) — sonst
greift der Textvergleich nicht.

**Wasser rendert auf ZWEI Wegen, mit einer scharfen Grenze dazwischen**
(Issue #34, Messprotokoll `docs/geometry-water-measurements.md`): die
Band-Geometrie (`buildRiverRibbons`) malt Mäander-Hauptläufe, Delta-Fächer und
Altarme, das Raster-Feld (`waterFieldBytes` + `terrain.gdshader`) die
dendritischen Zubringer, Seen und das Meer. Die Grenze ist die Wassersäule
`WaterRender.lakeRawWetDepth`: darunter malt nur die Geometrie, darüber nur das
Raster. Wer eine der beiden Seiten verschiebt, bekommt entweder einen Spalt oder
doppeltes Wasser — beides zählt `game/tests/water_geometry.gd`.

Zwei Drainage-Netze mit strikt getrennten Rollen: **D8/`area`** speist die Erosion
(kalibriert, implizit stabil), **MFD/`areaMFD`** (Freeman/Quinn) speist **nur** Render
und Braiding. Diese Trennung nicht aufweichen. (Eine dokumentierte Ausnahme in der
Gegenrichtung: die **Strahler-Ordnung** für die Ribbon-Render-Hierarchie, Issue #31,
läuft auf D8 — sie braucht den Empfänger-*Baum*, den MFD als Mehrfach-Verteilung
nicht hat.)

### Konfiguration

`SimCore/Sources/SimCore/Config.swift` hält **alle** Stellschrauben, jede mit
ausführlicher Begründung inkl. verworfener Werte und Messwerten. Beim Ändern eines
Werts den Kommentar mitpflegen — er ist das Kalibrier-Logbuch.

Drei Konfigurations-Ebenen, die absichtlich auseinanderlaufen:
- `SimConfig()`-Defaults = kalibrierte Produktions-Physik.
- `SimNode.productionConfig()` schaltet zusätzlich reine Performance-Optionen an
  (`hydraulicSkipWaterSpawns`, `meanderSpatialCutoffIndex`) — Verhalten muss dabei
  gleich bleiben, dafür gibt es Tests.
- Testkonfigs (`meanderCfg()` in `SimCoreTests.swift`) **pinnen alte Werte**, damit
  Kopplungs-Mechanik und Produktions-Kalibrierung entkoppelt bleiben. Nicht
  „aufräumend" an die Produktionswerte angleichen.

## Arbeitsweise in diesem Projekt

- **Erst headless messen, dann schrauben.** Visuelle Hypothesen waren hier mehrfach
  falsch. Kennzahlen über die Zeit loggen (Relief, Ruggedness, See-Anteil, meanLand,
  Churn); Baseline-Beispiele in `docs/river-baseline-metrics.md`.
- **Kalibrier-Kaskade:** Änderungen am Droplet-Pfad verschieben die Braiding-Kalibrierung;
  Rinnen-Textur bricht Formeln, die die Per-Zell-Steigung als „Hang" lesen (Regen,
  Vegetation, Biom-Farbe brauchen Makro-Steigung über ±2 Zellen).
- **`n` und `world` nur ZUSAMMEN ändern** — sonst ändert sich `cellSize` und alle
  per-Zell-Kalibrierungen (Braid-Gates, Droplet-Dichte, kappa-Skalierung) brechen.
- **Determinismus ist eine getestete Invariante — pro Maschine.** Gleicher Seed →
  bit-gleiches Ergebnis; Parallelisierung (`Terrain.parallel`, `parallelChunks` in
  `SimNode.swift`) nur über disjunkte Index-Bereiche, bit-identisch zur
  sequenziellen Schleife. Plattformübergreifend gilt Bit-Gleichheit NICHT
  (System-libm) und wird nicht getestet. Sim-Zustand deshalb nur auf der CPU;
  GPU-Floats sind nicht bit-kompatibel (Rundung/FMA/Reassoziation treiberabhängig),
  Shader/Compute nur für Render-Ableitungen — `docs/web-tech-refactor-evaluation.md` §5.
- **Framerate-Unabhängigkeit:** Gesamtwirkung eines Passes muss ∝ `dt` sein. Echtzeit-
  Zeitraffer (winziges dt/Frame) und `+10.000 Jahre`-Sprünge müssen dasselbe Ergebnis
  liefern. Die drei Bauformen dafür: Sub-Takten mit fester Teilschritt-Stärke
  (Hangdiffusion, `waveSchedule`), exponentielle Relaxation `1 − e^(−dt/τ)` statt
  linear gedeckelter (`Terrain.relaxFraction` — EINZIGE Quelle dieser Form, gelesen
  von `relaxWaterLevel`, Verlandungen, Vegetation) und Raten-Zähler
  mit Übertrag statt `max(1, …)` (Tropfenzahl, `dropCarry`). Deckel „halbe lokale
  Höhendifferenz" sind ebenfalls Raten (`stepCapFraction` — Halbwertszeit statt τ,
  deshalb bewusst nicht über den Helfer). Wächter:
  `SimCoreTests/DtInvariance.swift` + `SimCoreTests/RelaxationTests.swift`,
  Messreihen `docs/dt-invariance-measurements.md`
  (inkl. des benannten Rests: Abflussfeld wird nur einmal je Schritt bestimmt).
- Masse-Erhaltung gilt **nicht** (detachment-limited Stream-Power trägt Material aus);
  die Invariante ist beschränktes Relief / Fließgleichgewicht — Wächter:
  `Tests/SimCoreTests/LongRunCollapse.swift`.
- `ROADMAP.md` ist ein lebendes Dokument (Stand, offene Punkte, geparkter Code wie
  `fillLakes`/`floodplainAggradation`) — bei Änderungen mitziehen.
- Recherche-Belege in `docs/`; `docs/nickmcd-behavior-verification.md` hält je
  Ziel-Verhalten fest, wie es umgesetzt und womit es belegt ist.
