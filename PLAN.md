# river-sim — Bauplan & Architektur (Godot 4.6 + SwiftGodot)

Diese Datei hält die **Architektur-Entscheidungen und ihre Begründung** fest.
Aktueller Stand, offene Punkte und Verifikations-Rezepte stehen in `ROADMAP.md`.

Ursprung: Wegwerf-Prototyp (`../prototype-terrain-sim/index.html`, Three.js/JS). Er hat
die Kern-Design-Frage beantwortet: **Terrain formen → Zeit vergeht → Erosion/Flüsse/
Tektonik altern die Welt** trägt als Loop. Dieser Plan überführte das nach Godot, mit
Swift als Sprache für den Simulationskern.

---

## 1. Architektur-Entscheidung

**Godot** übernimmt Rendering, Szene, Kamera, Input, UI, Audio, Save/Load, Build.
**SwiftGodot** (GDExtension) übernimmt den rechenintensiven Simulationskern — typsicher,
schnell, und als reines Swift-Package **ohne Godot headless unit-testbar**.

Warum Swift statt GDScript/C# für den Kern:
- Der Kern ist Zahlenschieberei auf `Float`-Grids (Erosion, Flow-Accumulation, PDEs).
  GDScript ist dafür zu langsam; Swift ist AOT-kompiliert und kann via `Accelerate`/SIMD
  vektorisieren.
- Der Kern lässt sich als plattform-unabhängiges SwiftPM-Target bauen und mit **XCTest
  headless** prüfen (Masse-Erhaltung, Gleichgewicht, Determinismus) — ganz ohne GPU.
- Der User hat SwiftGodot explizit gewählt.

Preis dieser Entscheidung (siehe Stolpersteine): GDExtension baut ein `.dylib`, das
pro Plattform/Arch signiert und über eine `.gdextension`-Datei registriert wird — mehr
Build-Reibung als reines GDScript.

### Schichtenmodell

```
┌─────────────────────────────────────────────────────────┐
│ Godot-Projekt (game/)                                     │
│  Szene, TerrainRenderer, WaterRenderer, Kamera, UI,       │
│  Input/Brush, Zeit-Steuerung, Save/Load                   │
└───────────────▲───────────────────────────────────────────┘
                │  GDExtension (SwiftGodot-Node: `SimCore`)
                │  – exponiert Felder als PackedFloat32Array
                │  – Methoden: step(years), sculpt(...), regen(seed)
┌───────────────┴───────────────────────────────────────────┐
│ Sim-Kern (Swift Package, reines Swift, KEINE Godot-Deps)   │
│  TerrainState, HydraulicErosion, FlowNetwork (PriorityFlood│
│  + D8), Tectonics, Climate, Vegetation, (Stream-Power)     │
│  ← 100 % headless mit XCTest testbar                       │
└───────────────────────────────────────────────────────────┘
```

Der Sim-Kern kennt **kein** Godot. Der SwiftGodot-Node ist nur eine dünne Brücke:
er hält einen `TerrainState`, ruft die Kern-Funktionen und reicht die Grids als
`PackedFloat32Array` an Godot (Mesh-Update im GDScript/Godot-Renderer).

---

## 2. Repo-Struktur

```
river-sim/
├── PLAN.md                      ← diese Datei (Architektur & Begründung)
├── ROADMAP.md                   ← Stand, offene Punkte, Verifikation
├── docs/                        ← Recherche (Primärquellen) + Verhaltens-Abgleich
├── SimCore/                     ← reines Swift Package (Sim-Logik + Tests)
│   ├── Package.swift
│   ├── Sources/SimCore/
│   │   ├── Terrain.swift        (Zustand, generate(), step(), Flow, Erosion, Braiding)
│   │   ├── Hydraulic.swift      (Droplet-Erosion, Stream-Map, Pool-Kopplung)
│   │   ├── Meander.swift        (Lagrange-Zentrumslinie, Migration, Cutoff/Altarm)
│   │   ├── ErosionFilter.swift  (runevision-Pre-Erosion, Phacelle Noise)
│   │   ├── Noise.swift          (Simplex/ridged, deterministisch)
│   │   ├── MinHeap.swift        (für Priority-Flood)
│   │   └── Config.swift         (alle Stellschrauben, je mit Begründung)
│   └── Tests/SimCoreTests/      (Invarianten, Golden-Tests, Langzeit-Wächter)
├── Extension/                   ← SwiftGodot-Brücke → SimCore
│   ├── Package.swift            (dep: SimCore + SwiftGodot)
│   └── Sources/RiverSimGD/SimNode.swift  (class SimNode: Node, Felder + Palette)
├── scripts/build.sh             ← baut + signiert die .dylib
└── game/                        ← Godot-4.6-Projekt
    ├── project.godot  Main.tscn
    ├── bin/RiverSim.gdextension (verweist auf die .dylib)
    ├── scripts/Main.gd  shaders/terrain.gdshader  shaders/water.gdshader
    └── tests/smoke.gd
```

