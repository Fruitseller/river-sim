# Handoff — Terrain-Optik-Overhaul (Richtung nickmcd)

Stand: Commit `224d9e2` auf `main`. Alle Tests grün (2 bewusst geparkt, s. u.).

## Ziel

Der Look soll **exakt** dem Referenzartikel entsprechen:
https://nickmcd.me/2020/04/15/procedural-hydrology/

Kennzeichen der Referenz: feine **dendritische Erosions-Rinnen** über die ganze
Oberfläche, **grauer Fels**, **moosgrüne Täler**, weiße Gipfel, **dezentes
teal-Wasser** (halbtransparente Seen + dünne Fäden). Wichtig: die Referenz ist
ein **junges** Terrain, kein Langzeit-Gleichgewicht.

## Was bereits erreicht ist (Commit 224d9e2)

- **Droplet-Hydraulik-Erosion** (`SimCore/Sources/SimCore/Hydraulic.swift`,
  Lague/nickmcd): deterministisch, carvt feines dendritisches Detail statt zu
  glätten. Haupt-Sculptor in `Terrain.step()` wenn `cfg.hydraulicEnabled`.
- **Ridged-Terrain**: `Noise.ridged01` (Grundrelief + Tektonik-Feld), Auflösung
  `n=640`, Talboden angehoben (Täler bleiben Land).
- **U/K-Balance** hoch (stärkere Hebung, weniger Erodierbarkeit) für bleibendes
  Relief.
- **Optik**: naturalistische, entsättigte Palette in `SimNode.terrainColorBytes`
  (grauer Fels, grüne Täler, Schnee nur ganz oben); neutrales Licht/Environment
  in `game/scripts/Main.gd` (Blaustich behoben); Wasser als glattes teal-Feld
  (`SimNode.waterFieldBytes` + `game/shaders/terrain.gdshader`).
- **UI**: größere Schrift; Zoom ohne Maus (`+`/`−`, Trackpad Zwei-Finger-Wisch,
  Pinch).

Das **junge** Terrain (ca. 0–20k Jahre) ist nah an der Referenz. Screenshot-
Belege wurden während der Session erzeugt.

## Offene Aufgaben (priorisiert)

### 1. Langzeit-Kollaps — GEMESSEN & im Kern behoben ✅ (Rest s. Aufgabe 1b)
**Messung zuerst** (headless, quantitativ statt geschraubt): das Terrain
kollabierte NICHT zu glatten Kuppeln — es lief **weg** (Runaway). Über 100k Jahre
(n=640, gemessen): Relief 0.82 → **1.10** (+34%), See-Anteil 21% → **39%**, maxH
bis an den Clamp 1.25. Die Hebung (netto positiv) trug die Grate immer weiter
hoch, und der **Droplet-Pfad hatte keine Becken-Entwässerung** → geschlossene
Senken wucherten zu Seen.

**Fix (zwei Hebel, beide gemessen):**
- `cfg.basinFill = true` — geschlossene Becken verlanden langsam (das alte
  `fillLakes`, jetzt auch im Droplet-Zweig von `step()`). Hält den See-Anteil bei
  ~18% statt Richtung 39%.
- `cfg.isoHighClamp = 0.90` (war 1.25) — deckelt das Relief-Runaway. Pinnt
  Relief/maxH über 100k Jahre aufs junge Niveau (~0.77/0.92). 0.85 würde die Berge
  bereits abtragen, 1.0 driftet leicht hoch — 0.90 ist das Plateau.
- Ergebnis n=640 @100k: Relief 0.77 (stabil), See 18.7%, maxH 0.92. Festgehalten
  in `SimCoreTests/LongRunCollapse.swift` (Regressions-Wächter).

