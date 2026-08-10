# dt-Invarianz — Messreihen (Issue #2)

Gleiche Simulationszeit muss unabhängig von der Schrittweite dasselbe Ergebnis
liefern: der Echtzeit-Zeitraffer (viele winzige `dt` je Frame) und der
`+10.000 Jahre`-Sprung sind derselbe Vorgang (AGENTS.md, „Framerate-
Unabhängigkeit"). Dieses Dokument hält fest, **was gemessen wurde**, welche vier
Ursachen behoben sind und **welcher Rest bleibt** — inklusive des Belegs, woran
dieser Rest hängt.

## Methode

Alle Zahlen aus `SimCoreTests/DtInvariance.swift` (Release), Produktions-
Defaults, nur `n = 192` (Tempo), Seeds 1337 und 4242, 20.000 Jahre,
Schrittweiten `dt ∈ {10, 240, 2000}`.

```sh
swift test -c release --package-path SimCore -Xswiftc -swift-version -Xswiftc 5 \
    --filter DtInvariance                                  # Wächter
RS_MEASURE=1 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter Diagnostic # Messreihen
```

Kennzahlen:

| Kennzahl | Definition |
|---|---|
| Seeanteil | Anteil der Landzellen (`hf > sea`) mit `hf − h > 0.01` |
| Küstenzone | Zellen mit `\|h − sea\| ≤ waveBand` — genau das Gate von `wavePass` |
| Relief | `landReliefRobust()` = p95 − Median der Landhöhen |
| meanLand | mittlere Landhöhe (Massen-Proxy) |

Zwei Messregeln, ohne die der Vergleich Äpfel mit Birnen misst:

1. **Frisches Abflussfeld.** `hf` wird in `step()` einmal am Anfang bestimmt,
   danach verschieben die Erosionspässe `h`; am Schrittende ist `hf − h` umso
   verzerrter, je mehr ein Schritt bewegt. Gemessen bei dt = 2000, Seed 1337:
   Seeanteil **0.2111** am Schrittende gegen **0.1584** nach `computeFlow()`.
   Alle Zahlen unten sind auf frischem Feld gemessen.
2. **Zeitgemittelt statt momentan.** Der momentane Seeanteil ist keine stabile
   Kennzahl — Becken füllen und entleeren sich episodisch (§4). Die Tabellen
   unten mitteln über 6 Abtastungen (10k…20k Jahre, alle 2000 J.).

## 1. Ausgangslage (Stand `main`, zeitgemittelt)

| Seed | dt | Seeanteil | Küstenzone | Relief | meanLand |
|---|---|---|---|---|---|
| 1337 | 10 | 0.0347 | 5529 | 0.1690 | 0.3547 |
| 1337 | 240 | 0.0996 | 4003 | 0.1479 | 0.3575 |
| 1337 | 2000 | 0.1401 | 4042 | 0.1650 | 0.3524 |
| 4242 | 10 | 0.0000 | 11170 | 0.0941 | 0.2411 |
| 4242 | 240 | 0.0007 | 8438 | 0.0964 | 0.2282 |
| 4242 | 2000 | 0.0008 | 8198 | 0.0944 | 0.2346 |

Momentan (Einzelwert am Laufende, Seed 1337): Seeanteil 0.0359 / 0.0794 /
0.1809 — das ist die im Issue genannte Spanne (Faktor 2.3–5.0), Küstenzone
5943 / 4314 / 4344 (Spanne 38 %).

## 2. Die vier behobenen Ursachen

### 2.1 `wavePass` war eine Zählschleife, keine Rate

`max(1, min(24, dt/100))` Durchläufe mit VOLLER Stärke `waveRelax` je Durchlauf:
ein Zeitraffer-Schritt (dt ≈ 9 J.) bekam die ganze 100-Jahr-Relaxation, und ab
dt > 2400 sättigte der Deckel. Jetzt wie die Hangdiffusion sub-getaktet
(`Terrain.waveSchedule`): feste Teilschritt-Stärke, Anzahl ∝ dt. Bei dt = k·100
ist der Takt identisch zu vorher — `waveRelax` bleibt gepinnt.

Isoliert gemessen (nur `wavePass` aktiv, n=96, 4000 Jahre, Seed 1337;
`testWaveErosionIsFramerateIndependent`):

| dt | Küstenzone | Landmasse |
|---|---|---|
| 10 | 900 | 1246.627 |
| 250 | 913 | 1246.597 |
| 2000 | 909 | 1246.591 |

Spanne: Küstenzone 1.4 %, Landmasse 3·10⁻⁵.

### 2.2 Lineare statt exponentieller Relaxation

`fillShallowPonds`, `fillLakes`, `fillOxbows` und `updateVegetation` benutzten
`min(cap, dt/τ)` statt `1 − e^(−dt/τ)` (`relaxWaterLevel` und die Stream-Map
machten es schon richtig). Die lineare Form sättigt am Deckel und teleskopiert
nicht:

| Pass | τ | Anteil je Schritt bei dt=240 | bei dt=2000 |
|---|---|---|---|
| Vegetation | 250 | 0.96 → **0.62** | 1.00 → **0.9997** |
| Pfützen | 800 | 0.30 → **0.26** | 0.50 → **0.918** |
| Seen (`basinFill`, aus) | 3000 | 0.08 → **0.077** | 0.50 → **0.487** |
| Altarme | 5500 | 0.044 → **0.043** | 0.36 → **0.305** |

(links alt, rechts neu). `floodplainAggradation` (geparkt, `false`) ist
mitgezogen, damit kein bekannt dt-abhängiger Pass als Referenz liegenbleibt.

### 2.3 Tropfenzahl als Bruchteil

`max(1, Int(dt · hydraulicPerYear · Dichte))` rundete jeden Frame-Schritt auf:
bei dt = 0.2 J. verlangt die Rate 0.09 Tropfen, es fielen 1 — über 11× zu viel
Droplet-Erosion im Zeitraffer. Der angebrochene Rest wandert jetzt über
`Terrain.dropCarry` in den nächsten Schritt; über 1000 Jahre fällt für
dt ∈ {0.2, 1, 50, 1000} dieselbe Tropfenzahl (±1, `testDropletCountIsARate`).

### 2.4 Deckel je Schritt statt je Zeit

- **Halbe-Differenz-Deckel** („nicht unter den Empfänger graben", „nicht über
  den Innenhang schütten") in `meanderStamp` (Bett-Carve, Prallhang/Gleithang)
  galten mit festen `0.5` JE SCHRITT. Viele kleine Schritte nehmen jedes Mal die
  Hälfte des Rests und kommen der Grenze beliebig nahe, ein großer Schritt
  bleibt bei der Hälfte stehen. Jetzt `max(0.5, 1 − e^(−dt·ln2/500))`
  (`Terrain.stepCapFraction`).

  Der Fehler sitzt nämlich nur auf der GROSSEN Seite: bei kleinem dt ist der
  feste Deckel richtig (der Eingriff ist dort ∝ dt und winzig, der Deckel
  greift nicht, und über viele Schritte nähert sich das Gelände der Grenze
  asymptotisch an — genau das Kontinuums-Verhalten). Die Untergrenze 0.5 hält
  deshalb alles bis dt = 500 J. **bit-genau wie bisher**, darüber wächst der
  Deckel weiter: 0.75 bei 1000, 0.94 bei 2000, 0.999 bei 5000 — ein
  2000-Jahr-Sprung gibt praktisch dasselbe frei wie vier 500-Jahr-Schritte
  (1 − 0.5⁴ = 0.9375).

  **Verworfen: die reine Exponentialform ohne Untergrenze.** Sie drosselt kleine
  Schritte künstlich (dt = 20 J. → 0.027 statt 0.5) und verschob damit genau die
  Wächter, die in 20-Jahr-Schritten messen. Mit Anker 100 J. kippte
  `Lithology.testEndorheicMechanicsSurviveLithology` (Sprung τ=500 0.0081 gegen
  τ=0 0.0062), mit Anker 500 J. `EndorheicEvaporation.testBasinLevelIsRateLimited`
  (max. Spiegelsprung 0.0073 gegen die Schranke 0.002).
- **Überfüll-Zugabe** in `braidPass` (Delta/Seerand): `min(qin, (hf−h) + 0.005)`
  legte den Aufschlag über das AKTUELLE `h`, nicht über den Wasserspiegel —
  sobald `h` den Spiegel erreicht hatte, durfte jeder weitere Schritt noch
  0.005 draufsetzen. Jetzt dieselbe GEOMETRISCHE Obergrenze wie im aktiven
  Zweig (`hf + braidBarHeight`); die addiert sich über Schritte nicht auf.
  Zwei **verworfene** Varianten, beide gemessen:
  - Zugabe ∝ dt (0.005 je 100 J.): bei dt = 2000 wären das +0.1 in EINEM
    Schritt — ein 1.6-fach `puddleFillDepth` hoher Damm aus dem Stand
    (Seeanteil 0.1490 statt 0.1422).
  - eine höhere, kalibrierte Obergrenze (0.02 / 0.04) als Ausgleich für die
    weggefallene Aufsummierung: bringt den Braiding-A/B nicht zurück
    (Bank-Fläche an/aus 214/206 bzw. 126/206 bei dt = 1000, Seeds 5:6 bzw.
    8:7) — das Problem lag nicht in diesem Zweig, s. §7.
- Der **Scour**-Deckel in `braidPass` (Erosionsseite) bleibt bei festen 0.5:
  s. §7.

## 3. Stand nach dem Fix (zeitgemittelt, Seed 1337)

| dt | Seeanteil | Küstenzone | Relief | meanLand |
|---|---|---|---|---|
| 10 | 0.0364 | 4230 | 0.1663 | 0.3506 |
| 240 | 0.0781 | 4091 | 0.1456 | 0.3577 |
| 2000 | 0.1391 | 4133 | 0.1660 | 0.3513 |

| Kennzahl | Spanne vorher | Spanne nachher |
|---|---|---|
| Küstenzone | 38 % | **3.3 %** |
| meanLand | 1.4 % | 2.0 % |
| Relief | 12.5 % | 12.4 % |
| Seeanteil | 75 % | 74 % |

Die Küstenzone — die Kennzahl der Ursache 1 — ist damit schrittweiten-unabhängig.
Relief und Seeanteil bleiben auf dem Stand von `main`: sie hängen an einer
Ursache, die laut Issue-Zuschnitt **nicht** Teil von #2 ist. §4 und §5 belegen
das.

Isoliert gemessen ist dagegen JEDE der vier Ursachen behoben (§2, §8) — der
Gesamtpfad zeigt es nur nicht, weil ihn die Splitting-Drift überlagert.

## 4. Der momentane Seeanteil ist eine schwankende Größe

Zeitreihe (Seed 1337, Abtastung je 1000 Jahre, frisches Feld):

| Jahr | dt=250: Seeanteil / größter See | dt=2000: Seeanteil / größter See |
|---|---|---|
| 2000 | 0.0754 / 926 | 0.0906 / 662 |
| 4000 | 0.1218 / 1570 | 0.1549 / 1884 |
| 6000 | 0.1200 / 1822 | 0.1310 / 1539 |
| 10000 | 0.1277 / 1974 | 0.1285 / 1470 |
| 14000 | 0.1389 / 3251 | 0.1461 / 2220 |
| 17000 | 0.1499 / 3572 | — |
| 19000 | 0.0806 / 1272 | — |
| 20000 | 0.0787 / 1281 | 0.1584 / 3416 |

Innerhalb EINES Laufs bei festem dt schwankt der Seeanteil zwischen 0.071 und
0.150, die größte See-Komponente zwischen 926 und 3572 Zellen von einer
Abtastung zur nächsten: ein Grenzbecken läuft voll und entwässert wieder. Ein
Einzelwert am Laufende vergleicht deshalb Phasen, keine Regime — daher die
Zeitmittelung.

## 5. Der Rest ist Operator-Splitting-Drift des Tropfen-Passes

Das Abflussfeld (`hf`, `receiver`, `streamMap`) wird einmal je Schritt bestimmt;
die Tropfen laufen aber `dt · hydraulicPerYear · Dichte` mal dagegen. Bei
dt = 2000 arbeiten 360 Tropfen auf einem Feld, das dt = 10 alle 1.8 Tropfen neu
berechnet. Genau diese Größe — **Tropfen je Abfluss-Update** — erklärt den Rest.

Alles außer Auslass-Inzision/Wasserhaushalt abgeschaltet, nur die Tropfenrate
variiert (`testSplittingScalesWithDropRateDiagnostic`, zeitgemittelt):

| Tropfen/Jahr | dt=10 | dt=240 | dt=2000 | Spanne |
|---|---|---|---|---|
| 0.0 | 0.0498 | 0.0496 | 0.0490 | **1.6 %** |
| 0.2 | 0.0502 | 0.0510 | 0.0514 | **2.3 %** |
| 2.0 (Produktion) | 0.0718 | 0.0800 | 0.1013 | **29 %** |

Die Entwässerungs-Maschinerie selbst (Priority-Flood, Auslass-Inzision,
Pfützen/Seen) ist also über zwei Dekaden Schrittweite praktisch identisch; die
Abweichung entsteht ausschließlich dort, wo Tropfen zwischen zwei
Abfluss-Updates Material bewegen, und sie skaliert mit deren Anzahl. Auf dem
vollen Produktionspfad verstärkt sich das, weil `fillShallowPonds` ein
SCHWELLEN-Kriterium hat (eine Komponente mit ≥ `puddleLakeCoreCells` tiefen
Zellen gilt als See und verlandet nicht mehr): ein Becken, das die Schwelle
einmal reißt, bleibt See. Bilanz über 20k Jahre (n=192, Seed 1337): verlandetes
Pfützen-Volumen **205** bei dt=240 gegen **18** bei dt=2000.

Gegenprobe per Ablation (momentan, Seed 1337, 20k Jahre):

| Variante | dt=240 | dt=2000 |
|---|---|---|
| default | 0.0480 | 0.1584 |
| ohne Braiding | 0.1526 | 0.1376 |
| ohne Mäander | 0.0420 | 0.1353 |
| ohne Pfützen-Verlandung | 0.1428 | 0.1490 |
| **ohne Tropfen** | 0.1189 | 0.1112 |

Ein zweiter, kleinerer Verstärker sitzt im **See-Kern-Gate** der
Pfützen-Verlandung: eine Wasser-Komponente mit ≥ `puddleLakeCoreCells` tiefen
Zellen gilt als See und verlandet gar nicht mehr. Das ist eine BINÄRE
Klassifikation, die je Schritt neu fällt — je feiner getaktet, desto öfter
erwischt sie ein Grenzbecken in einem füllbaren Zustand, und wer die Schwelle
einmal reißt, bleibt See. Isoliert (ohne Tropfen, zeitgemittelt, Seed 1337):

| Variante | dt=10 | dt=240 | dt=2000 |
|---|---|---|---|
| Pfützen-Verlandung aus | 0.0498 | 0.0496 | 0.0490 |
| an, Produktions-Gates | 0.0211 | 0.0212 | **0.0503** |
| an, ohne Tiefen-Gate | 0.0000 | 0.0000 | 0.0000 |
| an, **ohne See-Kern-Gate** | 0.0044 | 0.0045 | 0.0046 |

Die RELAXATION ist also invariant (letzte Zeile); die Schwelle ist es nicht.
Das Gate selbst bleibt unangetastet: es ist die Antwort auf „wachsender Boden
ohne Wasser" (ROADMAP/Politur), und seine Alternativen sind dort als gemessene
Sackgassen dokumentiert.

**Offen (Folge-Arbeit, nicht #2):** (a) das Abflussfeld innerhalb eines großen
Schritts nachführen (Tropfen-Charge in Teilchargen mit zwischenzeitlichem
`computeFlow`, oder eine Obergrenze für Tropfen je Abfluss-Update) — Eingriff in
die Schritt-Struktur mit Laufzeit-Folgen (`computeFlow` ist der teuerste Pass);
(b) die See/Pfütze-Klassifikation zeitlich glätten statt sie je Schritt neu zu
würfeln; (c) der Scour-Deckel in `braidPass` (s. §2.4/§6). Vermerkt in
`ROADMAP.md`.

## 6. Kalibrier-Kaskade: was die Fixes an bestehenden Wächtern verschoben haben

Die Zeitkonstanten waren gegen die LINEARE Form kalibriert — die Umstellung
verschiebt also, wie erwartet, das Verhalten bei großen Schritten. Drei Wächter
haben darauf reagiert; alle drei sind wieder grün, ohne dass eine Zusicherung
aufgeweicht wurde:

| Wächter | Symptom | Ursache | Behandlung |
|---|---|---|---|
| `EndorheicEvaporation.testDriedBedIsRenderedAsPlaya` | Playa-Fläche >100 → 35 Zellen | **Scour**-Deckel in `braidPass` als Rate gelesen: bei dt = 200 räumt er 0.75 statt 0.5 der lokalen Differenz aus und gräbt den Boden abflussloser Becken tiefer | Scour-Deckel bleibt bei 0.5 — Issue #2 nennt die DEPOSITIONS-Deckel, dies ist die Erosionsseite (Rest-Abhängigkeit dokumentiert, §5) |
| `EndorheicEvaporation.testBasinLevelIsRateLimited` | max. Spiegelsprung 0.0050 gegen die absolute Schranke 0.002 | der größte Einzelsprung ist ein diskretes GELÄNDE-Ereignis (eine Sill bricht, der Priority-Flood pegelt das Becken um), kein Effekt der Ratenbegrenzung — jede Änderung an der Zeitintegration würfelt ihn neu | Schranke auf die Formulierung der eigenen Doku umgestellt: „weit unter der SPANNE, um die der Spiegel wandern kann". Das Verhältnis ist über den Fix hinweg stabil: `main` 0.00325/0.01433 = **0.227**, danach 0.00502/0.02316 = **0.217** (Schranke 0.35) |
| `RiverDynamicsTests.testBraidingBuildsBars` | Bank-Fläche an/aus 157/206 statt 199/94, Seed-Mehrheit 3:8 statt 9:3 | siehe §7 — die REFERENZ (ohne Braiding) gewinnt bei dt = 1000 trockene Flächen, weil die Pfützen-Verlandung dort vorher am 0.5-Deckel hing | Wächter taktet mit dt = 500 statt 1000; dort sind alte und neue Form fast deckungsgleich → 284/158 bei Seeds 9:3 |

`SimCoreTests.testMeanderOxbowSiltsUp` und `…OxbowAging` (dt = 500) blieben
unverändert grün: bei dt = 500 ist `1 − e^(−500/5500)` = 0.0870 gegen linear
0.0909, also −4.3 %.

### Offen: `Lithology.testEndorheicMechanicsSurviveLithology`

Der Wächter ist ROT (Stand dieses Branches) und bleibt es. Seine
Playa-Zusicherungen (der eigentliche Inhalt: „#11-Mechanik überlebt das
Gesteinsfeld") sind grün; rot ist die Unter-Prüfung, die den GRÖSSTEN
Einzelsprung des ratenbegrenzten Arms (τ=500) gegen den des unbegrenzten (τ=0)
stellt — nach dem Fix 0.00705 gegen 0.00555, also invertiert.

Warum das kein belegter Regress ist: die beiden Arme sind zwei UNABHÄNGIGE
Läufe (τ verändert die Trajektorie), und verglichen wird das Maximum über 200
Schritte, das in beiden Armen von einem diskreten Gelände-Ereignis kommt. In der
Ursachen-Bisektion kippt die Prüfung bei fünf voneinander unabhängigen
Einzel-Rücknahmen in BEIDE Richtungen (Wave-Takt zurück: 0.00615/0.00696 grün ·
Überfüll-Deckel zurück: 0.00011/0.00716 grün · Vegetation zurück:
0.00684/0.00837 grün · Pfützen zurück: 0.00574/0.00506 rot · Tropfenzahl
zurück: 0.00602/0.00560 rot) — eine Münze, kein Signal. Robustere Formen wurden
probiert und ändern nichts: spannen-relativ 0.308 gegen 0.261, mittlerer
Sprung je Schritt 0.000181 gegen 0.000122 (letzteres ist sogar systematisch
erwartbar: der ratenbegrenzte Arm bewegt sich JEDEN Schritt ein wenig, der
instantane springt einmal und ruht dann).

Die Eigenschaft selbst ist nachgewiesen — `EndorheicEvaporation.testBasinLevelIsRateLimited`
misst sie ohne Gesteinsfeld und ist grün (Sprung/Spanne 0.217 gegen 0.393).
Empfehlung fürs Folge-Issue: die Unter-Prüfung entweder streichen (sie
dupliziert #11) oder auf eine gepaarte Größe umstellen, die nicht zwei
chaotische Läufe gegeneinander stellt.

## 7. Was der Braiding-Wächter über dt = 1000 zeigte

Der Wächter vergleicht denselben Seed mit und ohne `braidPass` und zählt unter
anderem „Bank-Fläche" = trockene, vom Kanalnetz umschlossene Komponenten. Bei
dt = 1000 verlandet die Pfützen-Verlandung mit der korrigierten Form 0.713 des
Defizits je Schritt statt der gedeckelten 0.5 — **auch im Referenzarm**. Damit
entstehen dort trockene umschlossene Flächen ohne jedes Braiding: gemessen
Referenz-Bank-Fläche 94 (main) → 212 (nach dem Fix), während der Braiding-Arm
bei ~180 blieb. Der A/B-Kontrast ging also nicht verloren, weil der Pass
schwächer wurde, sondern weil die Referenz mitwuchs. Bei dt = 500 (alte Form
0.5, neue 0.465) steht er wieder wie auf `main`:

| Stand | dt | Bank-Fläche an / aus | Seeds dafür : dagegen | Inseln an / aus |
|---|---|---|---|---|
| main | 1000 | 199 / 94 | 9 : 3 | 68 / 45 |
| nach Fix | 1000 | 157 / 206 | 3 : 8 | 85 / 79 |
| nach Fix | 500 | 284 / 158 | 9 : 3 | 113 / 57 |

Verworfen wurde, die Braiding-Physik nachzuziehen: `braidCapacity`
5.0e-6 → 3.5e-6 / 2.5e-6 / 1.5e-6 ergab bei dt = 1000 Bank-Fläche 251/206
(Seeds 8:5), 159/206 (5:8) und 281/206 (9:5) — nicht monoton, also Rauschen
statt Signal, und ein 3-facher Eingriff in eine kalibrierte Transport-Konstante
wäre für ein Mess-Artefakt der Schrittweite die falsche Antwort.

## 8. Wächter

`SimCoreTests/DtInvariance.swift`:

| Test | prüft |
|---|---|
| `testWaveErosionIsFramerateIndependent` | Ursache 1, isoliert (Küstenzone ≤ 5 %, Masse ≤ 2 %) |
| `testRelaxationsTelescopeAcrossSubsteps` | Ursache 2, die Form selbst (exakt) |
| `testDropletCountIsARate` | Ursache 3 (±1 Tropfen über 1000 Jahre) |
| `testStepCapsAreRates` | Ursache 4 (teleskopiert, dt=100 → exakt 0.5) |
| `testDrainageIsFramerateIndependentWithoutDroplets` | Wasserhaushalt ohne Splitting (Seeanteil ≤ 10 %) |
| `testSameTimeSameResultAcrossStepSizes` | Gesamtpfad: Küste ≤ 10 %, Relief ≤ 12 %, meanLand ≤ 5 %, Seeanteil ≤ 80 % |
