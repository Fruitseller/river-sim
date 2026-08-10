# Web-Technologien statt Swift + Godot? — Stack-Evaluation (Stand August 2026)

Bewertung der Frage, ob ein Refactor der River-Sim auf Web-Technologien
(Babylon.js + WebAssembly o. ä.) dem heutigen Stack (Swift-`SimCore` +
SwiftGodot-GDExtension + Godot 4.7) überlegen wäre.

**Randbedingungen der Fragestellung** (vom Nutzer gesetzt):

- **Umbaukosten sind ausgeklammert** (als ~0 anzusetzen). Migrationsaufwand ist
  hier kein Argument — weder pro noch contra.
- Bewertet wird **nicht der Ist-Zustand**, sondern die Eignung für die nächsten
  Jahre: größere Grids, mehr Physik-Pässe, ggf. GPU-Compute, deutlich mehr
  UI/Features. Das Projekt ist Pre-Alpha.

Quellen sind Primärquellen (Specs, offizielle Doku, Repos, First-Party-Blogs);
jede Behauptung trägt ihren Link. Projekt-Bezüge sind gegen den Code geprüft.

---

## TL;DR — Empfehlung

**Beim nativen Stack bleiben. Der Sim-Kern gehört nicht in den Browser — aber er
sollte Wasm-fähig gehalten werden.**

Drei Befunde tragen die Empfehlung, alle drei hängen an Projekt-Invarianten, die
in `AGENTS.md` schriftlich festgehalten sind:

1. **Der größte versprochene Web-Gewinn ist mit der Kern-Invariante unvereinbar.**
   „Teile der Sim auf die GPU heben" scheitert nicht an der Reife von WebGPU,
   sondern an dessen **Spezifikation**: WGSL erlaubt Implementierungen explizit
   Reassoziation, Fusion, unspezifizierten Rundungsmodus und Flush-to-Zero
   (§5.3). „Determinismus ist eine getestete Invariante … bit-identisch" wäre
   damit per Spec nicht mehr haltbar. Dasselbe gilt aber auch für Godots eigene
   Compute-Shader — dieser Punkt ist **kein Argument gegen Web**, sondern gegen
   *GPU-Sim* auf beiden Stacks.

2. **Der Browser nimmt die Datenparallelität weg, die das Projekt gerade
   gewonnen hat.** Die Sim parallelisiert an drei Stellen über
   `DispatchQueue.concurrentPerform` (`Terrain.swift:277`,
   `ErosionFilter.swift:204`, `SimNode.swift:14`). **libdispatch existiert auf
   Swift-Wasm nicht**, und der Thread-fähige Swift-Wasm-Zieltriple wird von
   swift.org **nicht ausgeliefert** (§2.3). Dazu kommt ein Single-Thread-Malus
   von ~1,45–1,55× gegenüber nativem Code (§3.4). Für ein Projekt, dessen
   CPU-Budget wachsen soll, ist das die falsche Richtung — der Browser nähme
   ausgerechnet den Hebel weg, über den die Sim zuletzt Luft gewonnen hat.

3. **Der heutige Stack hat gar keinen Web-Pfad** — SwiftGodot lässt sich nicht
   ins Web exportieren (ABI-Bruch WASI ↔ Emscripten, §6.3). „Web als
   Zusatz-Target" ist also **keine** additive Option, sondern eine
   Entweder-oder-Entscheidung. Das ist ein realer Nachteil des Ist-Stacks —
   er wiegt nur dann schwer, wenn Web-Distribution ein Projektziel ist. Ist es
   das nicht, kostet er nichts.

**Was klar für Web spricht** und ehrlich benannt gehört: Distribution (Link statt
Installation, sofortige Updates), der Entwickler-Loop (Vite-HMR <50 ms gegen
3,5–27 min Extension-Build), und — kontraintuitiv — **stärkerer Determinismus als
nativ**, weil Wasm `sin`/`exp`/`pow` aus der einkompilierten wasi-libc bezieht
statt aus der plattformabhängigen System-libm (§5.2). Das ist der beste
technische Grund, `SimCore` Wasm-fähig zu **halten**, ohne heute zu portieren.

**Konkrete Empfehlung: Hybrid-Option B in §10** — nativer Produktions-Stack,
`SimCore` als Wasm-Ziel gepflegt (Portabilitäts-Hygiene + CI-Build), Web-Renderer
später als optionale Demo/Showcase-Schiene. Details und Alternativen in §10.

**Wo die Empfehlung kippen würde:** wenn das Projektziel von „tiefere Simulation"
auf „viele Spieler erreichen" wechselt, oder wenn Swifts
`wasm32-unknown-emscripten`-Target plus wasip1-threads offiziell werden (§11).

---

## 1. Was der heutige Stack tatsächlich ist (gegen den Code geprüft)

Damit die Bewertung nicht an einer Karikatur hängt, die für die Frage relevanten
Fakten aus dem Repo:

| Fakt | Beleg |
|---|---|
| Sim-Kern ~5.900 LoC reines Swift, keine Godot-Abhängigkeit | `SimCore/Sources/SimCore/*.swift` |
| Parallelisierung ausschließlich über `DispatchQueue.concurrentPerform` | `Terrain.swift:277`, `ErosionFilter.swift:204`, `SimNode.swift:14` |
| Transzendente im Kern: 14× `exp`, 12× `pow`, 4× `sin`, 4× `cos`, 4× `log`, 2× `atan2` | `grep` über `SimCore/Sources/SimCore` |
| Determinismus-Tests: 9 Stück, alle **intra-Maschine** (gleicher Seed → bit-gleiches Ergebnis, bzw. parallel == sequenziell) | `SimCoreTests.swift:58`, `RiverDynamicsTests.swift:31`, u. a. |
| Save/Load-Abnahme-Invariante: geladen weiterlaufen == durchgehend simuliert, bit-identisch | `WorldSnapshotTests`, `docs/world-save-format.md` |
| Grid n = 832, ~25 Felder à n² Float ≈ **69 MB** Zustand | `ROADMAP.md`, `WorldSnapshot.swift` |
| Rendering: Godot Forward+/Vulkan, 2 Shader, Datenfluss CPU-Felder → Texturen pro Frame | `Main.gd`, `game/shaders/` |

Zwei Punkte daraus sind für die Bewertung entscheidend:

- **Die Bit-Invariante ist heute eine *Reproduzierbarkeits*-Invariante auf
  derselben Maschine**, keine plattformübergreifende Golden-Value-Invariante.
  Das relativiert §5.2 (nativer Determinismus ist über macOS/Linux ohnehin nicht
  garantiert — es wird nur nicht getestet, und es fällt nicht auf).
- **Die Parallelität ist Dispatch-gebunden.** Sie steht und fällt mit einer
  Bibliothek, die auf Wasm nicht existiert.

---

## 2. Swift → WebAssembly: Wie reif ist das 2026?

### 2.1 Offizieller Support: ja, seit Swift 6.2 — aber ohne Tier

