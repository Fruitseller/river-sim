# river-sim — Bauplan (Godot 4.6 + SwiftGodot)

Vom Wegwerf-Prototyp (`../prototype-terrain-sim/index.html`, Three.js/JS) zum echten
Spiel. Der Prototyp hat die Kern-Design-Frage beantwortet: **Terrain formen → Zeit
vergeht → Erosion/Flüsse/Tektonik altern die Welt** trägt als Loop. Dieser Plan
überführt das nach Godot, mit Swift als Sprache für den Simulationskern.

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
├── PLAN.md                      ← diese Datei
├── SimCore/                     ← reines Swift Package (Sim-Logik + Tests)
│   ├── Package.swift
│   ├── Sources/SimCore/
│   │   ├── TerrainState.swift   (h, rock, sed, uplift, rain, veg, flow …)
│   │   ├── Noise.swift          (Simplex, mulberry32 — deterministisch)
│   │   ├── Generate.swift       (Terrain-Gen, Insel-Falloff, Tektonik-Feld)
│   │   ├── HydraulicErosion.swift (Droplet; später StreamPower)
│   │   ├── FlowNetwork.swift    (PriorityFlood, D8, Hysterese, Schmitt)
│   │   ├── Tectonics.swift      (Uplift, Isostasie, Kopplung)
│   │   ├── Climate.swift        (orographischer Regen, Temp, Schnee)
│   │   ├── Vegetation.swift
│   │   └── Coast.swift          (Wellenerosion)
│   └── Tests/SimCoreTests/      (Invarianten, Golden-Tests, Determinismus)
├── Extension/                   ← SwiftGodot-Brücke → SimCore
│   ├── Package.swift            (dep: SimCore + SwiftGodot)
│   └── Sources/RiverSimGD/SimCore+Node.swift  (class SimNode: Node)
└── game/                        ← Godot-4.6-Projekt
    ├── project.godot
    ├── bin/RiverSim.gdextension (verweist auf die .dylib)
    ├── scenes/  materials/  shaders/  ui/
    └── addons/gut/              (Test-Framework, headless CI)
