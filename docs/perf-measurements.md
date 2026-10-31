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
swift build -c release --package-path SimCore

SimCore/.build/release/simperf                      # Zeiten + Pass-Tabelle, dt = 100
SimCore/.build/release/simperf --repeat 3           # drei Messblöcke (s. u.)
SimCore/.build/release/simperf --dt 0.2 --steps 200 # Echtzeit-Takt statt Sprung
SimCore/.build/release/simperf --hash               # Bit-Identitäts-Fingerabdruck
SimCore/.build/release/simperf --no-profile         # Gegenprobe ohne Instrumentierung
```

Der Harness fährt die **Produktions-Konfiguration** — seit Issue #97 den
benannten Wert `SimConfig.production` selbst (`SimConfig()` plus
`hydraulicSkipWaterSpawns` und `meanderSpatialCutoffIndex`) statt eines
Nachbaus der zwei Schalter —, Seed 1337, **100 Schritte à
100 Jahre Einlauf**, danach die Messschritte. Gemessen wird also der
eingeschwungene Zustand, nicht der Kaltstart.

**Produktions-Config ja, Produktions-Einlauf nein** — die eine bewusste
Abweichung: die Brücke generiert seit PR #106 mit
`settleYears: SimNode.generationSettleYears` (3000 Jahre echte Physik in
1000-Jahr-Chunks, Uhr danach zurück auf 0, dann die Startzustands-Doktrinen für
Seespiegel und Playa-Kruste). Der Harness lässt `settleYears` beim Default 0 und
läuft stattdessen über `--warmup` ein: 100 × 100 Jahre, also 10.000 Jahre und
damit weiter eingeschwungen als die Produktionswelt, nur über einen anderen
Pfad. Gespiegelt wird der Wert nicht — er würde die Messwelt und damit jede Zahl
in diesem Dokument samt `--hash`-Fingerabdruck erneut unvergleichbar machen,
während der Harness genau für Vorher/Nachher auf DERSELBEN Maschine da ist.
Folge fürs Debuggen: ein Fingerabdruck aus `--hash` und einer aus der Brücke
gehören zu zwei verschiedenen Welten und stimmen nie überein.

`n` und `world` sind dabei KEINE Literale im Harness, sondern die Werte aus
der Produktions-Config selbst — derzeit 720/112,4789. Als Literal hätte er nach dem
gemeinsamen Umstellen der Paarung (832/130 → 720/112,4789, Aug 2026) still die
alte, größere Welt weitergemessen, obwohl Kopfzeile und `--hash` die
Produktion behaupten. Jede Kopfzeile weist `n=` und `world=` deshalb zusammen
aus. Alle Messreihen unterhalb dieses Abschnitts stammen von VOR der
Umstellung; wer sie nachrechnet, setzt BEIDE Schalter:

```sh
SimCore/.build/release/simperf --n 832 --world 130 --repeat 3
```

Nur EINEN der beiden zu setzen lehnt der Harness ab (Exit 2, Hinweis auf
stderr). Die halb umgestellte Paarung — alte Auflösung, neue Weltgröße — ergäbe
eine Zellgröße, die weder das Spiel noch irgendeine Messreihe je gefahren hat,
und sähe in der Kopfzeile trotzdem plausibel aus.

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

Zum Zeitpunkt dieser Messreihe: FNV-1a über die Bit-Muster von `h`, `hf`,
`area`, `areaMFD`, `sed`, `veg`, `snow`, `ice` nach Einlauf + Messschritten.
(Seit Issue #78 hasht `--hash` stattdessen das komplette Zustands-Inventar via
`Terrain.fingerprint()`; der unten festgehaltene Wert stammt vom alten
8-Felder-Hash und ist mit heutigen Ausgaben nicht vergleichbar.) **Jede**
Optimierung dieser Runde wurde damit geprüft; der Wert ist über die gesamte
Serie konstant:

```sh
SimCore/.build/release/simperf --hash --n 832 --world 130
```

```
n=832 world=130.0 seed=1337 warmup=100x100.0 steps=30x100.0
fingerprint b145f5ba674c23d9
```

Die beiden Schalter gehören zum Wert dazu: die Serie lief auf der Paarung
832/130, der Standard des Harness ist seit August 2026 die Produktions-Paarung
720/112,4789 (s. o.). Ohne sie rechnet `--hash` eine ANDERE Welt und meldet eine
Abweichung, wo keine Physik-Änderung ist.

Er ist maschinen-spezifisch (System-libm, s. AGENTS.md) — verglichen wird immer
auf DERSELBEN Maschine, vor und nach der Änderung.

**Zweiter Bruch der Vergleichbarkeit (September 2026):** der Harness generierte
die Messwelt ZWEIMAL — `Terrain(config:seed:)` generiert schon selbst, danach
stand noch ein `terrain.generate(seed:)`. `generate` leert `veg` nicht (der
Sukzessions-Pass liest über den Samen-Druck das vorhandene Feld, gepinnt in
`TerrainAPITests.testGenerateResetsAnAgedTerrain`), der zweite Lauf startete
also mit dem Samen-Druck des ersten. Gemessen wurde damit eine Vegetation, die
keine frisch generierte Produktionswelt hat — und `veg` hängt über `vegDamp` an
der Erosion. Der Aufruf ist weg; Fingerabdrücke und Zeiten von davor sind mit
heutigen nicht vergleichbar.

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

**dt = 0,2 kostet praktisch dasselbe wie dt = 100** (368,6 vs. 374,2 ms; in der
Abschluss-Sitzung 400,4 vs. 426,1 ms — dasselbe Bild). Genau
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
   → **In Runde 3 gemacht** (Abschnitt I): als `Terrain.Bed` plus zweite
   Signatur des Funnels, gemessen −3,3 ms. Aus den „zwei Aufrufern, eine
   Implementierung" wurden dabei allerdings zwei Implementierungen; Issue #81
   hat das zurückgedreht, ohne Laufzeit zu kosten (Abschnitt K).
2. **Sim-Schritt vom Render-Thread entkoppeln.** Ändert die Schrittkosten nicht,
   nimmt sie aber aus dem Frame — für die FPS der größte Hebel, und der
   einzige, der `priorityFlood` nicht anfassen muss.
   → **Im Oktober 2026 für den Zeitraffer gemacht** (Abschnitt L): Schritt und
   Frame-Aufbereitung laufen auf einem Hintergrund-Thread, bit-identisch.
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
swift build -c release --package-path SimCore

# Zeiten + Pass-Tabelle
SimCore/.build/release/simperf --repeat 3

# Bit-Identität gegen einen anderen Stand (gleiche Maschine!)
SimCore/.build/release/simperf --hash

# Baseline eines alten Stands in derselben Sitzung messen:
git stash -u
git checkout <ref> -- SimCore/Sources/SimCore/Terrain.swift
swift build -c release --package-path SimCore
SimCore/.build/release/simperf --repeat 3
git checkout HEAD -- SimCore/Sources/SimCore/Terrain.swift
git stash pop
```

Der Umweg über `git checkout <ref> -- …/Terrain.swift` (statt eines kompletten
Checkouts) hält Harness und `SimProfile` im Baum — der alte `Terrain.swift`
setzt dann keine Marken, die Gesamtzeit stimmt trotzdem.

---

## I. Runde 3 (August 2026) — 71,9 → 64,0 ms/Schritt, bit-identisch

Anlass: „die Performance ist immer noch nicht gut genug", Ziel −10 %.
Gemessen und geschraubt wurde diesmal auf einem **Apple-Silicon-Mac**, nicht auf
der Linux-VM der Abschnitte B–G — die absoluten Zahlen sind deshalb NICHT mit
denen dort vergleichbar, die Anteile schon.

### Messhygiene (Lehre dieser Runde)

Der Rechner lief unter Fremdlast (mehrere Agenten-Sitzungen, Lastmittel > 10).
Ein einzelner Vorher/Nachher-Lauf war damit wertlos: dieselbe Binärdatei streute
zwischen 69 und 108 ms, und eine Änderung wurde einmal als „langsamer"
verworfen, die tatsächlich half. Belastbar war erst dieses Verfahren:

1. beide Stände als **eigene Binärdateien** ablegen (`simperf.base`, `simperf.neu`),
2. **abwechselnd** messen (base, neu, base, neu …), je `--repeat 3`,
3. über 5 Paare vergleichen, Minimum UND Median ansehen.

Für einen einzelnen Pass ist die Pass-Tabelle das schärfere Werkzeug als die
Gesamtzeit: Fremdlast hebt alle Pässe gleichmäßig an, ein echter Gewinn zeigt
sich nur in der einen Zeile.

### Ergebnis

| | base | Runde 3 |
|---|---:|---:|
| ms/Schritt (Median aus 5 Paaren) | 71,9 | **64,0** |
| ms/Schritt (Minimum) | 71,6 | 63,8 |

**−11,0 %**, `simperf --hash` vor und nach der Runde identisch
(`330d5a1874eacd67`) — also bit-identische Physik.

Pass-Tabelle (derselbe Messblock, ms/Schritt):

| Pass | base | Runde 3 | |
|---|---:|---:|---|
| priorityFlood | 24,07 | 20,57 | Turnier-Auswahl im Heap-Pop |
| computeMFDArea | 11,28 | 9,99 | Division nach Vorzeichen-Test, fastmod |
| outletIncision | 6,14 | 5,40 | `area`-Zugriff nur bei `minAreaCells > 0` |
| meanderStamp | 4,69 | 2,92 | `Bed`-Sicht statt Klassen-Property |
| capEndorheicBasins | 3,11 | 2,84 | (Mitnahme) |
| braidPass | 2,97 | 2,21 | `Bed`-Sicht |
| fillShallowPonds | 2,65 | 1,29 | Roh-Puffer statt Klassen-Property |

### Was gewirkt hat

1. **`Terrain.Bed` — Roh-Puffer-Sicht auf `h`/`sed`/`rock` plus Eis-Maske**
   (−3,3 ms). Das Sample-Profil zeigte **4,5 % des Schritts in der
   Swift-Laufzeit selbst** (`swift_beginAccess`, `AccessSet::insert`,
   `SwiftTLSContext::get`, `swift_isUniquelyReferenced`) — reine
   Exklusivitäts- und COW-Buchhaltung. Sie steckte fast vollständig in
   `meanderStamp`, `fillShallowPonds`, `fillOxbows` und `braidPass`, also genau
   in den Pässen, die das Bett über die Klassen-Property adressieren mussten.
   Der Funnel `erodeCell`/`depositCell` hat dafür eine zweite Signatur bekommen
   (Abschnitt F, Punkt 1) — die zweite ausgeschriebene REGEL, die dabei
   entstand, war dagegen nie gemessen und ist seit Issue #81 wieder weg
   (Abschnitt K); `meanderStamp` ruft daneben `Terrain.bilinear` direkt
   auf demselben Zeiger, weil `bilinearH` `h` sonst ein zweites Mal öffnen würde.
   Mitgenommen: die `[k-1, k+1, k-n, k+n]`-Array-Literale in `fillOxbows` und
   `plugOxbows` waren eine Allokation JE Altarm-Knoten.
2. **Turnier statt serieller Kind-Abtastung im 4-ären Heap** (−3,5 ms auf
   `priorityFlood`, der größte Einzelposten der Runde). Die alte Schleife über
   die vier Kinder war eine reine Abhängigkeitskette aus drei Vergleichen; das
   Turnier (zwei Paare, dann das Finale) ist zwei Ebenen tief und lädt die vier
   Keys unabhängig. Weil alle Vergleiche strikt (`<`) bleiben, gewinnt bei
   Gleichstand weiterhin der kleinste Index — die Pop-Reihenfolge und damit
   `order` sind unverändert. **Das ist der Unterschied zu den in Abschnitt F
   ausgeschlossenen Heap-Varianten**: ein 8-ärer Heap ändert die STRUKTUR, das
   Turnier nur die Auswertungs-Reihenfolge derselben Vergleiche.
3. **Cache-Zeilen-Ausrichtung der Kindergruppe** (−0,3 ms). Die vier Kinder von
   `i` liegen auf 4i+1 … 4i+4, also auf Byte-Offset 64·i+16 — sie überspannten
   immer zwei Cache-Zeilen. Drei Einträge Vorlauf schieben sie auf 64·i+64.
   Ebenfalls reine Adress-Verschiebung, die Indizes bleiben dieselben.
4. **Division erst nach dem Vorzeichen-Test** in `computeMFDArea`,
   `computeReceiversAndArea` und `braidPass` (−0,6 ms). `s = (h − h_nb)/dist`
   mit `dist > 0` hat das Vorzeichen des Zählers; höhere Nachbarn (die Mehrzahl)
   brauchen die Fließkomma-Division also gar nicht. Der `s > 0`-Test bleibt für
   den theoretischen Unterlauf stehen.
5. **`fastmod` für den Spaltenindex in `computeMFDArea`** (−0,3 ms).
   `k / nn` ist eine Division auf einem LAUFZEIT-Divisor, die der Compiler nicht
   drehen kann; Lemires Verfahren macht daraus zwei Multiplikationen. Nur die
   Randzellen rechnen noch mit `/`.
6. **Kleinkram** (zusammen ~0,3 ms): `rainWeight.max()` in `Hydraulic.erode` lief
   über den generischen Sequence-Pfad über 692k Zellen; `outletIncision` lud
   `area[k]` für alle 692k Zellen, obwohl der Vergleich bei `minAreaCells = 0`
   (dem Produktionsfall) nie zutreffen kann.

### Was gemessen NICHT gewirkt hat

- **Software-Prefetch in `computeMFDArea`** (Vorablesen von `hf`/`h`/`areaMFD`
  24 Iterationen voraus, über eine Senke gegen Wegoptimierung gesichert):
  10,8 → 11,3 ms. Die Schleife ist nicht so latenz-gebunden, wie sie aussieht;
  die zusätzlichen Ladebefehle kosten mehr, als das Vorablesen einspart.
- **Sortier-Schlüssel (Höhe, Zelle) inline in `capEndorheicBasins`** statt des
  Nachschlagens im Höhenfeld je Vergleich: 2,99 → 3,08 ms. Der Aufbau des
  Schlüssel-Arrays und die dickeren Elemente im Merge fressen den Gewinn.
- **`landHeightQuantiles` auf Roh-Puffern**: 65,0 → 65,4 ms. Die
  Array-Iteration mit `where` ist hier schon optimal; eine von außen
  eingefangene Zählvariable macht es zusätzlich schlechter (sie landet auf dem
  Stack statt im Register).

### Wo der Rest jetzt steckt

`priorityFlood` bleibt mit 31 % der größte Posten und ist nach dem Turnier im
Wesentlichen die Latenz von 5,5 Heap-Ebenen je Pop. Alles Weitere dort ändert
die Reihenfolge (Abschnitt F) und braucht eine Kalibrier-Freigabe.
`computeMFDArea` (15 %) ist ein gestreuter Akkumulations-Pass in `order` mit
echter Datenabhängigkeit — dieselbe Lage wie in Runde 2.

## J. Wasser-Schwanzstufen auf die GPU (August 2026) — gebaut, gemessen, nicht eingeschaltet

Frage: `waterFieldBytes` kostet 14,4 ms je Aufruf. Wie viel davon kann die GPU
übernehmen, ohne die Physik zu berühren (Render-Ableitung, laut AGENTS.md
erlaubt)?

**Antwort auf die Form des Passes, nicht auf die Kosten.** Der Pass ist eine
*Graph*-Pipeline, keine Pixel-Pipeline. Zwei seiner Stufen sind sequenziell und
passen in kein Pixel-Programm:

1. die Kontinuitäts-Kette entlang der D8-Empfänger (Pointer-Chasing mit
   datenabhängigem `break`),
2. der Flood-Fill der Wasser-Komponenten für den Kohärenz-Fade.

Sie liegen in der MITTE der Kette. Die parallelen Stufen davor und dazwischen
(Stream-Intensität, dreifache Verbreiterung) wären GPU-fähig, aber sie
herüberzuholen bräuchte drei Readbacks je Tick — jeder ein GPU-Sync im Frame.
Ohne Round-Trip bleibt genau der SCHWANZ: räumlicher Blur, zeitliche EWMA,
Quantisierung.

### Gemessen (n = 832, M4 Max)

Standalone-Benchmark der Schwanzstufen (nachgebaute Schleifen, dichte
Zufallsdaten) sagte 4,3 ms vorher:

| Stufe | ms |
| --- | --- |
| `blurMax(sd, 1)` | 1,36 |
| `blurMax(lk, 2)` | 2,52 |
| EWMA + Packen | 0,44 |

In situ (`game/tests/sculpt_cost.gd`, echte Felder, bester von drei Läufen)
kam davon weniger an — die echten Felder sind spärlich und liegen warm im Cache:

| Aufruf | ms |
| --- | --- |
| `waterFieldBytes(1.0)` | 14,81 |
| `waterFieldRawBytes` (ohne Schwanz) | 12,98 |
| **Ersparnis** | **1,83** |

### Bildraten-Gegenprobe: nichts

`RS_FPS`, interleaved (Lehre aus Runde 3), n = 832, `balanced`:

| Runde | GPU-Kette | CPU-Pfad |
| --- | --- | --- |
| 1 | 67,92 | 69,29 |
| 2 | 71,21 | 68,39 |

Die Streuung innerhalb einer Variante (3,3 FPS) ist größer als der Unterschied
zwischen den Varianten. Erwartbar: im Zeitraffer laufen die Overlays nur alle
~0,5 s, 1,8 ms davon sind ~0,4 % der Wanduhr. Bezahlt würde es mit drei
zusätzlichen 832²-Pässen und 22 MB Targets auf einer GPU, die im Zeitraffer
nicht der leerlaufende Teil ist.

### Was der Umbau trotzdem belegt

- Der GPU-Pfad ist **korrekt**: Bildvergleich gegen den CPU-Pfad 1,09 von 255
  mittlerer Abweichung (gegen das vertikal gespiegelte Bild 35,87 — keine
  Y-Spiegelung, Viewport-Reihenfolge stimmt).
- Der CPU-Pfad ist **unverändert**: `render_fingerprint.gd` bit-identisch gegen
  den Stand vor der Änderung (gleiche Maschine, beide Libraries in derselben
  Sitzung gebaut).
- Die Kalibrierung wandert NICHT in den Shader: alle Schwellen des Wasserfelds
  bleiben im getesteten Vertrag `SimCore.WaterRender` und wirken CPU-seitig,
  bevor das Feld entsteht. Die beiden neuen Shader enthalten keine
  Kalibrier-Zahl.

Deshalb steht `water_gpu` in `Main.gd` auf `false`; `RS_WATER_GPU=1` schaltet
ein. Aufheben lohnt, wenn eine Maschine mit schwacher CPU und freier GPU
dazukommt — die iPad-Frage ist genau dieser Fall.

### Reproduktion

```sh
GODOT=…   # 4.7.2
"$GODOT" --headless --path game --script res://tests/sculpt_cost.gd   # Kostenaufschlüsselung
RS_FPS=1 RS_WATER_GPU=1 "$GODOT" --path game                          # Bildrate GPU-Kette
RS_FPS=1 "$GODOT" --path game                                         # Bildrate CPU-Pfad
RS_STEP=20000 RS_DIST=90 RS_SHOT=/tmp/gpu.png RS_WATER_GPU=1 "$GODOT" --path game
RS_STEP=20000 RS_DIST=90 RS_SHOT=/tmp/cpu.png "$GODOT" --path game    # Bildvergleich
```