### 1b. Endorheisches Becken — GEOMETRIE behoben ✅ (Rest ist Palette, s. Aufgabe 3)
Über die Zeit bildete sich ein **Ring aus Bergen um ein abflussloses Becken**; ohne
Fill säuft es voll, mit reinem `basinFill` verlandet es zu einer blassen Flach-Ebene.
- **Fix: Auslass-Inzision** (`Terrain.outletIncision`) — Flächen-Stream-Power auf dem
  Entwässerungsnetz (Priority-Flood liefert `order`/`receiver`/`area`). Konzentriert
  die Inzision auf Zellen mit großem Einzugsgebiet (Täler/Auslässe) → Becken
  **entwässern zum Meer**, es entstehen dendritische Rinnen + diskrete Seen statt
  einer Ebene. `cfg.outletIncision=true`, `cfg.outletErode=3e-5`.
  - Wichtig gemessen: die **Ponding-gegatete** Erstfassung überkämmte (rugged →0.14,
    See →45%). Die **flächen-basierte** (reine A^m·S) Variante konzentriert sich auf
    Täler und bleibt dendritisch. 6e-5 überkarvt bei 100k → 3e-5.
- `cfg.basinFill` ist jetzt AUS (s. Aufgabe 1c): bei niedriger Hebung würde er die
  Seen zu ~1% überfüllen → blasse Flach-Ebenen. Aus → diskrete blaue Seen (~15%).

### 1c. Berge wachsen nicht mehr + Palette (User-Feedback, umgesetzt) ✅
- **Berge wuchsen pro 10k-Schritt hoch:** gemessen stockte die alte Hebung
  (`upliftPer100y=0.009`) die gesamte Landmasse auf (meanLand 0.39→0.68 über 100k,
  +73%) — auch mit Gipfel-Clamp. `0.0015` → Masse bleibt ~flach, Relief erodiert
  sanft (0.76→0.65), Berge erodieren statt zu wachsen (real ohne aktive Tektonik).
- **Folge für den Look:** mit wenig Hebung entstehen kaum noch geschlossene Becken;
  Auslass-Inzision hält den See-Anteil bei ~15% als **diskrete blaue Seen** → daher
  `basinFill=false`. Das behob die blasse Interior-Ebene bei 100k.
- **Palette** (`terrainColorBytes` + `terrain.gdshader`): Steilfels-Highlight
  halbiert (wusch die Rinnen weiß), Fels dunkler-grau, mehr Moosgrün, Wasser
  gedämpfter + `lakeMask` höher (seichte Pfützen nicht mehr pastell).
