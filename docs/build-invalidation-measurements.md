# Build-Invalidierung und Bauzeiten (Issue #44)

Messungen vom 2026-08-11 auf dem macOS-Referenzrechner (M4 Max, 16 Kerne,
macOS 26.6.1, `/usr/bin/swift` = Swift 6.3.3 aus Xcode 26; Xcode und SDK seit
Wochen unverändert). Alle Zeiten mit `time`, `real` und `user` wie ausgegeben.

## Diagnose: Was löst die ~10-Minuten-Voll-Neubauten aus?

**Befund: SwiftPM verschlüsselt die komplette Prozessumgebung in die
Signaturen der Plugin- und Tool-Builds.** Schon eine einzige geänderte oder
zusätzliche Umgebungsvariable invalidiert die Host-Tool-Kette — und jeder
Aufruf-Kontext (Terminal-Pane, Editor, Agent-Session, Login- vs.
Nicht-Login-Shell) hat eine andere Umgebung. Deshalb wirkte es wie „erste
Ausführung des Tages": der erste Build aus einem anderen Kontext als dem des
Vorbaus zahlt den Voll-Neubau, und der nächste Build aus dem alten Kontext
zahlt ihn GLEICH NOCHMAL (Ping-Pong).

Beweiskette (alle Schritte auf diesem Rechner reproduziert):

1. **Reproduktion:** Nach einem konvergierten Stand aus Shell A baute derselbe
   `build.sh release` aus Shell B die komplette Tool-Kette neu (238 s), obwohl
   keine Quelle sich geändert hatte; zurück in Shell A noch einmal 292 s.
   Innerhalb derselben Shell: No-Op in 0,7 s.
2. **Minimaltrigger:** `RS_PROBE_FOO=42 scripts/build.sh release` — eine
   einzelne Junk-Variable — startet sofort den Neubau von
   `_SwiftSyntaxCShims`, `SwiftSyntax` und das Relinken von `Generator-tool`,
   `EntryPointGenerator-tool`, `TestSuiteGenerator-tool`.
3. **Wo die Umgebung steckt:** `Extension/.build/plugins/cache/*-state.json`
   speichert pro Plugin-Skript die vollständige `environment` des Aufrufs
   (PATH, FPATH, Homebrew-Variablen, Session-IDs …) und vergleicht sie beim
   nächsten Lauf. Die generierten Build-Manifeste selbst
   (`release.yaml`, `plugin-tools.yaml`) sind unter verschiedenen Umgebungen
   **byte-identisch** — die Invalidierung läuft also nicht über die
   Kommando-Argumente, sondern über den umgebungsabhängigen Zustand der
   Plugin-/Tool-Ebene.
4. **Kaskade:** Die SwiftGodot-Codegen-Kommandos (API-Bindings) hängen als
   llbuild-Inputs am `Generator-tool`-Binary. Ein Relink (neue mtime) lässt
   den Codegen neu laufen, dessen neue Ausgabedateien reißen `SwiftGodot` und
   `RiverSimGD` mit — zusammen die beobachteten ~10 Minuten bei ~1,1/16
   Kernen (serielle Modulkette + Whole-Module-Optimization, mehr Kerne helfen
   hier nicht).

Ausgeschlossene Kandidaten: Toolchain-/SDK-Wechsel (Xcode seit Juni
unverändert), Re-Resolution der Pakete (`workspace-state.json` unverändert),
`swift-version--*.txt` (Inhalt und mtime seit Wochen stabil), Sandbox
an/aus als solche (in sich konsistent).

## Fix in `scripts/build.sh`

- **Normalisierte Umgebung:** Alle `swift`-Aufrufe laufen unter
  `env -i HOME=… USER=… LOGNAME=… TERM=dumb PATH=/usr/bin:/bin:/usr/sbin:/sbin`
  (Linux: plus Swiftly-Bin und `LD_LIBRARY_PATH` für den ncurses-Shim).
  Damit ist die Signatur unabhängig vom Aufruf-Kontext; die Toolchain wählt
  allein `xcode-select` bzw. Swiftly. `DEVELOPER_DIR` wird durchgereicht
  (bewusste Xcode-Wahl).
- **Toolchain-Wechsel wird gemeldet:** `swift --version` wird in
  `<scratch>/riversim-toolchain.txt` gestempelt; weicht er ab, warnt build.sh
  laut vor dem anstehenden Voll-Neubau, statt still 10 Minuten zu kosten.
- **`--product RiverSimGD`:** baut nur noch das gebrauchte Produkt statt
  aller Begleit-Produkte (SwiftGodot-Testextension, docc-/man-Generatoren).
- **Doppel-Invocation:** Nach Kaltbau/Neuplanung invalidieren sich der
  Plugin-Tools-Plan und der Hauptplan (teils dieselben Ausgabepfade) einmal
  gegenseitig — der NÄCHSTE Aufruf baute sonst überraschend minutenlang „aus
  dem Nichts" (so entstand auch die zweite ~10-min-Welle hinter dem
  614-s-Lauf aus Issue #44). build.sh ruft `swift build` deshalb zweimal auf;
  der zweite Durchlauf ist im Normalfall ein ~0,4-s-No-Op und konvergiert
  andernfalls die Welle sofort im selben Aufruf.
