# Aufgabe: Vegetation in river-sim — Stufe 1+2+3 (autonom)

Du arbeitest vollständig autonom im Repo /home/agent/git/river-sim (Swift-Simulationskern
SimCore + SwiftGodot-Extension + Godot-Projekt game/). Lies ZUERST AGENTS.md vollständig —
alle Build-/Test-/Architektur-Konventionen stehen dort und sind verbindlich. Stell KEINE
Rückfragen; bei Blocker-Bugs entscheidest du pragmatisch und dokumentierst die Entscheidung.

## Projektkontext
river-sim ist eine Echtzeit-Landschaftssimulation (Erosion/Tektonik/Hydrologie), kein
Generator. Es gibt bereits ein Vegetationsfeld `veg: [Double]` (0..1, Dichte) in
Terrain.swift (`updateVegetation(years:)`, letzter Pass in step(), Relaxation auf ein Ziel
aus Höhenband/Slope/Regen/Überflutungstiefe, τ = vegTimeConstant = 250a). Es dämpft heute
Erosion überall als Faktor (1−0.6·veg): Droplet-Erosion, Stream-Power/Outlet, Braiding-Scour;
in der Hangdiffusion erhöht veg den Boden-Faktor. Rendering: veg färbt nur Moosgrün in
terrainColorBytes() — es gibt KEINE 3D-Bäume. Meander.swift kennt veg NICHT (keine
Ufer-Kohäsion). Das veg-Feld wird per `vegetation()`-Callable an Godot gereicht.

## Übersicht: 3 Stufen, in dieser Reihenfolge, je Stufe EIN logischer Commit
Stufe 1: Bäume rendern (reine Optik, null Sim-Einfluss)
Stufe 2: Veg-Typen + Ufer-Kohäsion (Sim)
Stufe 3: Störung + Sukzession (Sim)
Nach JEDER Stufe committen — so bleibt bei Abbruch ein sauberer Stand.

## Constraints (gelten durchgehend, nicht verhandelbar)
- Determinismus ist eine getestete Invariante: neue Pässe nur über disjunkte
  Index-Bereiche parallelisieren (`parallel(nn-4)`-Muster), Ergebnis bit-identisch zur
  sequenziellen Schleife. Muster für „liest Feld A, schreibt scratch, dann Feld B":
  hillslopeDiffusion Pass1/Pass2.
- Framerate-Unabhängigkeit: Gesamtwirkung eines Passes ∝ dt. Winzige dt pro Frame und
  +10.000-Jahre-Sprünge müssen dasselbe Ergebnis liefern (Diffusions-Substepping beachten).
- Kalibrier-Kaskade: BESTEHENDE Parameter NICHT ändern (braidPass 5e-6, meanderMigration
  8e-6, vegTimeConstant, die 0.6-Dämpfung, D8/MFD-Trennung). Alles Neue additiv in
  Config.swift, jeder Parameter mit Begründungs-Kommentar im Logbuch-Stil (verworfene
  Werte + Messwerte). Das 0.6 in den Erosions-Dämpfungen bleibt — Typ-Einfluss als
  multiplikativer Faktor dazu.
- veg bleibt Dichte 0..1 — alle bestehenden Konsumenten funktionieren unverändert.
  Typen/Störung sind additiv.
- Alle bestehenden Tests grün halten. `meanderCfg()` und Test-Configs PINNEN alte Werte —
  nicht an Produktionswerte angleichen, neue Parameter gehören in die Test-Configs der
  neuen Tests.
- Sprache: Code-Kommentare, Doc-Kommentare, PR-Body auf Deutsch; Commit-Messages Englisch.
- Metriken: docs/river-baseline-metrics.md lesen. Vor Stufe 2 einen Baseline-Lauf machen
  (Relief/Ruggedness/meanLand/Churn wie dort dokumentiert, LongRunCollapse-Test), nach
  Stufe 3 denselben Lauf wiederholen, Abweichung im PR dokumentieren. Kleine Verschiebungen
  ok, kein Runaway/Kollaps.

