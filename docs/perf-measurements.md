# Perf-Messreihe: Sim-Schritt bei n = 832 (Issue #43)

Ziel des Issues: der Sim-Schritt blockiert den Hauptthread und muss in
Produktions-Konfiguration mindestens **halbiert** werden — **ohne die Physik zu
verändern**. Diese Datei ist das Messprotokoll dazu: Werkzeug, Vorher/Nachher,
was gewirkt hat, was gemessen NICHT gewirkt hat, und wo der Rest steckt.

Leitsatz des Repos: **erst messen, dann schrauben.** Jede Zahl hier stammt aus
einem Lauf des Harness, nicht aus einer Schätzung.

---

## A. Werkzeug

### `simperf` — headless Zeit-Harness

```sh
source ~/.local/share/swiftly/env.sh
export LD_LIBRARY_PATH="$(git rev-parse --show-toplevel)/.tools/swift-libs:${LD_LIBRARY_PATH:-}"
swift build -c release --package-path SimCore -Xswiftc -swift-version -Xswiftc 5

SimCore/.build/release/simperf                      # Zeiten + Pass-Tabelle, dt = 100
SimCore/.build/release/simperf --repeat 3           # drei Messblöcke (s. u.)
SimCore/.build/release/simperf --dt 0.2 --steps 200 # Echtzeit-Takt statt Sprung
SimCore/.build/release/simperf --hash               # Bit-Identitäts-Fingerabdruck
SimCore/.build/release/simperf --no-profile         # Gegenprobe ohne Instrumentierung
```

Der Harness fährt die **Produktions-Konfiguration** (`SimConfig()` plus
`hydraulicSkipWaterSpawns` und `meanderSpatialCutoffIndex` — dieselben zwei
Schalter, die `SimNode.productionConfig()` setzt; die Extension ist von SimCore
aus nicht erreichbar, deshalb der Nachbau), n = 832, Seed 1337, **100 Schritte à
100 Jahre Einlauf**, danach die Messschritte. Gemessen wird also der
eingeschwungene Zustand, nicht der Kaltstart.

### `SimProfile` — Pass-Aufteilung

Auf dem Linux-Host gibt es kein `perf` und kein Instruments. Statt zu sampeln
setzt `Terrain.step()` (und `floodAndRoute`/`computeFlow`) **Marken** an den
Pass-Grenzen; `SimProfile` summiert die Spans. Standardmäßig aus — dann kostet
jede Marke einen Bool-Load.

Gegenprobe, dass die Instrumentierung nicht selbst misst, was sie messen soll
(Baseline-Stand, 30 × dt = 100):

| Lauf | ms/Schritt |
|---|---|
| mit Marken | 386,9 |
| `--no-profile` | 383,4 |

≈ 0,9 %, also innerhalb der Streuung der Maschine (s. u.).

### `--hash` — der Wächter für „Physik unverändert"

FNV-1a über die Bit-Muster von `h`, `hf`, `area`, `areaMFD`, `sed`, `veg`,
`snow`, `ice` nach Einlauf + Messschritten. **Jede** Optimierung dieser Runde
wurde damit geprüft; der Wert ist über die gesamte Serie konstant:

```
n=832 seed=1337 warmup=100x100 steps=30x100
fingerprint b145f5ba674c23d9
```

Er ist maschinen-spezifisch (System-libm, s. AGENTS.md) — verglichen wird immer
auf DERSELBEN Maschine, vor und nach der Änderung.

### Messhygiene auf der VM

Die Messmaschine hat 4 Kerne und streut **zwischen Prozessläufen** um ~5 %.
Innerhalb eines Laufs ist sie stabil, und weil die Simulation bit-identisch
bleibt, macht Block *N* in jeder Version exakt dieselbe Arbeit. Deshalb gilt für
jeden Vorher/Nachher-Vergleich: `--repeat 3`, **beide Stände in derselben
Sitzung**, blockweise vergleichen. Absolutzahlen aus verschiedenen Sitzungen
sind nicht vergleichbar (dieselbe Baseline maß je nach Tageszeit 374 … 387 ms).

---

## B. Baseline (origin/main, Stand vor dieser Runde)

VM, 4 Kerne, n = 832, Produktions-Config, Seed 1337, Einlauf 100 × 100 J.
(Die Absolutwerte hängen an der Tageslast der VM — dieselbe Baseline maß
374 … 439 ms. Maßgeblich ist immer der A/B-Vergleich in EINER Sitzung,
s. Abschnitt C.)

