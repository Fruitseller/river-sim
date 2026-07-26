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

### 1. Langzeit-Kollaps beheben (KERNPROBLEM, höchste Prio)
Über lange Zeitraffer-Läufe (~60–100k Jahre) kollabiert die Makro-Form zu
glatten Kuppeln mit Wasserbecken — das ist der Ursprung von „wird beim Steppen
schlechter". Das junge Terrain ist gut, der Langzeit-Zustand nicht.

- Hypothese: das Erosions-Gleichgewicht ist zu glatt / die Hebung trägt die
  Grate nicht. Ridged-Tektonik allein hat es nicht gelöst — evtl. Hebungs-
  Frequenz (`cfg.upliftFreq`) zu niedrig, oder Droplet-Rate/Balance.
- Idee: Sim auf einem **jung-gratigen Gleichgewicht** stabilisieren statt in
  Kuppeln altern zu lassen. Hebel: `upliftFreq` höher (feinere Gebirgszüge),
  `hydraulicPerYear`/`kRock`/`upliftPer100y` balancieren, Diffusion (`kappa` in
  `diffusionPass`) minimal halten.
- **Vorgehen: erst messen** — Screenshot-Serie Jahr 0 vs. gesteppt vergleichen
  (siehe Verifikation unten), nicht blind schrauben.

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