## Build-/Test-Befehle (exakt, aus AGENTS.md)
    source ~/.local/share/swiftly/env.sh
    export LD_LIBRARY_PATH="$PWD/.tools/swift-libs:${LD_LIBRARY_PATH:-}"   # aus Repo-Wurzel
    swift test -c release --package-path SimCore -Xswiftc -swift-version -Xswiftc 5
    # einzelner Test: --filter <Methodenname>  (NICHT der Klassenname)
    "$(git rev-parse --show-toplevel)"/scripts/build.sh release            # auf "gebaut"-Zeile prüfen
    # Godot headless: GODOT-Binary, dann z.B.
    "$GODOT" --headless --path game --script res://tests/smoke.gd
    "$GODOT" --headless --path game --script res://tests/pickaxe_repro.gd
    # Screenshot: RS_STEP=20000 RS_SHOT=/tmp/veg_stufeX.png RS_DIST=90 "$GODOT" --path game
    # FPS-Messung: RS_FPS=1

## Stufe 1 — Bäume rendern (MultiMesh, rein visuell)
Ziel: echte 3D-Bäume aus dem veg-Feld, ohne jede Sim-Rückwirkung.
- Baum-Maske je Zelle: veg > 0.45 UND trocken (hf−h > 0.02 — nicht im Flussbett) UND
  Grob-Steigung flach genug (slope ±2 Zellen wie in updateVegetation, slope·40 < 0.3).
- Instanzen deterministisch: Jitter aus Hash(i,j,Seed-Konstante) (z.B. FNV), KEIN
  Random je Frame (Flackern verboten). Position: Höhe aus heights(), kleiner z-Jitter.
- Verdünnung so, dass ~20–60k Instanzen bei n=832 entstehen (Kandidaten-Raster z.B.
  jede 2. Zelle). 2–3 Baum-Varianten (Laub/Nadel/Größen) + Büsche.
- Aktualisierung NICHT jeden Frame: Rebuild nur bei Generierung + wenn sich das veg-Feld
  merklich ändert (z.B. Max-Delta seit letztem Build > 0.1 — Heuristik frei wählbar,
  dokumentieren). MultiMeshInstance3D in Main.tscn/Main.gd.
- Distanz-Handling: LOD (nah detail / fern Impostor oder Billboards) oder aggressives
  Distanz-Culling — Budget entscheidet: aktuelle FPS nicht spürbar senken (vorher/nachher
  mit RS_FPS messen).
- Boden-Grün in terrainColorBytes leicht entsättigen/dämpfen (vegAmt-Faktor ~0.85), damit
  die Bäume abheben — kleine, begründete Änderung, per Screenshot-Vergleich belegen.
- Neuer Callable in SimNode.swift nur falls nötig (vegetation()/heights()/filled()
  existieren schon — Maske ist in GDScript berechenbar).
Verifikation: build.sh release grün, smoke.gd + pickaxe_repro.gd grün, Screenshot zeigt
Bäume in den Tälern (nicht im Wasser, nicht auf steilen Hängen), RS_FPS vorher/nachher
dokumentiert.

## Stufe 2 — Veg-Typen + Ufer-Kohäsion
Ziel: Vegetation differenziert in Gras / Wald / Auwald (riparian), Auwald stabilisiert
Flussufer → dämpft Mäander-Migration.
- Neues Feld vegClass (oder vegType) je Zelle: {0 kahl, 1 Gras, 2 Wald, 3 Auwald}.
  Ableitung aus der bestehenden Ziel-Funktion mit Differenzierung: flussnahe feuchte
  flache Zonen (z.B. Umkreis von Zellen mit areaMFD ≥ braidMinCells, oder Distanz zur
  nächsten Wasserzelle über hf−h — Heuristik frei, dokumentieren) → Auwald; trockenere
  Täler/Hänge → Wald; Übergangs-/Default-Flächen → Gras; steil/hoch/tief überflutet → kahl.
  Klassen-Übergänge weich halten (kein harter Flickenteppich; ggf. Klasse aus
  geglätteten Eingangsgrößen).