| Lauf | ms/Schritt |
|---|---|
| 30 Schritte à dt = 100 (`--repeat 3`) | **374,2 / 382,6 / 385,6** |
| 200 Schritte à dt = 0,2 | **368,6** |

Pass-Aufteilung (30 × dt = 100):

| Pass | ms/Schritt | Anteil |
|---|---:|---:|
| capEndorheicBasins | 61,9 | 16,0 % |
| priorityFlood | 56,0 | 14,5 % |
| outletIncision | 37,4 | 9,7 % |
| clearEndorheicBasins | 36,4 | 9,4 % |
| computeMFDArea | 32,6 | 8,4 % |
| applyUplift | 26,6 | 6,9 % |
| migrateMeander | 18,8 | 4,9 % |
| meanderStamp | 18,8 | 4,8 % |
| updateVegetation | 18,7 | 4,8 % |
| braidPass | 16,5 | 4,3 % |
| computeReceiversAndArea (2×) | 15,8 | 4,1 % |
| updateIce | 11,4 | 3,0 % |
| Hydraulic.erode | 10,4 | 2,7 % |
| fillShallowPonds | 7,7 | 2,0 % |
| wavePass | 5,1 | 1,3 % |
| computeRain | 4,5 | 1,2 % |
| hillslopeDiffusion | 4,0 | 1,0 % |
| Rest | 4,1 | 1,1 % |

Die Anteile decken sich mit dem Mac-Profil aus dem Issue (capEndorheic 16 vs.
17 %, clearEndorheic 9,4 vs. 9,5 %, MFD 8,4 vs. 10 %, Uplift 6,9 vs. 7,3 %) —
der Harness misst dasselbe Bild, nur auf langsamerer Hardware.

### Die Fixkosten-Beobachtung (Hypothese 2 des Issues, bestätigt)

**dt = 0,2 kostet praktisch dasselbe wie dt = 100** (368,6 vs. 374,2 ms). Genau
ein Pass skaliert mit `dt`: `Hydraulic.erode` (10,4 → 0,6 ms; die Tropfenzahl
ist ∝ dt), dazu ein Teil von `updateIce` (11,4 → 7,2, Sub-Taktung). **Alles
andere ist Fixkosten pro Schritt.** Für den Echtzeit-Zeitraffer, der viele
winzige Schritte macht, zählt deshalb praktisch der ganze Schritt — und die
Optimierung muss an den Fixkosten ansetzen, nicht an der pro-Jahr-Arbeit.

---

## C. Ergebnis dieser Runde

Abschluss-Messung, **beide Stände in EINER Sitzung**, direkt hintereinander
(Baseline = `git checkout origin/main -- SimCore/Sources/SimCore/Terrain.swift`,
alles andere identisch):

| Lauf | Baseline | nachher | Faktor |
|---|---:|---:|---:|
| 30 × dt = 100, Block 1/2/3 | 426,1 / 439,7 / 432,4 | **258,0 / 250,7 / 258,2** | **1,70×** |
| 200 × dt = 0,2 (Echtzeit-Takt) | 400,4 | **241,0** | **1,66×** |
| Einlauf 100 × 100 J. (Wanduhr) | 45,6 s | **26,8 s** | 1,70× |

**Das Ziel „mindestens halbiert" ist damit NICHT erreicht** — gemessen sind
~41 % weniger, nicht 50 %. Woran das liegt und was die letzten Prozent kosten
würden, steht in Abschnitt F; die kurze Fassung: `priorityFlood` ist inzwischen
24 % des Schritts und lässt sich unter der Auflage „bit-identisch" nicht
beschleunigen.

Zur Einordnung auf der Referenz-Hardware des Issues (M4 Max, Baseline
171 ms/Schritt): rechnet man die hier gemessenen Pass-Faktoren auf die
Mac-Anteile aus dem Issue hoch, landet man bei **~105 ms** — der Mac profitiert
zusätzlich davon, dass die parallelisierten Pässe dort 16 statt 4 Kerne
bekommen, die verbliebenen seriellen Pässe aber ohnehin latenz-gebunden sind.
Das ist eine Hochrechnung, keine Messung; die 90-ms-Marke des Issues wird sie
vermutlich knapp verfehlen.

Pass für Pass, jeweils in der Sitzung gemessen, in der die Änderung entstand
(Details und Begründung stehen als Kommentar am jeweiligen Pass in
`Terrain.swift`):