```

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
- Droplet-Methode bleibt optional als „schneller/verspielter" Modus.

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

### 3f. Gameplay & UX (hängt an offener Design-Entscheidung — s. Stolpersteine)
- **Save/Load** (Prototyp hat keins).
- Sculpt-Werkzeuge erweitern (Flüsse setzen, Dämme, Vulkane, Falten).
- Szenarien/Ziele ODER reiner Sandbox-Gott-Modus — **noch nicht entschieden**.
- Zeit-Steuerung wie Prototyp (Sprünge + Zeitraffer), plus Zeitrück-/Snapshots.

---

## 4. Meilensteine (jeweils eigenständig verifizierbar)

**M0 — Toolchain & Skelett** *(Stolperstein-lastig, s.u.)*
Godot 4.6 installieren, SwiftGodot-Package bauen, `.dylib` signieren, `.gdextension`
registrieren, ein `SimNode` druckt aus Swift in Godots Konsole. GUT + CI-Headless-Job steht.

**M1 — Sim-Kern in Swift, headless & deterministisch** *(voll autonom testbar)*
Prototyp-Felder + Algorithmen nach `SimCore` portieren (Noise, Generate, PriorityFlood,
D8+Hysterese+Schmitt, Droplet, Tectonics, Climate, Vegetation, Coast). XCTest-Golden-Tests
für die **Invarianten aus der Prototyp-Erfahrung**: Masse-Erhaltung, Relief-Gleichgewicht
über 5×10k Jahre, Fluss-Stabilität (71 % Zellen gleich/100 J), Determinismus je Seed.

**M2 — Rendering in Godot** *(visuell — braucht Display/GPU-Verifikation)*
Heightfield-Mesh aus `PackedFloat32Array`, Vertex-Farben/Splat, Wasserfläche,
Fluss-Ribbons + animierter Wasser-Shader (GLSL aus Prototyp portieren), Kamera-Controls,
Brush-Ring, Zeit-UI. Ziel: der Prototyp, aber in Godot — 1:1 Gefühl.

**M3 — Realismus-Upgrades** — Stream-Power/SPACE, 2D-Orographie, Schnee/Gletscher,
Whittaker-Biome, gekacheltes Terrain. *(Reihenfolge = Priorisierung durch User.)*

**M4 — Gameplay & UX** — Save/Load, erweiterte Werkzeuge, Szenarien *(nach Design-Entscheid)*.

**M5 — Perf & Politur** — GPU-Compute, Threading, LOD-Feinschliff, Audio.

---

## 5. Verifikationsstrategie

| Ebene | Autonom? | Wie |
|---|---|---|
| Sim-Kern-Logik | ✅ ja | `swift test` (XCTest), headless, GPU-frei. Invarianten + Golden-Werte. |
| Godot-Integration (Node lädt, Methoden callbar) | ✅ ja | Godot `--headless` + GUT, prüft `SimNode`-API & Felder. |
| Numerik über lange Zeiträume | ✅ ja | Headless-Batch: N Jahre simulieren, Kennzahlen (Relief, Steilheit, Fluss-Overlap) loggen. |
| **3D-Rendering / Spielgefühl** | ❌ **nein** | Braucht Display+GPU-Session. Siehe Stolperstein #2. |

Der Sim-Kern (das eigentlich Schwierige und Fehleranfällige) ist damit **vollständig
autonom** absicherbar — analog zu `window.__dbg` + Playwright-Messungen im Prototyp,
nur ohne Browser. Nur das *Aussehen* braucht ein Auge.

---

## 6. STOLPERSTEINE — was ich NICHT allein lösen kann

> Alles andere baue ich autark. Diese Punkte brauchen dich:

**#1 — Godot installieren & erster signierter GDExtension-Build.**
`brew install godot` kann ich versuchen, aber: (a) die selbstgebaute `.dylib` muss auf
macOS 26 signiert/notarisiert bzw. per Gatekeeper freigegeben werden — der erste Start
kann eine manuelle „Trotzdem öffnen"-Bestätigung in den Systemeinstellungen verlangen;
(b) der Godot-**Editor ist eine GUI-App**, den ersten Projekt-Import macht man dort.
→ *Ich brauche:* dein Go, Godot per brew zu installieren, und ggf. einen manuellen
Gatekeeper-Klick beim ersten `.dylib`-Load. Alternativ nennst du einen bereits
installierten Godot-Pfad.

**#2 — Visuelle Verifikation (der große Autonomie-Blocker).**
Godot rendert 3D **nicht** in einer headless/GPU-losen Shell — off-screen Rendering auf
CI ohne GPU ist bis heute ungelöst. Im Web-Prototyp haben Playwright-Screenshots diese
Rolle gespielt; ein Godot-Äquivalent gibt es so nicht. Optionen:
  - (a) **Du schaust drüber** bei visuellen Meilensteinen (M2, M3-Rendering).
  - (b) Ich versuche `codex` (gpt-5.5, Computer-Use aus deinen globalen Regeln) die
    laufende App visuell prüfen zu lassen — setzt aber voraus, dass die App auf *diesem*
    Mac überhaupt ein GPU-Fenster bekommt (WindowServer-Zugang meiner Shell ist unklar).
→ *Ich brauche:* eine Entscheidung, ob (a) oder (b) — und bei (b) einmalig die Klärung,
ob ich aus meiner Session eine GUI-Godot-Instanz mit echtem Rendering starten kann.

**#3 — Was IST das Spiel? (Design-Verdikt offen).**
Der Prototyp-Verdikt in `NOTES.md` steht noch auf „ausstehend". Sandbox-Gott-Modus vs.
zielgetriebenes Spiel (Aufgaben, Fortschritt, Fail-States) ändert Architektur (Save-Format,
UI, Systeme) grundlegend. → *Ich brauche:* die Richtung. Notfalls baue ich M0–M2 als
reinen Sandbox (deckt beide Wege ab) und du entscheidest vor M4.

**#4 — Umfang/Priorisierung (das ist mehrere Wochen Arbeit, nicht ein Rutsch).**
M3 allein (Stream-Power-Rewrite, GPU-Compute, gekacheltes Terrain, Gletscher) ist je ein
großes Teilprojekt. Ich baue nicht sinnvoll „alles auf einmal". → *Ich brauche:* was
zuerst? Mein Vorschlag: **M0 → M1 → M2 (Prototyp-Parität in Godot) und dann neu bewerten.**

**#5 — Ziel-Plattform(en).**
Nur macOS-Desktop, oder auch Windows/Linux/iOS? SwiftGodot baut die `.dylib` **pro
Plattform/Arch** — jede Zielplattform = eigener Build/Sign-Pfad, teils fremde Toolchains.
→ *Ich brauche:* die Zielliste (Default-Annahme sonst: nur macOS arm64 im Dev).

**#6 — Assets & Art-Direction.**
Rein prozedural (wie Prototyp) oder mit Kunst-Assets (Texturen, Modelle, Sound)? Bei
Assets: Quelle/Lizenz. → *Ich brauche:* prozedural-only bestätigen, oder Asset-Quelle nennen.

---

## 7. Getroffene Entscheidungen (2026-07-21)

- **Umfang/Start:** *Aggressiv* — M1 direkt mit **Stream-Power/FastScape**-Kern statt
  Droplet-Port. Der Kern braucht weder Godot noch GPU → voll autonom via `swift test`.
- **Godot-Install (#1):** *User installiert Godot selbst* und nennt den Pfad. Ich baue
  bis dahin nur `SimCore` (kein Godot nötig). GDExtension-Brücke erst danach.
- **Plattform (#5):** *nur macOS arm64*.
- **Design (#3/#6):** *Sandbox-Gott-Modus, prozedural-only* — keine Assets, keine Ziele.
- **Visuelle Verifikation (#2):** offen bis M2; Sim-Kern (M1) ist ohnehin GPU-frei prüfbar.

### Konsequenz für die Invarianten (WICHTIG)
Mit **detachment-limited Stream-Power** wird eingeschnittenes Material implizit ins Meer
ausgetragen (Sedimentfracht). Die strikte **Masse-Erhaltung** des Droplet-Prototyps gilt
damit **nicht mehr** — sie wird ersetzt durch die physikalisch korrekte
**Fluss-Bilanz / Fließgleichgewicht**: bei Gleichgewicht ≈ Hebung = Erosion, Relief
bleibt beschränkt (kein Weglaufen, keine Einebnung). Golden-Tests prüfen genau das.
Transport-limitierte Ablagerung (Deltas) kommt mit SPACE in M3.

## 8. Nächster Schritt (läuft)

M1: `SimCore` Swift-Package mit FastScape-Stream-Power + Priority-Flood-Entwässerung +
Tektonik/Isostasie + Hangdiffusion (Talus), verifiziert mit XCTest (Determinismus,
beschränktes Relief, Fließgleichgewicht, Entwässerungs-Invariante).