Seit Swift 6.2 verteilt swift.org Wasm-SDKs; die dokumentierte Installation
nennt aktuell Swift 6.3.3
([swift.org/documentation/articles/wasm-getting-started](https://www.swift.org/documentation/articles/wasm-getting-started.html)).
Das Release-Announcement zu 6.2 sagt: „Swift 6.2 gains support for WebAssembly …
You can build both client and server applications for Wasm and deploy to the
browser or other runtimes"
([swift.org/blog/swift-6.2-released](https://www.swift.org/blog/swift-6.2-released/)).
Die Platform Steering Group hat „A Vision for WebAssembly Support in Swift"
**angenommen**
([swift-evolution/visions/webassembly.md](https://github.com/swiftlang/swift-evolution/blob/main/visions/webassembly.md)).

**Aber:** Auf der offiziellen Platform-Support-Seite taucht WebAssembly
**nirgends** auf — weder unter „Deployment and Development" noch unter
„Deployment-only"
([swift.org/platform-support](https://www.swift.org/platform-support/)). Und die
Compiler-Doku sagt weiterhin: „WebAssembly is still at an early stage, so many
features you'd expect from other platforms are not available yet"
([swiftlang/swift/docs/WebAssembly.md](https://github.com/swiftlang/swift/blob/main/docs/WebAssembly.md)).
Das Swift-6.3-Release-Blog (24.03.2026) erwähnt Wasm gar nicht
([swift.org/blog/swift-6.3-released](https://www.swift.org/blog/swift-6.3-released/)).

**Einordnung:** ausgeliefert und CI-getestet, aber ohne formale Tier-Zusage.
„Unterstützt, aber jung."

### 2.2 WASI-Stand und Browser-Ziel

Unterstützte Triples sind `wasm32-unknown-wasip1` (primär),
`wasm32-unknown-wasip1-threads` sowie `wasm32/wasm64-unknown-none-wasm` für
Embedded Swift
([WebAssembly.md](https://github.com/swiftlang/swift/blob/main/docs/WebAssembly.md)).
**WASI-Level ist Preview 1**; Component Model steht im Visions-Dokument als
*Ziel*, nicht als Feature
([vision](https://github.com/swiftlang/swift-evolution/blob/main/visions/webassembly.md)).

`wasm32-unknown-unknown` ist **kein** Swift-Target. Browser-Betrieb läuft über
einen JS-WASI-Shim (JavaScriptKit-Ökosystem); das Visions-Dokument schiebt
Browser-Spezifika ausdrücklich in ein späteres Dokument.

Neu 2026: ein **Emscripten-Target** (`wasm32-unknown-emscripten`) wurde am
12.03.2026 gepitcht, experimentell hinter `--build-emscripten-stdlib`
([forums.swift.org/t/pitch-emscripten-target-support-for-swift/85310](https://forums.swift.org/t/pitch-emscripten-target-support-for-swift/85310)).
Die Build-Anleitung steht inzwischen in der offiziellen Compiler-Doku. Das ist
strategisch wichtig — siehe §6.3.

### 2.3 Threads: der harte Befund

Das ist der Punkt, an dem sich die Frage für dieses Projekt entscheidet.

- Multi-Threading gibt es **nur** für `wasm32-unknown-wasip1-threads`, nicht für
  das reguläre `wasip1`
  ([WebAssembly.md](https://github.com/swiftlang/swift/blob/main/docs/WebAssembly.md)).
- **Das Threads-SDK wird von swift.org nicht ausgeliefert.** Max Desiatov,
  29.03.2026: „Swift CI doesn't run the full test suite for this target triple …
  which means in the current state it's untested and not supported officially."
  ([forums.swift.org/t/what-happened-to-wasm32-unknown-wasip1-threads/85656](https://forums.swift.org/t/what-happened-to-wasm32-unknown-wasip1-threads/85656)).
  Es kommt aus dem Community-Repo
  ([github.com/swiftwasm/swift/releases](https://github.com/swiftwasm/swift/releases)).
- **`libdispatch` ist nicht verfügbar:** „The Dispatch core library is
  unavailable due to the lack of standardized multi-threading support in
  WebAssembly and SwiftWasm itself."
  ([book.swiftwasm.org/getting-started/porting.html](https://book.swiftwasm.org/getting-started/porting.html)).
  Ebenfalls weg: `FoundationNetworking`, `Process`, `RunLoop`, `Timer`.
- Swift Concurrency parallelisiert auf Wasm **nicht** von selbst: „Swift
  Concurrency defaults to a cooperative single-threaded executor due to the lack
  of wasi-threads support in libdispatch"
  ([vision](https://github.com/swiftlang/swift-evolution/blob/main/visions/webassembly.md)).
- `wasi-threads` selbst gilt als abgelöst; die Zukunft ist
  *shared-everything-threads*, **Phase 1**. Der klassische `threads`-Vorschlag
  ist Phase 4 und damit nicht Teil eines nummerierten Wasm-Releases
  ([WebAssembly/proposals](https://github.com/WebAssembly/proposals)).

**Es ist machbar, aber abseits des Pfads:** Goodnotes betreibt echte Parallelität
im Browser mit WASI-Threads + Web Workers + `SharedArrayBuffer` und
Custom-Actor-Executors, mit >2× besserer INP
([swift.org/blog/bringing-goodnotes-to-web-with-swift](https://www.swift.org/blog/bringing-goodnotes-to-web-with-swift/)).
Derselbe Artikel bestätigt aber: „libdispatch APIs are unavailable on
WebAssembly targets" und „Modern browser security policies require Cross-Origin
Isolation to use SharedArrayBuffer."

**Konsequenz für dieses Projekt:** Alle drei `concurrentPerform`-Stellen
(`Terrain.swift:277`, `ErosionFilter.swift:204`, `SimNode.swift:14`) müssten
auf einen Worker-basierten Executor umgeschrieben werden, auf einem SDK, das
swift.org nicht supportet, mit COOP/COEP-Zwang beim Hosting (§7.3). Auf dem
offiziellen SDK bekommt man **einen Thread**.

**Pro/Contra:**
- **Pro:** Swift-Code kann grundsätzlich in den Browser — die
  Sprachwahl ist kein Hindernis, `SimCore` müsste nicht neu geschrieben werden.
- **Contra:** Die einzige Performance-Achse, auf der das Projekt zuletzt gewonnen
  hat (bit-identische Datenparallelität über disjunkte Index-Bereiche), ist im
  Browser nur über den inoffiziellen Pfad zu haben.

### 2.4 Binärgröße und SIMD

Binärgröße ist auf Wasm ein Thema: „Binary size is a high priority requirement…
This means that Embedded Swift is commonly used when building for Wasm"
([WebAssembly.md](https://github.com/swiftlang/swift/blob/main/docs/WebAssembly.md)).
Embedded-Hello-World: **9,7 kB**
([Forum-Announcement](https://forums.swift.org/t/swift-sdks-for-webassembly-now-available-on-swift-org/80405)).
Mit voller Stdlib ist es deutlich mehr — Goodnotes liefert **~50 MB Wasm,
~12 MB Brotli-komprimiert** für 2,2 Mio. LoC
([swift.org-Blog](https://www.swift.org/blog/bringing-goodnotes-to-web-with-swift/)).
Für `SimCore` (~5.900 LoC, aber `import Foundation` überall) ist eine belastbare
Zahl nicht aus Primärquellen ableitbar; die Größenordnung „einige MB" ist
plausibel, aber **unbelegt**.

**SIMD** emittiert der Swift-Compiler auf Wasm nicht per Default; mit
`-Xcc -msimd128` entstehen echte `v128`/`f32x4`-Instruktionen
([forums.swift.org/t/how-to-enable-simd-in-swift-webassembly/80326](https://forums.swift.org/t/how-to-enable-simd-in-swift-webassembly/80326)).
Wichtig: das ist **fixed-width** SIMD und damit deterministisch — nicht das
nichtdeterministische relaxed-SIMD (§5.1).

**Ein Portabilitäts-Fallstrick:** Auf wasm32 ist `Int` **32-bit**. Goodnotes
musste Code anpassen, der 64-bit-`Int` annahm
([ebd.](https://www.swift.org/blog/bringing-goodnotes-to-web-with-swift/)). Für
`idx(i,j) = j*n + i` ist das bis n ≈ 46.000 unkritisch, für Byte-Offsets in
`WorldSnapshot` aber prüfenswert.

---

## 3. WebAssembly: Leistung und Fähigkeiten

### 3.1 SIMD

Fixed-width 128-bit SIMD ist **Phase 5** und Teil von **Wasm 2.0**; relaxed SIMD
ist Phase 5 und Teil von **Wasm 3.0**
([spec/appendix/changes](https://webassembly.github.io/spec/core/appendix/changes.html),
[webassembly.org/news/2025-09-17-wasm-3.0](https://webassembly.org/news/2025-09-17-wasm-3.0/)).
Engine-Support laut den offiziellen Feature-Daten der WebAssembly-Website: SIMD
ab Chrome 91 / Firefox 89 / Safari 16.4; relaxed SIMD ab Chrome 114 / Firefox 145,
in **Safari nur hinter einem JavaScriptCore-Flag**
([features.json](https://raw.githubusercontent.com/WebAssembly/website/main/features.json),
gerendert unter [webassembly.org/features](https://webassembly.org/features/)).

### 3.2 Threads und Cross-Origin-Isolation

`SharedArrayBuffer` erfordert (a) Secure Context und (b) ein **cross-origin
isoliertes** Dokument, hergestellt über `Cross-Origin-Opener-Policy` und
`Cross-Origin-Embedder-Policy`
([MDN SharedArrayBuffer](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/SharedArrayBuffer)).
Was das fürs Hosting heißt, steht in §7.3.

### 3.3 Speicher

wasm32 kann maximal 65.536 Seiten à 64 KiB = **4 GiB** adressieren
([MDN WebAssembly.Memory](https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/JavaScript_interface/Memory/Memory)).
V8 hat die Obergrenze von 2 GB auf 4 GB angehoben, mahnt aber: „2-4GB is a lot of
memory! … there just won't be enough free memory on many users' machines"
([v8.dev/blog/4gb-wasm-memory](https://v8.dev/blog/4gb-wasm-memory)). Memory64 ist
Phase 5 / Wasm 3.0, ausgeliefert in Chrome 133 und Firefox 134 — **Safari fehlt in
den Feature-Daten**
([features.json](https://raw.githubusercontent.com/WebAssembly/website/main/features.json)).

**Für dieses Projekt gerechnet:** 25 Felder × n² × 4 B ergibt

| n | Zustand | Bewertung |
|---:|---:|---|
| 832 (heute) | 69 MB | unkritisch |
| 1664 | 277 MB | unkritisch |
| 2048 | 419 MB | ok |
| 4096 | 1,7 GB | **an der Grenze** (V8-Default 2 GB, iOS ~2 GB, s. §7.2) |

Nativ existiert diese Grenze nicht. „Deutlich größere Grids" ist also ein
Argument **gegen** den Browser — allerdings erst ab n ≈ 4096, was gegenüber heute
das 24-fache Rechenbudget wäre und damit ohnehin GPU-Terrain.

### 3.4 Performance-Lücke zu nativem Code

Die kanonische Messung ist Jangda et al., **USENIX ATC '19**, „Not So Fast:
Analyzing the Performance of WebAssembly vs. Native Code": SPEC-CPU über
Browsix-Wasm, im Mittel **45 % (Firefox) bis 55 % (Chrome) langsamer**,
Spitzenwerte 2,08× / 2,5×
([usenix.org/conference/atc19/presentation/jangda](https://www.usenix.org/conference/atc19/presentation/jangda),
[PDF](https://www.usenix.org/system/files/atc19-jangda.pdf)). Die Arbeit weist
ausdrücklich darauf hin, dass frühere „Nahe-Parität"-Behauptungen aus
~100-LoC-Kerneln stammten.

Eine neuere Arbeit gleicher Güte für Browser-Wasm gegen nativ konnte nicht
gefunden werden; die 2019er-Zahlen sind ~7 Jahre alt, und Engines haben
zugelegt. **Planungsannahme:** 1,3–2× langsamer für float-/array-lastigen Code —
**zusätzlich** zum Thread-Verlust aus §2.3, der bei 8 Kernen der weit größere
Faktor ist.

---

## 4. Rendering: Babylon.js (und three.js)

Vorbemerkung: Die Engine ist in dieser Frage **nicht der Engpass**. Beide
Kandidaten können, was der Renderer hier tut. Der Abschnitt ist deshalb kurz
gehalten und beantwortet vor allem: „geht der heutige Datenfluss dort sauber?"

### 4.1 Babylon.js — Reife

Aktuell ist **9.20.0 (06.08.2026)**, Major 9.0.0 vom 26.03.2026,
Patch-Kadenz ~wöchentlich, Lizenz **Apache-2.0**
([GitHub Releases API](https://api.github.com/repos/BabylonJS/Babylon.js/releases),
[license.md](https://raw.githubusercontent.com/BabylonJS/Babylon.js/master/license.md)).
Eine Primärquelle, die Microsoft als *Eigentümer* benennt, ließ sich im Repo
nicht finden; die Indizien (Azure-DevOps-CI, `aka.ms`-Doc-Links, Microsofts
eigener Open-Source-Blog) tragen „Microsoft-gesponsert, Community-geführt"
([readme.md](https://raw.githubusercontent.com/BabylonJS/Babylon.js/master/readme.md),
[opensource.microsoft.com/blog/2021/02/22/…](https://opensource.microsoft.com/blog/2021/02/22/microsoft-open-source-success-story-babylon/)).

### 4.2 Der Datenfluss CPU-Felder → GPU pro Frame

Babylons *natives* Heightmap-Angebot passt **nicht**:
`CreateGroundFromHeightMap` lädt ein Graustufenbild per URL einmalig beim Bau,
`updatable` ist per Default `false`
([ground_hmap.md](https://raw.githubusercontent.com/BabylonJS/Documentation/master/content/features/featuresDeepDive/mesh/creation/set/ground_hmap.md)).
Die Community-Extension *Dynamic Terrain* zielt auf große **statische** Karten
und warnt selbst vor Meshes dieser Größe: ein 1000×800-Ribbon sei „a really big
mesh … You shouldn't try to render such large meshes in your scene if you want to
maintain a decent framerate"
([dynamicTerrains.md](https://raw.githubusercontent.com/BabylonJS/Documentation/master/content/communityExtensions/dynamicTerrains.md)).

**Der passende Weg ist derselbe wie heute in Godot:** statisches Mesh, Displacement
im Vertex-Shader aus einer pro Frame neu hochgeladenen Textur. Dafür gibt es
`RawTexture` mit `update(data)`
([rawTexture.ts:89](https://raw.githubusercontent.com/BabylonJS/Babylon.js/master/packages/dev/core/src/Materials/Textures/rawTexture.ts));
die Doku beschreibt `RawTexture` als „perfect for creating procedural textures on
the fly" und verlinkt als Beispiel exakt Noise-Daten → `Uint8Array` → Raw-Textur →
Heightmap-Displacement
([rawTexture.md](https://raw.githubusercontent.com/BabylonJS/Documentation/master/content/features/featuresDeepDive/materials/advanced/rawTexture.md)).
`DynamicTexture` ist hier das falsche Werkzeug (Canvas-basiert, für 2D/Text).

**Offizielle Kostenangaben zu Per-Frame-Uploads gibt es nicht** —
`webGPUOptimization.md` ist ein Ein-Satz-Stub
([Quelle](https://raw.githubusercontent.com/BabylonJS/Documentation/master/content/setup/support/webGPU/webGPUOptimization.md)).
Zur Größenordnung: Höhe (f32) 2,6 MiB + Wasser (r8) 0,66 MiB + Farbe (rgba8)
2,6 MiB ≈ **6 MiB/Frame ≈ 360 MiB/s bei 60 fps**. Das ist für moderne GPUs
unkritisch, wäre aber selbst zu messen.

### 4.3 Shader und Compute

Ein GLSL-Quelltext läuft auf beiden Backends — Babylon transpiliert nach WGSL,
lädt dafür aber eine WASM-Bibliothek nach: „If you decide to write a shader with
GLSL, Babylon.js will detect it and use internal tools to compile it to WGSL.
This takes some time and downloads a WASM library… It is recommended to write
your shaders directly in WGSL for faster startup time"
([webGPUWGSL.md](https://raw.githubusercontent.com/BabylonJS/Documentation/master/content/setup/support/webGPU/webGPUWGSL.md)).
Zu beachten: `ShaderMaterial`-WGSL ist **Babylon-Dialekt**, nicht reines WGSL
(eigene `varying`/`attribute`/`uniform`-Deklarationen, `vertexInputs.XXX`).

`ComputeShader` ist **WebGPU-only** seit v5.0; abfragbar über
`engine.getCaps().supportComputeShaders`. Bindings müssen von Hand als
`bindingsMapping` gepflegt werden, „Browsers do not currently support reflection
for WGSL shaders". `StorageBuffer.read` braucht per Default eine laufende
Render-Loop
([computeShader.md](https://raw.githubusercontent.com/BabylonJS/Documentation/master/content/features/featuresDeepDive/materials/shaders/computeShader.md)).
**Bemerkenswert:** dieselbe Doku liefert ein **Hydraulic-Erosion-Sample** —
„The generation of the terrain and the simulation of the erosion is done by using
two different compute shaders" (Playground `#C90R62#16`) — also fast genau die
hier gestellte Aufgabe, allerdings mit den Determinismus-Folgen aus §5.3.

### 4.4 three.js zur Einordnung

Aktuell r185 (01.07.2026), Kadenz ~2 Monate
([constants.js](https://raw.githubusercontent.com/mrdoob/three.js/dev/src/constants.js)).
`WebGPURenderer` ist weiterhin **als experimentell gekennzeichnet** und nicht der
Default; entscheidend ist die dokumentierte Einschränkung: „Custom materials
based on `ShaderMaterial`, `RawShaderMaterial` and modifications of built-in
materials via `onBeforeCompile()` are **not supported** in `WebGPURenderer`"
([manual/webgpurenderer](https://raw.githubusercontent.com/mrdoob/three.js/dev/manual/pages/webgpurenderer.html)).
Unter three+WebGPU müsste also alles nach TSL. three.js hat dafür die feineren
Upload-Primitiven (`BufferAttribute.addUpdateRange`), Texturen aber ebenfalls nur
ganz oder gar nicht.

**Fazit §4:** Babylon.js wäre die richtige Wahl, falls Web — reifer, konservativer,
GLSL überlebt den Umzug, komplettes Drumherum (Inspector V2, GUI, Loader,
Havok-Physik). Es ist kein Grund, umzuziehen; es ist nur kein Hindernis.

---

## 5. Determinismus — der entscheidende Abschnitt

### 5.1 WebAssembly ist spezifiziert deterministisch

Das offizielle Design-Dokument listet Nichtdeterminismus **abschließend** auf
([WebAssembly/design/Nondeterminism.md](https://github.com/WebAssembly/design/blob/main/Nondeterminism.md)):

1. Feature-Support (unterschiedliche Implementierungen),
2. die Außenwelt (Aufrufreihenfolge, Argumente),
3. **shared memory** — Ergebnisse von Load/Store/RMW bei Threads,
4. **relaxed SIMD**,
5. **NaN-Payload-Bits**,
6. Resource Exhaustion.

**Gewöhnliche f32/f64-Arithmetik steht nicht auf der Liste.** Die Spec:
„Floating-point arithmetic follows the IEEE 754 standard … All operators use
round-to-nearest ties-to-even"
([spec/exec/numerics](https://webassembly.github.io/spec/core/exec/numerics.html)).
Es gibt **kein** FMA im Kern-Wasm (nur in relaxed SIMD, dort explizit als
nichtdeterministisch markiert) und keine x87-Überpräzision. Fast-Math wurde
bewusst abgelehnt: „Nondeterminism at this level could cause distributed
WebAssembly programs to behave differently in different implementations"
([design/FAQ.md](https://github.com/WebAssembly/design/blob/main/FAQ.md)).

Wasm 3.0 führt zusätzlich ein formales **deterministisches Profil** ein
(kanonische NaNs, fixiertes Verhalten relaxter Vektor-Instruktionen)
([spec/appendix/profiles](https://webassembly.github.io/spec/core/appendix/profiles.html)) —
das aber derzeit von keinem Browser als unterstützt gemeldet wird.

Die konkreten Nichtdeterminismen von relaxed SIMD (u. a. **FMA: eine oder zwei
Rundungen**, Lane-Select bei gemischten Maskenbits, min/max bei NaN/±0) stehen im
Proposal
([relaxed-simd/Overview.md](https://github.com/WebAssembly/relaxed-simd/blob/main/proposals/relaxed-simd/Overview.md)).
Sie sind **opt-in beim Kompilieren** — wer sie nicht anfordert, bekommt sie nicht.

### 5.2 Nativer Swift ist plattformübergreifend *nicht* bit-deterministisch

Der interessante Befund: der heutige Stack ist hier **schwächer**, nicht stärker.

- Wasm hat keine `sin`/`cos`/`exp`/`pow`-Instruktionen. Diese Funktionen kommen
  aus der **einkompilierten** libm — bei WASI aus wasi-libc, deren obere Hälfte
  musl-basiert ist
  ([WebAssembly/wasi-libc](https://github.com/WebAssembly/wasi-libc)). Also
  **überall derselbe Code**.
- Nativ dagegen: glibc „does not aim for correctly rounded results for functions
  in the math library, with the exception of certain functions such as `sqrt`,
  `fma` and `rint`", und veröffentlicht eine **architekturabhängige ULP-Tabelle**
  („Different architectures have different results since their hardware support
  for floating-point operations varies")
  ([GNU libc manual](https://www.gnu.org/software/libc/manual/html_node/Errors-in-Math-Functions.html)).
  Korrekte Rundung ist von C nicht gefordert
  ([core-math.gitlabpages.inria.fr/faq](https://core-math.gitlabpages.inria.fr/faq.html));
  glibc importiert inzwischen CORE-MATH-Kernel, wodurch sich Ergebnisse **über
  glibc-Versionen hinweg ändern**.
- Swift-`Real`/`ElementaryFunctions` delegieren über `_NumericsShims` an die
  Host-libm und erben damit exakt diese Unterschiede
  ([swift-numerics RealModule README](https://github.com/apple/swift-numerics/blob/main/Sources/RealModule/README.md)).
- Immerhin ist Swift strenger als C: Reassoziation/FMA-Bildung ist **opt-in**
  (swift-numerics 1.1 „Relax"), während Clang für C per Default
  `-ffp-contract=on` fährt
  ([clang User's Manual](https://clang.llvm.org/docs/UsersManual.html)).

**Übersetzt aufs Projekt:** `SimCore` nutzt 36 Aufrufe transzendenter Funktionen.
Ein Lauf auf macOS/arm64 und einer auf Linux/x86-64 sind **heute schon nicht
bit-gleich** — es fällt nur nicht auf, weil alle neun Determinismus-Tests
intra-Maschine vergleichen. Ein Wasm-Build wäre plattformübergreifend
reproduzierbar. Das ist ein **echter Vorteil von Wasm**, und der einzige
technische Punkt in dieser Evaluation, der klar für den Web-Stack spricht.

Relevant wird er, sobald das Projekt will: geräteübergreifend teilbare Saves mit
identischer Fortsetzung, Golden-Value-Tests in CI, Replays, oder irgendwann
deterministisches Multiplayer.

### 5.3 GPU (WGSL): Bit-Determinismus ist per Spec ausgeschlossen

`AGENTS.md` schreibt: „Parallelisierung ist nur über disjunkte Index-Bereiche
erlaubt, wo das Ergebnis **bit-identisch** zur sequenziellen Schleife bleibt."
Die WGSL-Spec erlaubt Implementierungen ausdrücklich das Gegenteil
([W3C WGSL §15.7](https://www.w3.org/TR/WGSL/#floating-point-evaluation)):

- „**No rounding mode is specified.** An implementation may round an intermediate
  result up or down."
- „**Implementations may ignore the sign field of a floating point zero value.**"
- „**Any inputs or outputs** of operations listed in §15.7.4 **may be flushed to
  zero**."
- „**An implementation may reassociate operations.**" / „**An implementation may
  fuse operations** …"
- Finite-Math-Annahme: „Implementations may assume that overflow, infinities, and
  NaNs are not present during shader execution", sonst „indeterminate value".

Dazu die ULP-Toleranztabelle: `/` 2,5 ULP, `inverseSqrt` 2 ULP, `exp` 3+2|x| ULP,
**`atan`/`atan2` 4096 ULP**, `determinant` „Infinite ULP". Der Kern benutzt
`atan2` zweimal. Selbst Texel-Kopien sind nicht bitgetreu: „Texel copies only
guarantee that valid, finite, **non-subnormal** numeric values … have the same
numeric value in the destination"
([W3C WebGPU §11.2](https://www.w3.org/TR/webgpu/)).

**Das ist ein Bewertungs-Fixpunkt:** Eine GPU-Portierung der Sim wäre auf *einem*
Gerät reproduzierbar, aber nicht über GPUs/Treiber/Browser hinweg. `LongRunCollapse`
und die Save/Load-Bit-Abnahme müssten auf Toleranzen umgeschrieben werden.

**Wichtig für die Fairness der Bewertung:** Das gilt **nicht spezifisch für Web**.
Godots eigene Compute-Shader (Vulkan/GLSL) unterliegen denselben
GPU-Realitäten. Der Punkt lautet also korrekt: *„Sim auf GPU" kostet die
Bit-Invariante — unabhängig vom Stack.* Er entwertet nur das Argument, Web sei
wegen WebGPU-Compute überlegen.

Weitere WebGPU-spezifische Reibung für eine GPU-Sim: die Spec sanktioniert
**Watchdog-Timer** („may set up 'watchdog' timer that makes sure an application
doesn't cause GPU unresponsiveness for more than a few seconds") — ein
`+10.000 Jahre`-Sprung müsste über Frames gestückelt werden; **Device Loss** ist
ein Zustand, in dem die meisten Operationen *scheinbar erfolgreich* weiterlaufen;
und es gibt **kein synchrones Readback** (nur `mapAsync`), womit das heutige
kostenlose Kennzahlen-Logging (Relief, Ruggedness, See-Anteil) asynchron würde
([W3C WebGPU](https://www.w3.org/TR/webgpu/)).

---

## 6. WebGPU-Status 2026 und Godot-Web als Vergleichspunkt

### 6.1 WebGPU-Verfügbarkeit

| Browser | Stand | Quelle |
|---|---|---|
| Chrome | Windows/macOS/ChromeOS seit 113 (2023-05); Android 12+ seit 121; **Linux erst seit 144 (2026-01), zunächst nur Intel Gen12+**, NVIDIA-Wayland ab 147/148 | [developer.chrome.com/blog/webgpu-release](https://developer.chrome.com/blog/webgpu-release), [new-in-webgpu-144](https://developer.chrome.com/blog/new-in-webgpu-144), [147-148](https://developer.chrome.com/blog/new-in-webgpu-147-148) |
| Firefox | Windows ab 141 (2025-07), macOS/Apple-Silicon ab 145/147; **kein Linux**, **kein Android**, kein Intel-macOS — als `partial_implementation` markiert | [MDN BCD api.GPU](https://bcd.developer.mozilla.org/bcd/api/v0/current/api.GPU.json), [Firefox 141 Release Notes](https://www.firefox.com/en-US/firefox/141.0/releasenotes/) |
| Safari | seit **26.0 (2025-09-15)** default-an auf macOS/iOS/iPadOS/visionOS | [webkit.org/blog/17333](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/) |

MDN stuft WebGPU weiterhin als **„Limited availability — not Baseline"** ein
([MDN WebGPU API](https://developer.mozilla.org/en-US/docs/Web/API/WebGPU_API));
caniuse meldet 84 % voll + 1,6 % partiell
([caniuse.com/webgpu](https://caniuse.com/webgpu)).

**Für dieses Projekt praktisch relevant:** Entwickelt wird u. a. auf Linux. Dort
ist WebGPU in Chrome erst seit Januar 2026 und nur auf Intel-GPUs, und in Firefox
gar nicht. Ein WebGPU-getragener Renderer wäre auf der Linux-Entwicklungsmaschine
möglicherweise nicht lauffähig — der WebGL2-Fallback dagegen schon.

Spec-Defaults für Limits: `maxStorageBufferBindingSize` **128 MiB**,
`maxBufferSize` **256 MiB**, `maxStorageBuffersPerShaderStage` **8**,
`maxTextureDimension2D` 8192 (Compat-Mode 4096)
([W3C WebGPU §Limits](https://www.w3.org/TR/webgpu/#limits)). Ein Feld à 832² f32
= 2,64 MiB passt bequem; die **8 Storage-Buffer pro Stage** wären bei ~25 Feldern
die reale Enge. Ebenfalls beachtenswert: `float32-filterable` (bilineare
Filterung von `r32float`-Texturen) ist ein **optionales** Feature.

### 6.2 Godot-Web-Export

Godot 4.7 ist stabil (18.06.2026), 4.7.1 am 14.07.2026
([godotengine.org/releases/4.7](https://godotengine.org/releases/4.7/)).

- **Rendering:** „Godot 4 can only target WebGL 2.0 (using the Compatibility
  rendering method). Forward+/Mobile are not supported on the web platform …
  Godot currently does not support WebGPU"
  ([Exporting for the Web](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)).
- **WebGPU ist upstream nicht in Arbeit:** Proposal #6646 ist offen und mit
  `implementer wanted` gelabelt
  ([godot-proposals#6646](https://github.com/godotengine/godot-proposals/issues/6646)).
- **Compute-Shader:** „Compute shaders can only be used from RenderingDevice-based
  renderers (the Forward+ or Mobile renderer)"
  ([Compute shaders](https://docs.godotengine.org/en/stable/tutorials/shaders/compute_shaders.html))
  — im Web also **nicht verfügbar**.
- **Threads:** Seit 4.3 ist der Single-Thread-Export Default, weil der
  Thread-Export „requiring specific server-side headers and complete cross-origin
  isolation (meaning no ads, nor third-party integrations on the website hosting
  your game)" verlangt (gleiche Doku-Seite).
- **Weitere dokumentierte Grenzen:** der Tab **pausiert, wenn er nicht aktiv ist**
  (`_process`/`_physics_process` stoppen); `user://` hängt an IndexedDB; C#/.NET
  ist im Web weiterhin nicht unterstützt.

### 6.3 GDExtension und SwiftGodot im Web

GDExtension im Web ist **grundsätzlich unterstützt**, aber eng: eigenes
`_dlink`-Export-Template, Emscripten-Version im Gleichschritt (Godot 4.7 verlangt
Emscripten ≥ 4.0.0, CI pinnt 4.0.11), Extension als `SIDE_MODULE`, wasm32-only —
**und Cross-Origin-Isolation wird Pflicht**, sobald Extensions aktiviert sind
([Compiling for Web](https://docs.godotengine.org/en/stable/engine_details/development/compiling/compiling_for_web.html),
[godot-cpp/tools/web.py](https://github.com/godotengine/godot-cpp/blob/master/tools/web.py),
[Export-Doku](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)).
Der Bug-Schwanz ist aktiv (u. a.
[#94537](https://github.com/godotengine/godot/issues/94537),
[#97426](https://github.com/godotengine/godot/issues/97426),
[#105717](https://github.com/godotengine/godot/issues/105717)).

**SwiftGodot ins Web: geht nicht.** Tracking-Issue #447 nennt die Ursache:
„Godot seems to use the Emscripten ABI. Swift/Wasm seems to use the WASI API, and
these are different"
([SwiftGodot#447](https://github.com/migueldeicaza/SwiftGodot/issues/447)).
PR #762 bringt SwiftGodot zum *Kompilieren* für `wasm32-unknown-wasip1`, ist aber
nicht gemerged, und der Autor schreibt selbst: „The binary compiles but doesn't
run in Godot's web export due to ABI mismatch … Full runtime support requires
toolchain-level work"
([SwiftGodot#762](https://github.com/migueldeicaza/SwiftGodot/pull/762)). Der
Upstream-Fix ist genau der Emscripten-Pitch aus §2.2, der SwiftGodot explizit als
Motivation nennt und Stand Mai 2026 unmerged ist
([Pitch](https://forums.swift.org/t/pitch-emscripten-target-support-for-swift/85310)).

**Fazit §6:** Der Ist-Stack hat **keinen** Web-Pfad, und zwar nicht wegen einer
Build-Einstellung, sondern wegen eines ABI-Bruchs, dessen Behebung upstream in
Swift liegt. Wer Web will, verlässt Godot — oder schreibt den Kern aus Swift
heraus.

---

## 7. Plattform, Distribution, Betrieb

### 7.1 Was Web klar gewinnt

Kein Installer, kein Code-Signing pro Plattform, teilbarer Link, sofortige
Updates ohne Auslieferung, Reichweite auf Geräten ohne Installationsrecht. Das
ist real und nicht kleinzureden — es ist der einzige Vorteil in dieser
Evaluation, der außerhalb der Technik liegt und deshalb am Projektziel hängt, nicht
an Messwerten.

### 7.2 Was der Browser einer Langzeit-Simulation antut

- **`requestAnimationFrame` läuft im Hintergrund-Tab nicht.** MDN:
  „`requestAnimationFrame()` calls are paused in most browsers when running in
  background tabs"
  ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/Window/requestAnimationFrame));
  Chrome: rAF „simply isn't called for backgrounded pages"
  ([developer.chrome.com/blog/background_tabs](https://developer.chrome.com/blog/background_tabs)).
- **Timer werden gestaffelt gedrosselt** — bis auf **einmal pro Minute**
  (Intensive Throttling ab Chrome 88), Firefox drosselt inaktive Tabs auf 1 s,
  auf Android auf **15 Minuten**
  ([Chrome 88](https://developer.chrome.com/blog/timer-throttling-in-chrome-88),
  [MDN setTimeout](https://developer.mozilla.org/en-US/docs/Web/API/Window/setTimeout)).
- **Ein eingefrorener Tab blockiert auch seine Worker.** Page-Lifecycle-Spec:
  „Any dedicated worker agent whose single realm's global object's owning document
  is non-null and frozen must become blocked"
  ([wicg.github.io/page-lifecycle](https://wicg.github.io/page-lifecycle/)). Ein
  Worker mit eigener Rechenschleife läuft im bloß *versteckten* Tab weiter, im
  *eingefrorenen* nicht — und Einfrier-Resistenz ist heuristisch (Audio, WebRTC,
  Titel-/Favicon-Updates), keine API
  ([Page Lifecycle API](https://developer.chrome.com/docs/web-platform/page-lifecycle-api)).
- **Discarding:** Der Tab kann unter Speicherdruck vollständig entladen werden
  (`document.wasDiscarded`) — die Sim muss also checkpointen und fortsetzen
  können, statt Kontinuität anzunehmen.
- **iOS:** kein offizielles Heap-Limit; die belastbarste Aussage ist ein
  WebKit-Engineer im Bugtracker: „Currently the Gigacage supports 2GB of
  allocations on iOS" (deckt TypedArrays *und* Wasm-Memory ab)
  ([WebKit-Bug 268816](https://bugs.webkit.org/show_bug.cgi?id=268816)) — belastbar,
  aber kein Policy-Dokument.

**Bewertung:** Für ein Spiel, dessen Kern-Loop „Zeit vergeht, die Welt altert"
lautet und das Läufe über 100k–200k Jahre kennt, ist die Tab-Lifecycle-Realität
ein echter Verhaltensbruch gegenüber der nativen App. Er ist beherrschbar
(Worker + Checkpointing), aber er ist Arbeit, die nativ nicht anfällt — und
Godots eigener Web-Export hat dasselbe Problem laut eigener Doku (§6.2).

### 7.3 Hosting: Threads kosten Hosting-Freiheit

- **GitHub Pages kann COOP/COEP nicht setzen.** Die offizielle Limits-Seite kennt
  keinen Mechanismus für eigene Response-Header
  ([docs.github.com/…/github-pages-limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)),
  und ein GitHub-Mitarbeiter im offiziellen Community-Thread: „This is a scenario
  we would support with custom headers. No ETA at the moment"
  ([community/discussions/13309](https://github.com/orgs/community/discussions/13309)).
  Also: **kein `SharedArrayBuffer`, keine Wasm-Threads** auf GitHub Pages.
- **itch.io unterstützt es — experimentell und opt-in**, per Checkbox unter
  Embed Options → Frame Options. Preis laut itch.io-Admin: die Spieldateien
  ziehen auf die Domain `html.itch.zone` um, **wodurch bestehende
  localStorage-Saves verloren gehen**; Fremd-Embeds auf der Seite brechen; und die
  Isolation läuft über `COEP: credentialless`, „currently not supported in Firefox
  or other browsers"
  ([itch.io/t/2025776](https://itch.io/t/2025776/experimental-sharedarraybuffer-support),
  [itch.io/blog/456223](https://itch.io/blog/456223/godot-cross-origin-isolation-and-sharedarraybuffers)).
  HTML5-Grenzen: 500 MB entpackt gesamt, 200 MB pro Datei, 1.000 Dateien
  ([itch.io/docs/creators/html5](https://itch.io/docs/creators/html5)).
- Netlify u. ä. können Header setzen
  ([docs.netlify.com/manage/routing/headers](https://docs.netlify.com/manage/routing/headers/)).

**Die Pointe:** Single-Thread-Wasm läuft überall. Sobald man Threads will — und
dieses Projekt *braucht* sie —, verengt sich das Hosting auf Plattformen mit
Header-Kontrolle, und die „Link einfach teilen"-Erzählung verliert genau die
Reibungsfreiheit, die sie attraktiv machte.

### 7.4 Speichern/Laden im Browser

Hier hat der Web-Stack eine gute Antwort: **OPFS** mit
`createSyncAccessHandle()` erlaubt **synchrones** `read`/`write`/`truncate` —
allerdings nur in dedizierten Workern
([MDN OPFS](https://developer.mozilla.org/en-US/docs/Web/API/File_System_API/Origin_private_file_system),
[MDN createSyncAccessHandle](https://developer.mozilla.org/en-US/docs/Web/API/FileSystemFileHandle/createSyncAccessHandle)).
Da die Sim ohnehin im Worker liefe, bildet das `WorldSnapshot.swift` fast 1:1 ab:
Roh-`Float32Array`-Bytes, keine Serialisierungsschicht.

**Die Gefahr sitzt bei der Eviction.** Safari löscht mit
Tracking-Prevention nach **sieben Tagen** Browser-Nutzung ohne Interaktion mit
der Seite alle skriptgeschriebenen Daten
([MDN Storage quotas and eviction criteria](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria),
[webkit.org/blog/10218](https://webkit.org/blog/10218/full-third-party-cookie-blocking-and-more/));
Löschung ist **all-or-nothing pro Origin**. `navigator.storage.persist()` hilft,
wird aber in Chrome/Safari heuristisch entschieden — WebKit: „grants a request
based on heuristics like whether the website is opened as a Home Screen Web App"
([webkit.org/blog/14403](https://webkit.org/blog/14403/updates-to-storage-policy/)).
Eine echte Datei schreiben kann nur die File System Access API — **Chromium-Desktop
only**, Firefox und Safari nicht
([caniuse](https://caniuse.com/native-filesystem-api)). Ein
`Blob` + `<a download>`-Export bleibt also Pflichtprogramm.

Nativ ist Save/Load schlicht eine Datei. Das Feature ist gerade erst gelandet
(Issue #8) und würde im Web spürbar komplizierter und für den Nutzer riskanter.

---

## 8. Engine-Leistungen: was Godot heute gratis liefert

Godot bringt Szenengraph, Kamera, Input-Mapping, **UI-Nodes**, Import-Pipeline,
Audio, Export/Signing mit. Babylon.js bietet die 3D-Seite vollwertig
(Inspector V2, glTF/OBJ/STL-Loader, Havok-Physik, Playground) — die UI-Seite
läuft über **Babylon GUI**, das intern eine `DynamicTexture` bemalt
([gui.md](https://raw.githubusercontent.com/BabylonJS/Documentation/master/content/features/featuresDeepDive/gui/gui.md)),
oder über HTML/CSS-Overlay.

Für die Ansage „deutlich mehr UI und Gameplay-Systeme" ist das kein klarer
Nachteil, eher ein Tausch: **HTML/CSS/React ist als UI-Schicht mächtiger und
schneller iterierbar als Godots Control-Nodes**, dafür verliert man den
integrierten Editor, in dem Szene, Materialien und UI zusammen leben. Für ein
datengetriebenes Simulationsspiel mit vielen Panels, Kurven und Tabellen spricht
das eher für Web; für 3D-Autorenarbeit eher für Godot.

**Rendering-Ausblick ist dagegen deutlich:** Godot-Desktop bietet heute Forward+
mit Vulkan **und** Compute-Shader über `RenderingDevice`
([Doku](https://docs.godotengine.org/en/stable/tutorials/shaders/compute_shaders.html)).
Der Browser bietet WebGL2 überall und WebGPU auf ~85 % der Geräte, davon Firefox
ohne Linux und ohne Android (§6.1). Für „aufwendigere Optik" ist der native Stack
heute im Vorteil, mit sinkender Tendenz.

### 8.1 Entwickler-Loop — der stärkste Web-Punkt neben Distribution

Das ist kein Umbaukosten-Argument, sondern dauerhafte Geschwindigkeit, also
zulässig:

- **Heute:** Extension-Build ~3,5 min auf macOS mit warmem SwiftGodot-Cache,
  **21,5 min auf Linux aus leerem `.build`, 27 min auf einem 4-Kern-Host**
  (`AGENTS.md`), plus die Build-Stempel-Mechanik, die es überhaupt erst braucht,
  weil ein vergessener Rebuild sonst still die alte `.so` lädt.
- **Web:** Vite verspricht „nearly instant" Serverstart unabhängig von der
  Projektgröße, mit Oxc-Transformer „HMR updates can reflect in the browser in
  under 50ms"
  ([vite.dev/guide/why](https://vite.dev/guide/why),
  [vite.dev/guide/features](https://vite.dev/guide/features)). `.wasm`-Importe
  und Worker sind first-class; COOP/COEP setzt man über `server.headers` und
  `preview.headers`
  ([server-options](https://vite.dev/config/server-options)).

**Zur Fairness zwei Relativierungen:** Erstens ist der *eigentliche*
Verifikationsloop dieses Projekts `swift test -c release` auf `SimCore` — der
läuft ohne Godot und ohne Extension-Build. Der Extension-Build fällt nur an, wenn
Brücke oder Renderer angefasst werden. Zweitens: würde der Sim-Kern nach Wasm
gehen, wäre er dort ebenfalls ein Compile-Schritt, kein HMR — die 50 ms gelten
für TypeScript/Shader/UI, nicht für Swift→Wasm. Der Loop-Gewinn beträfe also
genau die Schicht (Renderer, UI, Shader), die heute den langen Build auslöst.
Das ist ein realer, aber begrenzter Gewinn — und er ließe sich auch innerhalb des
Ist-Stacks angehen (SwiftGodot-Build-Cache), was hier nicht bewertet wird.

---

## 9. Test- und Verifikationsebene

Die heutige Ebene — headless, GPU-frei, `swift test -c release` — überträgt sich
gut:

- Node stellt den kompletten `WebAssembly`-Namespace seit v8.0.0 global bereit
  ([nodejs.org/api/globals](https://nodejs.org/api/globals.html)); ein reiner
  Rechen-Wasm-Kern ohne DOM-Bezug testet in Vitests **Default-Node-Umgebung**
  am schnellsten („Environments exist only when running tests in Node.js …
  browser is not considered an environment in Vitest",
  [vitest.dev/guide/environment](https://vitest.dev/guide/environment)). Das ist
  strukturell dieselbe Trennung wie heute SimCore ↔ Godot.
- Für WASI-Binaries ist `node:wasi` **Stability 1 – Experimental**
  ([nodejs.org/api/wasi](https://nodejs.org/api/wasi.html)) — ein Wermutstropfen,
  falls man `wasip1` statt eines ES-Modul-Wrappers fährt.
- Der Headless-Screenshot (`RS_SHOT`) ließe sich mit Playwright nachbauen; **aber**
  Playwrights Doku sagt zu GPU/WebGL im Headless-Modus nichts. Chromes eigene
  Aussage: „By default, Headless Chrome disables GPU" — WebGL/WebGPU brauchen
  Flags (`--headless=new`, `--use-angle=vulkan`, `--enable-unsafe-webgpu`) **und
  passende Treiber auf dem Host**
  ([developer.chrome.com/blog/supercharge-web-ai-testing](https://developer.chrome.com/blog/supercharge-web-ai-testing)).
  Godots `--headless`-Screenshot-Rezept ist heute einfacher und robuster.

**Bewertung:** Unentschieden bis leicht pro nativ. Die wichtigste Ebene (headless
Kern-Tests) funktioniert in beiden Welten; die visuelle Ebene ist nativ heute
weniger fragil.

---

## 10. Gesamtabwägung

### 10.1 Bilanz

| Achse | Nativ (Swift + Godot) | Web (Wasm + Babylon) |
|---|---|---|
| CPU-Durchsatz Sim | **klar besser** (nativ + echte Threads) | −45…−55 % single-thread, Threads nur inoffiziell |
| Datenparallelität | vorhanden, bit-identisch getestet | libdispatch fehlt; Worker-Umbau + COOP/COEP |
| Bit-Determinismus je Maschine | **erfüllt** | erfüllt |
| Bit-Determinismus über Plattformen | **nicht gegeben** (libm) | **besser** (libm einkompiliert) |
| GPU-Compute für die Sim | verfügbar (Vulkan), aber Bit-Invariante fällt | verfügbar (WebGPU), Bit-Invariante fällt per Spec |
| Rendering heute | Forward+/Vulkan | WebGL2 überall, WebGPU ~85 %, Firefox ohne Linux |
| Grid-Skalierung | frei | Deckel bei ~n=4096 (2 GB) |
| Langzeit-Lauf | ungestört | Tab-Freeze blockiert auch Worker |
| Save/Load | Datei | OPFS gut, aber Safari-7-Tage-Eviction |
| Distribution | Installer pro Plattform | **klar besser** |
| Dev-Loop Renderer/UI | 3,5–27 min Build | **klar besser** (<50 ms HMR) |
| Headless-Verifikation | XCTest, etabliert | Vitest/Node gleichwertig; Screenshots fragiler |

Die beiden Achsen, auf denen Web klar gewinnt (Distribution, Dev-Loop der
Renderer-Schicht), stehen gegen die beiden Achsen, auf denen das Projekt seine
Zukunft definiert hat (CPU-Budget für mehr Physik, getesteter Determinismus).
Bei einem Pre-Alpha, das „deutlich aufwendiger und realistischer" werden soll,
wiegen die zweiten schwerer.

### 10.2 Optionen

**Option A — Voller Web-Refactor (SimCore nach Wasm, Babylon-Renderer).**
Nicht empfohlen. Man tauscht Threads und CPU-Durchsatz gegen Distribution, auf
einem Swift-Wasm-Threading-Pfad, den swift.org ausdrücklich nicht supportet.

**Option B — Nativer Stack, `SimCore` Wasm-fähig halten. ⟵ Empfehlung.**
Produktion bleibt Swift + SwiftGodot + Godot. Zusätzlich wird `SimCore` so
gepflegt, dass es für `wasm32-unknown-wasip1` baut:
- Dispatch-Nutzung hinter eine schmale Parallelisierungs-Abstraktion legen (drei
  Aufrufstellen), mit sequenziellem Fallback — das ist ohnehin sauberer und
  macht die Bit-Identitäts-Invariante explizit prüfbar.
- 64-bit-`Int`-Annahmen ausräumen (v. a. Offsets in `WorldSnapshot`).
- `import Foundation` dort zurückbauen, wo es nur für Kleinigkeiten steht.
- Einen Wasm-Build in CI aufnehmen, der nur *baut* und die Kern-Tests unter Node
  fährt.

Nutzen unabhängig von jeder Web-Entscheidung: **plattformübergreifender
Bit-Determinismus wird testbar** (§5.2) — das ist die Voraussetzung für
geräteübergreifend gültige Saves, Golden-Value-Tests und Replays. Und falls
Swifts Emscripten-Target landet (§2.2, §6.3), ist der Web-Pfad dann offen.

**Option C — TypeScript- oder Rust-Port des Kerns.**
TS scheidet aus: `Terrain.swift` ist Zahlenschieberei auf Float-Grids, genau die
Klasse, für die `PLAN.md` GDScript verworfen hat. Rust wäre technisch attraktiv
(echte Wasm-Threads via `wasm-bindgen-rayon`, godot-rust als *nativer* Weg,
`no_std`-freundlich) — aber es löst kein Problem, das der Stack heute hat, und
handelt sich dieselben Browser-Grenzen ein. Nur relevant, wenn Web-Distribution
zum Primärziel wird.

**Option D — GPU-Compute für die Sim (Godot RenderingDevice oder WebGPU).**
Unabhängig vom Stack zu entscheiden. Empfehlung: **nicht für Pässe, die die
Bit-Invariante tragen.** Falls GPU-Compute später als Performance-Hebel gebraucht
wird, zuerst reine Render-Ableitungen verschieben (Farb-/Wasser-Byte-Puffer,
Normalen, Baum-Instanzen) — dort ist Bit-Identität nicht gefordert. Die
Rollentrennung D8/MFD (`AGENTS.md`) gibt dafür schon die richtige Grenze vor:
`areaMFD` speist Render **und Braiding**, ist also *nicht* frei — eine
GPU-Verlagerung müsste diese Grenze zuerst schärfen.

---

## 11. Woran die Empfehlung hängt (Unsicherheiten)

1. **Der stärkste Web-Hebel ist nicht technisch, sondern das Projektziel.** Bleibt
   es „tiefere Simulation", gewinnt nativ. Wird es „viele Leute sollen das
   ausprobieren", kippt die Rechnung — dann wäre Option C die konsequente Antwort,
   nicht A.
2. **Swift-Wasm-Threads könnten offiziell werden.** Wenn `wasip1-threads` in die
   swift.org-Auslieferung wandert oder `wasm32-unknown-emscripten` landet, entfällt
   der schwerste Contra-Punkt — und im Emscripten-Fall bekäme sogar der *heutige*
   Stack einen Web-Export. Das ist der Grund, Option B jetzt zu tun.
3. **Die Performance-Zahl ist alt.** 45–55 % Nachteil stammt aus USENIX ATC '19;
   eine gleichwertige aktuelle Messung existiert nicht. Der wahre Wert ist
   vermutlich besser. Er ändert die Empfehlung aber nicht, weil der Thread-Verlust
   dominiert.
4. **Per-Frame-Texture-Upload-Kosten in Babylon sind nicht dokumentiert** und
   müssten gemessen werden (~6 MiB/Frame). Plausibel unkritisch, aber unbelegt.
5. **Binärgröße von `SimCore` als Wasm ist unbekannt** — zwischen 9,7 kB
   (Embedded) und 50 MB (Goodnotes) liegen drei Größenordnungen, und
   `SimCore` nutzt Foundation.
6. **Nicht verifiziert:** ob dedizierte Worker in bloß versteckten Tabs in allen
   Engines ungedrosselt weiterrechnen. Die Spec gestattet UAs ausdrücklich
   „implementation-defined" Verzögerungen
   ([HTML-Spec, Timers](https://html.spec.whatwg.org/multipage/timers-and-user-prompts.html)),
   und es gibt einen langlebigen Chromium-Bug dazu
   ([issues.chromium.org/issues/40494643](https://issues.chromium.org/issues/40494643)).

---

## Anhang: Quellen nach Themenblock

**Swift/Wasm:**
[swift.org Wasm Getting Started](https://www.swift.org/documentation/articles/wasm-getting-started.html) ·
[Swift 6.2 Release](https://www.swift.org/blog/swift-6.2-released/) ·
[Platform Support](https://www.swift.org/platform-support/) ·
[swiftlang/swift docs/WebAssembly.md](https://github.com/swiftlang/swift/blob/main/docs/WebAssembly.md) ·
[Vision: WebAssembly Support](https://github.com/swiftlang/swift-evolution/blob/main/visions/webassembly.md) ·
[SwiftWasm Book: Porting](https://book.swiftwasm.org/getting-started/porting.html) ·
[Goodnotes on the Web](https://www.swift.org/blog/bringing-goodnotes-to-web-with-swift/) ·
[wasip1-threads-Status](https://forums.swift.org/t/what-happened-to-wasm32-unknown-wasip1-threads/85656) ·
[Pitch: Emscripten Target](https://forums.swift.org/t/pitch-emscripten-target-support-for-swift/85310)

**WebAssembly-Spec und -Performance:**
[Core Spec: Numerics](https://webassembly.github.io/spec/core/exec/numerics.html) ·
[design/Nondeterminism.md](https://github.com/WebAssembly/design/blob/main/Nondeterminism.md) ·
[design/FAQ.md](https://github.com/WebAssembly/design/blob/main/FAQ.md) ·
[Spec: Profiles](https://webassembly.github.io/spec/core/appendix/profiles.html) ·
[relaxed-simd Overview](https://github.com/WebAssembly/relaxed-simd/blob/main/proposals/relaxed-simd/Overview.md) ·
[webassembly.org/features](https://webassembly.org/features/) ·
[Wasm 3.0](https://webassembly.org/news/2025-09-17-wasm-3.0/) ·
[V8: 4 GB Wasm Memory](https://v8.dev/blog/4gb-wasm-memory) ·
[Jangda et al., USENIX ATC '19](https://www.usenix.org/conference/atc19/presentation/jangda)

**Nativer Float-Determinismus:**
[GNU libc: Errors in Math Functions](https://www.gnu.org/software/libc/manual/html_node/Errors-in-Math-Functions.html) ·
[CORE-MATH FAQ](https://core-math.gitlabpages.inria.fr/faq.html) ·
[Clang User's Manual](https://clang.llvm.org/docs/UsersManual.html) ·
[swift-numerics RealModule](https://github.com/apple/swift-numerics/blob/main/Sources/RealModule/README.md) ·
[wasi-libc](https://github.com/WebAssembly/wasi-libc)

**Babylon.js / three.js:**
[Babylon Releases](https://api.github.com/repos/BabylonJS/Babylon.js/releases) ·
[RawTexture](https://raw.githubusercontent.com/BabylonJS/Documentation/master/content/features/featuresDeepDive/materials/advanced/rawTexture.md) ·
[WGSL in Babylon](https://raw.githubusercontent.com/BabylonJS/Documentation/master/content/setup/support/webGPU/webGPUWGSL.md) ·
[ComputeShader](https://raw.githubusercontent.com/BabylonJS/Documentation/master/content/features/featuresDeepDive/materials/shaders/computeShader.md) ·
[Dynamic Terrain](https://raw.githubusercontent.com/BabylonJS/Documentation/master/content/communityExtensions/dynamicTerrains.md) ·
[three.js WebGPURenderer](https://raw.githubusercontent.com/mrdoob/three.js/dev/manual/pages/webgpurenderer.html)

**WebGPU:**
[W3C WebGPU](https://www.w3.org/TR/webgpu/) ·
[W3C WGSL: Floating Point](https://www.w3.org/TR/WGSL/#floating-point-evaluation) ·
[Chrome: WebGPU auf Linux (144)](https://developer.chrome.com/blog/new-in-webgpu-144) ·
[MDN BCD api.GPU](https://bcd.developer.mozilla.org/bcd/api/v0/current/api.GPU.json) ·
[WebKit: Safari 26](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/) ·
[caniuse: webgpu](https://caniuse.com/webgpu)

**Godot:**
[Exporting for the Web](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html) ·
[Compiling for Web](https://docs.godotengine.org/en/stable/engine_details/development/compiling/compiling_for_web.html) ·
[Compute Shaders](https://docs.godotengine.org/en/stable/tutorials/shaders/compute_shaders.html) ·
[Godot 4.7 Release](https://godotengine.org/releases/4.7/) ·
[Proposal: WebGPU (#6646)](https://github.com/godotengine/godot-proposals/issues/6646) ·
[SwiftGodot #447](https://github.com/migueldeicaza/SwiftGodot/issues/447) ·
[SwiftGodot #762](https://github.com/migueldeicaza/SwiftGodot/pull/762)

**Browser-Plattform:**
[MDN requestAnimationFrame](https://developer.mozilla.org/en-US/docs/Web/API/Window/requestAnimationFrame) ·
[Chrome: Timer Throttling](https://developer.chrome.com/blog/timer-throttling-in-chrome-88) ·
[Page Lifecycle API](https://developer.chrome.com/docs/web-platform/page-lifecycle-api) ·
[Page Lifecycle Spec](https://wicg.github.io/page-lifecycle/) ·
[MDN OPFS](https://developer.mozilla.org/en-US/docs/Web/API/File_System_API/Origin_private_file_system) ·
[MDN Storage quotas](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria) ·
[WebKit Storage Policy](https://webkit.org/blog/14403/updates-to-storage-policy/) ·
[itch.io: SharedArrayBuffer](https://itch.io/t/2025776/experimental-sharedarraybuffer-support) ·
[GitHub Pages Limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)

**Dev-Loop und Tests:**
[vite.dev/guide/why](https://vite.dev/guide/why) ·
[vite.dev/config/server-options](https://vite.dev/config/server-options) ·
[vitest.dev/guide/environment](https://vitest.dev/guide/environment) ·
[nodejs.org/api/wasi](https://nodejs.org/api/wasi.html) ·
[Chrome: Headless GPU Testing](https://developer.chrome.com/blog/supercharge-web-ai-testing)
