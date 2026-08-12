# Gletscher: Messreihen zu Eisfluss und glazialer Erosion (Issue #35)

Rohdaten zur Kalibrierung von `Terrain.updateIce` und der `SimConfig.ice*`-Regler.
Modellwahl und Primärquellen: `docs/research-climate-cryosphere.md` §4/§5.
Kalibrier-Logbuch je Regler: `SimCore/Sources/SimCore/Config.swift`,
Abschnitt „Gletscher".

Alle Läufe mit Seed 1337, Produktionspfad (`hydraulicEnabled`), `dt = 500` Jahre,
sofern nicht anders vermerkt. Die Wächter, die diese Zahlen erzeugen bzw. pinnen,
stehen in `SimCore/Tests/SimCoreTests/Glacier.swift`.

**Wo das Eis überhaupt entstehen kann.** Die Firn-Grenze ist die 0-°C-Isotherme
aus der Klima-Kalibrierung von #33 und liegt fix bei

```
h(T = 0) = sea + climateSeaLevelTemp / climateLapseRate = 0.15 + 11/26 = 0.5731
```

Sie ist der Bezugspunkt aller folgenden Zahlen: darüber wandelt sich Firn zu Eis,
darunter kann Eis nur noch HINFLIESSEN.

---

## §A — Gipfelhöhe gegen Firn-Grenze (die Vorbedingung)

Ohne Gletscher gerechnet (`iceEnabled = false`), `maxHeight()` über die Zeit —
`testPeakHeightSeriesDiagnostic`:

| n | 0k | 10k | 20k | 30k | 40k |
|---|---|---|---|---|---|
| 192 | 0.6932 | 0.6609 | 0.6274 | 0.6066 | 0.5848 |
| 256 | 0.7046 | 0.6655 | 0.6305 | 0.6142 | 0.5942 |
| 384 | 0.7258 | 0.6652 | 0.6369 | 0.6251 | 0.6090 |
| 640 | 0.7154 | 0.6658 | 0.6433 | 0.6325 | 0.6236 |

Zwei Folgerungen, die den ganzen Rest der Kalibrierung bestimmen:

1. **Das Nährgebiet ist von Natur aus schmal und wird schmaler.** Bei der
   Generierung liegen ~1,5 % des Landes über der Firn-Grenze (dieselbe Zahl, an
   der #33 seinen Perzentil-Schnee kalibriert hat); nach 40k Jahren ist der
   Abstand Gipfel–Firn-Grenze bei n = 192 auf 0.012 Höheneinheiten geschrumpft.
2. **Die Gletscher-Tests brauchen n ≥ 384.** Bei kleinem n altert die Insel
   schneller unter die Firn-Grenze. Die Wächter laufen deshalb auf n = 384
   (Mechanik-Tests ohne Höhenbedarf auf 192/256).

Der allererste Versuch verwechselte genau das mit einem Fehler: bei n = 192 mit
einem viel zu großen `iceErodeK` (2.0, s. §D) fiel `maxH` in 5000 Jahren auf
0.5686 und das Eis verschwand vollständig — das war nicht die Alterung, sondern
der Gletscher, der sich selbst das Nährgebiet weggesägt hat.

---

## §B — Eismasse, Dicke und Reichweite

`testIceGrowthSeriesDiagnostic`, n = 384, Produktionswerte:

| Jahre | Eis-Zellen | Anteil Land | max. Dicke | mittl. Dicke | unter Firn-Grenze | maxH |
|---|---|---|---|---|---|---|
| 5.000 | 2376 | 2.34 % | 0.2615 | 0.0418 | 1275 | 0.6727 |
| 10.000 | 1816 | 1.79 % | 0.2112 | 0.0352 | 925 | 0.6451 |
| 20.000 | 1124 | 1.11 % | 0.1063 | 0.0233 | 498 | 0.6090 |
| 30.000 | 688 | 0.68 % | 0.0713 | 0.0182 | 259 | 0.5892 |
| 50.000 | 297 | 0.29 % | 0.0682 | 0.0208 | 94 | 0.5869 |

(Die Tabelle stammt aus dem Zwischenstand mit `iceTurnoverYears = 1000`; mit dem
gewählten Wert 4000 hält das Eis länger: 456 Zellen und 0.1064 max. Dicke nach
50k Jahren.)

**Lesart.** Das Eis baut sich in den ersten Jahrtausenden auf, erreicht um 5.000
Jahre sein Maximum und zehrt danach mit der alternden Insel ab — `maxH` sinkt,
das Nährgebiet schrumpft, und die glaziale Erosion sägt zusätzlich daran (§D).
Das ist kein Fehler, sondern derselbe Verlauf, den `docs/climate-snow-measurements.md`
schon für die Schneefläche zeigt; der Wächter
`testTongueReachesBelowTheFirnLine` prüft deshalb Wachstum in der Aufbauphase
(2k → 5k) und Bestand nach 30k.

**Dicke.** Max. 0.07 … 0.26 Höheneinheiten ≙ 280 … 1050 m bei H_ref = 4000 m.
Sie wird NICHT von `iceTurnoverYears` gesetzt, sondern von der Kontinuität: Eis
stapelt sich, bis sein Oberflächengefälle die Zufuhr abführt. Der Grundumsatz ist
nur die Notbremse für den entarteten Fall (kein Gefälle):
`I* = iceFirnPerSnowYear · snow · iceTurnoverYears`.

**Auflösungsabhängigkeit (benannt, nicht behoben).** kappa skaliert mit `(n−1)²`,
die Abfälle je Zelle mit `1/(n−1)` — die Fließstrecke in WELTEINHEITEN je Jahr ist
damit auflösungsunabhängig, die Gleichgewichts-DICKE aber ∝ `1/(n−1)`. Bei
kleinem n wird das Eis also dicker: über 200k Jahre (`testLongRunIceStaysBounded`,
n = 192, dt = 2000) steht das Maximum bei **1.0817**, bei n = 384 bleibt es unter
0.3. Beschränkt bleibt es in beiden Fällen — der Wächter prüft die
Konstruktions-Grenze (4.0) UND eine empirische Schranke (2.0).

### Sweep über die Zufuhr (`iceFirnPerSnowYear`)

n = 384, 30k Jahre, ohne glaziale Erosion isoliert (`testIceParameterSweepDiagnostic`):

| firn | Eis-Anteil | max. Dicke | Reichweite unter Firn-Grenze |
|---|---|---|---|
| 2e-5 | 0.68 % | 0.0377 | 0.0027 |
| 1e-4 | 1.71 % | 0.0972 | 0.0982 |
| 4e-4 | 2.13 % | 0.1767 | 0.0841 |
| 1e-3 | 2.33 % | 0.2126 | 0.1054 |

2e-5 war der erste, aus der Ziel-Dicke hergeleitete Wert — und er ist zu klein:
das Eis drapiert den Fels, statt Täler zu füllen, und nur gefülltes Eis hat eine
glatte Oberfläche, über die es quer zum Tal schleifen kann (§D). Gewählt: 1e-3.

### Sweep über die Fließ-Basis (`iceFlowK`)

n = 384, 30k Jahre, `firn = 1e-4`:

| iceFlowK | Eis-Anteil | max. Dicke | Reichweite |
|---|---|---|---|
| 1.0 | 1.41 % | 0.1309 | 0.0683 |
| 3.0 | 1.71 % | 0.0972 | 0.0982 |
| 6.0 | 1.88 % | 0.0769 | 0.1200 |

Mehr Fließen → dünneres, weiter reichendes Eis (erwartet). Über 3.0 kauft die
doppelte Rechenzeit (§E) nur noch ~20 % mehr Reichweite → **3.0 gewählt**.

---

## §C — Ablation und Reichweite der Zunge (`iceMeltPerKYear`)

n = 384, 30k Jahre. „Reichweite" = Höhenspanne, um die das Eis unter die
Firn-Grenze reicht:

| melt | Reichweite | Bemerkung |
|---|---|---|
| 0.004 | 0.003 … 0.024 | die Zunge kommt nicht aus dem Kar |
| 0.002 | 0.094 | |
| **0.001** | **0.098 … 0.133** | gewählt |
| 0.0004 | 0.139 | Eiskappe statt Zunge (6.2 % Landanteil) |

Die Zungenlänge ist `v · τ_Ablation`: Fließgeschwindigkeit mal Lebensdauer im
Zehrgebiet. Beide Regler ziehen also an derselben Größe — `iceFlowK` von der
Geschwindigkeits-, `iceMeltPerKYear` von der Lebensdauer-Seite.

**Dass die Zunge FLIESST und nicht nur bilanziert**, ist eigens gegengetestet
(`testWithoutFlowThereIsNoTongue`, n = 256, 10k Jahre, glaziale Erosion in beiden
Armen aus): mit Transport liegen 968 Zellen unter der Firn-Grenze, ohne
Transport 63. Die 63 sind kein geflossenes Eis, sondern gesunkenes BETT
(Hangdiffusion und Hebung sind nicht gegatet, am dünnen Saum unter
`iceMinThickness` auch die fluvialen Pässe) — deshalb ist das Kriterium des
Wächters der Vergleich und nicht die Null.

---

## §D — V→U: die Talquerprofil-Kennzahl

### Die Kennzahl

Gemessen wird der Exponent `b` der Anpassung `Δh(x) ∝ x^b` quer zur
Fließrichtung, aus zwei Stützstellen (3 und 6 Zellen):

```
b = log₂( Δh(6 Zellen) / Δh(3 Zellen) )        V ⇒ b = 1,  U (Parabel) ⇒ b = 2
```

**Verworfen: das Breitenverhältnis `W(2d)/W(d)`** (V = 2, U = √2 ≈ 1.414). Es
braucht eine absolute Tiefe `d` und einen Suchlauf bis dorthin; auf den steilen
Oberläufen, in denen die Gletscher sitzen, fand er auf einer der beiden Flanken
regelmäßig gar keinen Anstieg um `2d`, und die Stichprobe brach auf n = 1 … 22
zusammen. Zusätzlich verschob schon die unterschiedliche AUSWAHL zwischen den
beiden Armen den Mittelwert: derselbe eisfreie Referenzlauf kam je nach
Zellensatz auf 1.496 … 2.008. Seitdem wird **gepaart** gemessen — nur Zellen,
für die BEIDE Arme ein Profil liefern.

### Der Ausstrich (`iceErodeSwathRadius`) war nötig

Erste Messung (n = 384, 30k Jahre, `iceErodeK = 3e-5`, gepaartes
Breitenverhältnis, kleiner ist U-iger):

| Ausstrich | vergletschert | eisfreier Referenzarm |
|---|---|---|
| 0 (rein lokal) | 1.550 | 1.392 |
| 1 | 1.510 | 1.393 |
| 2 | 1.481 | 1.395 |
| 4 | 1.519 | 1.406 |

Ohne Ausstrich ist das vergletscherte Tal **V-IGER** als dasselbe Tal ohne Eis —
die falsche Richtung. Ursache: die lokale Flux-Rate ist im Thalweg am größten und
schneidet dort eine Kerbe. Genau diesen Fall sagt
`docs/research-climate-cryosphere.md` §4.3 beim Kauf des Flux-Modells voraus, und
er nennt auch die Gegenmaßnahme, die Liebl et al. 2023 im OpenLEM einsetzen: den
lateral ausgestrichenen Erosions-Streifen. Der Ausstrich verbessert die Kennzahl
monoton bis Radius 2; Radius 4 verwischt sie wieder. **Gewählt: 2** (5×5-Fenster).

### Erosionsrate (`iceErodeK`) und die Zeitreihe

`testValleyShapeSeriesDiagnostic`, n = 384, Formexponent `b` auf den am Ende
vergletscherten Zellen, gepaart gegen den eisfreien Referenzlauf. **Δ > 0 heißt
U-iger als ohne Eis.**

`iceTurnoverYears = 4000`, `iceErodeK = 1e-4` (die gewählte Kombination):

| Jahre | b (Eis) | b (ohne Eis) | Δ | n |
|---|---|---|---|---|
| 0 | 1.513 | 1.513 | +0.000 | 54 |
| 10.000 | 1.462 | 1.191 | **+0.271** | 51 |
| 20.000 | 1.363 | 1.141 | **+0.223** | 41 |
| 30.000 | 1.412 | 1.109 | **+0.302** | 40 |
| 40.000 | 1.383 | 1.136 | **+0.247** | 40 |
| 50.000 | 1.371 | 1.119 | **+0.252** | 38 |

Das ist das Signal des Tickets: die eisfreien Täler laufen unter der fluvialen
Alterung von b ≈ 1.5 auf b ≈ 1.1 (also Richtung Kerbtal), die vergletscherten
bleiben bei b ≈ 1.4 (parabolisch). Gepinnt von
`testGlaciatedValleysWidenTowardsU` (30k und 50k, Schranke Δ > 0.1).

Verworfene Arme derselben Messreihe:

| Variante | Befund |
|---|---|
| `iceErodeK = 3e-5` | Δ −0.09 … +0.00 — kein Signal: der Abtrag bleibt unter 20 % der vorhandenen Taltiefe |
| `iceErodeK = 3e-4` | Eisfläche bricht auf 0.06 % ein (Buzzsaw), Stichprobe n ≤ 3, Δ unbrauchbar verrauscht |
| `iceTurnoverYears = 1000` | Δ +0.03 … +0.84 ohne Trend, Eis nur noch 0.29 % der Landfläche |
| `iceErodeK = 2.0` (erster Versuch) | die Rate war um vier Größenordnungen zu hoch; der Deckel „ein Viertel der lokalen Abfälle je Teilschritt" band dauernd und trug 0.05 Höheneinheiten JE SCHRITT ab |

**Preis der gewählten Rate.** `iceErodeK = 1e-4` kostet auf 30k Jahre 0.024
Höheneinheiten Gipfelhöhe gegen den eisfreien Arm (n = 384: 0.6237 gegen 0.6475).
Das ist die erwünschte glaziale Denudation — und zugleich der Grund, warum die
Eisfläche über den Lauf zurückgeht (§B).

---

## §E — Rechenzeit und Sub-Taktung

Die Sub-Taktzahl ist `⌈kappa_Jahr · wMax · dt / iceFlowSubCap⌉`, mit `wMax` =
größte Summe positiver Oberflächen-Abfälle über die eisbedeckten Zellen
(einmal je Schritt gemessen, `steepestIceSurfaceDrop`).

**Warum `wMax` gemessen und nicht angenommen wird:** der explizite Deckel gilt am
Produkt `kappa · ΣΔs⁺`, nicht an kappa allein. Mit der pessimistischen Annahme
`ΣΔs⁺ ≤ 1` liefe die Taktung um den Faktor `1/wMax` (gemessen 5 … 20) zu fein.
Der harte Positivitäts-Deckel `iceFlowMoveFraction` bleibt trotzdem stehen: `wMax`
stammt vom Zustand VOR den Teilschritten.

`testIcePassCostDiagnostic`, Schrittzeit mit gegen ohne Gletscher, nach 20k Jahren
Vorlauf (`iceFlowK = 3.0`):

| n | dt | mit Eis | ohne Eis | Δ |
|---|---|---|---|---|
| 384 | 0.2 | 64.5 ms | 61.0 ms | +3.6 ms |
| 384 | 500 | 98.3 ms | 81.7 ms | +16.6 ms |
| 384 | 10.000 | 508 ms | 370 ms | +138 ms |
| 640 | 0.2 | 189 ms | 205 ms | −16 ms (im Rauschen) |
| 640 | 500 | 284 ms | 266 ms | +18 ms |
| 640 | 10.000 | 1970 ms | 1128 ms | +842 ms |

Im Echtzeit-Zeitraffer (dt ≈ 0.2 J./Frame) ist der Pass EIN Teilschritt und
verschwindet im Rauschen; er kostet dort, wo er muss — im großen Sprung.

---

## §F — Moränen-Budget

`testMoraineBudgetDiagnostic`, n = 256, EIN Schritt aus demselben Zustand nach
20k Jahren Vorlauf, drei Arme (nichts / nur Abtrag / nur Moräne), damit die
Differenzen genau die beiden Terme isolieren:

| dt | glazialer Abtrag (Σ Δh) | Moräne (Σ Δh) | Anteil |
|---|---|---|---|
| 500 | 6.014 | 1.241 | **20.6 %** |
| 5.000 | 57.747 | 13.076 | **22.6 %** |

Bei `iceMoraineK = 0.05` legt das Eis also gut ein Fünftel dessen wieder ab, was
es abträgt. Der Rest verlässt das System als Schmelzwasserfracht —
Masse-Erhaltung gilt in diesem Repo ohnehin nicht (detachment-limited
Stream-Power, AGENTS.md), die Invariante ist beschränktes Relief.

Dass der Anteil zwischen dt = 500 und dt = 5000 nur um 2 Prozentpunkte wandert,
ist der Nebenbefund: beide Terme sind Raten und skalieren zusammen (der Abtrag
fast exakt ×9.6, die Moräne ×10.5 bei ×10 Zeit — die Abweichung ist der
Operator-Splitting-Rest aus §G).

**Wo die Moräne landet**, prüft `testMoraineBuildsAtTheTongue`: der Schutt
schmilzt nur über den SCHMELZ-Anteil von μ aus, und der ist bei `T ≤ 0` exakt 0 —
unter dem Nährgebiet entsteht also keine Moräne, im Zehrgebiet schon. Beim Aufbau
dieses Wächters sind zwei Messfehler aufgefallen, die hier festgehalten sind,
weil sie leicht wiederkehren:

1. **Zwei getrennt gelaufene Arme taugen nicht.** Nach 30k Jahren sind sie überall
   auseinander; die Differenz misst Chaos statt Moräne (Summe über das Nährgebiet
   1.02 statt 0). Der Wächter kopiert deshalb den Zustand über das
   Zustands-Inventar (Issue #8) und vergleicht EINEN Schritt.
2. **Die Temperatur am Schrittende ist die falsche Klassifikation.**
   `updateClimate` läuft zuletzt und auf den FINALEN Höhen; eine Zelle kann
   zwischen Moränen-Ablage und Messung über die 0-°C-Grenze wandern (gemessen:
   1.1e-4 „Schutt im Nährgebiet", der in Wahrheit im Zehrgebiet lag).

---

## §G — dt-Invarianz

`testIceIsFramerateIndependent`, n = 256, 20.000 Jahre in verschiedenen
Schrittweiten:

| dt | Eismasse (Σ ice) | Eis-Zellen |
|---|---|---|
| 100 | 21.6867 | 1056 |
| 500 | 21.4821 | 1048 |
| 2500 | 20.1029 | 1010 |

Spanne 7.9 % in der Masse, 4.6 % in der Fläche — innerhalb der Schranken des
Wächters (15 % / 20 %). Der Rest ist die benannte Operator-Splitting-Drift des
Projekts (`docs/dt-invariance-measurements.md` §5): das Abflussfeld und die
Klima-Felder werden einmal je Schritt bestimmt, der Gletscher läuft aber
`nSub`-mal dagegen; zusätzlich variiert die Teilschritt-Stärke `kappa·dt/nSub` mit
der Aufrundung von `nSub` (dieselbe Konstruktion wie bei der Hangdiffusion).

Exakt sind dagegen die beiden Zeit-Terme im Teilschritt: die Bilanz ist die
geschlossene Lösung von `İ = a − μI` (teleskopiert über beliebig viele
Teilschritte), und die ausgeschmolzene Menge ist das exakte Integral `∫μ·I dt`
über den Teilschritt. `dt = 0` lässt das Feld Byte für Byte stehen
(`testZeroStepLeavesIceUntouched`).

---

## §H — Kalibrier-Kaskade: was der Gletscher an bestehenden Wächtern verschiebt

Der Pass ist eine neue Physik auf den Produktions-Defaults, also verschiebt er
Kennzahlen, die andere Tickets gepinnt haben. Sechs Zusicherungen in sechs Tests
wurden rot; keine davon war ein Fehler des Passes (seine eigenen Aus- und
dt-Wächter blieben durchgehend grün, §G und `Glacier.swift`). Diese Reihe hält
fest, was gemessen wurde und wie jeder Fall aufgelöst ist. Jede Zeile ist EIN
Lauf mit `iceEnabled = true` gegen denselben Lauf mit `iceEnabled = false`.

### H.1 — Aus-Wächter, die zwei verschiedene Welten verglichen

`MeltRunoff.testDisabledMeltRunoffIsBitIdentical` und
`ClimateSnow.testDisabledClimateIsBitIdenticalPhysics` bauen ihren
Vergleichsarm über „es fällt nie Schnee" bzw. „kein Klima". Beides nimmt dem
Gletscher sein Nährgebiet — der eine Arm vergletschert, der andere nicht, und
die Bit-Gleichheit prüft dann zwei Physiken statt einer (gemessen:
Höhendifferenzen bis 0.1 und konstante ~1.87 in `area`). Beide Arme laufen
deshalb jetzt zusätzlich mit `iceEnabled = false`. Die Bit-Gleichheit des
Gletscher-Pfades selbst steht unangetastet in `testDisabledIceIsBitIdentical`
und `testIcelessWorldIsBitIdentical`: **jede Kopplung einzeln abschaltbar,
jede einzeln bewacht.**

`FlattenRegeneration.testRegenerationIsFramerateIndependent` gehört in dieselbe
Klasse, mit einem lehrreichen Detail: die frisch eingeebnete Platte liegt bei
`sea + 0.25` weit unter der Firn-Grenze, trotzdem entsteht dort Eis. Grund ist
das Operator-Splitting — `updateIce` läuft am Schrittanfang auf dem Klima des
vorigen Schrittendes, im ersten Schritt also auf der Temperatur der noch
ungeebneten Gipfel. Dieses Eis schmilzt im zweiten Schritt aus und legt seine
Moräne ab; die Menge hängt an der Länge dieses EINEN Fensters, also an dt
(gemessen: max. Abweichung 0.0018 zwischen dt = 50 und dt = 1000). Der Test legt
für seine 1e-9-Schranke ohnehin alle anderen `h`-Pässe stumm — der Gletscher ist
jetzt einer davon.

### H.2 — Alterungsverlauf: der Gipfel hängt an der Firn-Grenze

`TerrainAging.testAgingTrajectoryOver100k`, n = 160, Seed 1337, alle 20k Jahre:

| Kennzahl | 0k | 20k | 40k | 60k | 80k | 100k |
|---|---|---|---|---|---|---|
| `landRelief()` (max−min), Eis an | 0.5364 | 0.4509 | 0.4366 | 0.4320 | 0.4301 | 0.4289 |
| `landRelief()`, Eis aus | 0.5364 | 0.4721 | 0.4316 | 0.4254 | 0.4180 | 0.3930 |
| `landReliefRobust()` (p95−Median), Eis an | 0.1802 | 0.1504 | 0.1260 | 0.1152 | 0.1104 | 0.1084 |
| `landReliefRobust()`, Eis aus | 0.1802 | 0.1479 | 0.1289 | 0.1182 | 0.1123 | 0.1069 |
| `maxH`, Eis an | 0.6864 | 0.6010 | 0.5866 | 0.5821 | 0.5801 | 0.5789 |
| `maxH`, Eis aus | 0.6864 | 0.6221 | 0.5816 | 0.5754 | 0.5680 | 0.5430 |
| vergletscherte Zellen | 0 | 272 | 100 | 53 | 37 | 17 |

Das ist der interessanteste Befund der ganzen Reihe: **der Gipfel sinkt bis auf
die Firn-Grenze (0.5731) und bleibt dort stehen.** Er sinkt darauf zu, weil er
erodiert; sobald er sie unterschreitet, verschwindet das Eis und die fluvialen
Pässe greifen wieder — ein selbst-stabilisierendes Gleichgewicht bei 0.5789,
gehalten von zuletzt 17 Zellen. Genau dieses Einpendeln knapp über der
Schneegrenze beschreibt die Buzzsaw/Protection-Literatur
(`docs/research-climate-cryosphere.md` §4).

Für den Wächter heißt das: `landRelief()` ist max − min und damit per
Konstruktion die Kennzahl, die eine einzelne Zelle bewegen kann (die Doku von
`landReliefRobust` misst das aus: +145 % durch EINE Zelle). Die FLÄCHE altert
dagegen unbeeindruckt weiter und praktisch gleich schnell wie ohne Eis — 0.1084
gegen 0.1069 nach 100k, ein Unterschied von 1.4 %. Kriterium 3 („sinkt in der
zweiten Hälfte weiter") misst deshalb jetzt das robuste Relief: 0.1191 (50k) →
0.1084 (100k), also −9.0 % gegen eine Schwelle von −5 %. Die Kriterien 2 und 4
(Gesamtabnahme, kein Einebnen) bleiben auf `landRelief()` — sie halten dort mit
Reserve.

### H.3 — Geerbte dt-Drift der Schneedecke

`ClimateSnow.testSnowThroughFullStepsIsDtInvariant`, n = 192, 20k Jahre:

| dt | Vorrat (Eis an) | Rampe (Eis an) | Eis-Zellen | Relief | Vorrat (aus) | Rampe (aus) |
|---|---|---|---|---|---|---|
| 50 | 0.00185 | 0.00367 | 321 | 0.4388 | 0.00224 | 0.00457 |
| 500 | 0.00218 | 0.00466 | 395 | 0.4482 | 0.00251 | 0.00515 |
| 2000 | 0.00173 | 0.00353 | 292 | 0.4385 | 0.00226 | 0.00456 |

Spanne mit Eis 20.6 % (Vorrat) bzw. 24.2 % (Rampe), ohne Eis 10.8 % / 11.5 %.
Die Schranke des Wächters steht deshalb auf 30 % statt 20 %. Dass das geerbte
Drift ist und keine dt-Abhängigkeit der Schneebilanz, sagen drei Beobachtungen:

1. Die Bilanz selbst bleibt bei 1e-12 (`testSnowBalanceIsDtInvariant`), und der
   Gletscher schreibt `snow` überhaupt nicht — er liest es.
2. Die Abweichung ist **nicht monoton in dt**: in beiden Armen ist dt = 500 der
   Ausreißer nach oben. Das ist Streuung um die Maske herum (eine Zelle fällt
   über oder unter die Firn-Grenze), kein Trend über die Schrittweite.
3. Die Schneegrenze `snowStart` steht mit Eis über alle drei Schrittweiten
   bit-gleich auf 0.5697 — sie hängt an der Höhenverteilung, und die driftet
   nicht.

### H.4 — Zwei Mechanik-Wächter, die jetzt ausgepinnt sind

Beide Fälle folgen der Doktrin, die in `EndorheicEvaporation.cfg()` schon
dreimal steht (Lithologie #12, Höhenbänder #4, Schmelzwasser #36): ein Wächter,
der die MECHANIK an einem konkreten Objekt prüft, pinnt die
Produktions-Kalibrierung aus, die dieses Objekt austauscht.

**`EndorheicEvaporation` (n = 256, κ = 6, Seed 1337, 200×20 Jahre):**

| Arm | max Sprung, Eis an | Eis aus |
|---|---|---|
| τ = 500 (ratenbegrenzt) | 0.00675 | 0.00654 |
| τ = 0 (Kontrollarm) | 0.00493 | 0.00787 |

Die Ratenbegrenzung selbst bewegt sich um 3 %; es ist der KONTROLLARM, der mit
Eis um 37 % ruhiger wird und unter den ratenbegrenzten rutscht. Ursache ist
dieselbe Kante, die schon die Lithologie traf: der Spiegel springt an
DISKRETEN Ereignissen (eine Sill bricht, der Priority-Flood pegelt das Becken
um), und unter dem Eis liegt der fluviale Abtrag still, der diese Sills
durchsägt. Die Sichtbarkeits-Schranke maxJump/Spanne bleibt derweil auf ihrem
Niveau (0.320 gegen 0.307).

**`RainWeightedFlow` (n = 192, 6 Seeds, 20k Jahre, gepoolte Drainagedichte
Luv/Lee):**

| | ungewichtet | gewichtet | Hub |
|---|---|---|---|
| ohne Eis | 1.164 | 1.315 | ×1.130 |
| mit Eis | 1.197 | 1.230 | ×1.027 |

Die Richtung stimmt in der Produktion weiterhin (gewichtet > ungewichtet), aber
der Hub schrumpft von +13 % auf +2.7 % und trägt die 5-%-Marge des Wächters
nicht mehr. Der Grund ist systematisch und nicht zufällig: Schnee fällt, wo es
hoch UND nass ist — also bevorzugt im LUV —, und unter dem Eis entstehen keine
fluvialen Rinnen. Die Gletscher dünnen ausgerechnet die Luv-Kanäle aus, an denen
die Kennzahl hängt.

---

## §I — Wie viel fluvialer Abtrag lief unter dem Eis noch weiter?

Nachgereicht zur PR-Review von #35. `underIce` gatete zunächst nur die zwei
Pässe, die das Ticket nennt (`outletIncision`, `Hydraulic.erode`) — und der
Abnahme-Wächter `testNoFluvialErosionUnderIce` lief mit `quietCfg()`, in der
`meanderEnabled` und `braidingEnabled` AUS sind. In Produktion sind beide an,
und beide bewegen Bettmaterial: `meanderStamp` carvt sein Bett selbst plus die
lateralen Ufer, `braidPass` deponiert und scourt die Bedload-Fracht.

**Aufbau** (n = 384, Seed 1337, `iceErodeK = iceMoraineK = 0`, 20k Jahre
vorgelaufen, dann EIN Schritt à 500 Jahren aus demselben Zustandsinventar):
gezählt werden die vergletscherten Zellen, deren `h` sich vom Kontrollarm
unterscheidet, in dem alle fluvialen Bett-RATEN auf 0 stehen. Je Zeile ist
genau eine Rate wieder aktiv.

| aktive Rate | veränderte Zellen auf Eis | abseits des Eises |
|---|---|---|
| `meanderCarve` (Bett-Carve) | **3** | 4 963 |
| `meanderBankErode` (laterale Ufer) | **6** | 6 811 |
| `braidCapacity` (Braid-Fracht) | **1** | 5 395 |
| `outletErode` (gegatet seit #35) | 0 | 92 962 |
| `hydraulicPerYear` (gegatet seit #35) | 0 | 81 486 |
| alle zusammen | **9** | 123 077 |

Die zwei gegateten Pässe halten exakt (0 Zellen) — das Gate selbst war nie das
Problem. Die 9 Zellen sind die drei ungegateten Bett-Bewegungen, und sie liegen
dort, wo die Review sie vermutet hat: wo eine Zunge über einen Talboden
vorstößt, aus dem `traceChannels` seine Läufe zieht. Neun Zellen JE SCHRITT
sind wenig, aber es ist genau das Doppel-Carve, das die Maske verhindern soll —
ein fluvialer Kerb-Querschnitt im Trog, jeden Schritt aufs Neue.

**Konsequenz:** Das Gate sitzt jetzt an `Terrain.erodeCell`/`depositCell`, den
zwei Funneln, über die ALLE Bett-Bewegungen außer den Tropfen laufen
(Bett-Carve, laterale Ufer, Altarm-Pfropf und -Verlandung, Braid-Fracht,
Auen-Aggradation). `meanderStamp` überspringt vergletscherte Zellen zusätzlich
schon vor der Kanalmaske — ein Lauf unter einer Zunge ist kein Kanal, und
`isChannel`/`veg = 0` haben dort nichts zu suchen. Nach dem Gate: 0 Zellen in
allen Zeilen. Wächter: `testNoFluvialErosionUnderIceInProduction`.

### I.1 — Warum der Wächter die Hangdiffusion ausschaltet

Derselbe Aufbau mit `hillDiffusion` auf dem Produktionswert meldet **852**
veränderte Zellen auf dem Eis, davon 825 allein aus `outletErode` und 235 aus
`hydraulicPerYear` — also aus den beiden Pässen, die nachweislich (Tabelle oben)
keine einzige Eiszelle anfassen. Es ist das Bodenkriechen: `hillslopeDiffusion`
läuft flächendeckend und trägt die Höhenänderung der NACHBARN auf die Eiszelle.

Das ist kein fluvialer Abtrag und wird bewusst nicht gegatet — Kriechen unter
Eis abzuschalten wäre eine eigene physikalische Behauptung, und der Trog bliebe
sonst mit unbehandelten Kanten zurück. Für den Wächter heißt es: mit Diffusion
misst er die Diffusion statt das Gate. Deshalb erbt der Produktions-Arm
`hillDiffusion = 0` aus `quietCfg()` und schaltet nur `meanderEnabled` und
`braidingEnabled` zu.