### Deckung seit Issue #95 (Oktober 2026)

Seit #95 ist der Pass-Plan (Pass-Zahlen, Kanal-Masken, Priming) ein Datum aus
`SimRender.WaterTailPlan` — dieselbe Quelle, aus der der CPU-Pfad seine
Pass-Zahlen nimmt — und der Vertragstest `game/tests/water_gpu_tail.gd` vergleicht
beide Fassungen Zelle für Zelle (in CI mit echtem Renderer über xvfb + llvmpipe,
`GODOT_TEST_RENDER=1`; headless überspringt er den GPU-Teil mit Meldung).
Messwerte des CI-Laufs vom 2026-10-24 (ubuntu-22.04-Runner, llvmpipe, n = 720,
Standard-Seed, settled + 6 Zeitraffer-Takte à 1000 Jahre, Blende 0.15):

| Vergleich | max (255tel) | Mittel (255tel) | Grenze max/Mittel |
| --- | --- | --- | --- |
| CPU-Schwanz gegen GPU-Kette (Endzustand, alle 4 Kanäle) | 1,33 | 0,07 | 4 / 2 |
| Priming: erster Takt mit Zeitraffer-Blende ≡ erster Takt mit Blende 1.0 | 0,50 | 0,02 | 4 / 2 |
| Frame-Kadenz 4 gegen 10 Frames je Update (EWMA) | 0,50 | 0,06 | 1 / 1 |

Einordnung: Die Toleranz (Begründung am Test) ist die Summe aus der einseitigen
`byte01`-Abkappung (≤ 1/255, auf beiden Seiten — das GPU-Rohfeld ist bereits
quantisiert, die CPU quantisiert erst am Ende), der durch Blur (Konvex), max
(monoton) und EWMA (konvex) nicht vergrößerten Rohfeld-Quantisierung und der
Half-Float-Auflösung des Zustands (≈ 0,12/255 je Schritt). Die gemessene
Abweichung bleibt deutlich darunter und stimmt mit dem älteren in-situ
Bildvergleich überein (1,09/255 mittlere Abweichung, M4 Max): die Kette ist
zur Deckung gebracht, der Schalter bleibt aus den Messgründen oben trotzdem aus.
Der Kadenz-Vergleich bestätigt die Framerate-Unabhängigkeit der EWMA: sie tickt
mit dem Textur-Update (`UPDATE_ONCE` je `update()`), nicht mit dem Frame.

Reproduktion des Deckungsvergleichs:

```sh
GODOT_TEST_RENDER=1 scripts/godot-test.sh res://tests/water_gpu_tail.gd WATER_GPU_TAIL_OK
```

---

## K. Ein Funnel statt zweier Fassungen (August 2026, Issue #81) — kostenlos