Anders als hier ursprünglich geplant liegt der Sim-Kern **nicht** in vielen kleinen
Dateien: Klima, Vegetation, Tektonik und Küste sind Passes *innerhalb* von
`Terrain.swift`, weil sie alle auf denselben Grids arbeiten und die Reihenfolge pro
Zeitschritt zusammen gelesen werden muss.

Zwei Swift-Packages bewusst getrennt: `SimCore` baut/testet ohne SwiftGodot-Toolchain
(schnelle Iteration, `swift test`); `Extension` linkt beides und erzeugt die `.dylib`.

---

## 3. Was gegenüber dem Prototyp „mehr" wird (Realismus & Features)

Der Prototyp ist bewusst grob (128²→256² Grid, Droplet-Erosion, grobes Klima). Der
Ordnername **river-sim** setzt den Fokus: Hydrologie ist der Star.

### 3a. Erosionsmodell — vom Droplet zum wissenschaftlichen Standard
- **Stream-Power-Inzision (SPACE / FastScape, Braun & Willett 2013)**: implizites,
  O(n)-stabiles Landschaftsentwicklungsmodell `dz/dt = U − K·Aᵐ·Sⁿ + D∇²z`. Stabil
  auch bei großen Zeitschritten (10 000 Jahre in einem Schritt statt 100 000 Tropfen).
  Physikalisch fundierter als die stochastische Droplet-Methode und **rauschärmer**
  (der Prototyp kämpft mit Tick-Flackern → EMA-Glättung; Stream-Power ist deterministisch).
- SPACE trennt sauber **Bedrock-Inzision vs. Sediment-Transport** — der Prototyp
  gestikuliert das schon mit `rock`/`sed`; hier wird es das fundierte Modell.

**So ist es tatsächlich gekommen** (Umsetzung wich begründet ab): Es gibt kein
SPACE-Modul. Die Makro-Täler kommen aus flächen-basierter Stream-Power auf dem
Priority-Flood-Netz (`outletIncision`) plus transport-limitiertem Sedimenttransport, und
die **Droplet-Methode ist nicht der „verspielte Modus", sondern der Haupt-Sculptor für
die feine dendritische Textur** — sie liefert den nickmcd-Ziel-Look, den ein reines
Grid-Modell glättet. Dazu kam als dritter Prozess die lineare Hangdiffusion (rundet die
Grate; ohne sie wird das Terrain über die Zeit spitzer statt runder).

### 3b. Hydrologie (Kern-Thema)
- Abfluss aus **echtem Klima** (Niederschlag − Verdunstung), nicht nur Zellzahl.
- Seen/Stauseen mit Volumen und Überlauf (Priority-Flood liefert das schon).
- **Mäander, Auen, Deltas** über Sediment-Transport; Flussordnung (Strahler) für Rendering.
- Optional: **Shallow-Water-Modus** für Hochwasser-Ereignisse (der Prototyp hat das
  bewusst verworfen — hier als abschaltbares Feature für Flut-Szenarien).

### 3c. Klima & Kryosphäre
- Orographischer Niederschlag (Prototyp hat 1D-Sweep; hier 2D mit Windrichtung).
- Temperatur nach Höhe/Breitengrad → **Schnee-Akkumulation, Gletscher, glaziale
  Erosion** (U-Täler statt V-Täler) — großer visueller + realistischer Gewinn.
- Jahreszeiten (Schneedecke, Abfluss-Schwankung).

### 3d. Biome & Vegetation
- Whittaker-Biome aus Temperatur × Niederschlag statt nur Feuchte×Hang×Höhe.
- Sukzession, Baumgrenze, Vegetations-Rückkopplung auf Erosion (hat der Prototyp im Ansatz).

### 3e. Maßstab & Rendering
- **Gekacheltes Terrain mit LOD** (Clipmap/Quadtree) statt einem 256²-Mesh → größere
  Welten, mehr Detail nah an der Kamera.
- **GPU-Compute** (Godot `RenderingDevice`, GLSL-Compute) für die Grid-PDEs als
  Ausbaustufe — 10–100× schneller, erlaubt 1024²+ in Echtzeit.