- **Geteilter Build-Cache für Worktrees:** Worktrees bauen per
  `--scratch-path` in das `Extension/.build` des Haupt-Repos. Die
  Abhängigkeiten (swift-syntax, SwiftGodot inkl. Codegen-Ausgaben) haben dort
  identische Kommando-Signaturen und werden wiederverwendet; nur
  RiverSimGD/SimCore (worktree-eigene Quellpfade) kompilieren neu. Die
  dokumentierte Handarbeit „`.build` kopieren, ModuleCache löschen" entfällt.
  `RS_NO_SHARED_BUILD=1` erzwingt einen eigenständigen Build.

## Messreihe vorher/nachher

„Vorher" = `build.sh` vor diesem Issue (Zahlen aus Issue #44, gleicher
Rechner, gleicher Tag). „Nachher" = gehärtetes `build.sh`.

| Fall | vorher real | nachher real | nachher user |
|---|---|---|---|
| No-Op, gleiche Shell | 1,1 s | 1,3 s | 0,8 s |
| Quellen unverändert, anderer Aufruf-Kontext | **614 s** (auch 238 s / 292 s gemessen) | **1,3 s** | 0,8 s |
| Junk-Umgebungsvariable (`RS_PROBE_FOO=42`) | Voll-Neubau der Tool-Kette | **1,3 s** | 0,8 s |
| SimCore-Edit (`touch Terrain.swift`) | 14,8 s | 8,9 s | 8,4 s |
| Extension-Edit (`touch SimNode.swift`) | — (vergleichbar SimCore-Edit) | 4,8 s | 3,8 s |
| Frischer Worktree, erster Build | 7:29 min (eigener Kaltbau, gemessen) + Handarbeit | **3:08 min** | 237 s |
| Checkout-Wechsel Haupt ↔ Worktree | — (getrennte `.build`s) | 3:07 min je Richtung | 235 s |
| Kaltbau (leeres `.build` im Haupt-Repo) | ~8 min **+ zweite ~5–10-min-Welle beim nächsten Aufruf** | 10:16 min in EINEM Aufruf, danach echter No-Op | 785 s |

Die Inkremental-Zeilen (SimCore-/Extension-Edit) wurden vor der
Doppel-Invocation gemessen; sie werden dadurch ~0,4 s langsamer.

Einordnung:

- Die drei oberen Fälle sind der eigentliche Gewinn: der tägliche
  „10-Minuten-Build aus dem Nichts" ist weg. Kontextwechsel und
  Umgebungsvariablen sind für die Signaturen unsichtbar.
- Der Rest-Posten ist die Neuplanung: Immer wenn SwiftPM den Build-Plan neu
  erzeugen muss (Checkout-Wechsel im geteilten Cache, geänderte Build-Flags),
  baut diese SwiftPM-Version die swift-syntax-Kette samt Codegen-Tools neu —
  auch bei byte-identischen Kommandos (die beim Replan neu geschriebenen
  Hilfsdateien invalidieren die llbuild-Regeln). Das sind die ~3 min je
  Checkout-Wechsel. Innerhalb desselben Checkouts wird nie neu geplant.
- Ein Plan-Cache je Checkout (Planungs-Artefakte sichern/zurückspielen) wurde
  ausprobiert und verworfen: llbuild ließ dabei nachweislich einen veralteten
  Link-Stand als „aktuell" durchgehen (der Build-Stempel-Check fing es ab).
  Zwei Regel-Sätze auf denselben Output-Pfaden sind nicht verlässlich —
  deshalb räumt build.sh beim Checkout-Wechsel die checkout-eigenen Ausgaben
  (`RiverSimGD.build`, `SimCore.build`, Module, Produkt) explizit weg.

## Kerne / Parallelität

`user/real ≈ 1,1` beim Voll-Neubau: Engpass ist die serielle Modulkette
(swift-syntax → SwiftGodot-Tools → Codegen → SwiftGodot → RiverSimGD) und
WMO (ein Frontend je Modul, intern `-num-threads 16`). Mehr Jobs ändern daran
nichts — der wirksame Hebel ist, diese Kette gar nicht erst neu zu bauen
(Normalisierung oben). Optimierungs-Schalter, die die Gleitkomma-Semantik
ändern würden (fast-math, `-Ounchecked`), sind tabu: Determinismus/Bit-Identität
pro Maschine ist eine getestete Invariante.

## SimCore: Extension- vs. Testpfad bleiben getrennt

Eine SimCore-Änderung wird weiterhin zweimal übersetzt (einmal im
Extension-Build, einmal von `swift test --package-path SimCore`). Ein
geteilter Scratch-Pfad würde nicht helfen, sondern schaden: beide Pfade
schreiben `release.yaml`/`build.db` desselben Scratch-Verzeichnisses mit
unterschiedlichen Paketwurzeln, Zielmengen (Testtargets) und Flags — das
erzeugt genau das Invalidierungs-Ping-Pong, das dieses Issue beseitigt.
Die Doppelarbeit kostet ~13 s und ist der Preis für einen stabilen Cache.
SimCore selbst hat keine Plugins/Makros und ist vom Umgebungs-Problem nicht
betroffen.
