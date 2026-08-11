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

**Extension bauen** (~3,5 min gilt für macOS mit warmem SwiftGodot-Cache; **auf Linux
gemessen 21,5 min** aus leerem `.build`, auf einem 4-Kern-Host 27 min — SwiftGodots
Codegen dominiert) — **immer mit absolutem Pfad aufrufen**;
relativ aus `game/` heraus schlägt es still fehl und Godot lädt weiter die ALTE
Library:

```sh
"$(git rev-parse --show-toplevel)"/scripts/build.sh release  # auf die "gebaut"-Zeile am Ende prüfen
```

Baut `Extension` und kopiert `libRiverSimGD.so`/`libSwiftGodot.so` plus die komplette
Swift-Runtime nach `game/bin/` (unter macOS `.dylib` + `codesign`).

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
`RS_RIVER_RIBBONS` zusätzlich in `SimNode.swift`):
`RS_SEED`, `RS_STEP`, `RS_SHOT`, `RS_DIST`, `RS_QUALITY` (`performance|balanced|quality`),
`RS_RENDER_GRID`, `RS_DIAG`, `RS_FPS`, `RS_IDLE`, `RS_FLATTEN`, `RS_NO_MEANDER_PAINT`,
`RS_RIVER_RIBBONS` (Issue #31: Mäander als Band-Geometrie statt Textur-Stempel,
A/B gegen den Stempel-Pfad ohne Rebuild).

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
→ Mäander (migrate + stamp) → outletIncision → Pfützen/Seen → braidPass
→ Droplet-Erosion (Hydraulic.erode) + Stream-Map-EWMA → Hangdiffusion → Wave
→ Vegetation
```

Ausgelagert sind nur Dinge mit eigener Datenstruktur: `Hydraulic.swift` (Droplet-Erosion,
Stream-Map, Pool-Kopplung), `Meander.swift` (Lagrange-Zentrumslinie, Migration, Cutoff),
`ErosionFilter.swift` (runevision-Pre-Erosion, **MPL-2.0** — siehe `NOTICE`),
`Noise.swift`, `MinHeap.swift`.

Zwei Dateien in SimCore sind bewusst **Render**-Ableitungen ohne Sim-Zustand — sie
liegen hier, weil sie in der GDExtension bzw. im Shader nicht testbar wären:
`Strahler.swift` (Rang-Hierarchie der Ribbons, Issue #31) und `WaterRender.swift`
(Kalibrier-Paarungen des Wasserfelds: Komponenten-Fade ↔ Shader-Smoothstep ↔
Altarm-Stempel, Issue #32). Beide sind aus `SimCoreTests` gepinnt; Werte dort
ändern heißt Shader UND `SimNode` mitziehen (der Test sagt, wo).

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
  linear gedeckelter (`relaxWaterLevel`, Verlandungen, Vegetation) und Raten-Zähler
  mit Übertrag statt `max(1, …)` (Tropfenzahl, `dropCarry`). Deckel „halbe lokale
  Höhendifferenz" sind ebenfalls Raten (`stepCapFraction`). Wächter:
  `SimCoreTests/DtInvariance.swift`, Messreihen `docs/dt-invariance-measurements.md`
  (inkl. des benannten Rests: Abflussfeld wird nur einmal je Schritt bestimmt).
- Masse-Erhaltung gilt **nicht** (detachment-limited Stream-Power trägt Material aus);
  die Invariante ist beschränktes Relief / Fließgleichgewicht — Wächter:
  `Tests/SimCoreTests/LongRunCollapse.swift`.
- `ROADMAP.md` ist ein lebendes Dokument (Stand, offene Punkte, geparkter Code wie
  `fillLakes`/`floodplainAggradation`) — bei Änderungen mitziehen.
- Recherche-Belege in `docs/`; `docs/nickmcd-behavior-verification.md` hält je
  Ziel-Verhalten fest, wie es umgesetzt und womit es belegt ist.