- PBR-Terrain-Shader (Triplanar, Splat-Maps aus Biom/Sediment/Hang), bessere Wasser-Shader.

### 3f. Gameplay & UX
- Entschieden: **reiner Sandbox-Gott-Modus**, keine Szenarien/Ziele (s. §6).
- Zeit-Steuerung wie im Prototyp (Sprünge + Zeitraffer) ✅.
- Offen: **Save/Load**, erweiterte Sculpt-Werkzeuge (Dämme, Vulkane, Falten), Snapshots.

---

## 4. Meilensteine

- **M0 — Toolchain & Skelett** ✅ (SwiftGodot-Build, signierte `.dylib`, `.gdextension`).
- **M1 — Sim-Kern in Swift, headless & deterministisch** ✅ (`SimCore` + XCTest-Wächter).
- **M2 — Rendering in Godot** ✅ (Heightfield-Mesh, Palette, Wasser-Shader, Kamera/Zoom,
  Brush, Zeit-UI). Visuelle Verifikation läuft über headless Screenshots (`RS_SHOT`).
- **M3 — Realismus-Upgrades** — läuft: Erosion/Hydrologie/Flüsse sind weit (s. `ROADMAP.md`),
  offen sind Gletscher, Klima-Jahreszeiten und gekacheltes Terrain/LOD.
- **M4 — Gameplay & UX** — Save/Load, erweiterte Werkzeuge, Szenarien. Nicht begonnen.
- **M5 — Perf & Politur** — GPU-Compute, Threading, LOD-Feinschliff, Audio. Nicht begonnen.

---

## 5. Verifikationsstrategie

| Ebene | Autonom? | Wie |
|---|---|---|
| Sim-Kern-Logik | ✅ ja | `swift test` (XCTest), headless, GPU-frei. Invarianten + Golden-Werte. |
| Godot-Integration (Node lädt, Methoden callbar) | ✅ ja | Godot `--headless` + GUT, prüft `SimNode`-API & Felder. |
| Numerik über lange Zeiträume | ✅ ja | Headless-Batch: N Jahre simulieren, Kennzahlen (Relief, Steilheit, Fluss-Overlap) loggen. |
| 3D-Rendering (Look) | ✅ ja | Headless-Screenshots: `RS_STEP`/`RS_SHOT`/`RS_DIST` + Godot `--path game` (s. `ROADMAP.md`). |
| **Spielgefühl / Bewegung** | ❌ **nein** | Braucht ein Auge: Springen und Fluss-Dynamik sind nur in Bewegung sichtbar, nicht im Standbild. |

Der Sim-Kern (das eigentlich Schwierige und Fehleranfällige) ist damit **vollständig
autonom** absicherbar — analog zu `window.__dbg` + Playwright-Messungen im Prototyp,
nur ohne Browser. Nur das *Aussehen* braucht ein Auge.

---

## 6. Getroffene Entscheidungen (2026-07-21, weiter gültig)

- **Umfang/Start:** *Aggressiv* — M1 direkt mit Stream-Power-Kern statt Droplet-Port.
  Der Kern braucht weder Godot noch GPU → voll autonom via `swift test`.
- **Plattform:** *nur macOS arm64*. (SwiftGodot baut die `.dylib` pro Plattform/Arch —
  jede weitere Zielplattform wäre ein eigener Build/Sign-Pfad.)
- **Design:** *Sandbox-Gott-Modus, prozedural-only* — keine Assets, keine Ziele/Fail-States.
- **Godot:** installiert der User selbst (aktuell die Steam-Version, Pfad s. `ROADMAP.md`).
- **Visuelle Verifikation:** gelöst über headless Screenshots (`RS_STEP`/`RS_SHOT`) —
  Godot rendert aus der Shell mit echtem GPU-Zugriff. Nur *Bewegung* braucht ein Auge.

### Konsequenz für die Invarianten (WICHTIG)
Mit **detachment-limited Stream-Power** wird eingeschnittenes Material implizit ins Meer
ausgetragen (Sedimentfracht). Die strikte **Masse-Erhaltung** des Droplet-Prototyps gilt
damit **nicht mehr** — sie wird ersetzt durch die physikalisch korrekte
**Fluss-Bilanz / Fließgleichgewicht**: bei Gleichgewicht ≈ Hebung = Erosion, Relief
bleibt beschränkt (kein Weglaufen, keine Einebnung). Golden-Tests prüfen genau das
(`SimCoreTests/LongRunCollapse.swift`). Transport-limitierte Ablagerung ist umgesetzt
(`transportLimited` + Pool-Delta-Deposition), aber nicht als SPACE-Modul.