- **Rest-Weiß auf den Graten** ist Sonnenlicht auf der dissozierten Geometrie
  (wie „weiße Gipfel" der Referenz) — akzeptabel. Wer es weiter drücken will:
  Stream-Overlay-Intensität / dry-SPECULAR im Shader senken.
- Das junge/mittlere Terrain (bis ~20k) ist weiterhin sehr nah an der Referenz.

### 2. Mäander mit Droplet-Erosion versöhnen
`cfg.meanderEnabled = false` in Produktion, weil die Migration unter der neuen
Erosion/dem neuen Terrain instabil läuft (Sinuosität läuft weg).
- Mäander-Kern-Tests laufen isoliert über `meanderCfg()` (Grid-Erosion, Mäander
  an) und sind grün.
- **Geparkt mit `XCTSkip` + Begründung** (rekalibrieren, dann reaktivieren):
  - `testMeanderTerrainLongRunStable` (Sinuosität läuft unter neuem Terrain weg)
  - `testMeanderOxbowSiltsUp` (Altarm-Verlandung nicht mehr mehrheitlich)
- Ziel: Migration/Cutoff/Verlandung aufs neue ridged-Terrain kalibrieren, dann
  `meanderEnabled` wieder an.

### 1d. Realistisches Altern: Hangdiffusion (LEM-Recherche) ✅
Der Droplet-Pfad hatte KEINEN grat-abtragenden Prozess → Terrain wurde über die
Zeit *spitzer* statt runder (rugged 0.015→0.05 über 100k). Recherche in
`docs/research-terrain-aging.md` (Primärquellen: Theodoratos 2018, Whipple&Tucker,
Braun&Willett, nickmcd/SoilMachine). Umgesetzt:
- **Lineare Hangdiffusion** (`hillslopeDiffusion`) im Droplet-Pfad — der Prozess,
  der Grate rundet (konvexe Kuppen = Appalachen-Signal). RÄUMLICH VARIABEL: volle
  Rundung auf soil-mantled/sanften/bewachsenen Hängen, gedrosselt (15%) auf hohem
  steilem Kahlfels → **einzelne spitze Gipfel bleiben** (die Ausnahme, nicht die
  Regel — User-Wunsch). `cfg.hillDiffusion=0.05`, auf n=640 kalibriert & auflösungs-
  unabhängig skaliert (kappa=D·Δt/dx² ∝ (n−1)²).
- **Prozess-Reihenfolge** LEM-konform: Uplift→Flow→SPL/Auslass→Droplet→Diffusion→Wave.
- Kennzahl zum Weiterdrehen: `l_c=D/K` (klein=zerklüftet/jung, groß=rund/alt).
- **OFFEN (optional, größer):** abklingende Hebung `U(t)=U_floor+(U₀−U_floor)e^(−t/τ)`
  für noch dramatischeres „jung→alt" (Recherche §3). Bewusst NICHT gemacht, weil
  U₀>heute einen Wachstums-Puls einführt (User will kein Wachsen). Diffusion + wenig
  Hebung liefert das Altern schon ohne Wachstum.
- `isoHighClamp` (0.90) bleibt vorerst als Sicherheitsnetz; laut Recherche mit
  Diffusion überflüssig — kann später getestet/entfernt werden.

### 3. Optik-Feinschliff (nach 1 & 2)
- Grün-Anteil in den Tälern feiner (Referenz hat deutlich sichtbares Moosgrün).
- Gipfel-Gleißen / Schnee-Schwelle prüfen.
- Wasser: Küstensaum-Breite, Fluss-Kontrast.

## Verifikation

- **Headless-Tests**: `cd SimCore && swift test` (≈80 s). Alle grün, 2 skipped.
- **Extension bauen** (~3,5 min): `./scripts/build.sh release`.
- **Screenshots headless** (Godot via Steam):
  ```
  GODOT="$HOME/Library/Application Support/Steam/steamapps/common/Godot Engine/Godot.app/Contents/MacOS/Godot"
  RS_STEP=<jahre> RS_SHOT=/pfad/shot.png "$GODOT" --path <repo>/game
  ```
  `RS_STEP` steppt die Sim vor dem Shot (Jahr-0 vs. gesteppt vergleichen!).
- **App interaktiv**: `"$GODOT" --path game` (oder `--editor`).

## Wichtige Dateien

- `SimCore/Sources/SimCore/Hydraulic.swift` — Droplet-Erosion.
- `SimCore/Sources/SimCore/Terrain.swift` — `generate()` (ridged Relief+Tektonik),
  `step()` (Erosions-Auswahl), `diffusionPass`.
- `SimCore/Sources/SimCore/Noise.swift` — `ridged01`.
- `SimCore/Sources/SimCore/Config.swift` — alle Stellschrauben (`n`, `baseRelief`,
  `kRock`, `upliftPer100y`, `upliftFreq`, `hydraulic*`, `meanderEnabled`).
- `Extension/Sources/RiverSimGD/SimNode.swift` — `terrainColorBytes` (Palette),
  `waterFieldBytes` (Wasser-Feld).
- `game/shaders/terrain.gdshader` — Wasser-Overlay + Shading.
- `game/scripts/Main.gd` — Licht/Environment, UI, Kamera/Zoom.

## Prozess-Feedback vom User (ernst nehmen)

- **Nicht zaghaft** („MVP vom MVP") — bold und richtig lösen.
- **Nicht blind an Details schrauben**, wenn das Gesamtbild nicht stimmt; erst
  objektiv per Screenshot messen (Jahr 0 vs. gesteppt).
- Der User hat wiederholt zu Recht kritisiert, dass Einzel-Tweaks am falschen
  Problem ansetzten — die Wurzel war Terrain-Detailgrad + Erosionsmodell, nicht
  Wasserfarbe.
