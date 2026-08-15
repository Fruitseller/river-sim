# CI-Laufzeiten und Laufzeit-Budget (Issue #52)

Was in CI läuft, was es kostet und was zu tun ist, wenn es zu lang wird.
Aufbau der Jobs: `AGENTS.md` §CI, Definition: `.github/workflows/ci.yml`.

## Warum das hier steht

Vor #52 lief in CI nur die SimCore-Suite. Der Godot-Vertrag — GDExtension-Build,
Projekt-Import, Smoke-/Geometrie-/Ribbon-Tests, Build-Stempel-Parität — war eine
Zusage im Review („lokal ausgeführt"). Genau die Fehler, gegen die diese Tests
gebaut wurden (veraltete `.so`, nicht registriertes `SimNode`, gebrochener
Renderpfad-Vertrag), fallen aber erst auf, wenn sie jemand ausführt.

Der Preis dafür ist Laufzeit, und Laufzeit ist ein Budget: eine Suite, deren
Rücklauf man nicht mehr abwartet, wird umgangen. Deshalb ziehen dieselbe Änderung
zwei Richtungen — der Godot-Vertrag kommt dazu, die Mess- und Sweep-Läufe gehen
raus.

## Budget

| Ebene | Deckel | Wirkung bei Überschreitung |
| --- | --- | --- |
| Pflichtsuite (`test`) | **15 min** | `timeout-minutes: 40` bricht ab |
| Godot-Vertrag (`godot-contract`), warmer Cache | **15 min** | `timeout-minutes: 75` bricht ab |
| Godot-Vertrag, Kaltbau | ~30 min Build + Vertrag | — |

Der Deckel für die Pflichtsuite liegt gut doppelt über dem lokal gemessenen Wert
(6:58), weil der GitHub-Runner langsamer ist als der Messhost und der
Cache-Restore dazukommt.

Die `timeout-minutes` liegen bewusst über dem Budget: sie fangen den *Hänger* ab,
nicht das langsame Wachstum. Das Wachstum fängt dieses Dokument — wer einen
langen Testlauf hinzufügt, misst nach und zieht die Zahlen unten mit.

Beide Jobs laufen parallel und ohne `needs:`. Ein CI-Lauf kostet also die Zeit
des langsameren Jobs, nicht die Summe.

## Gemessen

Messmaschine: Linux-Host, **4 Kerne**, Swift 6.3.3, `-c release`, Godot 4.7.1
(dieselbe Binärdatei, die `scripts/fetch-godot.sh` holt — per sha256 gegen den
CI-Download geprüft). Der GitHub-Runner `ubuntu-22.04` hat ebenfalls 4 Kerne; die
Zahlen sind damit übertragbar, aber nicht identisch — Cache-Restore, Toolchain-
Entpacken und langsamere I/O kommen dazu.

> **Offen:** Die Zahlen unten sind alle **lokal** gemessen. Die tatsächlichen
> CI-Zeiten je Job (inkl. Cache-Restore) trägt der erste grüne Lauf von
> `.github/workflows/ci.yml` nach — sie stehen in der Job-Übersicht der
> GitHub-Actions-Oberfläche. Bis dahin gilt: die Budgets oben sind die Zusage,
> die Werte unten die Untergrenze.

### SimCore-Suite (Job `test`)

| Stand | ausgeführt / übersprungen | Testlauf | + Build (warm) |
| --- | --- | --- | --- |
| vor #52 | 211 / 12 | **689 s** (11:29) | 741 s (12:21) |
| nach #52, ohne `RS_MEASURE` | 196 / 29 | **418 s** (6:58) | 443 s (7:23) |

Beide Läufe grün, 0 Fehlschläge. Der Testlauf verliert **271 s (−39 %)**.

Herausgenommen wurden **17 Läufe mit zusammen 270 s** — Tests, die gar nicht rot
werden können: die `…Diagnostic`-Methoden drucken die Tabellen für
`docs/*-measurements.md`. (Zwölf weitere waren schon vorher gegatet, nur unter
drei verschiedenen Schaltern; sie stecken in den „12 übersprungen" der ersten
Zeile.) Die teuersten Einzelposten:

| Test | Laufzeit |
| --- | --- |
| `Glacier.testValleyShapeSeriesDiagnostic` | 55,7 s |
| `Glacier.testGlacialErosionSweepDiagnostic` | 48,1 s |
| `Glacier.testIcePassCostDiagnostic` | 31,3 s |
| `ClimateSnow.testProductionResolutionDiagnostic` | 26,4 s |
| `Glacier.testPeakHeightSeriesDiagnostic` | 24,3 s |
| `Glacier.testIceParameterSweepDiagnostic` | 24,0 s |
| `MeltRunoff.testSnowyIslandScanDiagnostic` | 16,6 s |

Die Pflichtsuite bleibt damit auch nach oben Luft: der teuerste verbliebene Test
ist `DeepPitDiag.testSimulationCreatesNoDeepPits` mit 84 s — ein echter Wächter
(keine tiefen Löcher nach einem langen Lauf), der bleibt.

Drei der herausgenommenen Läufe trugen je **eine** Zusicherung mit. Was davon in
der Pflichtsuite bleibt und was nicht — die Aufstellung ist bewusst genau, weil
„ist ja anderswo gedeckt" der Satz ist, mit dem Abdeckung verschwindet:

- `MeltRunoff.testMeltRunoffMeasurementDiagnostic` und
  `RainWeightedFlow.testRainWeightMeasurementDiagnostic` prüften je
  `landRelief() > 0.10` („Terrain nicht eingeebnet"). **Vollständig gedeckt** von
  `LongRunCollapse.testLongRunDoesNotRunAway`, dort mit `> 0.30` über den vollen
  Horizont statt als Beifang einer Messreihe.
- `RainWeightedFlow.testRainWeightLuvLeeIsSeedRobustDiagnostic` prüfte gepoolt
  über sechs Seeds, dass der gewichtete Abfluss die Drainagedichte Richtung Luv
  verschiebt (Faktor > 1,05). Die **Richtung** bleibt gedeckt, sogar schärfer:
  `testRainWeightedFlowFavorsLuv` (D8) und `testRainWeightedMFDFavorsLuv` (MFD)
  fordern Faktor > 1,10, beide ungegatet. Was die Pflichtsuite verliert, ist die
  **Seed-Robustheit** dieser Richtung — die hing an sechs 20.000-Jahre-Läufen
  und ist mit `RS_MEASURE=1` reproduzierbar. Ein Bruch, den nur der Seed-Schnitt
  zeigt, fällt damit erst bei der nächsten Messreihe auf; das ist der bewusst
  in Kauf genommene Rest.

Das Gate ist ein Schalter für alle: `RS_MEASURE=1`. Vorher waren es drei
(`RS_MEASURE`, `RS_SWEEP`, `RS_EVAP_MEASURE`) plus ein Dutzend ungegateter
Diagnose-Läufe. `MeasurementGateTests` hält die Konvention beidseitig fest
(Details: `SimCore/Tests/SimCoreTests/MeasurementGate.swift`).

Der Schalter prüft auf den **Wert `1`**, nicht auf „gesetzt": ein versehentlich
exportiertes `RS_MEASURE=0` soll die Messläufe nicht wieder in die Pflichtsuite
holen. Der Konventions-Wächter sieht diesen Fall nicht — er prüft nur die
Paarung „`Diagnostic` ↔ `skipUnlessMeasuring()`".

### Godot-Vertrag (Job `godot-contract`)

Lokal gemessen im Worktree gegen den geteilten Build-Cache des Haupt-Repos
(entspricht in CI dem Cache-Hit auf `Extension/.build`):

| Schritt | Laufzeit |
| --- | --- |
| `scripts/build.sh release` (warmer Cache, worktree-eigene Module) | TBD |
| `godot --headless --path game --import` | TBD |
| `build_stamp_parity.gd` | TBD |
| `smoke.gd` | TBD |
| `water_geometry.gd` | TBD |
| `river_ribbons.gd` | TBD |

Der **Kaltbau** der Extension ist der dominierende Posten und in CI nur beim
ersten Lauf bzw. nach einem SwiftGodot-Pin-Wechsel (Issue #49) fällig: auf einem
4-Kern-Linux-Host **27 min** (AGENTS.md, „Extension bauen"). SwiftGodots Codegen
speist die ganze Modulkette, mehr Kerne helfen nicht.

Auf dem Runner gemessen (`ubuntu-22.04`, Lauf 31898601044, Extension-Cache leer):
Bau **28,6 min**, Import 6 s, Stempel-Parität < 1 s, `smoke.gd` 8 s,
`water_geometry.gd` 13 s, `river_ribbons.gd` 4 s. Der Rest des Jobs (Toolchain,
Godot-Download aus dem Cache) liegt zusammen unter 40 s. **Achtung beim
Iterieren:** `actions/cache` schreibt seinen Eintrag nur bei ERFOLGREICHEM Job —
solange `godot-contract` rot ist, kostet jede Runde den vollen Kaltbau.

#### Erst-Import stürzt auf dem Runner ab (Issue #61)

Der ERSTE `--import` in ein frisches `game/.godot` reißt Godot 4.7.1 auf diesem
Image beim Herunterfahren ab (Signal 6/11, Exit 139) — nachdem alle Import-Phasen
`DONE` gemeldet haben und `extension_list.cfg` geschrieben ist. Belegt in Lauf
31898601044 (Diagnose-Schritte aus Commit db4f93a, danach wieder entfernt):

- der `gdb`-Backtrace zeigt den Abort in Thread 1 **im Godot-Binary** (stripped,
  keine Symbole; kein Frame der GDExtension, Worker-Threads in `futex`-Waits),
- dieselbe Binärdatei importiert **ohne** `game/bin/*.so` sauber (Exit 0),
- der **zweite** Import (warmes `.godot`) läuft sauber durch, ebenso jeder
  folgende Skript-Lauf — `smoke.gd` meldete im selben Job `SMOKE_OK`.

Lokal (Debian 13) tritt der Absturz nicht auf. Der Job wiederholt den Import
deshalb bis zu dreimal, statt ihn zu übergehen: der Vertrag bleibt voll wirksam,
weil jeder folgende Schritt die Extension wirklich lädt. Schlagen alle drei
Versuche fehl, ist der Job rot.

## Cache-Strategie

Vier `actions/cache`-Einträge, jeder mit einem anderen Verfallsgrund:

| Cache | Key hängt an | Warum getrennt |
| --- | --- | --- |
| `/opt/swift` | Toolchain-Version | Mehrere GB Download; ändert sich fast nie |
| `SimCore/.build` | `Package.swift` + Sources + Tests | Verfällt bei jeder Sim-Änderung, ist aber billig neu zu bauen |
| `Extension/.build` | `Package.resolved` + Sources | Der teure; `restore-keys` holt den letzten Stand desselben Toolchain-Stands, aus dem SwiftPM inkrementell weiterbaut |
| `.tools/godot-<version>` | Version aus `scripts/fetch-godot.sh` | ~76 MB Download, wechselt nur mit dem Godot-Pin |

Die beiden **Fremd-Downloads** (Swift-Toolchain, Godot-Binärdatei) hängen an einer
gepinnten sha256, nicht nur an HTTPS. Beim Godot-Cache wird die Prüfsumme auch beim
**Cache-Hit** gezogen (~0,1 s) — sonst hinge der Vertragstest an einem Cache-Key,
der nur den Versions-Tag nennt. Version und Prüfsumme werden immer zusammen
ausgetauscht: `SWIFT_VERSION`/`SWIFT_SHA256` in `ci.yml`, `GODOT_VERSION`/
`GODOT_SHA256`/`GODOT_BIN_SHA256` in `scripts/fetch-godot.sh`.

`SimCore/.build` und `Extension/.build` sind **kein** Doppel-Build derselben
Sache: verschiedene Paketgraphen, verschiedene Scratch-Pfade. Der Extension-Build
kompiliert SimCore als Abhängigkeit mit, kann aber die Testziele nicht ausführen —
der Sim-Kern-Job braucht sein eigenes Paket. Sie parallel laufen zu lassen kostet
also nichts extra an Wanduhr-Zeit und spart die Serialisierung.

## Wenn das Budget reißt

In dieser Reihenfolge prüfen:

1. **Ist der neue Test ein Messlauf?** Dann gehört er hinter `RS_MEASURE`
   (Namensendung `Diagnostic`, `try skipUnlessMeasuring()`).
2. **Braucht er die Produktionsauflösung?** Die meisten Wächter der Suite laufen
   auf `n = 96…256`; `n = 832` gehört in `simperf`, nicht in die Suite.
3. **Ist der Cache kaputt statt der Test langsam?** Ein Kaltbau sieht in der
   Übersicht wie eine langsame Suite aus. Der Schritt „GDExtension bauen" im
   Log sagt es.
4. Erst dann das Budget anheben — und diese Zahlen hier mitziehen.
