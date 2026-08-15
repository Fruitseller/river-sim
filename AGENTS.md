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

**Mess- und Sweep-Läufe gehören NICHT in die Pflichtsuite** (Issue #52). Jede
Testmethode, deren Name auf `Diagnostic` endet, druckt nur die Tabellen für
`docs/*-measurements.md` und läuft erst mit `RS_MEASURE=1`:

```sh
RS_MEASURE=1 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter testDtSpreadDiagnostic
```

Namensendung `Diagnostic` und Gate `try skipUnlessMeasuring()` gehören zusammen:
`MeasurementGateTests` prüft **beide** Richtungen und wird rot, wenn ein Messlauf
ungegatet in die Pflichtsuite rutscht oder ein echter Wächter still hinter dem
Schalter verschwindet. Begründung: `SimCore/Tests/SimCoreTests/MeasurementGate.swift`,
Laufzeiten: `docs/ci-measurements.md`.

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
Toolchain-Wechsel wird laut gemeldet statt still neu zu bauen. Weil der PATH des
Aufrufers damit bewusst nicht durchgereicht wird, findet `build.sh` nur Swiftly
bzw. Xcode; Toolchains an anderer Stelle (CI installiert nach `/opt/swift`)
zeigt man ihm mit **einer** Variablen: `RS_SWIFT_BIN=/pfad/zur/toolchain/bin`.

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
`game/scripts/BuildStamp.gd` bytegleich bleiben — das prüft seit Issue #52
`game/tests/build_stamp_parity.gd` (führt die Shell-Seite selbst aus und
vergleicht mit der GDScript-Seite; braucht die GDExtension nicht):

```sh
"$GODOT" --headless --path game --script res://tests/build_stamp_parity.gd
```

**App starten / Godot-Smoke-Tests:**

```sh
scripts/fetch-godot.sh                               # holt die gepinnte Godot-Version nach .tools/
GODOT="$(scripts/fetch-godot.sh)"
"$GODOT" --headless --path game --import             # EINMALIG pro Arbeitsverzeichnis
./scripts/start.sh                                   # GODOT=… überschreibt die Binärdatei
./scripts/start.sh --rendering-method gl_compatibility # ohne Vulkan
"$GODOT" --headless --path game --script res://tests/smoke.gd
"$GODOT" --headless --path game --script res://tests/pickaxe_repro.gd
"$GODOT" --headless --path game --script res://tests/river_ribbons.gd
"$GODOT" --headless --path game --script res://tests/water_geometry.gd
"$GODOT" --headless --path game --script res://tests/tree_count.gd
"$GODOT" --headless --path game --script res://tests/water_rings.gd   # 106.000 Jahre, langsam
```

`scripts/fetch-godot.sh` ist die **einzige** Quelle der Godot-Version im Repo
(Prüfsumme inklusive); `scripts/start.sh` und CI lesen sie von dort. Damit läuft
CI garantiert gegen dieselbe Binärdatei wie der Arbeitsplatz — sonst beweist ein
grüner Lauf nichts über den lokalen Stand.

`res://tests/render_fingerprint.gd` ist kein Wächter, sondern das A/B-WERKZEUG
für Umbauten der Render-Aufbereitung (Issue #53): es druckt SHA-256 je
Render-Puffer nach einem festen Lauf. Vorher laufen lassen, umbauen, nachher
laufen lassen — gleiche Zeilen heißt bit-identisch. Die Hashes gelten je
Maschine, nicht plattformübergreifend (System-libm), deshalb steht keine
Erwartung im Skript.

Der Import-Lauf ist Pflicht, bevor irgendetwas die GDExtension benutzt: Godot lädt
Extensions ausschließlich aus `game/.godot/extension_list.cfg`, und die entsteht erst
beim Import. `game/.godot/` ist gitignoriert, fehlt also in jedem frischen Klon oder
Worktree — ohne Import bleibt `SimNode` unregistriert, obwohl `game/bin/` korrekt
gefüllt ist. `smoke.gd` erkennt genau diesen Fall und nennt den Befehl.

**Headless-Screenshot** (visuelle Verifikation ohne Auge):

```sh
RS_STEP=20000 RS_SHOT=/pfad/shot.png RS_DIST=90 "$GODOT" --path game
```

`RS_*`-Schalter (alle in `game/scripts/Main.gd`; `RS_WATER_STAMP` zusätzlich in
`SimNode.swift`, `RS_NO_MEANDER_PAINT` in `WaterFieldRenderer.swift`):
`RS_SEED`, `RS_STEP`, `RS_STEP_CHUNK` (Schrittweite des `RS_STEP`-Vorlaufs,
Standard 1000 J. — der Vorlauf taktet wie der Zeitraffer, nicht in EINEM Sprung),
`RS_SHOT`, `RS_DIST`, `RS_TARGET` (`"x,z"` — Blickpunkt in
Weltkoordinaten, für Ausschnitt-Screenshots), `RS_YAW`, `RS_PITCH`,
`RS_QUALITY` (`performance|balanced|quality`), `RS_RENDER_GRID`, `RS_DIAG`,
`RS_DEBUG_DIFF` (Δ-Karte gleich an, für automatisierte Diagnose-Screenshots),
`RS_FPS`, `RS_IDLE`, `RS_FLATTEN`, `RS_NO_MEANDER_PAINT`,
`RS_WATER_STAMP` (Issues #31/#34: zurück auf den alten Raster-Stempel-Pfad statt
der Wasser-Geometrie — A/B im selben Build; ohne den Schalter rendert die
Geometrie). `RS_SHOT` blendet zusätzlich die Bedienleiste aus. Einzeln davon
steht `RS_REPRO_YEARS` — das gehört nicht `Main.gd`, sondern kürzt den langen
Lauf von `game/tests/water_rings.gd` ab.

## CI

`.github/workflows/ci.yml`, zwei Jobs auf `ubuntu-22.04`, bei jedem Push auf
`main` und jedem PR. Sie laufen **parallel** — die Laufzeit eines CI-Laufs ist die
des langsameren Jobs, nicht die Summe:

| Job | Prüft | Lokal reproduzieren |
| --- | --- | --- |
| `test` | Sim-Kern: die SimCore-Pflichtsuite (ohne `RS_MEASURE`) | `swift test -c release --package-path SimCore …` |
| `godot-contract` | Godot-Vertrag: GDExtension-Build (release), Projekt-Import, Build-Stempel-Parität, `smoke.gd`, `water_geometry.gd`, `river_ribbons.gd` | `scripts/build.sh release` + die `"$GODOT" --headless`-Zeilen oben |

Beide Jobs richten die Toolchain über dieselbe lokale Composite-Action ein
(`.github/actions/swift-toolchain`) — die Einrichtung ist nicht generisch (feste
Version, swift.org-Direktdownload, ncurses-Shim), und zweimal dieselbe Fassung zu
pflegen war die absehbare Fehlerquelle. Ein „Doppel-Build" ist das trotzdem nicht:
`SimCore/.build` und `Extension/.build` sind verschiedene Paketgraphen mit
verschiedenen Scratch-Pfaden, jeder mit eigenem `actions/cache`-Eintrag.

**Laufzeit-Budget, Messwerte und was bei Überschreitung zu tun ist:**
`docs/ci-measurements.md`. Kurzfassung: Pflichtsuite ≤ 15 min (lokal gemessen
7 min), Godot-Vertrag ≤ 15 min bei warmem Cache, Kaltbau der Extension ~30 min.
Wer einen langen Testlauf hinzufügt, prüft die Zahlen dort mit.

Bis Issue #52 lief in CI nur der Sim-Kern; der Godot-Vertrag war eine Zusage im
Review („lokal ausgeführt"). Der Job heißt weiterhin `test`, damit vorhandene
Verweise auf denselben Check zeigen.

## Architektur

Drei Schichten, bewusst getrennt (Begründung: `PLAN.md` §1):

1. **`SimCore/`** — reines Swift-Package, **keine Godot-Abhängigkeit**. Die gesamte
   Physik. Headless mit XCTest verifizierbar.
2. **`Extension/`** — SwiftGodot-GDExtension (`SimNode: Node`). Bewusst dünn: hält einen
   `Terrain` und reicht seine Felder als `Packed*Array` an Godot. Keine Physik.
3. **`game/`** — Godot-4.7-Projekt: `Main.gd` (Mesh/Textur-Update, UI, Kamera, Input),
   `shaders/terrain.gdshader` + `water.gdshader`.

Datenfluss pro Frame: `Main.gd` ruft `sim.step(years)`, zieht danach `heightsBytes()`,
`waterFieldBytes()`, `terrainColorBytes()` etc. und schiebt sie als Texturen ins Mesh.
Alle Felder sind row-major `n×n` (`idx(i,j) = j*n + i`).

### Extension-Aufbau (Issue #53)

`SimNode.swift` ist reines Marshalling: Aufruf weiterreichen, Ergebnis als
`Packed*Array` zurückgeben. Die Render-AUFBEREITUNG liegt daneben, je Pfad ein
Modul — sie hält Render-Zustand (EWMA-Felder, Arbeitspuffer, Dirty-Snapshots),
liest das Terrain und ändert es nie:

- `WaterFieldRenderer` — Raster-Wasser (`waterFieldBytes`),
- `RiverRibbonRenderer` — Band-Geometrie (`buildRiverRibbons` + Puffer),
- `TerrainColorRenderer` — Biom-/Höhen-Färbung,
- `TreeInstanceRenderer` — MultiMesh-Puffer der Bäume,
- `TerrainDiagnostics` — Kennzahlen und Δ-Karte,
- `RenderSupport.swift` — was mehrere brauchen (`parallelChunks`,
  `openWaterSurface`, `mouthPath`, Band-Halbbreite): die beiden Wasser-Pfade
  müssen sich über die Uferlinie und die Mündung exakt einig sein,
- `BrushTool` — Werkzeug-Modi; dieselbe Reihenfolge wie die Werkzeug-Tabelle in
  `Main.gd` (Wächter: `SimCoreTests/ToolContractTests.swift`).

Die KALIBRIER-Zahlen bleiben dabei in `SimCore` (`WaterRender`,
`RenderContract`) — die Module rechnen nur mit ihnen. Die Wächter lesen die
Extension als GANZES (`RepoSource.extensionSources()`), ein Umzug zwischen
diesen Dateien bricht sie also nicht.

### SimCore-Aufbau

`Terrain.swift` (~4500 Zeilen) ist absichtlich **eine** Datei: Klima, Vegetation,
Tektonik, Küste, Braiding, Auslass-Inzision sind Pässe auf denselben Grids und ihre
**Reihenfolge pro Zeitschritt muss zusammen lesbar sein**. Die Reihenfolge in `step()`
ist LEM-Konvention und nicht beliebig — hier vollständig, weil jeder nachgerüstete
Prozess sich an einer begründeten Stelle einhängt:

```
applyUplift (abklingende Hebung + Relief-Servo als Untergrenze)
→ regenerateDisturbed (Störungs-Regeneration nach Pinselstrich, #26)
→ updateLithology (Gesteinsfeld auf die frische Höhe nachziehen)
→ computeFlow: computeRain (+ updateRainWeight/updateRunoffWeight → flowWeight)
  → priorityFlood → D8-Empfänger/area → capEndorheicBasins → computeMFDArea
→ relaxWaterLevel (Darstellungs-Seespiegel) → updateSaltCrust (Playa-Kruste)
→ Gletscher (updateIce: Firn→Eis, Eisfluss, glaziale Erosion, Moränen)
→ Mäander (migrateMeander + meanderStamp)
──── ab hier der Produktionszweig `hydraulicEnabled` ────
→ outletIncision → fillLakes (geparkt, `basinFill = false`) → fillShallowPonds
→ braidPass → Droplet-Erosion (Hydraulic.erode) + Stream-Map-EWMA
→ floodplainAggradation (geparkt, `floodplainEnabled = false`)
→ Hangdiffusion (sub-getaktet) → wavePass (sub-getaktet)
────────────────────────────────────────────────────────
→ Klima-Vertikale (updateClimate: Temperatur + Schneebilanz) → updateVegetation
```

Der eingerahmte Block ist der `hydraulicEnabled`-Zweig; der Testpfad
(`hydraulicEnabled = false`, s. unten) fährt an dieser Stelle stattdessen
`transportLimited` und danach `diffusionPass`/`wavePass` verschränkt. Alles vor
und nach dem Block läuft in BEIDEN Zweigen.

Die Klima-Vertikale (Issue #33) steht **direkt vor** der Vegetation und damit am
Schrittende: die Temperatur liest die FINALEN Höhen des Schritts, und
`updateVegetation` leitet über `updateHeightBands` die Schneegrenze aus dem
frischen Schneefeld ab.

Seit Issue #36 koppelt das Klima über **einen** Weg in die Erosion: die
Schmelze speist das Abfluss-Gewicht (`Terrain.flowWeight` = Regen + Ablation,
gebaut in `updateRunoffWeight` am Ende von `computeRain` — also innerhalb von
`computeFlow`, aus dem Schneefeld vom Schrittende davor). Begründung bei
`SimConfig.climateEnabled` und
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
`HeightBands.swift` (Perzentil-Höhenbänder, Issue #4), `WorldSnapshot.swift`
(Speicherformat, Issue #8 — das Zustands-INVENTAR `TerrainState` steht dagegen am
Ende von `Terrain.swift`), `Profile.swift` (`SimProfile`, die Pass-Marken des
Mess-Harness), `Noise.swift`, `MinHeap.swift`.

Größenordnung zur Orientierung (Stand Aug 2026, gerundet — wer eine Datei teilt
oder zusammenlegt, zieht die Zahl mit): `Terrain.swift` ~4500 Zeilen,
`Config.swift` ~1500, `WorldSnapshot.swift` ~750, `WaterRender.swift` ~580,
`Hydraulic.swift` und `Meander.swift` je ~390, der Rest dreistellig oder kleiner.
Auf der anderen Seite der Brücke: `game/scripts/Main.gd` ~1280 Zeilen, die
gesamte GDExtension ~2100 (davon `SimNode.swift` ~320 — s. u.).

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
Shader (Farben, Fresnel, Rauheit/Specular, Strömungs-Schimmer). Die Extension und
die Shader dürfen dazu keine eigenen Literale mehr halten: `WaterRenderTests` und
`RenderContractTests` lesen die ECHTEN Quelltexte der GDExtension, beiden
`.gdshader`, `Main.gd` und den Godot-Wächtern und vergleichen sie gegen diese
Werte (gemeinsamer Helfer: `Tests/SimCoreTests/RepoSource.swift`). Zahlen im
Shader deshalb in **Swift-Schreibweise** notieren (`0.7`, nicht `0.70`) — sonst
greift der Textvergleich nicht.

**Wasser rendert auf ZWEI Wegen, mit einer scharfen Grenze dazwischen**
(Issue #34, Messprotokoll `docs/geometry-water-measurements.md`): die
Band-Geometrie (`RiverRibbonRenderer`) malt Mäander-Hauptläufe, Delta-Fächer und
Altarme, das Raster-Feld (`WaterFieldRenderer` + `terrain.gdshader`) die
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

`SimConfig` in `SimCore/Sources/SimCore/Config.swift` ist der **eine** Konfigurations-
Wert, den ein `Terrain` bekommt, und trägt die große Mehrheit der Stellschrauben
direkt — jede mit ausführlicher Begründung inkl. verworfener Werte und Messwerten.
Beim Ändern eines Werts den Kommentar mitpflegen — er ist das Kalibrier-Logbuch.

Zwei Gruppen sind bewusst NICHT in `Config.swift` deklariert, sondern neben ihrem
Code — sie hängen als Feld in `SimConfig` und reisen damit vollständig im
Spielstand mit (`Codable`):

- `HydraulicParams` (`Hydraulic.swift`) — die Tropfen-Parameter, erreichbar als
  `cfg.hydraulic`. `Config.swift` überschreibt davon nur, was hier anders
  kalibriert ist (derzeit `inertia = 0.10`); der Rest steht kommentiert an der
  Struktur. Wer einen Tropfen-Wert sucht, sucht in `Hydraulic.swift`.
- `ErosionFilter.Params` (`ErosionFilter.swift`) — die Pre-Erosion bei der
  Generierung, erreichbar als `cfg.preErodeParams`, unverändert übernommen. Sie
  liegt beim Portierten-Code, weil ihre Werte gegen das GLSL-Original stehen
  (`docs/references/runevision-erosion/`, MPL-2.0). Ihre `Codable`-Konformität
  steht als handgeschriebene Extension in `WorldSnapshot.swift` — die Struktur
  führt Tupel, die der Compiler nicht synthetisieren kann.

Keine Stellschraube ist dagegen `WaterRender`/`RenderContract`: das sind
Render-KALIBRIERUNGEN mit Wächtern über Shader und GDExtension (s. o.), keine
Physik-Regler. Auch die Extension und `Main.gd` halten keine eigenen Regler mehr
— ihre Zahlen kommen aus dem Vertrag.

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
  Vegetation, Biom-Farbe brauchen Makro-Steigung über ±2 Zellen). Diese
  Makro-Steigung hat seit Issue #50 genau EINE Quelle — `Terrain.macroSlope`;
  wer sie erneut lokal ausrechnet, baut die Kaskade wieder ein.
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
  Messreihen `docs/dt-invariance-measurements.md`.
  Zwei **benannte Reste** bleiben bewusst stehen — wer eine dt-Abweichung misst,
  prüft zuerst gegen diese beiden, bevor er einen Fehler vermutet:
  1. **Operator-Splitting-Drift**: das Abflussfeld wird nur EINMAL je Schritt
     bestimmt, die Tropfen laufen `dt·Rate` mal dagegen (`docs/dt-invariance-…`
     §5). Das ist der Löwenanteil des Rests.
  2. **Der Scour-Deckel in `braidPass`** steht bei festen 0.5 der lokalen
     Höhendifferenz JE SCHRITT und ist bewusst NICHT auf `stepCapFraction`
     umgestellt: Issue #2 hat die DEPOSITIONS-Deckel geradegezogen, dies ist die
     Erosionsseite. Als Rate darf ein 200-Jahr-Schritt 0.75 statt 0.5 ausräumen,
     womit der Braid-Scour die Böden der abflusslosen Becken tiefer gräbt — die
     Playa-Fläche fiel gemessen von >100 auf 35 Zellen und die #11-Wächter
     `testDriedBedIsRenderedAsPlaya`/`testBasinLevelIsRateLimited` kippten
     (`docs/dt-invariance-measurements.md` §6). Die Begründung steht auch am
     Code, direkt über dem Deckel.
- Masse-Erhaltung gilt **nicht** (detachment-limited Stream-Power trägt Material aus);
  die Invariante ist beschränktes Relief / Fließgleichgewicht — Wächter:
  `Tests/SimCoreTests/LongRunCollapse.swift`.
- `ROADMAP.md` ist ein lebendes Dokument (Stand, offene Punkte, geparkter Code wie
  `fillLakes`/`floodplainAggradation`) — bei Änderungen mitziehen.
- Recherche-Belege in `docs/`; `docs/nickmcd-behavior-verification.md` hält je
  Ziel-Verhalten fest, wie es umgesetzt und womit es belegt ist.