| Pass | vorher | nachher | Mittel |
|---|---:|---:|---|
| capEndorheicBasins | 61,9 | 8,6 | Roh-Puffer, Scratch aus der Klasse heraus, `k/nn` statt `%`+`/` |
| clearEndorheicBasins | 36,4 | 0,4 | `memset` statt Zellschleife (`Terrain.fill`) |
| applyUplift | 26,6 | 2,4 | Roh-Puffer + `parallel` (per-Zelle unabhängig) |
| outletIncision | 45,9¹ | 29,9 | `A^m` parallel vorberechnet; Diagonale aus der Index-Differenz |
| updateVegetation | 18,9 | 14,5 | separables Box-Maximum (10 statt 25 Vergleiche/Zelle) |
| braidPass | 17,0 | 12,2 | Roh-Puffer, Nachbar-Scratch auf dem Stack |
| migrateMeander | 19,1 | 13,7 | Felder EINMAL öffnen statt je Knoten/Streifenzelle |
| meanderStamp | 20,2 | 17,4 | Roh-Puffer für `hf`/`veg`/`isChannel`/`underIce` |
| wavePass | 5,7 | 1,6 | Roh-Puffer (serieller Pass, aber vielfach getaktet) |
| updateIce, fillShallowPonds | 12,0 / 7,1 | 9,0 / 3,5 | `Terrain.fill`/`anyCell` statt Zellschleifen |

¹ in der Sitzung gemessen, in der die Änderung entstand (die Maschine war dort
langsamer als beim Baseline-Lauf; der A/B-Vergleich in derselben Sitzung ist die
belastbare Zahl, nicht der Absolutwert).

### Das Muster hinter fast allen Zahlen

Der Löwenanteil steckte **nicht in der Arithmetik**, sondern in Bounds-, COW-
und Exklusivitätsprüfungen bei Zugriffen auf **Klassen-Properties** im
Zell-Loop — bei n = 832 gemessen ~40 Zyklen je Zugriff. Faustzahl aus dieser
Runde: eine Schleife `for k in 0..<count { feldA[k] = …; feldB[k] = … }` über
zwei oder mehr Klassen-Property-Arrays kostet ~9 ms **je Feld** und Schritt.
Über einen lokalen `withUnsafe*BufferPointer` ist dieselbe Schleife ein Memset
bzw. ein normaler Loop.

(Eine EINZELNE Feld-Schleife optimiert der Compiler selbst: er hebt die Prüfung
aus dem Loop. Deshalb brachte das Ersetzen von `for k … { qs[k] = 0 }` durch
`fill(&qs, 0)` gemessen nichts, das Ersetzen der Drei-Felder-Schleife in
`clearEndorheicBasins` dagegen 36 ms. Beide Formen sind trotzdem auf `fill`
umgestellt, damit die Absicht am Aufrufort steht.)

Zwei weitere wiederkehrende Posten:
- **`pow` im Zell-Loop.** Ein libm-`pow` je Zelle kostete in `outletIncision`
  ~16 ms/Schritt (Diagnose: mit einer Multiplikation statt `pow` fiel der Pass
  von 41 auf 25 ms). Wo das Argument sich während des Passes nicht ändert, lässt
  sich die Potenz parallel vorberechnen — gleiche Aufrufe, gleiche Argumente,
  bit-identisches Ergebnis.
- **Integer-Division.** `k % n` und `k / n` je Zelle sind bei 692k Zellen
  messbar; `j = k / n; i = k - j*n` halbiert sie, und wo nur „diagonal ja/nein"
  gebraucht wird, reicht die Index-Differenz.

---

## D. Was gemessen NICHT gewirkt hat

Wichtiger als die Treffer, damit die nächste Runde sie nicht wiederholt:

1. **4-ärer Heap-Pop mit entrollten Kind-Vergleichen.** Statt der Schleife über
   bis zu vier Kinder drei datenunabhängige Vergleiche. Gemessen **langsamer**:
   `priorityFlood` 57,1 → 61,3 ms. Verworfen.
2. **Software-Prefetch in `computeMFDArea`.** Die Schleife läuft über `order`,
   kennt ihre nächsten Zellindizes also lange im Voraus; ein Vorab-Lesen von
   `hf`/`area`/`h` mit Abstand 24 sollte die Latenz verstecken. Gemessen
   **langsamer**: 31,0 → 33,8 ms — die Out-of-Order-Maschine überlappt die
   Zugriffe bereits selbst. Verworfen.
3. **Array-Literale in Zell-Loops entrollen** (`for nb in [k-1, k+1, k-n, k+n]`
   in `wavePass`, `fillOxbows`, `plugOxbows`). Kein messbarer Unterschied — der
   Optimierer legt diese Literale auf den Stack. Verworfen (der Roh-Puffer-
   Umbau von `wavePass` blieb, der wirkte).