- Erosions-Dämpfung: (1 − 0.6·veg) × typFactor mit typFactor als Config-Parameter je Typ
  (Vorschlag: Gras 1.0 — heutiges Verhalten bleibt flächenmäßig erhalten, Wald ~1.1,
  Auwald ~1.3; Werte selbst kalibrieren und begründen).
- Ufer-Kohäsion in Meander.swift: Migration je Knoten × (1 − meanderCohesion · mittleres
  riparian-veg im Ufer-Streifen um die Zentrumslinie, Breite ~ meanderBankWidth).
  Config-Parameter meanderCohesion mit Begründung; Default so, dass die GESAMT-Migration
  im Schnitt erhalten bleibt, aber bewaldete Reaches sichtbar langsamer sind.
- Neuer Callable für vegClass (z.B. PackedByteArray) ans Rendering (Stufe 3 + Optik nutzen
  ihn; Auwald kann später eigene Baum-Art bekommen).
Verifikation: kompletter swift test grün; neue Tests: (a) Auwald nur flussnah/flach/feucht,
(b) Migration mit bewaldetem Ufer < ohne (mit gepinnter Test-Config), (c) bestehende
Meander-Tests unverändert grün. Baseline-Metriken vor/nachher verglichen, Abweichung
dokumentiert.

## Stufe 3 — Störung + Sukzession
Ziel: Vegetation wird ereignisgetrieben — die Landschaft „atmet", Bäume reagieren auf den
Fluss.
- Flood-Kill: in updateVegetation, wo hf−h > vegFloodKillDepth (Vorschlag ~0.03), sinkt
  veg mit schneller eigener Rate (τ_kill ~20a, eigener Parameter) statt der 250a-Relaxation
  — Auwald zuerst, dann Wald. dt-skalierend, deterministisch.
- Ufer-Kill (Mäander-Fraß): Zellen, die der Meander-Pass frisch als Bett stampft/carvt
  (dort wo die Grid-Kopplung schreibt), bekommen veg = 0 — Wurzel-Wegriss. Danach wächst
  alles von Nachbarn zurück.
- Sukzession/Dispersal: Regrünung braucht Samen-Druck — vegTarget = max(geografisches
  Ziel, Nachbarschaftsterm aus max. veg im Radius vegDispersalRadius · vegDispersalStrength).
  WICHTIG: Dispersal darf KEINE neue Vegetation in geografisch kahlen Zonen erzeugen
  (steile Hänge, Höhenwüste bleiben kahl) und die Landschaft nicht uniform verwaldet —
  es soll nur Störungsflächen neben intaktem Bewuchs regenerieren. Pass1/Pass2-Muster
  (liest veg → scratch → schreibt veg), deterministisch, bit-identisch.
- Die Stufe-1-Bäume reagieren automatisch (gleiches veg-Feld; Rebuild-Heuristik greift).
Verifikation: neue Tests: (a) Flood-Kill senkt veg in tief überfluteten Zellen,
(b) Regrünung nach Kill innerhalb ~3·τ, (c) karge Insel bleibt kahl (kein Spontanwald),
(d) Ufer-Kill nach Meander-Schritt setzt veg auf 0, (e) Determinismus-Test (gleicher Seed
→ bit-identisch), (f) LongRunCollapse + komplette Suite grün. Baseline-Vergleich im PR.

## Abschluss
1. Branch `vegetation-trees` erstellen, 3 logische Commits (Englisch, Stufe je Commit).
2. Pushen und PR gegen main öffnen (gh CLI). Falls die Repo-Historie erkennbar keinen
   PR-Workflow nutzt, stattdessen direkt auf main committen — begründen.
3. PR-Body auf Deutsch: Was gebaut (je Stufe), Test-Ergebnisse, Baseline-Metrik-Diff
   (vorher → nachher), Screenshot-Pfade, offene Punkte/Risiken.
4. Abschluss-Bericht an den User auf Deutsch, kompakt: je Stufe 2–3 Sätze + Befunde.