Anlass: die Perf-Runde 3 (Abschnitt I) hat dem Bett-Funnel
`erodeCell`/`depositCell` eine zweite Signatur auf der Roh-Puffer-Sicht
`Terrain.Bed` gegeben. Beide Fassungen schrieben die Regel aus — erst Sediment,
dann Fels, `h = rock + sed`, unter Eis gar nichts — und wurden nur durch einen
Kommentar synchron gehalten („wer eine ändert, ändert beide"). Frage dieser
Runde: **braucht die zweite AUSSCHREIBUNG eine Messung, oder reicht die zweite
SIGNATUR?**

### Was §I bestätigt und was es nicht trägt

Bestätigt: die `Bed`-**Sicht** in den Hot-Loops ist der gemessene Gewinn
(−3,3 ms, `meanderStamp` 4,69 → 2,92, `braidPass` 2,97 → 2,21). Daran ändert
diese Runde nichts — `meanderStamp`, `braidPass`, `fillOxbows` und `plugOxbows`
öffnen die Sicht weiterhin EINMAL je Pass und reichen sie durch.
(`fillShallowPonds` steht in §I daneben, benutzt aber eigene Roh-Puffer statt
`Bed` und rührt den Funnel nicht an.)

Nicht getragen hat §I dagegen die zweite ausgeschriebene Regel. Die
Property-Fassung hat genau zwei Aufrufer, und **keiner davon läuft in der
Produktion**:

| Aufrufer | Läuft wann |
|---|---|
| `transportLimited` | nur im Nicht-Droplet-Zweig (`hydraulicEnabled = false`), reiner Testpfad |
| `floodplainAggradation` | geparkt (`floodplainEnabled = false`) — und der Aufruf steht INNERHALB des `hydraulicEnabled`-Zweigs, braucht also zusätzlich `hydraulicEnabled = true` |

Die zweite Zeile ist keine Fußnote: die beiden Aufrufer liegen in
**gegenläufigen** Zweigen von `step()`. Keine einzelne Konfiguration fährt
beide, ein einzelner Beleglauf deckt also immer nur einen ab — s. den
Fingerprint-Abschnitt unten, der genau daran zuerst gescheitert ist.

Damit kann das Öffnen der Sicht je Aufruf (`withBed { … }`) im Produktions-
Schritt gar nichts kosten. Seit dieser Runde ist die Property-Fassung ein
dünner Adapter, und Regel plus Gletscher-Gate stehen genau einmal.

### Gemessen

Interleaved nach der Hygiene aus §I (eigene Binärdateien `simperf.base` /
`simperf.neu`, abwechselnd, je `--repeat 3`, 5 Paare), Linux-VM, 4 Kerne,
Lastmittel 0,7 — also NICHT mit den Apple-Silicon-Zahlen aus §I vergleichbar,
nur base gegen neu:

| ms/Schritt | base | Adapter |
|---|---:|---:|
| Median aus 5 Paaren | 162,2 | 161,5 |
| Minimum | 158,7 | 158,0 |

**Kein Unterschied** — die 0,4 % liegen unter der Streuung der Einzelblöcke
(base streute 158,7 … 170,7). Erwartungsgemäß: der Produktionspfad ruft die
geänderte Fassung nicht auf.

### Bit-Identität — und warum `simperf --hash` allein sie nicht belegt

`simperf --hash` vor und nach der Änderung identisch: `8a785727acabcd51`.
Das ist die halbe Antwort, und die unwichtigere. `simperf` fährt `SimConfig()`,
also den Produktionspfad — und der ruft die geänderte Fassung gar nicht auf
(`hydraulicEnabled = true` heißt Droplet statt `transportLimited`,
`floodplainEnabled = false` heißt keine Aggradation). Sein Fingerprint KONNTE
sich nicht ändern; er belegt „die Produktion ist nicht aus Versehen
mitgewandert", nicht „der Umbau ist bit-neutral".

Der eigentliche Beleg gehört auf die Konfigurationen, in denen die zwei
Aufrufer laufen — **Plural**, und das war der erste Fehlversuch dieser Runde:
ein Lauf mit `hydraulicEnabled = false, floodplainEnabled = true` sieht nach
„beide an" aus, fährt aber nur `transportLimited`, weil der
`floodplainAggradation`-Aufruf im abgeschalteten Zweig liegt (gemessen: 40
Aufrufe `transportLimited`, 0 Aufrufe `floodplainAggradation`). Die zwei
Aufrufer brauchen zwei Läufe.

Werkzeug: `BedFunnelTests.testChangedPathFingerprintDiagnostic` (gegatet wie
jeder Messlauf, `RS_MEASURE=1`), n = 96, Seed 1337, 20.000 Jahre, darüber
`Terrain.fingerprint()` — derselbe volle State-Fingerprint aus Issue #78:

| Stand | Arm `transportLimited`<br>(`hydraulicEnabled = false`) | Arm `floodplainAggradation`<br>(`hydraulicEnabled = true`) |
|---|---|---|
| base (zwei ausgeschriebene Regeln) | `fb91725969f21a54` | `64d89c0982691f03` |
| Adapter | `fb91725969f21a54` | `64d89c0982691f03` |
| Gegenprobe: NUR der Adapter sabotiert | `464edcd82603df0c` | `3c9bb7c23b50f5ac` |

Die dritte Zeile ist der Grund, den ersten beiden zu glauben. Sabotiert wurde
dafür **nur der Adapter** (Regel zurück-inlined, Eis-Gate weg), nicht die
Bed-Fassung: eine Änderung an der Bed-Fassung würde auch über `meanderStamp`
und `braidPass` durchschlagen und damit gar nicht zeigen, dass der ADAPTER-Weg
am Ergebnis beteiligt ist. Beide Arme wandern — beide Aufrufer laufen also
wirklich durch die geänderte Stelle.

Alle Zahlen sind MESSWERTE dieser Maschine, keine Erwartungen: der Fingerprint
ist ein Pro-Maschine-Vergleich (System-libm), und genau deshalb liegt nirgends
im Repo ein Sollwert (AGENTS.md, „Laufzeit messen").

Für den Testpfad, den es wirklich betrifft (`transportLimited` läuft dort
wirklich und öffnet die Sicht jetzt je Aufruf), ist die SimCore-Pflichtsuite
das Maß — 269 Tests, gleiche VM, nacheinander gelaufen:

| Lauf | Suite-Zeit |
|---|---:|
| base | 363,9 s |
| Adapter, Lauf 1 | 367,7 s |
| Adapter, Lauf 2 | 349,0 s |

**base ist hier nicht `origin/main`**, sondern der Stand mit dem Wächter und
den zwei ausgeschriebenen Regeln (Commit „test(sim): pin bed funnel parity");
getauscht wurde genau eine Datei, `Terrain.swift`. Anders ginge es nicht: gegen
ein `Terrain.swift` von vor dem Wächter compiliert `BedFunnel.swift` nicht,
und ein Vergleich mit unterschiedlichem Testbestand misst den Testbestand. So
fahren alle drei Läufe denselben Bestand: 269 Tests, davon 29 übersprungene
Messläufe.

Die beiden Adapter-Läufe klammern den base-Lauf ein — **kein Signal über dem
Rauschen dieser geteilten VM**. Der erste Lauf allein hätte „+1 %" gesagt; das
ist genau der Fehlschluss, vor dem §I warnt. Alle drei liegen deutlich unter
dem 15-min-Budget aus `docs/ci-measurements.md`.

### Wächter statt Kommentar

`SimCoreTests/BedFunnel.swift` prüft beide Aufruf-Formen über eine Matrix aus
Bett-Zuständen und Beträgen auf bit-gleiche Rückgabe und bit-gleiche
`h`/`sed`/`rock`, mit und ohne `underIce`, und pinnt zusätzlich die Regel
selbst — sonst bliebe die Parität grün, wenn beide Formen gemeinsam abdriften.
Gegenprobe beim Bau: das Gate aus der Property-Fassung entfernt →
`testErodeParityUnderIce` rot; den Sediment-Anteil halbiert → beide
Erosions-Paritäten rot.

### Reproduktion

```sh
swift build -c release --package-path SimCore
cp SimCore/.build/release/simperf /tmp/simperf.base    # bzw. .neu, je Stand
for i in 1 2 3 4 5; do for b in base neu; do /tmp/simperf.$b --repeat 3; done; done
/tmp/simperf.base --hash && /tmp/simperf.neu --hash    # Produktionspfad unberührt

# Der Beleg für den GEÄNDERTEN Pfad — je Stand einmal, Werte vergleichen:
RS_MEASURE=1 swift test -c release --package-path SimCore \
    --filter testChangedPathFingerprintDiagnostic
```

---

## L. Zeitraffer ohne Warten: Sim-Schritt im Hintergrund (Oktober 2026)

Befund (Integrationsstand #174, `0fec08b`): im Zeitraffer rief `Main.gd` alle
`SIM_TICK_SECONDS` (0,25 s) SYNCHRON `sim.step(years)` und danach
`sim.renderFrame(FRAME_TIMELAPSE)` auf. Headless gemessen (M4 Max, Seed 1337,
Produktionswelt nach 20.000 Jahren, n = 720, je 5 Wiederholungen):
`step` 47–57 ms, `renderFrame` mit Overlays und Band-Bau 31–37 ms. Jeder
Takt-Frame dauerte damit 70–120 ms, viermal je Sekunde ein Ruckler; die
Zielbild-Messung (`docs/zielbild-measurements.md`, Punkt 47) fand im Zeitraffer
p95 bis 79 ms gegen ≤ 30 ms in Standbild und Kamerafahrt. §F Punkt 2 hatte
genau das als größten Hebel benannt: die Schrittkosten bleiben, aber nicht mehr
im Frame.

### Entwurf

- **`SimRender.BackgroundJob<Output>`** ist die ganze Nebenläufigkeit:
  höchstens EIN Job, ein Ergebnis-Platz, ein Besitzer-Thread. `isReady`
  blockiert nie; `wait`/`take` blockieren, solange der Job rechnet, und zählen
  diese Zeit (`waits`, `waitedSeconds`); `start` startet nichts, solange ein
  Ergebnis noch nicht abgeholt ist (sonst ginge etwa ein Band-Bau verloren, den
  `RenderState` schon für ausgeliefert hält). Godot-frei, damit der Vertrag
  headless prüfbar bleibt.
- **`SimNode.beginStep(years, trigger, now)`** startet den Job: `terrain.step`,
  `render.invalidate(.advanced)`, `render.frame(trigger, now)` und das
  Verpacken ins Frame-Dictionary (`packFrame`). Die Packed-Arrays entstehen auf
  dem Arbeits-Thread; es sind Godots eingebaute Werttypen, kein `Object`.
  Abholen: `stepReady()` (blockiert nie), `finishStep()`. Messgröße:
  `stepWaitMilliseconds()`.
- **Tore statt Disziplin:** `terrain` und `render` sind in `SimNode` berechnete
  Properties, die zuerst `job.wait()` rufen. Jeder Aufruf der Brücke kommt nur
  über sie an Welt und Render-Zustand; die gespeicherten Felder `world` und
  `renderState` nennt allein `beginStep`, nachdem es geprüft hat, dass kein Job
  unterwegs ist. Ein gleichzeitiger Zugriff ist damit ausgeschlossen, ohne dass
  ein Aufruf daran denken muss; `deinit` wartet einen laufenden Job ab (beim
  Beenden entlädt Godot sonst die Library unter ihm).
- **Der Frame trägt den ganzen gezeigten Stand:** `trigger`, `year`, `heights`
  immer, mit Overlays zusätzlich `filled` (Seespiegel) und `bands`
  (Höhenbänder), nach einem Band-Bau das Mesh. Für einen Frame fragt der
  Hauptthread die Sim nichts mehr; `renderFrame` liefert dasselbe Dictionary
  synchron.
- **`Main.gd`:** `_process` holt einen fertigen Schritt ab (`stepReady` →
  `finishStep` → `_apply_step`) und beginnt den nächsten, wenn der Takt fällig
  UND keiner unterwegs ist. Takt (0,25 s), Jahresdeckel (240), Overlay-Drossel
  (0,30 s), Band-Deckel (1 Hz) und alle Überblenden sind unverändert.

Verworfen: Godots `WorkerThreadPool` aus GDScript. Dann riefe ein Fremd-Thread
Methoden eines `Node` im Szenenbaum, und die Ausschlussregel stünde als
Disziplin im Skript statt im Typ; prüfen ließe sie sich nur mit laufender
Engine.

### Synchronisationsregeln je Pfad

| Pfad in `Main.gd` | Regel |
| --- | --- |
| Zeitraffer-Takt | beginnt nur ohne Schritt unterwegs, abgeholt wird nur ein fertiger (`stepReady`); der Hauptthread wartet nie |
| Pinselstrich | wartet nicht: solange ein Schritt rechnet, setzt der Strich aus, bis das Abholen ihn hochgeladen hat; während des Strichs beginnen keine Schritte (`_simulation_should_step`, wie bisher) |
| Pinsel-Nachzug, Strich-Ende | `_settle_sim()`, dann synchron wie bisher |
| Zeitsprung | `_settle_sim()` vor jedem Chunk (zwischen zwei Chunks läuft `_process`), Chunks synchron wie bisher |
| Neu, Laden, Speichern | `_settle_sim()` zuerst; gespeichert wird der Stand, den man sieht |
| Diagnose | der Takt-Refresh (1 s) läuft nur in Frames ohne Schritt unterwegs (Kennzahlen 2,3 ms); Δ-Karte und Referenz setzen `_settle_sim()` |
| Kamera-Presets F1–F3 | `_settle_sim()` (Abfluss und Empfänger kommen aus der Sim) |
| Raycast, Höhen-Cache, Pinselkuppel, Jahresanzeige, Detailstärke | lesen den GEZEIGTEN Stand (`shown_heights`, `shown_year`) und fragen die Sim nicht |
| synchroner Frame (`_render_frame`) | `_settle_sim()` zuerst |
| Leerlauf-Drossel | ein Schritt unterwegs zählt als Aktivität |
| ein vergessener Pfad | die Brücke wartet selbst (Tor): kein Datenrennen. Das Ergebnis bliebe aber liegen und käme NACH dem neueren Stand an, deshalb der Quelltext-Wächter auf `Main.gd` |

`_settle_sim()` wartet einen laufenden Schritt ab UND lädt ihn hoch. Nur
abwarten genügt nicht: das Ergebnis enthält Bänder und Wasser, die `RenderState`
ab dann für sichtbar hält.

### Determinismus

- Die Physik ist nicht berührt (`SimCore/Sources/SimCore` unverändert,
  `simperf --hash` damit gleich).
- Hintergrund = synchron, headless: `BackgroundJobTests.
  testBackgroundStepsAreBitIdenticalToSynchronousSteps` fährt sechs
  Zeitraffer-Schritte (15–240 Jahre, ein Pinselstrich dazwischen) synchron und
  über den Job; Fingerabdruck der Welt, alle Overlay-Puffer und das Band-Mesh
  sind je Schritt bit-gleich.
- Durch die Brücke, alter gegen neuen Stand: 14 Zeitraffer-Takte (Seed 1337,
  Produktionswelt + 5.000 Jahre, 15 Jahre je Takt, feste Uhr), alter Build
  `step` + `renderFrame`, neuer `beginStep` + `finishStep`. SHA-256 von Höhe,
  Wasser, Farbe, Material, Bodenbedeckung, Rinnen, Schutz- und Waldmaske,
  Sedimentfahne je Takt sowie das Band-Mesh am Ende: 14 von 14 gleich.
- `game/tests/smoke.gd` prüft dasselbe gegen die geladene Welt (Jahr, Höhe,
  Seespiegel, Wasser) auf jedem CI-Lauf.

### Was auf dem Hauptthread bleibt

Je abgeholtem Schritt nur noch Hochladen. Aufgeschlüsselt mit Zeitmarken in
`_apply_frame` (einmaliger Lauf, nicht eingecheckt; Seed 1337, 20.000 Jahre,
`balanced`, maximiert 3456 × 2104, 33 Schritte):

| Teil | ms je Schritt | Takt |
| --- | ---: | --- |
| Höhe (R32F, Vorgänger + neu) | 0,35–0,48 | jeder Schritt |
| Band-Mesh (`add_surface_from_arrays`) | 0,38–0,51 | ≤ 1 Hz |
| Seespiegel, Höhenbänder, Farbe, Material, Bodenbedeckung, Rinnen | 1,2–1,5 | Overlay-Takt (jeder 2. Schritt) |
| Wasser + Schutzmaske | 0,32–0,40 | Overlay-Takt |
| Waldmaske | 0,08–0,11 | Overlay-Takt |
| Sedimentfahne samt Mip-Kette | 0,50–0,66 | Overlay-Takt |
| Relief-Back (nur der Auftrag, die GPU zeichnet ihn) | 0,02 | jeder Schritt |
| **Summe** | **0,4–3,7** | |

Das gefährdet das 33,3-ms-Budget nicht, ein Verteilen der Uploads über
mehrere Frames lohnt deshalb nicht. Die A/B-Läufe unten bestätigen es: der
Median der Hochlade-Zeit liegt bei 2,4–2,9 ms, ihr Maximum bei 5–8 ms
(`apply_median_ms`/`apply_max_ms`), und die längsten Frames sind nicht die mit
Hochladen (`apply_frame_max_ms` < `max_ms`). Die Hälfte der Overlay-Bytes lädt
`FieldTexture` übrigens nur hoch, um den Vorgängerstand der Überblende (#172)
erneut zu senden; Tauschen statt Kopieren halbierte das, CPU-seitig sind es
aber nur ~1 ms (s. Offene Punkte).

### Gemessen: Frame-Zeiten im Zeitraffer

M4-Max-Referenz-Mac (16 Kerne, 64 GB), offizielles Godot 4.7.2, eingebauter
Bildschirm, maximiert, Viewport 3456 × 2104, `balanced`, Flusstal-Bühne im
Betrieb `simulation` (Seed 1337 nach 20.000 Jahren, Kamera `detail`, 60 J./Sek.,
Frame-Abstände über 10 s). A = `0fec08b` (synchron), B = dieser Stand.
`scripts/timelapse-timing.sh`, interleaved (A B, B A, …), 6 Runden,
2026-10-17. Der Rechner war dabei NICHT ruhig: andere Agenten bauten, testeten
und renderten parallel (Lastmittel 11–86), in vier Runden lief mindestens ein
fremdes Godot auf derselben GPU. Deshalb je Runde, nicht nur der Median:

| Runde | Last A / B | fremdes Godot A / B | A p95 | A > 33,3 ms | B p95 | B > 33,3 ms |
| ---: | --- | --- | ---: | ---: | ---: | ---: |
| 1 | 11 / 20 | 1 / 0 | 88,7 ms | 45 / 361 | 38,4 ms | 35 / 435 |
| 2 | 51 / 24 | 1 / 1 | 95,6 ms | 169 / 175 | 22,3 ms | 0 / 485 |
| 3 | 44 / 46 | 3 / 1 | 178,8 ms | 114 / 114 | 113,7 ms | 165 / 165 |
| 4 | 37 / 37 | 1 / 1 | 184,3 ms | 127 / 127 | 122,5 ms | 148 / 148 |
| 5 | 86 / 84 | 1 / 0 | 167,0 ms | 125 / 126 | 31,2 ms | 19 / 367 |
| 6 | 74 / 77 | 0 / 0 | 148,8 ms | 67 / 265 | 31,3 ms | 19 / 368 |

Median über alle sechs Läufe je Stand:

| Stand | Mittel | p95 | p99 | Max | > 33,3 ms | Hochladen Median / Max | Upload-Frame Max | Hauptthread wartet |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| A (synchron) | 69,6 ms | 157,9 ms | 171,6 ms | 179,0 ms | 120 | – | – | – |
| B (Hintergrund) | 27,3 ms | 34,8 ms | 38,8 ms | 55,8 ms | 27 | 2,9 / 7,7 ms | 35,4 ms | 0,0 ms |

Lesart: In JEDER Runde liegt B unter A, auch unter gleicher Last. In den
Runden 3 und 4 teilten sich drei bzw. zwei Godots die GPU; dort sind beide
Stände GPU-gebunden und keine Aussage über die Sim. In den übrigen Runden
fällt p95 von 89–167 ms auf 22–38 ms. Der Hauptthread hat in keinem Lauf auf
einen Schritt gewartet (`step_wait_ms` 0,0 im Messfenster), und der längste
Frame mit Hochladen ist kürzer als der längste Frame überhaupt: was über dem
Budget bleibt, ist Last von außen, nicht das Hochladen.

Ergänzend zwei Einzelläufe vom Vorabend (2026-10-16, NICHT interleaved,
Lastmittel 15–57, kein fremdes Godot): A Mittel 28,4 / p95 97,9 / p99 119,0 /
Max 124,3 ms, 38 von 353 Frames über dem Budget (die vier Takte je Sekunde);
B Mittel 22,0–22,9 / p95 24,6–25,0 / p99 29,6–31,1 / Max 32,7–44,6 ms, 0–1
Frames über dem Budget. Das entspricht dem Standbild derselben Kamera
(Zielbild-Messung: `detail` p95 26,6 ms). Die endgültige Messung gehört auf
einen ruhigen Rechner: `RS_TIMING_EXCLUSIVE=1` (s. Reproduktion).

### Wächter

- `SimCoreTests/BackgroundJobTests.swift`: Vertrag von `BackgroundJob`
  (Ergebnis genau einmal, kein zweiter Start, `isReady` blockiert nie, nur
  echtes Warten zählt, Schreibzugriffe des Jobs sind nach `wait` sichtbar),
  Bit-Gleichheit Hintergrund ↔ synchron, und als Quelltext: die Brücke fasst
  Welt und Render-Zustand nur über die Tore an; `_process` beginnt Schritte im
  Hintergrund, holt nur fertige ab und ruft weder `sim.step` noch
  `renderFrame`; JEDE Funktion in `Main.gd`, die die Welt ändert oder ihren
  aktuellen Stand liest, ruft vorher `_settle_sim()` (der Pinsel: setzt aus).
  Gegenprobe beim Bau: `_settle_sim()` aus `_regen` entfernt bzw. die
  Pinsel-Sperre gelöscht → beide rot.
- `RenderStateTests`: `beginStep` steht in der Liste der ändernden Einstiege
  und meldet `.advanced`.
- `RenderFrameTests`: jeder Frame-Schlüssel, den `packFrame` setzt, wird in
  `Main.gd` gelesen; `Main.gd` holt Seespiegel, Höhenbänder und Band-Mesh nicht
  mehr selbst.
- `game/tests/smoke.gd`: Protokoll über die echte Brücke (wartender Aufruf
  lässt das Ergebnis liegen, zweiter Start startet nichts, Schlüssel) und
  Hintergrund = synchron nach dem Laden derselben Welt.
- `game/tests/relief.gd`: der Zeitraffer-Pfad in `Main` mit echtem
  Hintergrund-Schritt (Back-Takt, Blenden) und ein Strich, der während eines
  rechnenden Schritts beginnt, ohne zu warten.

### Offene Punkte

- **Zeitsprünge** laufen weiter synchron, ein Chunk (2.000 Jahre) je Frame.
  Mit demselben Job könnten sie im Hintergrund laufen (`beginStep(chunk,
  FRAME_JUMP_CHUNK, …)` und abwarten per `await`), dann bliebe die Kamera
  auch im Sprung flüssig. Nicht Teil dieser Runde.
- **Pinsel-Nachzug** (`recomputeFlow` 35 ms, dann `renderFrame(FRAME_STROKE)`)
  bleibt synchron; das betrifft Pinsel-Frames, nicht den Zeitraffer.
- **Doppelter Upload der Vorgängerstände** (#172, `FieldTexture` mit
  `keeps_previous`): je Overlay-Takt geht die Hälfte der ~30 MB Texturdaten
  nur dafür über den Bus, den alten Stand erneut zu senden. Tauschen der beiden
  Texturen statt Kopieren halbierte das; CPU-seitig ~1 ms, GPU-seitig nicht
  gemessen.
- **QoS des Arbeits-Threads**: `.userInitiated`. Ob `.utility` unter Fremdlast
  ruhigere Frames gibt (der Schritt teilt sich die Kerne mit Godots
  Render-Thread), ist nicht gemessen.

### Reproduktion

```sh
GODOT=…/Godot.app/Contents/MacOS/Godot   # 4.7.2, offiziell
cp -R game /tmp/alt/game                 # Vorher-Stand samt bin/ und .godot/ sichern
# … umbauen, scripts/build.sh release …
RS_TIMING_SCREEN=1 RS_TIMING_RUNS=6 RS_TIMING_EXCLUSIVE=1 \
    scripts/timelapse-timing.sh /tmp/alt/game game
```

Die Bit-Gleichheit durch die Brücke (14 Takte, oben) lief als Einmal-Skript:
dieselbe Folge `step(15)` + `renderFrame(FRAME_TIMELAPSE, t)` im alten und
`beginStep(15, FRAME_TIMELAPSE, t)` + `finishStep()` im neuen Build, SHA-256 je
Puffer. Bleibend prüfen dasselbe `BackgroundJobTests` und `smoke.gd`.


---

## M. Mäandergürtel-Fenster auf mobilen Abschnitt beschränkt (Oktober 2026, Issue #174) — bit-identisch

Anlass: `meanderBeltStep` iterierte je Teilschritt über alle Knoten der wandernden
Läufe, obwohl weite Strecken (insbesondere der unbewegliche Gebirgsoberlauf mit
Abfluss unter `meanderBeltMinCells = 2000`) weder wandern noch erodieren noch
gestempelt werden. Ziel: Berechnung auf die mobilen Fenster samt Schablonen-Rändern
beschränken, strikt bit-identisch.

### Was geändert wurde

1. **`beltMigrationPlan` / Teilschritt-0-Wiederverwendung**: `meanderBeltStep`
   berechnet vor den Teilschritten die maximale Rate via `beltMigrationPlan`.
   Geometrie und Ratenvektoren werden für Teilschritt 0 direkt übernommen,
   statt sie im ersten Teilschritt identisch nochmals zu berechnen.
2. **`beltGeometry(..., minDischarge:)`**: Bei der Migration werden für Knoten
   mit `discharge < meanderBeltMinCells` die drei `heightAt`-Bilinear-Lookups
   (Längsneigung, Meereshöhe) übersprungen (`g.mob[i] = 0`), da
   `beltRatesAndErodibility` solche Knoten ohnehin per Guard ausblendet.
3. **`implicitDiffuse` Thomas-Algorithmus**: Zeilen mit $a_i = 0$ sind exakte
   Identitätszeilen ($cp=0, dx=nodes[i]$). Das Gleichungssystem entkoppelt an den
   Rändern, sodass der Vorwärts- und Rückwärtslauf exakt auf
   `firstA...lastA` mit festen Dirichlet-Rändern an `firstA - 1` und `lastA + 1`
   begrenzt werden kann.
4. **`perturb` und Verschiebungs-Schleifen**: Ratenverschiebung auf Knoten mit
   $r_i \neq 0$ beschränkt, Hash-Rauschen und Glättung in `perturb` auf
   `firstErod...lastErod`.
5. **`beltStamp` (Teil 1, mobile Teilschritte)**: Früher Abbruch, falls keine
   mobilen Knoten vorhanden sind. `bendCurvature` auf `firstMob...lastMob`
   eingeschränkt, `floorH` auf das $\pm 2$-Sohlenfenster
   `max(0, firstMob - 2)...min(c - 1, lastMob + 2)` und der Stempel-Loop auf
   `firstMob...lastMob`.

### Bit-Identität

Vor und nach der Optimierung identischer Fingerprint:
```
n=720 world=112.4789 seed=1337 warmup=100x100.0 steps=30x100.0
fingerprint c25268a941dd4beb
```

### Gemessen

Interleaved A/B-Benchmark über 6 Runden (`/tmp/bw.base` vs `/tmp/bw.cand`,
`--repeat 3`, 30 Schritte à dt=100.0, M4 Max):

```
1 base Messung: 30 Schritte à dt=100.0 → 63.2 ms/Schritt (Minimum aus 3 Blöcken)
1 cand Messung: 30 Schritte à dt=100.0 → 62.0 ms/Schritt (Minimum aus 3 Blöcken)
2 cand Messung: 30 Schritte à dt=100.0 → 61.2 ms/Schritt (Minimum aus 3 Blöcken)
2 base Messung: 30 Schritte à dt=100.0 → 64.8 ms/Schritt (Minimum aus 3 Blöcken)
3 base Messung: 30 Schritte à dt=100.0 → 64.2 ms/Schritt (Minimum aus 3 Blöcken)
3 cand Messung: 30 Schritte à dt=100.0 → 62.8 ms/Schritt (Minimum aus 3 Blöcken)
4 cand Messung: 30 Schritte à dt=100.0 → 63.4 ms/Schritt (Minimum aus 3 Blöcken)
4 base Messung: 30 Schritte à dt=100.0 → 64.3 ms/Schritt (Minimum aus 3 Blöcken)
5 base Messung: 30 Schritte à dt=100.0 → 63.7 ms/Schritt (Minimum aus 3 Blöcken)
5 cand Messung: 30 Schritte à dt=100.0 → 63.6 ms/Schritt (Minimum aus 3 Blöcken)
6 cand Messung: 30 Schritte à dt=100.0 → 62.8 ms/Schritt (Minimum aus 3 Blöcken)
6 base Messung: 30 Schritte à dt=100.0 → 65.1 ms/Schritt (Minimum aus 3 Blöcken)
```

| Stand | Runden | Median | Minimum |
|---|---|---:|---:|
| Base (`/tmp/bw.base`) | 63.2, 64.8, 64.2, 64.3, 63.7, 65.1 | 64.25 ms/Schritt | 63.2 ms/Schritt |
| Cand (`/tmp/bw.cand`) | 62.0, 61.2, 62.8, 63.4, 63.6, 62.8 | 62.80 ms/Schritt | 61.2 ms/Schritt |

Differenz: **−1.45 ms/Schritt** (Cand war in allen 6 Runden schneller).

Pass-Tabelle (`simperf --repeat 3`, letzter Block):

| Pass | base | cand | Delta |
|---|---:|---:|---:|
| `belt.migrate` | 6.44 ms/Schritt (10.0 %) | 5.14 ms/Schritt (8.4 %) | **−1.30 ms/Schritt (−20.2 %)** |
| `belt.stamp` | 7.31 ms/Schritt (11.3 %) | 7.22 ms/Schritt (11.8 %) | **−0.09 ms/Schritt** |
| `belt.*` gesamt | 13.75 ms/Schritt | 12.36 ms/Schritt | **−1.39 ms/Schritt (−10.1 %)** |

## N. Sim-Kern, dritte Runde für #174, Oktober 2026

Startstand `7b7a880`, Branch `t3/174-sim-perf-r3`. Gemessen am 17.10.2026
auf Apple M4 Max, 16 Kerne, 64 GiB, macOS 26.7, Apple Swift 6.4.
Release-Build mit Swift-5-Sprachmodus. Andere Agenten bauten und testeten auf
derselben Maschine. Deshalb ausschließlich interleaved A/B, je Runde wechselnd
A B bzw. B A, je Prozess `simperf --repeat 1`. Produktionspaarung n = 720,
world = 112,4789, Seed 1337, Einlauf 100 × 100 Jahre, Messblock 30 × 100 Jahre.
Die Mediane beziehen sich auf alle Runden, nicht auf das Minimum.

Start-Binary `/tmp/simperf.r3-start`, Profil mit `--repeat 3`: Blöcke
73,1 / 70,8 / 70,5 ms/Schritt. Diese Einzelmessung dient nur zur Hotspot-Suche.
Im letzten Block: Priority-Flood 15,96, MFD 7,27, Gürtel-Stempel 7,93,
Gürtel-Migration 5,59, Eis 4,51, Inzision 3,97 ms/Schritt. Ergänzend
`sample <pid> 10` während desselben Harness-Pfads. Das Sample umfasst auch den
Einlauf und ersetzt keinen A/B-Vergleich.

Vor der ersten Änderung selbst gemessene Fingerprints, jeweils mit `--hash`
und sonst unveränderten Standardargumenten:

| Seed | Start-Fingerprint |
| ---: | --- |
| 1337 | `c25268a941dd4beb` |
| 42 | `685222593c36209f` |
| 20 | `948941e9feca57df` |

### Verworfen: Heap-Pop bis zum Blatt, danach aufwärts einsetzen

Der volle Abstieg entfernt den Vergleich des letzten Elements mit dem kleinsten
Kind je Ebene. Danach wandert das letzte Element entlang desselben Pfades
aufwärts. Für dieselbe Pop-Reihenfolge muss es dabei auch über GLEICHE Eltern
steigen. Ein erster Versuch mit streng größeren Eltern scheiterte bereits am
Hash-Check, Seed 1337 `b809efbbd8d7a30f`, und wurde vor einer vollständigen
Messreihe korrigiert. Die korrigierte Fassung besteht alle drei Hash-Vergleiche.
Sie ist trotzdem langsamer und bleibt nicht im Code.

A = `/tmp/simperf.r3-start`, B = `/tmp/simperf.r3-heap2`.

| Runde | A ms/Schritt | B ms/Schritt | A Priority-Flood | B Priority-Flood |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 66,6 | 88,9 | 15,58 | 18,72 |
| 2 | 71,4 | 81,7 | 16,12 | 18,86 |
| 3 | 70,9 | 99,6 | 16,17 | 21,59 |
| 4 | 66,9 | 100,6 | 15,50 | 21,74 |
| 5 | 68,0 | 69,1 | 15,69 | 16,25 |
| 6 | 65,5 | 67,5 | 15,47 | 16,31 |
| Median | 67,45 | 85,30 | 15,635 | 18,790 |

Die Gesamtzeit streut durch Fremdlast stark. Auch im betroffenen Pass ist die
Variante in allen sechs Runden langsamer. Auf flachen Flächen steigt sie erst
ab und über gleiche Keys wieder auf, während die bisherige Fassung früher
abbricht. FIFO und eine andere Heap-Verzweigung wurden wegen der in §F belegten
Änderung von `order` und `floodParent` nicht umgesetzt.

### Verworfen: MFD-Nachbargewichte in 32.768-Zellen-Blöcken vorbereiten

Nachbarschaft, Gefälle und Gewichte für beide möglichen Exponenten werden
parallel vorbereitet. Die Akkumulation bleibt in `order` rückwärts, inklusive
der unveränderten Nachbarreihenfolge und des `floodParent`-Rückfalls. Die
Flächen-Schwelle entscheidet erst während der Akkumulation zwischen beiden
Exponenten. Alle drei Hashes stimmen, ebenso der zusätzliche Vergleich gegen
eine serielle Referenz auf einem ungeraden Gitter mit Exponenten 4, 2 und 1,3.

A = Start, B = `/tmp/simperf.r3-mfd-only`. Sechs Runden:

| Runde | A ms/Schritt | B ms/Schritt | A MFD | B MFD |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 72,8 | 69,0 | 7,07 | 5,61 |
| 2 | 68,8 | 110,3 | 7,38 | 11,73 |
| 3 | 79,7 | 117,5 | 7,04 | 10,81 |
| 4 | 71,8 | 83,8 | 7,02 | 8,86 |
| 5 | 75,1 | 72,5 | 7,02 | 7,10 |
| 6 | 66,9 | 66,8 | 6,92 | 5,69 |
| Median | 72,30 | 78,15 | 7,03 | 7,98 |

Die Variante trägt unter der gemessenen geteilten Last keinen Gewinn.
Einzelne gute Runden reichen nicht als Beleg. Die vielen parallelen Blockstarts
und das zusätzliche Schreiben und Lesen der Routendaten sind zusätzliche
Arbeit. Welcher Anteil die schlechteren Runden verursacht, isoliert diese
Messung nicht.

### MFD-Alternative mit gemeinsamem Parallelstart und wiederverwendbarem Puffer

Gleiche Zerlegung wie im Blockversuch, aber ein Parallelstart je MFD-Pass,
Routendaten in einem wiederverwendbaren Array. Auch die Division der Gewichte
durch ihre Summe wird vorbereitet. Die Auswahl anhand der Fläche und alle
Flächensummen bleiben seriell. Alle drei Hashes und der Referenztest stimmen.

A = Start, B = `/tmp/simperf.r3-mfd2`.

| Runde | A ms/Schritt | B ms/Schritt | A MFD | B MFD |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 67,4 | 67,5 | 6,9 | 5,1 |
| 2 | 80,4 | 67,4 | 7,78 | 5,27 |
| 3 | 77,5 | 64,9 | 7,17 | 4,54 |
| 4 | 79,9 | 69,6 | 7,06 | 5,02 |
| 5 | 72,6 | 63,8 | 6,85 | 4,62 |
| 6 | 71,4 | 68,9 | 7,47 | 5,0 |
| Median | 75,050 | 67,450 | 7,115 | 5,010 |

Im MFD-Pass fällt der Median um 2,105 ms. Der Gesamtmedian sinkt um 7,60 ms;
diese größere Differenz darf nicht vollständig dem MFD-Umbau zugeschrieben
werden. Die unveränderten Pässe schwanken mit der Fremdlast ebenfalls.
Der zusätzliche Puffer hält zwei Gewichtssätze und Nachbarindizes je Zelle.
Eine weitere Gegenprobe prüft deshalb SIMD ohne diesen Zusatzpuffer.

### Verworfen: MFD-Nachbararithmetik als SIMD

Bei inneren Zellen und den Exponenten 4 und 2 werden acht Nachbargefälle und
Potenzen als SIMD berechnet. Die Reduktion und Akkumulation bleiben seriell,
Randzellen und andere Exponenten benutzen den bisherigen Pfad. Drei Hashes
und der serielle Referenztest stimmen. A = Start, B = `/tmp/simperf.r3-mfd-simd`.

| Runde | A ms/Schritt | B ms/Schritt | A MFD | B MFD |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 72,9 | 77,3 | 7,15 | 9,74 |
| 2 | 72,1 | 73,7 | 7,17 | 9,68 |
| 3 | 68,2 | 76,8 | 6,85 | 9,7 |
| 4 | 67,9 | 83,7 | 6,96 | 10,01 |
| 5 | 67,7 | 71,2 | 6,96 | 9,41 |
| 6 | 68,4 | 72,1 | 6,97 | 9,58 |
| Median | 68,300 | 75,250 | 6,965 | 9,690 |

SIMD ist hier in allen sechs Runden langsamer. Übernommen wird die Fassung
mit gemeinsamem Parallelstart und wiederverwendbarem Puffer, nicht der
Blockversuch oder SIMD. `MFDRouteTests` vergleicht die komplette Ausgabe
bitweise gegen die serielle Referenz, inklusive beider Exponenten-Zweige,
Randzellen, flachen Flächen und eines nichtganzzahligen Exponenten. Die
Scratch-Einordnung ist in `StateInventoryTests` erfasst.

### Gegenmessung bei der Übernahme (Integrationszweig)

Unabhängig nachgemessen vor dem Cherry-Pick, M4 Max, dieselbe geteilte
Maschine (zwei weitere Agenten aktiv), interleaved, drei Stände je Runde,
Reihenfolge je Runde umgekehrt, `simperf --repeat 1`, 8 Runden:

| Stand | ms/Schritt, Runde 1–8 | Median |
| --- | --- | ---: |
| Integration `7b7a880` | 62,8 62,9 62,8 63,2 63,4 63,3 63,2 63,5 | 63,20 |
| MFD-Routen (`3133d27`) | 60,2 60,5 60,6 60,2 60,0 61,0 60,5 61,6 | 60,50 |
| dazu Inzisionsfaktor vorab parallel (WIP) | 59,7 60,4 61,1 60,6 60,2 59,6 60,6 60,4 | 60,40 |

Der MFD-Umbau spart −2,70 ms (−4,3 %) und ist in allen acht Runden
schneller. Der zusätzliche WIP-Schritt (Faktor `kErode·dt·A^m/dist` der
`outletIncision` parallel vorab statt nur `A^m`) liegt mit −0,10 ms im
Rauschen und wurde nicht übernommen; bit-identisch war er (Hash 1337/42/20).
Fingerprints nach dem Cherry-Pick: `c25268a941dd4beb` / `685222593c36209f` /
`948941e9feca57df`, unverändert.

---

## O. Sim-Kern, Runde 4 (Oktober 2026) — aktive Eis-Bounding-Box, parallele D8-Abschnitte und Gürtelschleifen, bit-identisch

Startstand `6a0dfde` (Integrationszweig nach `§M` und `§N`). Gemessen am
17.10.2026 auf Apple M4 Max (16 Kerne, 64 GiB, macOS 26.7, Swift 6.4 im
Swift-5-Sprachmodus). Wie in `§I` und `§N` liefen andere Agenten parallel auf
derselben Maschine; alle Vergleiche erfolgten daher verschränkt (interleaved
`A B`, `B A`, …) zwischen vorab gebauten Binärdateien (`/tmp/simperf.r4-start`
gegen Kandidaten), je Prozess `simperf --repeat 1` (Einlauf 100 × 100 Jahre,
Messblock 30 × 100 Jahre, `n = 720`, `world = 112,4789`).

Fingerprints vor und nach allen übernommenen Änderungen:

| Seed | Fingerprint (`simperf --hash`) |
| ---: | --- |
| 1337 | `c25268a941dd4beb` |
| 42 | `685222593c36209f` |
| 20 | `948941e9feca57df` |

### Ausgangsprofil und Hypothesen

Nach `§M` (mobiles Gürtel-Fenster) und `§N` (MFD-Routen vorab parallel) verteilte
sich ein ruhiger 30-Schritt-Messblock auf Seed 1337 (~56–68 ms/Schritt je nach
Systemlast) auf:

- `priorityFlood`: ~14,4–15,9 ms (25 %) — unter Bit-Identität ausgereizt (`§F`, `§N`).
- `belt.stamp`: ~6,8–7,0 ms (12 %) + `belt.fixedStamp`: ~1,6–1,8 ms (3 %).
- `updateIce`: ~6,1–7,9 ms (12 % auf Seed 1337, ~3,4 ms auf Seed 20).
- `belt.migrate`: ~4,8–5,0 ms (8 %).
- `computeMFDArea`: ~3,9–5,1 ms (7 %).
- `belt.couple` (`segments` + `build` + `match` + `runs`): ~2,6 ms (`segments`
  1,03–1,17 ms, `build` 1,07–1,14 ms).
- `channelCarve`: ~1,1–1,4 ms.

Daraus wurden vier gezielte Hypothesen abgeleitet und einzeln geprüft:

1. **Hypothese 1 (`belt.couple.segments` + `belt.couple.build`)**:
   In `Terrain.drainageSegments` lief zwar die Suche nach den ~753
   Abschnitts-Startzellen (Quellen und Zusammenflüsse) parallel, das Verfolgen
   der 753 disjunkten `receiver`-Ketten jedoch seriell auf einem Thread; zudem
   allokierte jeder Abschnitt ein frisches `[Int32]` ohne Größen-Vorwissen, und
   `coupleBeltToDrainage` schrieb `segOwner`/`segPos` sowie `area` über die
   Klassen-Property (mit Swift-Exklusivitäts-/COW-Prüfung je Knotenzelle).
   Da jede Kette deterministisch an einer Senke oder einem Zusammenfluss
   (`inDeg[cur] != 1`) endet und nur `receiver`/`inDeg` liest, kann jede
   Thread-Scheibe ihre Ketten direkt in `concurrentPerform` mit einem
   wiederverwendbaren `cells`-Puffer verfolgen.
2. **Hypothese 2 (`updateIce` — Roh-Zeiger-Scan + aktives Gitterfenster)**:
   - `anyCell(ice)` und `steepestIceSurfaceDrop()` lasen `ice[k]` und `h[k]`
     über die Klassen-Property (ohne `withUnsafeBufferPointer`) zweimal über
     alle 518.400 Zellen.
   - Die Gletscher- und Firnzellen (`ice[k] > 0 || (temperature[k] < 0 && snow[k] > 0)`)
     belegen auf Seed 1337 nur **5,1 %** der Gitterzellen (26.574 / 518.400) in
     einem Bounding-Box-Rechteck von **23,0 %** der Welt (`j = 135…582`,
     `i = 184…449`) bei bis zu `nSub = 27` SIA-Teilschritten je Schritt (auf
     Seed 20: **2,4 %** aktive Zellen in **21,0 %** Bounding-Box bei `nSub = 3…7`).
   - Weil Eis pro Teilschritt maximal um 1 Zelle in die 4-Nachbarschaft fließt
     (`inflow > 0` erfordert einen 4-Nachbarn mit `prate[nb] > 0`, also
     `ice[nb] > thr`), wächst der Träger aktiver Zellen im Teilschritt `s`
     (`0..<nSub`) um höchstens `reach = s + 1` Zellen in jeder Richtung. Pass 2
     muss daher nur auf dem um `s + 1` erweiterten Rechteck laufen, und Pass 1
     nur auf dem zusätzlich um `pad = max(1, swath)` erweiterten Halo (damit
     alle eingefrorenen `psurf`-, `prate`- und `pero`-Nachbarn im `swath`-Fenster
     von Pass 2 frisch berechnet sind).
3. **Hypothese 3 (`beltStamp` / `belt.fixedStamp` + `Meander.swift`)**:
   - In `beltStamp(dt:only:ageAtEnd:)` iterierte jeder mobile Teilschritt
     (`only != nil`, ~233 Aufrufe/Schritt auf Seed 1337) über
     `meander.channels.enumerated() where only.map({ $0 == ci }) ?? ...` und
     kopierte dabei jedes Mal alle ~686 `RiverChannel`-Structs, nur um 685
     davon zu verwerfen.
   - Im Schrittende-Pass (`belt.fixedStamp`, `only == nil`) wurde für alle
     wandernden Läufe (`part == 2`) sowie für alle komplett steilen Läufe
     (`firstMob == nil`) trotzdem `MeanderState.bendCurvature` berechnet und
     `floorH` (Nullen-Array der Länge `c`) allokiert, obwohl weder `bendCurv`
     noch `floorH` ohne mobile Stempel-Knoten gelesen werden.
   - In `MeanderState.beltGeometry` wurde die kumulierte Bogenlänge `cum`
     berechnet und sofort wieder verworfen, worauf `beltRatesAndErodibility`
     exakt dasselbe `cum`-Array nochmals allokierte und über `dist(...)`
     aufsummierte. Ebenso berechnete `applyBeltCutoffs` die Kanalbreite
     `beltWidthCells` je Knoten zweimal hintereinander.
4. **Hypothese 4 (`channelCarve` & verbleibende Property-Scans)**:
   In `channelCarve` wurden `receiver` und `area` innerhalb von `withBed` als
   Array-Kopie aus der Klassen-Property gebunden statt über
   `withUnsafeBufferPointer`; gleiches galt für `h`/`rain` in `updateRainWeight`
   und `h`/`snow` in `snowAreaFractions`.

---

### Experiment 1 (Übernommen): Parallele Abschnittsketten in `drainageSegments` + Roh-Puffer in `coupleBeltToDrainage`

`Terrain.drainageSegments` klemmt die Chunk-Zahl auf `Terrain.coreCount` (statt
64 Kleinst-Chunks), verfolgt die `receiver`-Kette direkt im parallelen Chunk mit
einem wiederverwendbaren `cells`-Puffer je Chunk (`Array(cells)` kopiert exakt
auf die tatsächliche Länge) und hängt die Abschnitte in unveränderter
Chunk-Reihenfolge zusammen. In `coupleBeltToDrainage` werden `segOwner`,
`segPos` und `area` über `withUnsafeMutableBufferPointer` /
`withUnsafeBufferPointer` adressiert.

10 Runden interleaved (`/tmp/simperf.r4-start` gegen `/tmp/simperf.r4-couplesegs`,
Seed 1337):

| Pass | A (Start, Mittel / Median) | B (Exp. 1, Mittel / Median) | Differenz | Siege B |
| --- | ---: | ---: | ---: | ---: |
| `belt.couple.segments` | 1,03 / 1,03 ms | **0,41 / 0,41 ms** | **−0,62 ms (−60 %)** | 10 / 10 |
| `belt.couple.build` | 1,07 / 1,07 ms | **0,99 / 0,99 ms** | **−0,08 ms (−7,5 %)** | 10 / 10 |

Beide Pässe gewinnen in allen 10 Runden, zusammen **−0,70 ms/Schritt**.

---

### Experiment 2 (Verworfen): Zweigeteilter Geometrie-Pass in `MeanderState.beltGeometry`

**Hypothese**: Wenn `beltGeometry` zuerst nur `width` und `mob` berechnet, kann
für Knoten außerhalb des mobilen Fensters `[firstMob - maxKb, lastMob + maxKb]`
das `atan2` für `g.curv` entfallen (und in `beltStamp` mit `part == 1` auch die
Normalen `g.nx`/`g.nz` außerhalb von `firstMob - 2 ... lastMob + 2`).

**Befund**: Auf Seed 1337 sind in den 39 wandernden Läufen bereits **67 %**
aller Knoten mobil (`21.745 / 32.993` Knoten je Schritt über alle Teilschritte).
Die Aufteilung in zwei Schleifen über `0..<c` sparte nur bei einem Drittel der
Knoten das `atan2`, verdoppelte aber die Schleifen- und Nachbarschafts-Arbeit
(`nodes[i - k]`, `nodes[i + k]`). Im verschränkten A/B-Test stieg `belt.stamp`
von 6,82 ms auf 7,05 ms (+0,23 ms). Vollständig verworfen.

**Zusatzbefund zu `seg` in `beltRatesAndErodibility`**: Während `cum` aus
`beltGeometry` für die Sehnen-Sinuosität (`cum[hi] - cum[lo]`) bit-identisch
wiederverwendet werden kann, darf die einzelne Segmentlänge `seg` für das
Exponentialgewicht `exp(-seg / ...)` **nicht** durch `cum[i] - cum[i - 1]`
ersetzt werden: durch die vorangegangene Addition `cum[i - 1] + dist(...)` weicht
die Differenz `cum[i] - cum[i - 1]` in IEEE-754 um bis zu 1 ULP von
`dist(nodes[i - 1], nodes[i])` ab, was den Fingerprint verändert (`cd11a10566f3a789`
statt `c25268a941dd4beb`). Mit `cum` aus `BeltGeometry` für die Sinuosität und
`dist(...)` für `seg` bleibt die Rechnung auf allen drei Seeds bit-identisch.

---

### Experiment 3 (Übernommen): `updateIce` mit aktivem Bounding-Box-Fenster und kombiniertem Roh-Zeiger-Scan

`activeIceBoundsAndSteepestDrop()` ersetzt `anyCell(ice)` und
`steepestIceSurfaceDrop()` durch einen einzigen Roh-Zeiger-Durchlauf über
`ice`, `h`, `temperature` und `snow`, der gleichzeitig `wMax` (für die
CFL-Teilschrittzahl `nSub`) und die exakte Bounding-Box `(jMin...jMax, iMin...iMax)`
aller aktiven Eis-/Firnzellen liefert. In `iceFlowSubStep` laufen Pass 1 und
Pass 2 nur noch über die im Teilschritt `s` um `s + 1` (bzw. `s + 1 + max(1, swath)`
für Pass 1) erweiterte Bounding-Box.

Isolierter A/B-Test (`/tmp/simperf.r4-couplesegs` gegen `/tmp/simperf.r4-ice`,
6 Runden je Seed):

- **Seed 1337**: `updateIce` sinkt von **7,34 ms (Med. 6,94)** auf **6,13 ms
  (Med. 6,03)** (**−1,21 ms Mittel / −0,91 ms Median**, B gewinnt 5/6 Runden).
- **Seed 20**: `updateIce` sinkt von **3,42 ms (Med. 3,43)** auf **2,83 ms
  (Med. 2,82)** (**−0,59 ms Mittel / −0,61 ms Median, −17 %**, B gewinnt 6/6 Runden).

---

### Experiment 4 (Übernommen): Direkte Kanal-Indizierung & Lazy-Allokation in `beltStamp`, `BeltGeometry.cum`, `channelCarve`

Zusammengefasst:
1. `beltStamp`: Bei `only != nil` wird direkt `only..<only+1` indiziert statt
   `meander.channels.enumerated()` über alle ~686 Kanäle zu kopieren; `bendCurv`
   und `floorH` werden nur berechnet bzw. allokiert, wenn `part != 2 && firstMob != nil`.
2. `Meander.swift`: `BeltGeometry` speichert das in `beltGeometry` ohnehin
   gebildete `cum`-Array für `beltRatesAndErodibility`; `applyBeltCutoffs`
   merkt sich die Kanalbreiten `widths[i]` aus der `maxReach`-Schleife für die
   Cutoff-Suche.
3. `channelCarve`, `updateRainWeight`, `snowAreaFractions`, `landHeightQuantiles`:
   Roh-Puffer-Zeiger (`withUnsafeBufferPointer`) statt Klassen-Property-Zugriffen.

---

### Gesamtvalidierung Runde 4 (Start gegen Endstand)

Verschränkter A/B-Vergleich zwischen `/tmp/simperf.r4-start` (`de4ba53`) und
dem kompletten Runde-4-Stand (`/tmp/simperf.r4-meander`), 8 Runden auf Seed 1337
und 6 Runden auf Seed 20:

#### Seed 1337 (8 Runden interleaved)

| Runde | A Gesamt | B Gesamt | A `updateIce` | B `updateIce` | A `couple.segments` | B `couple.segments` | A `couple.build` | B `couple.build` | A `belt.migrate` | B `belt.migrate` |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 70,6 | 68,1 | 7,84 | 6,28 | 1,15 | 0,60 | 1,14 | 1,04 | 4,92 | 4,85 |
| 2 | 71,9 | 68,2 | 8,94 | 6,20 | 1,18 | 0,59 | 1,15 | 1,01 | 5,02 | 4,86 |
| 3 | 70,5 | 67,4 | 8,86 | 6,35 | 1,32 | 0,52 | 1,15 | 1,01 | 4,99 | 4,86 |
| 4 | 68,8 | 71,7 | 8,04 | 6,37 | 1,16 | 0,49 | 1,10 | 1,02 | 4,93 | 5,03 |
| 5 | 65,3 | 61,0 | 7,17 | 5,03 | 1,10 | 0,48 | 1,09 | 0,96 | 4,91 | 4,78 |
| 6 | 71,0 | 59,6 | 8,44 | 5,03 | 1,18 | 0,44 | 1,21 | 0,96 | 5,60 | 4,76 |
| 7 | 61,7 | 62,2 | 6,24 | 5,19 | 1,04 | 0,46 | 1,06 | 0,98 | 4,84 | 4,77 |
| 8 | 70,1 | 60,2 | 7,50 | 4,98 | 1,21 | 0,49 | 1,21 | 0,99 | 5,13 | 4,70 |
| **Mittel** | **68,74** | **64,80** | **7,88** | **5,68** | **1,17** | **0,51** | **1,14** | **1,00** | **5,04** | **4,83** |
| **Median** | **70,30** | **64,80** | **7,94** | **5,70** | **1,17** | **0,49** | **1,15** | **1,00** | **4,96** | **4,81** |

Aufschlüsselung aller geänderten Pässe (Seed 1337, 8 Runden):

| Pass | A Mittel (Median) | B Mittel (Median) | Differenz Mittel (Median) | Siege B |
| --- | ---: | ---: | ---: | ---: |
| `updateIce` | 7,88 (7,94) ms | **5,68 (5,70) ms** | **−2,20 (−2,24) ms (−28 %)** | 8 / 8 |
| `belt.couple.segments` | 1,17 (1,17) ms | **0,51 (0,49) ms** | **−0,66 (−0,68) ms (−56 %)** | 8 / 8 |
| `belt.couple.build` | 1,14 (1,15) ms | **1,00 (1,00) ms** | **−0,14 (−0,15) ms (−12 %)** | 8 / 8 |
| `belt.migrate` | 5,04 (4,96) ms | **4,83 (4,81) ms** | **−0,22 (−0,15) ms (−4 %)** | 7 / 8 |
| `channelCarve` | 1,40 (1,42) ms | **1,26 (1,23) ms** | **−0,14 (−0,19) ms (−10 %)** | 6 / 8 |
| `belt.fixedStamp` | 1,78 (1,76) ms | **1,70 (1,69) ms** | **−0,08 (−0,07) ms (−4,5 %)** | 7 / 8 |
| `belt.stamp` | 7,03 (7,04) ms | **6,95 (6,98) ms** | **−0,08 (−0,06) ms (−1 %)** | 6 / 8 |
| **Gesamt (`step`)** | **68,74 (70,30) ms** | **64,80 (64,80) ms** | **−3,94 (−5,50) ms (−5,7 %)** | 6 / 8 |

#### Seed 20 (6 Runden interleaved)

| Pass | A Mittel (Median) | B Mittel (Median) | Differenz Mittel (Median) | Siege B |
| --- | ---: | ---: | ---: | ---: |
| `updateIce` | 3,39 (3,38) ms | **2,59 (2,61) ms** | **−0,80 (−0,77) ms (−24 %)** | 6 / 6 |
| `belt.couple.segments` | 0,71 (0,72) ms | **0,39 (0,40) ms** | **−0,32 (−0,32) ms (−45 %)** | 6 / 6 |
| `belt.couple.build` | 0,63 (0,63) ms | **0,56 (0,56) ms** | **−0,07 (−0,07) ms (−11 %)** | 6 / 6 |
| `belt.migrate` | 2,20 (2,21) ms | **2,14 (2,15) ms** | **−0,06 (−0,06) ms (−3 %)** | 6 / 6 |
| `channelCarve` | 0,80 (0,80) ms | **0,74 (0,74) ms** | **−0,06 (−0,06) ms (−7,5 %)** | 6 / 6 |
| `belt.fixedStamp` | 1,02 (1,02) ms | **0,99 (0,99) ms** | **−0,03 (−0,03) ms (−3 %)** | 6 / 6 |
| **Gesamt (`step`)** | **45,45 (45,50) ms** | **44,40 (44,45) ms** | **−1,05 (−1,05) ms (−2,3 %)** | 6 / 6 |

### Übernahme in den Integrationszweig

Übernommen sind nur die Teile AUSSERHALB des Gletschers: parallele
Abschnittsketten in `drainageSegments` und Roh-Puffer in
`coupleBeltToDrainage`, `beltStamp` (direkte Kanal-Indizierung, Krümmung nur
für mobile Läufe), `BeltGeometry.cum`/`applyBeltCutoffs` in `Meander.swift`
und die Roh-Zeiger in `channelCarve`, `updateRainWeight`, `snowAreaFractions`
und `landHeightQuantiles`. Die Eis-Bounding-Box (Experiment 3) bleibt draußen:
der Gletscher-Zweig (`t3/174-glacier-recal`, dt-Fix aus `docs/glacier-measurements.md`
§L) schreibt die Teilschritte von `updateIce` neu und bringt dort seine eigene,
ebenfalls bit-identische Begrenzung auf das vergletscherte Gebiet mit.

Gegenmessung der Übernahme (Pass-Tabelle `simperf --repeat 3`, je Runde
Integration `6a0dfde` und Kandidat nacheinander, 4 Runden, geteilte Maschine,
Median der Blöcke): `belt.couple.segments` 1,14 → 0,49 ms, `belt.couple.build`
1,16 → 1,08, `channelCarve` 1,27 → 1,15, `computeRain` 1,19 → 1,13,
`belt.fixedStamp` 1,67 → 1,62; `belt.stamp` 7,28 → 7,38 und `belt.migrate`
5,14 → 5,21 im Rauschen. Netto rund −0,8 ms je Schritt. Der Gesamtschritt
streute unter der Fremdlast (Load wechselnd) zu stark für eine schärfere Zahl
(8 Runden, Median 75,4 → 68,2 ms bei Einzelrunden von −14 bis +11 ms).
Fingerprints mit den übernommenen Teilen: `c25268a941dd4beb` /
`685222593c36209f` / `948941e9feca57df`, unverändert.

---

## P. Sim-Kern, Runde 5 (Oktober 2026) — Eis-Domäne und Tropfen über Roh-Puffer, bit-identisch

Startstand `aeed3b3` (Integrationszweig mit Gletscher-Nachkalibrierung),
M4 Max, geteilte Maschine (mehrere Agenten, Load stark wechselnd). Vorschläge
eines Agenten (Gemini 3.8 Flash, Branch `t3/174-sim-perf-r5b`), unabhängig
nachgemessen: Gesamtschritt 10 Runden interleaved (`simperf --repeat 1`),
dazu die Pass-Tabelle (`--repeat 3`, 4 Runden, Median der Blöcke).

| Pass | `aeed3b3` | Kandidat (alle vier Commits) | übernommen |
| --- | ---: | ---: | --- |
| `Hydraulic.erode` | 3,35 ms | 2,62 ms | ja |
| `updateIce` | 5,48 ms | 4,07 ms | ja (zeilenweise über `Terrain.parallel` neu geschrieben) |
| `updateVegetation` | 4,02 ms | 3,94 ms | nein (Gewinn im Rauschen) |
| `belt.migrate` / `belt.stamp` | 6,16 / 7,88 ms | 6,68 / 8,09 ms | nein (behaupteter Gewinn nicht reproduziert) |

Der Gesamtschritt streute unter der Fremdlast stärker als der Effekt
(10 Runden, Median 74,95 → 74,0 ms, gepaart +0,8 ms); deshalb gilt hier die
Pass-Tabelle. Der Agent hatte −2,95 ms gemeldet, seine eigene Tabelle zeigte
in den drei ruhigsten Runden den Kandidaten LANGSAMER (+1,5 … +2,0 ms) — der
Median kam aus Lastspitzen auf der Basis-Seite. Lehre: bei wechselnder Last
nicht den Gesamt-Median, sondern die gepaarten Differenzen und die
betroffenen Pässe lesen.

`iceTransportDomain` schrieb im Vorschlag aus `DispatchQueue.concurrentPerform`
heraus in Swift-Arrays (formal ein Data Race); übernommen ist die Fassung mit
je Zeile eigenem Ergebnis in Roh-Puffern und serieller Reduktion.
Fingerprints unverändert: `6ffeb97d52f8e8d9` / `9f0fb0e9ad4d8493` /
`49c9ba0762c9ee01`.


## Q. Mäandergürtel parallel, Oktober 2026 (Issue #174)

Startstand `ea85a7c`, Branch `t3/174-belt-parallel`. Gemessen auf Apple M4 Max,
16 Kerne, 64 GiB, macOS 26.7, Apple Swift 6.4, Release im Swift-5-Sprachmodus.
Die Maschine war geteilt. Alle A/B-Vergleiche wechseln je Runde A B / B A;
Schleifen mit `bash -c`. Produktionspaarung n = 720, world = 112,4789,
Seed 1337, Einlauf 100 × 100 Jahre, Messblock 30 × 100 Jahre.
`--repeat 1` misst den gesamten ersten Block; bei `--repeat 3` stammt die
Pass-Tabelle aus dem dritten Block und die ausgegebene Gesamtzeit aus dem
schnellsten Block. Beide Größen werden getrennt ausgewertet.

### Ansatz und Unabhängigkeit

Die Läufe bleiben gegenüber jedem überlappenden Vorgänger geordnet. Für jeden
Lauf wird eine geländeunabhängige Obergrenze seiner anfänglichen Rate berechnet:
Mobilität, Sättigung und Talwand-Bremse können den Betrag nur vermindern;
Beträge vor der unveränderten Ratenglättung begrenzen auch die mögliche
Auslöschung verschiedener Vorzeichen. Daraus folgt eine Obergrenze der einmal
gewählten CFL-Teilschrittzahl. Die tatsächliche Zahl wird erst am zulässigen
Ausführungspunkt aus dem aktuellen Bett berechnet und gegen diese Schranke
geprüft, nicht vor überlappenden Vorgängern.

Das Fenster enthält alle anfänglichen Knoten, je möglichem Teilschritt einen
Knotenabstand für die beiden jeweils auf einen halben Abstand geklemmten
Bewegungen, sowie den größeren Rand aus 3,5 Kanalbreiten für die Talwand und
0,5 + `meanderBarWidths` für den Stempel. Zwei zusätzliche Zellen decken
Rundung, bilineare Abfragen und die vier Nachbarn der Altarm-Pfropfen ab.
Implizite Diffusion mit nichtnegativen Koeffizienten, Cutoffs und Resample
bleiben in der konvexen Hülle. Der Sicherheitsaufschlag 1,001 auf Rate/Breite
verhindert eine zu knappe Schranke durch Rundung. Ungültige Voraussetzungen
fallen auf den bisherigen seriellen Weg zurück; die Physik bekommt keinen
neuen Deckel.

Jeder Arbeiter besitzt einen lokalen `MeanderState`, Cutoff-Index und
Altarm-Historie. Der Rausch-Schlüssel bleibt der ursprüngliche Kanalindex.
Bett, Vegetation, Bankalter und Masken sind einmal als Roh-Puffer geöffnet;
parallel werden ausschließlich disjunkte Lese- und Schreibfenster bearbeitet.
Neue Altarme und Cutoff-Zähler werden nach allen Arbeiten in ursprünglicher
Lauf-Reihenfolge eingetragen. Pfropfen entstehen weiterhin nach jedem
Teilschritt, `attachTributaries`, feste Stempel und Verlandung danach seriell.
Die Kopplung samt Diagnose-Zählern bleibt vor der Migration.

Zusätzlich reist die Geometrie des letzten Stempels zur nächsten Migration:
Breiten, Krümmung, Normalen und Bogenlängen bleiben bei unveränderter Linie
gültig, nur die Mobilität liest das frisch gestempelte Bett erneut. Ein
Bank-Saum endet, sobald außerhalb des Betts kein Sedimentbudget mehr besteht;
dort kann dann keine weitere Zelle geändert werden.

### Vorversuche und verworfene Varianten

Die Vorversuche dienten zur Auswahl; während einzelner Runden liefen eigene
Builds/Hash-Prüfungen zusätzlich zur Fremdlast. Maßgeblich ist deshalb die
abschließende, separat ausgeführte Messreihe unten.

| Variante B | A | Gesamt A / B, Median | gepaarte Δ B−A | mobile Pässe A / B, Median |
| --- | --- | ---: | ---: | ---: |
| Cache, getrennte Geometrie-/Mobilitäts-Schleifen | Start | 58,350 / 58,900 | 0,450 | 13,025 / 12,580 |
| Cache mit gemeinsamer Mobilitätsformel + Bank-Abbruch | Start | 58,350 / 58,350 | -0,500 | 13,040 / 12,045 |
| Feste Ebenen + Cache + Bank-Abbruch | Start | 60,750 / 57,300 | -1,850 | 13,110 / 11,490 |
| Konvexe Hüllen + feste Ebenen | Start | 59,050 / 59,800 | 0,550 | 12,990 / 12,205 |
| Tabelle gesättigter Querprofile | Ebenen | 57,200 / 59,850 | 2,700 | 11,610 / 11,905 |
| Abhängigkeitsplan, Tabelle, Broadcast | Ebenen | 59,100 / 58,500 | -1,500 | 11,805 / 11,895 |
| Abhängigkeitsplan ohne Tabelle, gezieltes Aufwecken | Ebenen | 57,300 / 57,650 | 0,600 | 11,700 / 11,095 |

Alle Zeiten in ms/Schritt, je vier Runden `--repeat 1`. Mobile Pässe sind in A
`belt.migrate + belt.stamp`, beim Parallelpfad `belt.schedule + belt.parallel`.
Die Summe enthält die Planung. Der erste Cache teilte die volle Geometrie
ungünstig in zwei Schleifen und wurde durch die gemeinsame skalare
Mobilitätsformel ersetzt. Die Tabelle identischer gesättigter Querprofile wird
verworfen: kein Gewinn im betroffenen Pass. Konvexe Hüllen vermindern zwar die
Überlappungen, kosten aber mehr Planung. Die Produktionsfassung verwendet
Rechtecke und einen gemeinsamen Parallelstart. Ein Lauf wartet nur auf seine
überlappenden Vorgänger, statt auf eine ganze Ebene. Der Condition-Lock schützt
alle Scheduler-Daten, gezielte Signale wecken neu ausführbare Arbeiter; am Ende
werden alle wartenden Arbeiter freigegeben.

Die erste Rechteck-Diagnose auf dem seriellen Startstand maß 1.072 mobile Läufe
über 30 Schritte, 0 vollständig isolierte Läufe, 5.860 überlappende Paare von
18.665 möglichen Paaren, 783 Ebenen insgesamt. Das sind 35,73 Läufe und 26,10
Ebenen je Schritt; 68,60 % der Laufpaare sind unabhängig. 572 von 1.072 Läufen
liegen in Ebenen mit mehreren Läufen (53,36 %). Die konvexen Hüllen erreichen
4.462 überlappende Paare, 737 Ebenen, 657 Laufplätze in mehrfach besetzten
Ebenen, aber weiterhin 0 isolierte Läufe. Diese geometrischen Anteile sind
keine Zeitanteile; die Läufe haben unterschiedliche Knoten-/Teilschrittzahlen.

Der gegatete `testBeltOverlapDiagnostic` reproduziert die Statistik
mit denselben Produktions-Fenstern; `testBeltScheduleReleasesOnlyIndependentReadyRuns`
prüft gleichzeitig aktive Läufe und sämtliche Vorgänger-Kanten.

Vor allen Änderungen selbst bestätigte Hashes auf `ea85a7c`:

| Seed / dt | Fingerprint |
| --- | --- |
| 1337 / 100 | `08d32575d5cd353a` |
| 42 / 100 | `0fd978609f8cc241` |
| 20 / 100 | `9df73cb7672f2610` |
| 1337 / 15 | `90b5a31c0d94a030` |

Der Ebenen-Kandidat bestätigt alle vier Werte, Seed 1337 zusätzlich zweimal.
Auch Cache, Hüllen, Profil-Tabelle und der gemeinsame Parallelstart wurden
jeweils vor ihrer Messung auf Seed 1337 gegen denselben Startwert geprüft.
Abschlussprüfung und vollständige Messreihe folgen unten.

### Abschließende Gesamtschritt-Messung

A = `/tmp/simperf.q-start` aus `ea85a7c`, B = `/tmp/simperf.q-end` aus dem
Quellstand `fac991d`. Zehn Runden `--repeat 1`, anschließend vier Runden
`--repeat 3`, jeweils wechselnde Reihenfolge. Während dieser abschließenden
Reihen lief kein eigener weiterer Build, Test oder Hash-Lauf. Fremdlast auf
der geteilten Maschine blieb möglich.

| Runde | A Gesamt | B Gesamt | Δ B−A | A mobile Pässe | B mobile Pässe inkl. Planung |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 58,6 | 57,3 | -1,3 | 13,07 | 10,97 |
| 2 | 59,6 | 57,7 | -1,9 | 13,08 | 11,07 |
| 3 | 58,1 | 57,7 | -0,4 | 13,02 | 11,27 |
| 4 | 59 | 56,5 | -2,5 | 13,23 | 10,83 |
| 5 | 58,1 | 56,7 | -1,4 | 12,93 | 10,95 |
| 6 | 58 | 59,3 | 1,3 | 12,87 | 11,32 |
| 7 | 58 | 57 | -1 | 13,02 | 11,02 |
| 8 | 57,6 | 57,3 | -0,3 | 12,85 | 11,04 |
| 9 | 57,7 | 55,7 | -2 | 13,01 | 10,84 |
| 10 | 58,6 | 56,8 | -1,8 | 12,95 | 10,92 |
| Median | 58,1 | 57,15 | -1,35 | 13,015 | 10,995 |

Alle Zeiten in ms/Schritt. Gesamt-Mediane **58,1 → 57,15 ms**,
Differenz der Mediane **-0,95 ms (-1,635 %)**,
gepaarter Median **-1,35 ms**; B gewinnt 9/10 Paare.
Der Median der gepaarten Differenzen der mobilen Pässe beträgt
**-2,005 ms**. Die unveränderte Priority-Flood liegt bei A/B im Median bei
14,72/15,46 ms.
Der Pass-Gewinn darf deshalb nicht als derselbe Gewinn des Gesamtschritts
angegeben werden. Diese Messung isoliert den Grund der anderen Pass-Zeiten nicht.

### Pass-Tabelle, vier Runden `--repeat 3`

Rohwerte des dritten Blocks; die erste Zeitangabe des Harness ist dagegen
das Minimum der drei Blöcke und wird hier nicht mit der Pass-Tabelle vermischt.

| Runde | A Minimum | B Minimum | A dritter Block | B dritter Block | A mobil | B mobil inkl. Planung | Δ mobil B−A |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 57,5 | 56,5 | 61 | 58,1 | 15,85 | 12,98 | -2,87 |
| 2 | 58,8 | 58,3 | 60,3 | 58,3 | 15,65 | 13,05 | -2,6 |
| 3 | 57,4 | 56,7 | 59,3 | 57,7 | 15,51 | 12,92 | -2,59 |
| 4 | 59,4 | 57,7 | 61,9 | 58,5 | 16,03 | 13,12 | -2,91 |

| Pass | A Median | B Median | Δ Mediane | Median der gepaarten Δ |
| --- | ---: | ---: | ---: | ---: |
| Migration + Stempel inkl. Planung | 15,75 | 13,015 | -2,735 | -2,735 |
| `belt.stamp` | 9,355 | — | — | — |
| `belt.migrate` | 6,395 | — | — | — |
| `belt.parallel` | — | 12,795 | — | — |
| `belt.schedule` | — | 0,22 | — | — |
| `belt.fixedStamp` | 1,55 | 1,47 | -0,08 | -0,06 |
| `belt.attach` | 1,265 | 1,21 | -0,055 | -0,045 |
| `priorityFlood` | 14,805 | 15,38 | 0,575 | 0,57 |
| `computeMFDArea` | 4,24 | 4,32 | 0,08 | 0,035 |
| `updateIce` | 2,785 | 2,775 | -0,01 | -0,045 |
| `Hydraulic.erode` | 1,97 | 1,935 | -0,035 | -0,005 |

`belt.parallel` misst die Wandzeit des gesamten parallelen Abschnitts auf dem
aufrufenden Thread, einschließlich Synchronisation und Historien-Übernahme.
Es addiert keine CPU-Zeiten der Arbeiter. `belt.schedule` kommt hinzu.

Das Ziel **mindestens 4 ms weniger im Gesamtschritt ist nicht erreicht**.
Übernommen wird ein kleinerer, bit-identischer Gewinn. Eine neue Zusage für
Abnahmepunkt 48 gegenüber `main` folgt daraus allein nicht: `main` wurde in
dieser Runde nicht erneut mitgemessen. Die 51,9/59,8 ms aus dem Auftrag gehören
zu dessen eigener Messreihe und werden nicht mit diesen Werten verrechnet.

### Abschlussprüfung nach Rebase

`git rebase t3/issue-174-integration` meldete „up to date“; der lokale
Integrationsstand war weiterhin `ea85a7c`. Die Sim-Quellen des gemessenen
`fac991d` bleiben damit unverändert. Nach dem Rebase erneut vollständige
Pflichtsuite, danach die gegatete Überlappungs-Diagnose und ein regulärer
Release-Build des Harness. Alle vier Hash-Fälle wurden nach dem Rebase jeweils
zweimal mit `SimCore/.build/release/simperf` ausgeführt:

| Seed / dt | Start `ea85a7c` | Ende, Lauf 1 | Ende, Lauf 2 |
| --- | --- | --- | --- |
| 1337 / 100 | `08d32575d5cd353a` | `08d32575d5cd353a` | `08d32575d5cd353a` |
| 42 / 100 | `0fd978609f8cc241` | `0fd978609f8cc241` | `0fd978609f8cc241` |
| 20 / 100 | `9df73cb7672f2610` | `9df73cb7672f2610` | `9df73cb7672f2610` |
| 1337 / 15 | `90b5a31c0d94a030` | `90b5a31c0d94a030` | `90b5a31c0d94a030` |

Vor dem Rebase ebenfalls alle vier Werte bestätigt, Seed 1337 / dt 100
zusätzlich wiederholt. Die Hashes umfassen das komplette Zustands-Inventar,
nicht nur die Kanalgeometrie.

Die Pflichtsuite lief vor und nach dem Rebase mit
`swift test -c release --package-path SimCore`:
je **599 Tests, 69 regulär übersprungen, 0 Fehler**. Laufzeit der Tests
186,696 bzw. 185,957 Sekunden, jeweils ohne Build-Zeit. Enthalten sind
`testBeltIsDeterministic`, alle Mäander-/Gürtel-Wächter, `FingerprintTests` und
`DtInvariance`. Zwei unabhängige Quelltext-Reviews (Standards und Auftrag)
fanden keine bestätigten Korrektheitsverletzungen. Die Extension wurde nicht
gebaut.

Die abschließende Rechteck-Diagnose der tatsächlichen Produktionsfenster zählt
5.862 überlappende Paare von 18.665, also **68,59 % unabhängige Paare**.
Gegenüber dem ersten Diagnose-Prototyp kommen durch den Sicherheitsaufschlag
auf die Breite zwei konservative Kanten hinzu. Unverändert sind **1.072 Läufe,
0 isolierte Läufe, 783 Ebenen**, davon **283 mehrfach besetzte Ebenen
(36,14 %)** mit **572 Läufen (53,36 %)**. Der Abhängigkeitsplan kann unabhängige
Läufe verschiedener Ebenen gleichzeitig bearbeiten; die Ebenenzahlen
beschreiben den Graphen, nicht die gemessene CPU-Auslastung.

---

## S. Sim-Kern, Runde 7 (Oktober 2026) — MFD-Routen-Speicher, Inzisions-Gates, Braid-Gate und Carve-Vorfilter vorab, bit-identisch

Startstand `e6d15ea` (Integrationszweig), Branch `t3/174-sim-perf-r7`. Gemessen
am 18.10.2026 auf Apple M4 Max (16 Kerne, 64 GiB, macOS 26.7, Apple Swift 6.4 im
Swift-5-Sprachmodus). Geteilte Maschine: Alle Vergleiche laufen verschränkt
(interleaved, `A B` / `B A` je Runde wechselnd), je 8 Runden, je Prozess
`simperf --repeat 3` (Einlauf 100 × 100 Jahre, drei Messblöcke à 30 × 100 Jahre,
n = 720, world = 112,4789, Seed 1337). Pass-Tabelle = dritter Block,
Gesamtzeit = Minimum der Blöcke (wie §Q). Ausgewertet werden die gepaarten
Differenzen; der Gesamtschritt trennt unter Fremdlast keine Sub-Millisekunden-
Effekte (Lehre aus §P/§Q), die Pass-Zeilen tun es. Vier Änderungen, jede einzeln
gemessen und als eigener Commit übernommen; Baseline `/tmp/simperf.r7-old`.

Fingerprints (`simperf --hash`), nach JEDEM der vier Commits erneut geprüft und
unverändert:

| Seed / dt | Fingerprint |
| ---: | --- |
| 1337 / 100 | `08d32575d5cd353a` |
| 42 / 100 | `0fd978609f8cc241` |
| 20 / 100 | `9df73cb7672f2610` |
| 1337 / 15 | `90b5a31c0d94a030` |

### Änderung 1 (übernommen): MFD-Routen-Speicher von 256 auf ~104 Byte je Zelle geschrumpft

Die MFD-Route reiste als 256-Byte-Struct (zwei komplette `SIMD8<Double>`-
Gewichtssätze plus Zähler) durch Schreibe- und Leseschleife von `computeMFDArea`
— rund 133 MB Schreib- UND Leseverkehr je Schritt allein für den
Zwischenspeicher, obwohl die Mehrheit der Zellen Meer ist und gar keine Route
braucht. Jetzt trägt der Struct nur den dendritischen Satz (Nachbarn + Gewichte
+ Summe, 104 Byte) und wird NUR für Landzellen mit mindestens einem tieferen
Nachbarn geschrieben; der seltene disbursive Satz (Exponent `braidDispersion`)
liegt getrennt in `mfdDispersed` und wird nur für canDisperse-Zellen
geschrieben. Die Klassifikation (−1 Meer/Beckenwasser · 0 flach · c tiefe
Nachbarn, c+10 mit Dispersionsflag) reist als Int8 in `mfdRouteCounts` — für
Meerzellen bleibt vom Zwischenspeicher exakt 1 Byte. Additionskette je
Summen-Akkumulator (aufsteigend in j), Divisions-Operanden und die
Flächen-Schwelle an der angesammelten Fläche (weiterhin seriell entschieden)
sind unverändert.

A = `/tmp/simperf.r7-old`, B = C1-Binary (`a8ec392`). Pass `computeMFDArea`:

| Runde | A Pass | B Pass | Δ Pass | A Gesamt | B Gesamt | Δ Gesamt |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 6,42 | 4,80 | −1,62 | 75,2 | 73,2 | −2,0 |
| 2 | 7,28 | 5,59 | −1,69 | 74,3 | 74,1 | −0,2 |
| 3 | 8,41 | 4,78 | −3,63 | 94,1 | 77,8 | −16,3 |
| 4 | 8,10 | 7,22 | −0,88 | 91,0 | 96,1 | +5,1 |
| 5 | 7,04 | 5,38 | −1,66 | 89,1 | 87,7 | −1,4 |
| 6 | 6,06 | 5,31 | −0,75 | 71,7 | 83,6 | +11,9 |
| 7 | 6,56 | 4,73 | −1,83 | 87,6 | 76,5 | −11,1 |
| 8 | 6,06 | 4,99 | −1,07 | 74,0 | 78,5 | +4,5 |
| **Median** | 7,04 | 4,99 | **−1,64** | 82,3 | 77,2 | **−0,8** |

B gewinnt den Pass in 8/8 Runden; der Gesamtschritt in 5/8 (Fremdlast mit
Einzelrunden von −16 bis +12 ms).

### Änderung 2 (übernommen): Auslass-Inzision — Gate-Kette und kErode vorab parallel

`outletIncision` lief seriell über alle 518k Zellen und zahlte je Zelle
verstreute Lesezugriffe auf sämtliche Gate-Operanden (`h`, `underIce`, `area`,
`endorheicBasin`, `receiver`) und auf den Vegetations-/Lithologie-Faktor
(`veg`, `vegClass`, `vegTypeFactor`, `lithErodeK`), obwohl die meisten Zellen an
einem Gate scheitern. Alle Entscheidungen, die nicht vom laufend veränderten
Bett abhängen, laufen jetzt in EINEM parallelen Sweep (der auch das bisher
separat vorab gerechnete `A^m` übernimmt): die Gate-Kette als Int8 in
`incisionGate` (0 überspringen, 1 normal, 2 Weltrand), der Faktor `kErode` in
`incisionKErode`. Bit-identisch, weil der Pass nur je BESUCHTER Zelle schreibt
(`h`/`sed`/`rock` an `k` selbst — jede Zelle sieht bei ihrem Besuch noch exakt
die Pass-Startwerte) und `underIce`/`area`/`receiver`/`endorheicBasin`/`veg*`/
`lith*` im Pass überhaupt nicht geschrieben werden. Der frische
Empfänger-Höhen-Lesezugriff, die Implizit-Solver-Formel und der
Sediment/Fels-Split bleiben seriell und unverändert.

A = C1-Binary, B = C2-Binary (`4c479e5`). Pass `outletIncision`:

| Runde | A Pass | B Pass | Δ Pass | A Gesamt | B Gesamt | Δ Gesamt |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 4,74 | 3,33 | −1,41 | 73,7 | 74,8 | +1,1 |
| 2 | 4,50 | 3,53 | −0,97 | 66,2 | 71,8 | +5,6 |
| 3 | 4,35 | 2,98 | −1,37 | 69,5 | 68,0 | −1,5 |
| 4 | 6,89 | 3,47 | −3,42 | 60,4 | 74,4 | +14,0 |
| 5 | 4,08 | 2,88 | −1,20 | 65,8 | 63,5 | −2,3 |
| 6 | 3,98 | 2,98 | −1,00 | 63,0 | 62,6 | −0,4 |
| 7 | 3,73 | 2,72 | −1,01 | 59,8 | 56,3 | −3,5 |
| 8 | 3,63 | 2,77 | −0,86 | 55,9 | 55,7 | −0,2 |
| **Median** | 4,22 | 2,98 | **−1,11** | 64,8 | 67,8 | **−0,3** |

B gewinnt den Pass in 8/8 Runden; der Gesamtschritt in 5/8 (Runde 4 mit +14 ms
Fremdlast auf der B-Seite zeigt, warum nur gepaarte Differenzen zählen).

### Änderung 3 (übernommen): Braid-Gate und inaktiver Depositions-Deckel vorab parallel

`braidPass` läuft über alle Zellen in `order` rückwärts, auch wenn nur wenige
ein Braid-Reach sind; der active-Test kostete je Zelle vier verstreute
Lesezugriffe (`areaMFD`, `hf`, `h` ×2). Er lässt sich vorab und parallel
entscheiden, weil seine Operanden bis zum eigenen Besuch unverändert bleiben:
`hf` und `areaMFD` schreibt der Pass gar nicht, und `h[k]` ändert sich
ausschließlich im Funnel von k's EIGENEM Besuch (`erodeCell`/`depositCell`
schreiben nur die Zelle `k`, s. Bed-Funnel). Dasselbe gilt für den
Depositions-Deckel der inaktiven Landzellen (`hf + braidDeltaCeiling − h`), der
mitvorberechnet in `braidDepositCeil` reist. Der serielle Loop liest ein
Status-Byte (`braidStatus`: 0 Meer, 1 inaktives Land, 2 aktiv) und geht nur die
Wege, die der Originalcode auch gegangen wäre.

A = C2-Binary, B = C3-Binary (`a0324c3`). Pass `braidPass`:

| Runde | A Pass | B Pass | Δ Pass | A Gesamt | B Gesamt | Δ Gesamt |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 2,40 | 2,30 | −0,10 | 58,3 | 57,6 | −0,7 |
| 2 | 2,27 | 2,15 | −0,12 | 58,1 | 57,0 | −1,1 |
| 3 | 2,27 | 2,40 | +0,13 | 57,9 | 59,8 | +1,9 |
| 4 | 2,37 | 2,30 | −0,07 | 60,2 | 60,2 | 0,0 |
| 5 | 2,25 | 2,15 | −0,10 | 57,9 | 57,7 | −0,2 |
| 6 | 2,29 | 2,30 | +0,01 | 58,0 | 59,9 | +1,9 |
| 7 | 2,30 | 2,15 | −0,15 | 57,3 | 56,7 | −0,6 |
| 8 | 2,29 | 2,17 | −0,12 | 58,1 | 57,1 | −1,0 |
| **Median** | 2,29 | 2,30 | **−0,10** | 58,05 | 57,7 | **−0,4** |

B gewinnt den Pass in 6/8 Runden, Band auf beiden Seiten eng (2,15–2,40 ms).
Ein kleiner, aber konsistenter Gewinn; die Gesamtzeit liegt im Rauschen.

### Änderung 4 (übernommen): `channelCarve` — area/Gürtel-Vorfilter vorab parallel

Nur Zellen mit `area ≥ channelFlowMinCells` außerhalb des Mäandergürtels können
überhaupt carven — eine kleine Minderheit. `area` und `inBelt` sind die
einzigen zwei Gates des Passes, deren Operanden sich während des Passes nicht
ändern; der kombinierte Obermengen-Filter läuft jetzt vorab und parallel in
`carveStatus`. Reine `continue`-Filter darf man vorziehen (ihr Ergebnis ist
pro Zelle identisch, egal in welcher Reihenfolge sie geprüft werden); alle
übrigen Gates (Meer, See-Rand, Gürtel-Flachheit) lesen frisches `h` — die
Ufer-Erosion schreibt FREMDE Zellen, `h[k]` ist zum Besuchszeitpunkt nicht der
Pass-Startwert — und bleiben unverändert im seriellen Loop, der jetzt ~95 %
der Zellen nach einem Status-Byte überspringt.

A = C3-Binary, B = C4-Binary (`5807b3c`). Pass `channelCarve`:

| Runde | A Pass | B Pass | Δ Pass | A Gesamt | B Gesamt | Δ Gesamt |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1,46 | 0,43 | −1,03 | 57,0 | 56,8 | −0,2 |
| 2 | 1,21 | 0,44 | −0,77 | 55,7 | 57,0 | +1,3 |
| 3 | 1,35 | 0,53 | −0,82 | 61,1 | 59,1 | −2,0 |
| 4 | 1,34 | 0,45 | −0,89 | 59,2 | 58,6 | −0,6 |
| 5 | 1,26 | 0,46 | −0,80 | 59,5 | 59,8 | +0,3 |
| 6 | 1,20 | 0,46 | −0,74 | 57,7 | 58,5 | +0,8 |
| 7 | 1,20 | 0,44 | −0,76 | 57,2 | 57,3 | +0,1 |
| 8 | 1,21 | 0,45 | −0,76 | 57,9 | 57,0 | −0,9 |
| **Median** | 1,28 | 0,45 | **−0,79** | 57,55 | 57,9 | **−0,05** |

B gewinnt den Pass in 8/8 Runden (inklusive des neuen parallelen Vorfilter-
Sweeps). Der Gesamtschritt ist hier — wie in §P/§Q — zu träge, um einen
Sub-Millisekunden-Effekt unter Fremdlast zu trennen (4/8, Median −0,05).

### Gesamtschritt alt gegen Endstand

A = `/tmp/simperf.r7-old` (`e6d15ea`), B = Endstand (`5807b3c`), 8 Runden
verschränkt. Die Pass-Zeilen sind über die vier Einzelmessungen oben belegt;
hier zählt der Gesamtschritt:

| Runde | A alt | B final | Δ B−A |
| ---: | ---: | ---: | ---: |
| 1 | 63,1 | 60,1 | −3,0 |
| 2 | 60,3 | 58,1 | −2,2 |
| 3 | 62,0 | 56,7 | −5,3 |
| 4 | 58,9 | 58,8 | −0,1 |
| 5 | 57,1 | 54,1 | −3,0 |
| 6 | 57,8 | 53,7 | −4,1 |
| 7 | 58,6 | 55,2 | −3,4 |
| 8 | 58,5 | 55,4 | −3,1 |
| **Median** | 58,7 | 56,6 | **−3,05** |

B gewinnt 8/8 Paare, gepaarter Median **−3,05 ms** — konsistent mit der Summe
der Pass-Mediane (−1,64 − 1,11 − 0,10 − 0,79 = −3,64 ms abzüglich der
Vorfilter-Sweeps, die in den Pass-Zeilen bereits eingerechnet sind, plus
Messrauschen). Zur Orientierung die Pass-Tabelle je eines ruhigen Paarlaufs
(dritter Block, hintereinander, nicht gepaart): `computeMFDArea` 5,38 → 4,13,
`outletIncision` 4,02 → 2,94, `channelCarve` 1,37 → 0,55, `braidPass`
2,45 → 2,51 (im Rauschen; der gepaarte Gewinn dieser Änderung liegt bei
−0,10 ms), Gesamt 66,4 → 62,5 ms/Schritt.

### Nicht weiterverfolgt (mit Begründung)

- **`computeReceiversAndArea`** (≈ 2 ms): Die Empfänger-Suche ist bereits
  zeilenparallel mit festen 8-Offset-Zweig und Roh-Puffern; die
  Flächen-Akkumulation ist eine strikt serielle Abhängigkeitskette
  (`pa[r] += pa[k]` in `order` rückwärts — der Empfänger eines Zuflusses muss
  bereits vollständig eingesammelt sein). Kein bit-identischer Hebel mit
  klarem Kopfroom übrig.
- **`wavePass`** (≈ 1,4 ms): Eine Band-Maske (`|h − sea| ≤ waveBand`) ließe
  sich vorab berechnen, wird aber während des Passes STALE — der Pass verschiebt
  Material ZELLE-für-Zelle, Zellen können dabei ins Band ein- und austreten
  (auch der EMPFÄNGER kann aufsteigen). Der Scan selbst läuft bereits
  sequenziell über ein 4-MB-Feld mit gutem Ort.
- **`computeRain`** (≈ 1,3 ms): Der orographische EWMA-Sweep ist bereits über
  `parallel(nn)` in 64 Zeilenblöcken parallel; die Land-Mittel in
  `updateRainWeight`/`updateRunoffWeight` müssen SEQUENZIELL laufen (feste
  FP-Reihenfolge → bit-genau, AGENTS.md). Eine Block-Reduktion würde die
  Additionskette ändern — nicht erlaubt.
- **`applyUplift`** (≈ 0,6 ms): Reine per-Zelle-Arithmetik, bereits parallel
  mit Roh-Puffern; kein messbarer Kopfroom.

### Reproduktion

```sh
swift build -c release --package-path SimCore
SimCore/.build/release/simperf --hash --seed 1337        # 08d32575d5cd353a
SimCore/.build/release/simperf --hash --seed 42          # 0fd978609f8cc241
SimCore/.build/release/simperf --hash --seed 20          # 9df73cb7672f2610
SimCore/.build/release/simperf --hash --seed 1337 --dt 15  # 90b5a31c0d94a030
SimCore/.build/release/simperf --repeat 3                # Pass-Tabelle
```

Pflichtsuite nach dem Endstand (`swift test -c release --package-path SimCore`):
**611 Tests, 71 übersprungen, 0 Fehler**
(212,8 s ohne Build). Die Hashes sind Pro-Maschine-Werte (System-libm);
verglichen wird vor/nach auf DERSELBEN Maschine.

### Gegenmessung und Übernahme

Vor der Übernahme in den Integrationszweig selbst nachgemessen (2026-10-18,
M4 Max, geteilte Maschine, Last 5–9): Basis `e6d15ea` gegen die vier
Perf-Commits, acht Paare `--repeat 3` mit wechselnder Reihenfolge, Minimum
der drei Blöcke.

| Größe | Basis | Runde 7 | gepaart | Siege |
| --- | ---: | ---: | ---: | ---: |
| Gesamtschritt | 58,65 | 55,45 | **−3,25 ms** | 8/8 |
| `computeMFDArea` | 4,37 | 3,37 | −1,00 ms | 8/8 |
| `outletIncision` | 3,56 | 2,73 | −0,86 ms | 8/8 |

Hashes je zweimal gleich (1337, 42, 20 und 1337 bei dt 15). Geprüft am Code:
die Vorab-Entscheidungen von Inzision und Braid lesen nur Felder, die der
Pass nicht schreibt, oder `h` der Zelle selbst, die nur ihr eigener Besuch
ändert (`erodeCell`/`depositCell` bekommen ausschließlich die besuchte
Zelle); der `kErode`-Ausdruck ist Glied für Glied derselbe.

**Verworfen bei der Übernahme:** der verzweigungsfreie Innenteil von
`dilateDamped` (nächtlicher PR #190, dort −1,7 ms in `updateVegetation` auf
dem Linux-Host gemessen). Bit-identisch (die Uferwald-Maske ist 0/1 und wird
mit `max` und 0,65 erweitert, also nie negativ), aber hier im selben
Acht-Paar-Lauf nur −0,05 ms in `updateVegetation` (6/8): mehr Code ohne
messbaren Gewinn auf dem Referenz-Mac.

## T. Übergänge im Zeitraffer (Oktober 2026, Befund zu Punkt 50)

Einwachsen, Versiegen und Wald-Rückzug (`docs/zielbild-measurements.md`
§ Übergänge im Zeitraffer). M4 Max, Produktions-Config, Seed 1337.

**Sim-Schritt** (`simperf --repeat 1`, 8 Paare, Reihenfolge je Paar
wechselnd): `main` 56,1–56,7 ms, neu 56,0–56,9 ms; Median der Paardifferenz
+0,15 ms (0,3 %), 2 Paare schneller, eines gleich. Fingerabdruck bit-gleich.
Die erste Fassung (volles `born`-Array je Lauf, in jeder Neuabtastung
interpoliert) lag in 6/6 Paaren 0,1–1,0 ms darüber (Median +0,4 ms); seither
ist `born` leer, solange ein Lauf keinen jungen Knoten hat, und die Kopplung
setzt Geburtsjahre älter als das Einwachsen wieder auf −∞.

**Frame-Aufbereitung** (`RenderState.frame` im emulierten 60-J./Sek.-Zeitraffer,
Jahr 20.000 → 22.505, 167 Takte, 83 Uploads, 41 Band-Bauten; je Stand zwei
Läufe, abwechselnd; ad hoc gemessen, nicht eingecheckt):

| Stand | ms je Upload | ms je Frame mit Band-Bau |
| --- | ---: | ---: |
| `main` | 30,2–31,2 | 34,9–36,1 |
| erste Fassung | 33,2–33,8 | 40,6–41,3 |
| eingecheckt | 32,0–32,4 | 37,6–38,3 |

Aufgeteilt (Summe über den Lauf): Band-Bau 415 → 471 ms, davon Fluss-Schleife
+41 ms und versiegende Arme 13 ms; Wald +14 ms; Rest im Rauschen. Zwei
Ursachen der ersten Fassung lagen an Klassen-Properties in inneren Schleifen
(`matureCoverage` je Zelle im Deckungs-Stempel, `youngYear` je Zelle im
Kopplungsbau, beide mit Exklusivitätsprüfung): auf Roh-Zeiger umgestellt.
Die versiegenden Arme geben nur die unverdeckten Stücke aus. Das alles läuft
im Hintergrund-Job (`BackgroundJob`), nicht auf dem Hauptthread; je
Zeitraffer-Takt sind das gut 1 % der Hintergrund-Arbeit.

## U. Vorab-Berechnung der Auslass-Inzision auf aktive Zellen beschränkt (Oktober 2026) — bit-identisch

### Was geändert wurde

In `Terrain.outletIncision` berechnete der parallele Vorfilter bisher
`pap[k] = pow(pa[k], m)` sowie `pker[k]` für ALLE 518.400 Zellen des Gitters
vorab — auch für Ozeanzellen (`ph0[k] <= sea`), vergletscherte Zellen, Seeflächen
und abflusslose Senken. Für all diese inaktiven Zellen setzt die Gate-Kette
`pgate[k] = 0`. In der anschließenden seriellen Schleife über `order` verwirft
`if g == 0 { continue }` die Zelle sofort; weder `pap[k]` noch `pker[k]` werden
dort jemals gelesen.

Mit `guard g != 0 else { continue }` vor der `pow`- und `kErode`-Berechnung
entfallen die teuren `libm`-`pow`-Aufrufe und Tabellenabfragen für die rund
200.000+ inaktiven Ozean- und Seegitterzellen vollständig. Für alle aktiven
Zellen (`g != 0`) bleiben Eingangsgrößen, Aufrufe und Reihenfolge exakt
dieselbe Rechnung; die nachgelagerte serielle Inzision rechnet bit-identisch.

### Gemessen

Verschränkte A/B-Messung in einer Sitzung (`/tmp/simperf-old` vs `/tmp/simperf-new`,
jeweils `--repeat 3`, 30 Schritte à dt=100.0, Seed 1337):

- **Lauf 1 (alt → neu):**
  - Alt: 171,3 / 168,9 / 163,5 ms/Schritt (Minimum: 163,5 ms), `outletIncision`: 9,46 ms
  - Neu: 158,8 / 156,2 / 161,2 ms/Schritt (Minimum: 156,2 ms), `outletIncision`: 8,65 ms (−0,81 ms / −8,6 %)
- **Lauf 2 (neu → alt, umgekehrte Reihenfolge gegen VM-Drift):**
  - Neu: 162,6 / 148,8 / 151,3 ms/Schritt (Minimum: 148,8 ms), `outletIncision`: 8,11 ms
  - Alt: 161,9 / 157,7 / 159,4 ms/Schritt (Minimum: 157,7 ms), `outletIncision`: 9,24 ms (−1,13 ms / −12,2 %)

Der Pass `outletIncision` sinkt stabil um **0,8 bis 1,1 ms/Schritt** (−9 % bis −12 %).

### Bit-Identität

Fingerprints (`simperf --hash`) auf allen Seeds und Zeitschrittweiten exakt identisch:

| Seed / Konfiguration | Fingerprint vorher | Fingerprint nachher | Status |
| --- | --- | --- | --- |
| Seed 1337, dt = 100 | `7667d3585b1f1904` | `7667d3585b1f1904` | bit-identisch |
| Seed 42, dt = 100 | `758727b1ae0866a8` | `758727b1ae0866a8` | bit-identisch |
| Seed 20, dt = 100 | `629eb937b51dfe81` | `629eb937b51dfe81` | bit-identisch |
| Seed 1337, dt = 15 | `764c3535772abcdd` | `764c3535772abcdd` | bit-identisch |

## V. Vegetations-Pass: Box-Maximum zeilenweise gestrafft und Makro-Steigung in Vegetations-Klassen gegatet (Oktober 2026) — bit-identisch

### Was geändert wurde

1. **Separables Box-Maximum der Samenausbreitung gestrafft:** In `Terrain.updateVegetation`
   iterierte das Spalten-Maximum (Pass 2) bisher je Spaltenindex `i` über `dj` und griff
   mit Zeilensprüngen (`dj * nn + i`) über das Array zu. Durch Vertauschen der Schleifen
   wird für jede Zeile `j` zuerst die Startzeile kopiert und anschließend jede Nachbarzeile
   in einer linearen, cache-lokalen Schleife mit `max` akkumuliert. Das vermeidet 518.400
   `ClosedRange`-Instanziierungen und nicht-sequenzielle Speicherzugriffe. Im Zeilen-Maximum
   (Pass 1) werden die inneren Zellen für den Standardfall `dr = 2` direkt ohne
   Randprüfungen entrollt.
2. **Makro-Steigungsberechnung in `updateVegClass` gegatet:** In Pass 3 von `updateVegClass`
   wurde `Terrain.macroSlope(ph, k, nn)` bisher für jede Landzelle mit `v >= 0.12`
   berechnet (~150.000 Zellen). Die Steigung wird im Entscheidungsbaum jedoch ausschließlich
   für Auwald-Kandidaten benötigt (`prip[k] >= 0.4 && v >= 0.25 && phf[k] - ph[k] <= 0.02 && slope * 40 < 0.6`).
   Durch Kurzschlussauswertung am Ende dieser Bedingung entfallen für über 90 % der
   Landzellen 4 Speicherzugriffe und Absolutwertdifferenzen vollständig.

### Gemessen

Verschränkte A/B-Messung in einer Sitzung (`/tmp/simperf-old` vs `/tmp/simperf-new`,
jeweils `--repeat 3`, 30 Schritte à dt=100.0, Seed 1337):

- **Paar 1 (alt → neu):**
  - Alt: 161,9 / 156,7 / 164,1 ms/Schritt (Minimum: 156,7 ms), `updateVegetation`: 9,48 ms
  - Neu: 152,9 / 152,1 / 159,8 ms/Schritt (Minimum: 152,1 ms), `updateVegetation`: 8,07 ms (−1,41 ms / −14,9 %)
- **Paar 2 (neu → alt, umgekehrte Reihenfolge gegen VM-Drift):**
  - Neu: 158,8 / 162,1 / 159,2 ms/Schritt (Minimum: 158,8 ms), `updateVegetation`: 8,20 ms
  - Alt: 170,9 / 169,2 / 165,4 ms/Schritt (Minimum: 165,4 ms), `updateVegetation`: 9,77 ms (−1,57 ms / −16,1 %)

Der Pass `updateVegetation` sinkt stabil um **1,4 bis 1,6 ms/Schritt** (−15 % bis −16 %).

### Bit-Identität

Fingerprints (`simperf --hash`) auf allen Seeds und Zeitschrittweiten exakt identisch:

| Seed / Konfiguration | Fingerprint vorher | Fingerprint nachher | Status |
| --- | --- | --- | --- |
| Seed 1337, dt = 100 | `7667d3585b1f1904` | `7667d3585b1f1904` | bit-identisch |
| Seed 42, dt = 100 | `758727b1ae0866a8` | `758727b1ae0866a8` | bit-identisch |
| Seed 20, dt = 100 | `629eb937b51dfe81` | `629eb937b51dfe81` | bit-identisch |
| Seed 1337, dt = 15 | `764c3535772abcdd` | `764c3535772abcdd` | bit-identisch |

## VI. Knotenhöhen in BeltGeometry zwischengespeichert (Oktober 2026) — bit-identisch

### Was geändert wurde

In `MeanderState.beltGeometry` und `updateBeltMobility` wurde für jeden Knoten `i`
entlang der Flussläufe (`ch.nodes`) in `beltMobility` mehrfach `heightAt` aufgerufen
(`nodes[i - ks]`, `nodes[i + ks]`, `nodes[i]`). Jedes `heightAt` interpoliert
bilinear auf `bed.h`. Zusätzlich rief `beltRatesAndErodibility` für jeden Knoten `i`
beim Berechnen der Uferbremse (`wall - heightAt(nodes[i])`) erneut `heightAt(nodes[i])` auf.

Durch Speichern der Knotenhöhen in `BeltGeometry.h` (einmalig pro Knoten vorab
berechnet) entfallen alle redundanten bilinearen Abtastungen in `beltMobility` und
`beltRatesAndErodibility`. Die Knotenhöhen werden direkt aus dem Array gelesen.

### Gemessen

Verschränkte A/B-Messung in einer Sitzung (`simperf --repeat 3`, 30 Schritte à dt=100.0, Seed 1337):

- **Lauf 1 (alt → neu):**
  - Alt: 180,8 / 184,7 / 183,3 ms/Schritt (Minimum: 180,8 ms), `belt.parallel`: 45,82 ms
  - Neu: 158,4 / 163,2 / 170,8 ms/Schritt (Minimum: 158,4 ms), `belt.parallel`: 40,38 ms (−5,44 ms / −11,9 %)
- **Lauf 2 (neu → alt, umgekehrte Reihenfolge gegen VM-Drift):**
  - Neu: 175,4 / 170,7 / 164,1 ms/Schritt (Minimum: 164,1 ms), `belt.parallel`: 38,50 ms
  - Alt: 175,4 / 183,8 / 187,5 ms/Schritt (Minimum: 175,4 ms), `belt.parallel`: 45,52 ms (−7,02 ms / −15,4 %)

Der Pass `belt.parallel` sinkt stabil um **5,4 bis 7,0 ms/Schritt** (−12 % bis −15 %).

### Bit-Identität

Fingerprints (`simperf --hash`) auf Seed 1337 (dt = 100 und dt = 15), Seed 42 und Seed 20
sind vor und nach der Änderung bit-identisch.

## VII. Braid-Pass: Vorfilter gestrafft, inaktiver Depositions-Puffer entfernt und Nachbarsuche entrollt (Oktober 2026) — bit-identisch

### Was geändert wurde

In `Terrain.braidPass`:
1. **Ozeanzellen im Vorfilter sofort abfangen:** Für alle Ozeanzellen (`phf[k] <= sea`, ~40 % des Gitters) ist `active` per Definition ausgeschlossen. Durch Vorziehen des Tests `if phf[k] <= sea { pst[k] = 0; continue }` entfallen für über 200.000 Zellen die Lesezugriffe auf `areaMFD` und `h`.
2. **`braidDepositCeil`-Arbeitspuffer eliminiert:** Der 4,1-MB-Puffer (`[Double]` mit 518.400 Elementen) wurde bisher im parallelen Vorfilter für alle Landzellen berechnet und geschrieben, im anschließenden seriellen Durchlauf über `order` aber ausschließlich dann gelesen, wenn `st == 1 && qin > 0` galt — was fast nie der Fall ist (nur wo MFD-Braid-Zuflüsse Fracht in nicht-aktive Seeränder/Deltas abgeben). Weil `h[k]` und `phf[k]` bis zum Besuch von `k` exakt ihren Ausgangswerten entsprechen, wird der Deckel `max(0, phf[k] + deltaCeiling - bed.h[k])` jetzt on-demand nur noch im seltenen Fall `qin > 0` berechnet. Das spart 4,15 MB Speicherallokation und Schreib-/Lese-Verkehr je Schritt.
3. **Nachbarsuche für innere Zellen entrollt:** Wie in `computeMFDArea` und `computeReceiversAndArea` werden die 8 Nachbarn auf inneren Zellen (`0 < i < n-1, 0 < j < n-1`) ohne 2D-Schleife, Modulo/Multiplikation und Randprüfungen direkt über feste Offsets abgefragt.

### Gemessen

Verschränkte A/B-Messung in einer Sitzung (`/tmp/simperf-baseline` vs `/tmp/simperf-opt`,
jeweils `--repeat 3`, 30 Schritte à dt=100.0, Seed 1337):

- **Paar 1 (Baseline → Opt):**
  - Baseline: 172,9 / 168,3 / 166,7 ms/Schritt (Minimum: 166,7 ms), `braidPass`: 7,22 ms
  - Opt: 170,9 / 167,7 / 172,6 ms/Schritt (Minimum: 167,7 ms), `braidPass`: 6,86 ms (−0,36 ms)
- **Paar 2 (Opt → Baseline, umgekehrte Reihenfolge gegen VM-Drift):**
  - Opt: 165,9 / 164,4 / 168,5 ms/Schritt (Minimum: 164,4 ms), `braidPass`: 6,47 ms
  - Baseline: 169,5 / 178,6 / 177,5 ms/Schritt (Minimum: 169,5 ms), `braidPass`: 8,29 ms (−1,82 ms / −22 %)

Der Pass `braidPass` gewinnt in beiden Paaren messbar und stabil (−0,36 bis −1,82 ms/Schritt).

## VIII. Hangdiffusion: Flache Zellen abgefangen, Felsfaktor gegatet und Randprüfungen entrollt (Oktober 2026) — bit-identisch

### Was geändert wurde

In `Terrain.hillslopeDiffusion`:
1. **Flache Zellen sofort abfangen:** Für alle flachen Gitterzellen (gesamter Ozean, Seen und ebene Ebenen; über 40 % des Gitters) ist der Laplace-Operator `lap = hl + hr + hd + hu - 4 * ph[k]` exakt 0. Durch `if lap == 0 { psc[k] = 0; continue }` entfallen für über 200.000 Zellen die Berechnung des Gradienten, die Gleitkomma-Wurzel (`squareRoot()`), die Abfragen von `bare` und `soil` sowie die Lesezugriffe auf `psed`, `pveg`, `lithHardness` und `area` vollständig. Das Ergebnis `psc[k] = 0` ist bit-identisch zu `localK * 0.0`.
2. **Kahler-Fels-Faktor auf Hochlagen beschränkt:** Der Fels-Schutzfaktor `high = min(1, max(0, (ph[k] - 0.42) / 0.35))` ist für alle Lagen `ph[k] <= 0.42` mathematisch exakt 0.0, womit `bare = 0.0` und `1 - 0.92 * bare = 1.0` gilt. Durch Kapseln der Felsberechnung in `if ph[k] > 0.42` entfallen für alle verbleibenden Tiefland- und Hügelzellen die Gradienten-Norm, die Quadratwurzel und die Speicherzugriffe auf `sed` und `veg`.
3. **Randprüfungen für innere Zellen entrollt:** Für alle inneren Zellen (`0 < i < nn - 1, 0 < j < nn - 1`, rund 99 % des Gitters) werden die 4 Nachbarhöhen ohne bedingte Verzweigungen direkt geladen.

### Gemessen

Verschränkte A/B-Messung in einer Sitzung (`/tmp/simperf-old` vs `/tmp/simperf-new`,
jeweils `--repeat 3`, 30 Schritte à dt=100.0, Seed 1337):

- **Paar 1 (alt → neu):**
  - Alt: 182,8 / 183,7 / 178,2 ms/Schritt (Minimum: 178,2 ms), `hillslopeDiffusion`: 2,59 ms
  - Neu: 175,8 / 173,2 / 185,5 ms/Schritt (Minimum: 173,2 ms), `hillslopeDiffusion`: 1,78 ms (−0,81 ms / −31,3 %)
- **Paar 2 (neu → alt, umgekehrte Reihenfolge gegen VM-Drift):**
  - Neu: 172,5 / 177,8 / 185,8 ms/Schritt (Minimum: 172,5 ms), `hillslopeDiffusion`: 1,84 ms
  - Alt: 165,1 / 162,2 / 168,6 ms/Schritt (Minimum: 162,2 ms), `hillslopeDiffusion`: 2,26 ms (−0,42 ms / −18,6 %)

Der Pass `hillslopeDiffusion` sinkt stabil um **0,42 bis 0,81 ms/Schritt** (−19 % bis −31 %).

### Bit-Identität

Fingerprints (`simperf --hash`) auf allen Seeds und Zeitschrittweiten exakt identisch:

| Seed / Konfiguration | Fingerprint vorher | Fingerprint nachher | Status |
| --- | --- | --- | --- |
| Seed 1337, dt = 100 | `7667d3585b1f1904` | `7667d3585b1f1904` | bit-identisch |
| Seed 42, dt = 100 | `758727b1ae0866a8` | `758727b1ae0866a8` | bit-identisch |
| Seed 20, dt = 100 | `629eb937b51dfe81` | `629eb937b51dfe81` | bit-identisch |
| Seed 1337, dt = 15 | `764c3535772abcdd` | `764c3535772abcdd` | bit-identisch |




## VIII. Eine Bett-Regel für jeden Schreiber (Oktober 2026, Issue #96) — bit-identisch

### Umbau

Auslass-Inzision, Tropfenschleife und Pinsel schreiben seit #96 ausschließlich
über den Bett-Funnel; Regel (erst Sediment, dann Fels) und Gletscher-Gate
stehen einzig in `Terrain.Bed.erode/deposit`. Drei Konstruktionen dabei:

1. **Ziel-Fassung `erodeCellTo`** für die Auslass-Inzision: sie schreibt die
   Zielhöhe `hNew` EXAKT statt `h −= (h − hNew)`. Der Rundtrip
   `h − fl(h − hNew)` ist im aggressiven Regime (Abtrag > halbe Höhe, große
   Becken-Auslässe) NICHT bit-gleich zu `hNew` — Stichprobe über 20 Mio.
   Wertepaare der Inzisionsformel: **29,4 % aller Abträge weichen um 1 ulp ab**
   (im Regime `hNew < h/2`: 5,9 Mio. von 9,9 Mio. ≈ **59 %**). Die naive
   `erodeCell`-Übergabe des Deltas hätte den Fingerprint also brechen
   müssen; die Ziel-Fassung hält ihn (s. u.). Pinnning-Wächter mit
   konkretem Gegenbeispiel (h = 1.3, target = 0.3):
   `BedFunnelTests.testTargetFasciaRoundtripIsNotBitIdentical`.
2. **Eis-Zeile aus der Inzisions-Gate-Kette entfernt**: vergletscherte Zellen
   laufen jetzt durch die Vorab-Kette und die serielle Formel, der Funnel
   verwirft den Abtrag. Ergebnis bit-identisch, aber Formel-Arbeit mehr auf
   Eis-Zellen — das ist die einzige messbare Kostenstelle (s. u.).
3. **Tropfen-`deposit` rekonstruiert die Suspension-Fracht** aus dem
   `Bed.deposit`-Rückgabewert (`amount − deposited`): gesperrte Zellen
   liefern 0 zurück, die Fracht bleibt wie bisher in Suspension — dieselbe
   Arithmetik wie vor dem Umbau, bit-identisch.

### Gemessen (Apple-Silicon-Arbeitsplatz dieses Agenten, arm64, `--repeat 3`, 30 Schritte à dt=100, Seed 1337)

| Größe | vorher | nachher | Bewertung |
| --- | --- | --- | --- |
| Fingerprint `--hash` | `31835ab8b1a85069` | `31835ab8b1a85069` | bit-identisch (nach JEDEM Teilschritt geprüft) |
| ms/Schritt gesamt | 62,9 | 60,3–62,0 (2 Läufe) | im Lauf-zu-Lauf-Rauschen |
| `outletIncision` | 2,61 ms | 2,80–2,83 ms | **+0,2 ms** — Eis-Zellen rechnen die Formel, der Funnel verwirft |
| `Hydraulic.erode` | 2,12 ms | 2,09–2,18 ms | im Rauschen (Regel via `Bed.erode` inline) |

Der +0,22-ms-Posten ist der bewusste Preis dafür, dass das Eis-Gate nur noch
EINMAL steht und in keinem künftigen Pass vergessen werden kann; er beträgt
0,35 % des Schritts. Der Pinsel läuft nicht im Fingerprint (kein Nutzereingriff
im Mess-Harness); seine Funnel-Fassungen öffnen die Sicht je Zelle — einige
Tausend Zellen je Strich, irrelevant gegen den Schritt.

## IX. Zuflüsse an Vorfluter anbinden: Raster-Kandidaten vorab abgeflacht und Endknoten gefiltert (Oktober 2026) — bit-identisch

### Was geändert wurde

In `MeanderState.attachTributaries` (Pass `belt.attach`):
1. **Endknoten vorab aus dem Bin-Gitter filtern:** Die letzten 3 Knoten jedes Laufs (`nj >= ch.nodes.count - 3`) zählen per Definition nie als gültiges Mündungsziel für andere Läufe (sie liegen auf der Mündungszelle und führen den Abfluss des größeren Vorfluters). Bisher wurden sie ins Bin-Gitter eingetragen und erst in der innersten `while e >= 0`-Suchschleife je Nachbarzelle abgefragt. Durch die Vorfilterung `for ni in 0..<max(0, ch.nodes.count - 3)` entfallen diese Knoten vorab aus dem Gitter, womit das Array `flatN` und die Indexgrenzen-Prüfung in der inneren Schleife komplett entfallen.
2. **Kandidatenknoten, Gürtelbreiten und Endabflüsse vorab abflachen:** Bisher griff jeder Schritt der Nachbarsuche (`while e >= 0`) über `snap[cj].nodes[nj]`, `snap[cj].discharge.last` und `snap[cj].discharge[nj]` auf verschachtelte Array-Properties von Channel-Objekten zu und berechnete `Self.beltWidthCells` (inkl. `squareRoot()`) wiederholt für dieselben Knoten in überlappenden Suchfenstern. Durch Vorabberechnung in flache Puffer (`flatNode`, `flatWidth`, `flatQEnd`) mit vorab reservierter Kapazität (`reserveCapacity`) werden alle Feldzugriffe im Suchgitter zu einfachen Pointer-/Array-Indizierungen ohne Wiederholungsrechnung oder Property-Overhead.
3. **Closure-Allokationen eliminiert & Inverser Zellabstand:** Die dynamische Closure `reach` in `nearestBigger` wurde durch einen einfachen Bool-Zweig (`isTributary ? 0.5 * (bA + bB) : 2 * bB`) ersetzt; `qaEnd` wird pro Kanal nur noch einmal statt in jedem `nearestBigger`-Aufruf geladen; Koordinaten-zu-Bin-Divisionen wurden auf `* invCell` (0.125) umgestellt.

### Gemessen

Verschränkte A/B-Messung in einer Sitzung (`/tmp/simperf-baseline` vs `/tmp/simperf-opt`,
jeweils `--repeat 3`, 30 Schritte à dt=100.0, Seed 1337):

- **Paar 1 (Baseline → Opt):**
  - Baseline: 167,4 / 180,5 / 175,8 ms/Schritt (Minimum: 167,4 ms), `belt.attach`: 2,60 ms
  - Opt: 176,1 / 182,4 / 168,5 ms/Schritt (Minimum: 168,5 ms), `belt.attach`: 1,78 ms (−0,82 ms / −31,5 %)
- **Paar 2 (Opt → Baseline, umgekehrte Reihenfolge gegen VM-Drift):**
  - Opt: 168,7 / 183,1 / 179,2 ms/Schritt (Minimum: 168,7 ms), `belt.attach`: 1,93 ms
  - Baseline: 175,6 / 179,3 / 175,1 ms/Schritt (Minimum: 175,1 ms), `belt.attach`: 2,49 ms (−0,56 ms / −22,5 %)

Der Pass `belt.attach` sinkt stabil um **0,56 bis 0,82 ms/Schritt** (−22 % bis −31 %).

### Bit-Identität

Fingerprints (`simperf --hash`) auf Seed 1337 (dt = 100 und dt = 15), Seed 42 und Seed 20
sind vor und nach der Änderung bit-identisch.

## X. MFD-Pass: Vektor-Registerspills im Nachbar-Loop eliminiert, orthogonale Divisionen eingespart und Routenspeicher gestrafft (Oktober 2026) — bit-identisch

### Was geändert wurde

In `Terrain.computeMFDArea`:
1. **Vektor-Registerspills im inneren Nachbar-Loop eliminiert:** Im parallelen Pass 1 waren `neighbors` (`SIMD8<Int32>`) und `slopes` (`SIMD8<Double>`) lokale SIMD-Vektoren. Bei dynamischer Indizierung (`neighbors[c] = ...`, `slopes[c] = ...`) kann der Compiler keine Registerzuweisung vornehmen und generierte pro gefundenem Nachbarn vollständige Spills und Reloads aller 16 Vektorregister auf den Stack (~64 Speicherzugriffe je Zelle). Durch Vorab-Allokation temporärer Puffer je Threadscheibe (`withUnsafeTemporaryAllocation`) erfolgen Nachbar- und Gefälle-Zuweisungen als direkte skalare Schreibzugriffe ohne Spills. Erst beim Abschluss der Zelle wird der fertige Vektor geladen. Ebenso werden im seriellen Pass 2 Nachbarn und Gewichte direkt über Rohzeiger gelesen.
2. **Orthogonale Nachbar-Divisionen entfallen:** Für die vier orthogonalen Nachbarn innerer Zellen ist der Gitterabstand `dist == 1.0`. Die Gleitkomma-Division `d / 1.0` ist nach IEEE 754 bit-identisch zu `d` und wird für orthogonale Nachbarn vollständig eingespart (über 1,2 Mio. FP-Divisionen je Schritt).
3. **Routenspeicher gestrafft:** Das redundante Feld `sum` in `MFDRoute` und `MFDDispersion` wurde entfernt. Da flache Zellen und ungültige Summen bereits in Pass 1 abgefangen werden (`prc[t] = 0`), sinkt `MFDRoute` von 104 auf 96 Byte.
4. **Review-Nachbesserung (beide Punkte des Review-Bots, PR #210):** Die drei temporären Puffer von Pass 1 werden jetzt von Anfang an als skalare Typen allockiert (`Int32`/`Double`, je Kapazität 8) — die Zeiger für die Nachbarschafts-Suche und die Gewichtsschleifen kommen direkt vom `baseAddress` und kein `withMemoryRebound`-Zeiger verlässt mehr seine Closure. Zusätzlich werden die Puffer einmal je Threadscheibe vollständig initialisiert, bevor einzelne Lanes beschrieben und ganze Vektoren geladen werden (die alten lokalen `SIMD8(repeating: 0)` garantierten das je Zelle); Lanes ab `c` tragen damit definierte Werte und Pass 2 liest ohnehin nur `0..<c`. Die Vektor-Ladung am Zellenende erfolgt als unalignierter Raw-Load (`loadUnaligned(fromByteOffset:as:)`), ebenfalls ohne Neu-Bindung des Puffers. Wert-Semantik unverändert: Fingerprint A/B auf dem PR-Head vor und nach der Nachbesserung exakt gleich (`31835ab8b1a85069`, dieselbe Maschine); die Messwerte oben bleiben gültig, da die Speicherzugriffsstruktur im Inneren (skalare Schreibzugriffe, eine Vektor-Ladung je Zelle) erhalten blieb.

### Gemessen

Verschränkte A/B-Messung in einer Sitzung (`/tmp/simperf-base` vs `/tmp/simperf-opt`, 4 Paare, je `--repeat 3`, 30 Schritte à dt=100.0, Seed 1337):

- **Paar 1 (Base → Opt):**
  - Base: 190.5 / 194.8 / 185.9 ms/Schritt (Minimum: 185.9 ms), `computeMFDArea`: 24.04 ms
  - Opt: 174.2 / 172.2 / 178.7 ms/Schritt (Minimum: 172.2 ms), `computeMFDArea`: 14.59 ms (−9.45 ms / −39.3 %)
- **Paar 1 umgekehrt (Opt → Base):**
  - Opt: 167.6 / 149.6 / 160.3 ms/Schritt (Minimum: 149.6 ms), `computeMFDArea`: 13.55 ms
  - Base: 171.2 / 171.9 / 180.1 ms/Schritt (Minimum: 171.2 ms), `computeMFDArea`: 21.91 ms (−8.36 ms / −38.2 %)
- **Paar 2 (Base → Opt):**
  - Base: 182.5 / 188.4 / 178.0 ms/Schritt (Minimum: 178.0 ms), `computeMFDArea`: 20.77 ms
  - Opt: 173.9 / 171.6 / 158.9 ms/Schritt (Minimum: 158.9 ms), `computeMFDArea`: 14.17 ms (−6.60 ms / −31.8 %)
- **Paar 2 umgekehrt (Opt → Base):**
  - Opt: 187.5 / 167.7 / 167.9 ms/Schritt (Minimum: 167.7 ms), `computeMFDArea`: 14.28 ms
  - Base: 170.9 / 174.4 / 187.2 ms/Schritt (Minimum: 170.9 ms), `computeMFDArea`: 22.81 ms (−8.53 ms / −37.4 %)
- **Paar 3 (Base → Opt):**
  - Base: 175.2 / 163.5 / 178.0 ms/Schritt (Minimum: 163.5 ms), `computeMFDArea`: 21.14 ms
  - Opt: 170.4 / 158.6 / 163.4 ms/Schritt (Minimum: 158.6 ms), `computeMFDArea`: 13.19 ms (−7.95 ms / −37.6 %)
- **Paar 3 umgekehrt (Opt → Base):**
  - Opt: 162.1 / 166.2 / 172.9 ms/Schritt (Minimum: 162.1 ms), `computeMFDArea`: 14.18 ms
  - Base: 181.6 / 166.4 / 173.2 ms/Schritt (Minimum: 166.4 ms), `computeMFDArea`: 20.81 ms (−6.63 ms / −31.9 %)
- **Paar 4 (Base → Opt):**
  - Base: 172.4 / 167.0 / 180.7 ms/Schritt (Minimum: 167.0 ms), `computeMFDArea`: 21.26 ms
  - Opt: 169.6 / 155.1 / 168.0 ms/Schritt (Minimum: 155.1 ms), `computeMFDArea`: 14.29 ms (−6.97 ms / −32.8 %)
- **Paar 4 umgekehrt (Opt → Base):**
  - Opt: 174.6 / 188.3 / 187.2 ms/Schritt (Minimum: 174.6 ms), `computeMFDArea`: 14.92 ms
  - Base: 171.9 / 175.0 / 161.4 ms/Schritt (Minimum: 161.4 ms), `computeMFDArea`: 19.64 ms (−4.72 ms / −24.0 %)

Der Pass `computeMFDArea` sinkt stabil um **4.7 bis 9.5 ms/Schritt** (−24 % bis −39 %).

### Bit-Identität

Fingerprints (`simperf --hash`) auf allen Seeds und Zeitschrittweiten exakt identisch:

| Seed / Konfiguration | Fingerprint vorher | Fingerprint nachher | Status |
| --- | --- | --- | --- |
| Seed 1337, dt = 100 | `7667d3585b1f1904` | `7667d3585b1f1904` | bit-identisch |
| Seed 42, dt = 100 | `758727b1ae0866a8` | `758727b1ae0866a8` | bit-identisch |
| Seed 20, dt = 100 | `629eb937b51dfe81` | `629eb937b51dfe81` | bit-identisch |
| Seed 1337, dt = 15 | `764c3535772abcdd` | `764c3535772abcdd` | bit-identisch |


---

## Inline-Gitterkoordinaten-Rundung in Meander-Stempelung (Oktober 2026)

### Was und warum

In `Terrain.beltStampChannel`:
1. **PLT-Aufrufe von `round` durch direkte Ganzzahlabrundung eliminiert:** Die lokale Hilfsfunktion `cell(_ x: Double, _ z: Double)` wandelte Fließkomma-Koordinaten über `min(max(Int(z.rounded()), 0), nn - 1) * nn + min(max(Int(x.rounded()), 0), nn - 1)` in Gitterindizes um. `Double.rounded()` ruft unter Linux über die PLT die glibc-Funktion `round` auf (~20 Zyklen plus Stack-Frame und Register-Spills je Achse und Aufruf). `Terrain.cellIndex` verwendet kaufmännische Rundung (`Terrain.gridRound`: `c >= 0 ? (c < 0.5 ? 0 : Int(c + 0.5)) : (c > -0.5 ? 0 : Int(c - 0.5))`), die den IEEE-754-Grenzfall an `0.5.nextDown` (= `0.49999999999999994`) exakt erhält (wo eine naive Addition `x + 0.5` wegen Round-to-Nearest-Even fälschlicherweise auf 1.0 gerundet hätte). Damit ist die Rundungssemantik für alle Double-Werte bit-identisch zu `Int(coord.rounded())`, benötigt keine externen PLT-Funktionsaufrufe und inlinet direkt als schlanke Register-Operationen. Da `cell` in der Querschnittsabtastung und Profilstempelung über 1 Mio. Mal pro Sim-Schritt aufgerufen wird, entfallen damit Millionen von PLT-Sprungbefehlen und Stack-Spills.
2. **Skalar-Wiederverwendung im Querprofil:** In der Profilstempelung (`while s >= inner - 1e-9`) wurde `(1 + skew * a * e)` pro Stempelschritt neu berechnet. Da `kap = skew * a` vor der Schleife bereits berechnet vorliegt, spart `(1 + kap * e)` die redundante Multiplikation im inneren Loop.

### Gemessen (simperf, eine Sitzung, --repeat 3)

Verschränkte A/B-Messung in einer Sitzung (`/tmp/simperf-base` vs `/tmp/simperf-opt`, 2 Paare, je `--repeat 3`, 30 Schritte à dt=100.0, Seed 1337):

- **Paar 1:**
  - Base: 183.2 / 174.4 / 173.9 ms/Schritt (Minimum: 173.9 ms)
  - Opt:  153.8 / 153.6 / 154.3 ms/Schritt (Minimum: 153.6 ms)
  - Pass-Vergleich (`belt.parallel` + `belt.fixedStamp` + `belt.finishProfile`):
    - `belt.parallel`: 43.51 ms → 33.21 ms (−10.30 ms / −23.7 %)
    - `belt.fixedStamp`: 6.04 ms → 4.54 ms (−1.50 ms / −24.8 %)
    - `belt.finishProfile`: 3.22 ms → 2.51 ms (−0.71 ms / −22.0 %)
    - Summe Stempelpässe: 52.77 ms → 40.26 ms (−12.51 ms / −23.7 %)

- **Paar 2:**
  - Base: 164.6 / 169.7 / 162.3 ms/Schritt (Minimum: 162.3 ms)
  - Opt:  151.9 / 164.3 / 162.7 ms/Schritt (Minimum: 151.9 ms)
  - Pass-Vergleich:
    - `belt.parallel`: 41.01 ms → 35.35 ms (−5.66 ms / −13.8 %)
    - `belt.fixedStamp`: 5.10 ms → 4.85 ms (−0.25 ms / −4.9 %)
    - `belt.finishProfile`: 3.07 ms → 2.61 ms (−0.46 ms / −15.0 %)
    - Summe Stempelpässe: 49.18 ms → 42.81 ms (−6.37 ms / −13.0 %)

### Bit-Identität

Physik-Fingerprint (`simperf --hash`) vor und nach der Änderung exakt identisch: `7667d3585b1f1904`.