4. **`k / n` per Kehrwert-Multiplikation** (Granlund–Montgomery, exakte
   Ganzzahl-Arithmetik, also erlaubt) in `computeMFDArea`, `braidPass` und der
   Becken-Flutfüllung. A/B in einer Sitzung: kein belastbarer Unterschied
   (`computeMFDArea` 33,4 vs. 33,7 ms). Die Integer-Division steht offenbar
   nicht auf dem kritischen Pfad — die Out-of-Order-Maschine überlappt sie mit
   den Speicherzugriffen. Verworfen; `j = k/n; i = k − j*n` (EINE Division
   statt `%` und `/`) bleibt.
5. **`fillShallowPonds` und `updateRainWeight` auf Roh-Puffer.** Kein messbarer
   Gewinn (7,1 → 7,7 bzw. 4,2 → 4,2 ms) — beide sind von der
   Speicher-Latenz ihres Streu-Zugriffs bestimmt, nicht von der Prüfung.
   Verworfen zugunsten der einfacheren Fassung.

---

## E. Hypothese 3 des Issues: MFD-Update-Takt

Das Issue vermutet, `computeMFDArea` laufe nur deshalb jeden Schritt, weil
`braidingEnabled` das Intervall aushebelt. **Das trifft nicht zu:**
`SimConfig.mfdUpdateInterval` steht auf **1**, das Feld würde also auch ohne
Braiding jeden Schritt neu gebaut. Der Braiding-Zweig in `step()` ändert am
Produktions-Takt nichts.

Ein größeres Intervall wäre eine **Physik-Änderung** (Braiding liest `areaMFD`,
und `braidPass` wirkt auf `h`) und fällt damit aus dem Rahmen dieses Issues
(„bit-identisch"). Der Takt ist damit bewusst unangetastet; wer ihn verschieben
will, braucht eine eigene Kalibrier-Runde mit den Braiding-Wächtern.

---

## F. Wo der Rest steckt

Pass-Aufteilung nach dieser Runde (30 × dt = 100, Summe ~244 ms):

| Pass | ms/Schritt | Anteil |
|---|---:|---:|
| priorityFlood | 59,7 | 24,4 % |
| computeMFDArea | 31,5 | 12,8 % |
| outletIncision | 29,8 | 12,2 % |
| meanderStamp | 17,7 | 7,2 % |
| updateVegetation | 15,3 | 6,2 % |
| migrateMeander | 14,8 | 6,1 % |
| braidPass | 13,3 | 5,4 % |
| computeReceiversAndArea (2×) | 13,0 | 5,3 % |
| updateIce | 9,3 | 3,8 % |
| Hydraulic.erode (∝ dt) | 9,2 | 3,7 % |
| capEndorheicBasins | 8,0 | 3,3 % |
| fillShallowPonds | 7,6 | 3,1 % |
| Rest (14 Pässe) | 15,2 | 6,2 % |

Die drei Spitzenreiter sind serielle, `order`-getriebene Gitterpässe:

| Pass | warum er bleibt |
|---|---|
| priorityFlood | s. u. |
| computeMFDArea | seriell (Akkumulation stromab), Streu-Zugriff über `order` |
| outletIncision | seriell (Empfänger muss VOR der Zelle aktualisiert sein) |

**`priorityFlood` ist unter der Bit-Identitäts-Auflage praktisch ausgereizt.**
Gemessen (Instrumentierung des Heaps, 105 Floods): max. Heap-Größe 77 180
Einträge (1,2 MB), 929k Pushes je Flood, **1,17** Sift-Ebenen je Push und
**5,5** je Pop. Der Pass ist damit im Wesentlichen 692k × 5,5 Heap-Ebenen mit
Streu-Zugriff — Instruktions- und Latenz-gebunden, nicht durch Overhead
aufgebläht. Die bekannten Beschleunigungen sind allesamt
**Reihenfolge-ändernd** und deshalb hier ausgeschlossen:

- Priority-Flood + FIFO (Barnes et al., Alg. 2) verarbeitet gleich hohe Zellen
  in BFS- statt Heap-Reihenfolge,
- ein 8-ärer oder cache-ausgerichteter Heap ändert das Tie-Break zwischen
  gleichen Keys.

Beides ändert `order` und `floodParent` bei Gleichstand — und `order` bestimmt
die **Summationsreihenfolge** der Flächen-Akkumulation (`pa[r] += pa[k]`), also
die Rundung. Ein anderer Tie-Break ist damit keine „gleichwertige" Variante,
sondern eine andere Welt.

Dasselbe gilt für `computeMFDArea` und `outletIncision`: ihre Schleifen laufen
zwingend in `order`, jede Zelle greift auf 5–10 Felder an einer gestreuten
Adresse zu, und die Akkumulation ist eine echte Datenabhängigkeit. Was sich
ohne Reihenfolge-Änderung herausziehen ließ (die `pow`-Vorberechnung), ist
herausgezogen; Prefetch und der Wegfall der Integer-Division wurden gemessen
und brachten nichts (Abschnitt D).

### Was noch ginge — und was es kostet

1. **Bett-Funnel als Roh-Puffer-Variante** (`erodeCell`/`depositCell`).
   `meanderStamp` und `braidPass` müssen `h`/`sed`/`rock` heute über die
   Klassen-Property adressieren, weil ein Roh-Zeiger mit dem Funnel
   kollidierte; eine Zeiger-Fassung des Funnels (eine Implementierung, zwei
   Aufrufer — wie `mfdLocalExponent`) macht sie frei. Schätzung aus den
   Restzeiten: ~10 ms. Preis: der Funnel, der heute bewusst die EINE Stelle mit
   dem Gletscher-Gate ist, bekommt eine zweite Signatur.
2. **Sim-Schritt vom Render-Thread entkoppeln.** Ändert die Schrittkosten nicht,
   nimmt sie aber aus dem Frame — für die FPS der größte Hebel, und der
   einzige, der `priorityFlood` nicht anfassen muss.
3. **Bit-Identität aufgeben.** Priority-Flood + FIFO und ein
   cache-ausgerichteter Heap zusammen halbieren realistisch den größten Posten.
   Das ist eine Physik-Änderung mit eigener Kalibrier-Runde und gehört in ein
   eigenes Issue — nicht in dieses.

---

## G. Diagnose „49 → 18 FPS"

Aus den Messungen lässt sich der FPS-Einbruch direkt erklären, ohne Vermutung
über einzelne Merges:

1. **Der Sim-Schritt ist Fixkosten** (Abschnitt B): dt = 0,2 kostet dasselbe wie
   dt = 100. Im Echtzeit-Zeitraffer macht `Main.gd` pro Frame einen winzigen
   Zeitschritt — und zahlt trotzdem den vollen Schritt. Die Framerate ist damit
   direkt `1 / Schrittkosten`, nicht `1 / (Arbeit pro Jahr)`.
2. **Der Zuwachs kam aus Pässen, die nichts mit der Zeitschrittweite zu tun
   haben.** Im Baseline-Profil sind die drei größten Posten nach dem
   Priority-Flood `capEndorheicBasins` + `clearEndorheicBasins` (zusammen
   **25,4 %** des Schritts, Issue #11) und `applyUplift` (**6,9 %**) — alle drei
   reine Buchhaltung über das ganze Gitter, deren Kosten praktisch vollständig
   aus Klassen-Property-Overhead bestanden (Abschnitt C). Genau diese drei sind
   jetzt zusammen von 124,9 auf 11,4 ms gefallen.
3. **Die Gletscher-/Klima-Kette (#33/#35/#36)** kostet zusammen ~4 % und ist
   nicht der Haupttreiber.

Kurz: die FPS gingen nicht an „mehr Physik pro Jahr" verloren, sondern an
Fixkosten pro Schritt — und davon war der größte Teil kein Rechnen, sondern
Zugriffs-Overhead.

---

## H. Reproduktion

```sh
source ~/.local/share/swiftly/env.sh
export LD_LIBRARY_PATH="$(git rev-parse --show-toplevel)/.tools/swift-libs:${LD_LIBRARY_PATH:-}"
swift build -c release --package-path SimCore -Xswiftc -swift-version -Xswiftc 5

# Zeiten + Pass-Tabelle
SimCore/.build/release/simperf --repeat 3

# Bit-Identität gegen einen anderen Stand (gleiche Maschine!)
SimCore/.build/release/simperf --hash

# Baseline eines alten Stands in derselben Sitzung messen:
git stash -u
git checkout <ref> -- SimCore/Sources/SimCore/Terrain.swift
swift build -c release --package-path SimCore -Xswiftc -swift-version -Xswiftc 5
SimCore/.build/release/simperf --repeat 3
git checkout HEAD -- SimCore/Sources/SimCore/Terrain.swift
git stash pop
```

Der Umweg über `git checkout <ref> -- …/Terrain.swift` (statt eines kompletten
Checkouts) hält Harness und `SimProfile` im Baum — der alte `Terrain.swift`
setzt dann keine Marken, die Gesamtzeit stimmt trotzdem.
