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

**Stand seit #174:** die Produktion nutzt `climateSeaLevelTemp = 13` (Grenze bei
`0.15 + 13/26 = 0.65`); §A bis §K gelten für die 11 °C und die alte Großform, auf
der ihre Wächter weiter laufen (`calibrationSeaLevelTemp`). Begründung und
Messreihe: §L.

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
Auen-Aggradation; seit I.2 auch `transportLimited`). `meanderStamp` überspringt
vergletscherte Zellen zusätzlich
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

### I.2 — Der Grid-Pfad (`hydraulicEnabled = false`) war die letzte Lücke

Zweite Review-Runde, dasselbe Thema: `Hydraulic.erode` ist nur der
PRODUKTIONS-Zweig. Steht `hydraulicEnabled` auf `false` — was die isolierten
Mäander-, Becken- und Snapshot-Tests bewusst tun (`meanderCfg()` in
`SimCoreTests.swift`, `EndorheicEvaporation`, `WorldSnapshotTests`) — läuft an
seiner Stelle `transportLimited`, und der schrieb `h`/`sed`/`rock` an drei
Stellen direkt: Delta am Meer, Ablagerung über Kapazität, Inzision darunter.

**Aufbau** (n = 384, Seed 1337, `quietCfg()` + `hydraulicEnabled = false`, 20k
Jahre vorgelaufen): der Pass wird danach EINZELN aufgerufen (`dt` = 500) und
`h` davor/danach bit-verglichen. Einzeln statt über `step()`, weil der Grid-Pfad
fest mit `diffusionPass` zusammenläuft (kappa ist dort ein Default, kein
Regler) — ein Zwei-Arm-Vergleich über den Schritt misst sonst wieder das
Bodenkriechen aus §I.1.

| | vergletscherte Zellen | davon bewegt | eisfreie bewegt |
|---|---|---|---|
| ungegatet | 651 | **651** | 82 414 |
| über den Funnel gegatet | 1 385 | **0** | 81 738 |

Der Pass traf also nicht ein paar Zellen am Zungenrand wie Mäander und Braiding,
sondern **jede einzelne**: er läuft flächendeckend über `order`, nicht entlang
der Läufe. Dass die Eisfläche mit Gate von 651 auf 1 385 Zellen steigt, ist die
Rückkopplung dazu — 20k Jahre lang trug der ungegatete Grid-Pfad das Bett unter
der Zunge ab und drückte das Nährgebiet unter die Firn-Grenze.

**Konsequenz:** `transportLimited` bewegt das Bett jetzt ausschließlich über
`erodeCell`/`depositCell`. Die Fracht `qs` verschwindet dabei nicht: was eine
Eiszelle weder abgibt noch annimmt, zieht unverändert zum Empfänger weiter
(`depositCell` gibt dafür den tatsächlich abgelegten Betrag zurück). Wächter:
`testNoFluvialErosionUnderIceOnTheGridPath`.

---

## §J — Das Hangknick-Signal der Lithologie (#12) unter Eis

Nachgereicht, weil `Lithology.testHardnessContrastHoldsSlopeBreak` mit den
Funnel-Gates aus §I knapp kippte. Der Wächter misst das Verhältnis der
Makro-Steigung auf HARTEN gegen WEICHE Zellen (lokal gepaart, geometrisch
gepoolt — Herleitung im Test) und hat drei Zusicherungen: Signal > 1.10,
Abstand zum Referenzarm > 0.06, Reinheit des Referenzarms |aus − 1| < 0.08.
Der Referenzarm rechnet dasselbe Feld mit `lithContrast = 0`, die Härte wirkt
dort also auf keine Rate.

**Aufbau** (n = 192, Seed 1337, 20k Jahre, dt = 500), 2×2 über die zwei
Klima-Kopplungen:

| | Eis aus | Eis an |
|---|---|---|
| Schmelze aus | an 1.1781 / aus **1.0282** / Δ 0.150 | an 1.1423 / aus **1.0843** / Δ 0.058 |
| Schmelze an | an 1.1950 / aus **1.0995** / Δ 0.096 | an 1.1853 / aus **1.0710** / Δ 0.114 |

Das Feld unten links ist die Messung, mit der #36 den Schmelze-Pin begründet hat
(dort notiert als 1.1950 / 1.0995) — reproduziert, der Messaufbau ist also
derselbe.

**Befund:** Was das Eis anhebt, ist der REFERENZARM (1.0282 → 1.0843), nicht das
Signal (1.1781 → 1.1423). Das ist dieselbe Mechanik, die #36 schon für die
Schmelze notiert hat: die Härte enthält die stratigraphische Schichtwelle und
hängt per Konstruktion an `h`, also hebt jeder Prozess, der gezielt das HOCHLAND
steiler macht, auch den Arm, in dem die Härte gar nicht wirkt. Das Eis sitzt noch
höher als der Ablationssaum und trifft die Kennzahl entsprechend härter. Von den
412 vergletscherten Zellen kommt kein Beitrag zum Härte-Kontrast — sie tragen nur
glaziale Steigung in die Paarung.

Kein Fehler der Gates also, sondern eine bekannte Schwäche der KENNZAHL. Die
beiden inhaltlichen Zusicherungen halten in allen vier Feldern; nur die
Reinheits-Schranke hält allein im eis- und schmelzfreien Feld.

**Konsequenz** (dieselbe Doktrin wie der Schmelze-Pin von #36, §3 in
`docs/melt-runoff-measurements.md`): Der Wächter pinnt jetzt auch
`iceEnabled = false` — beide Arme, damit weiter nur die WIRKUNG der Härte den
Unterschied macht. Die Gegenprobe `testSlopeBreakSurvivesMeltRunoff` läuft auf
`cfg()` und damit auf voller Produktionsphysik (Schmelze UND Eis, Feld unten
rechts); sie prüft die zwei inhaltlichen Zusicherungen und hält jetzt zusätzlich
fest, dass ihr Arm die vergletscherten Zellen wirklich hat (> 100), damit die
Gegenprobe nicht still leer läuft.

---

## §K — Die Schwelle galt nur den fluvialen Pässen (Review-Fund)

Dritte Review-Runde, Gegenrichtung zu §I: dort ging es darum, wo FLUVIAL unter
dem Eis noch abgetragen wurde, hier darum, wo das EIS unterhalb seiner eigenen
Schwelle noch gearbeitet hat. `SimConfig.iceMinThickness` ist als „unter einem
Schneefeld dieser Mächtigkeit fließt kein Eis und der Bach läuft normal weiter"
dokumentiert, gelesen hat sie aber nur `rebuildIceMask` (und damit die fluvialen
Gates). `iceFlowSubStep` gatete den Ausstrom an `ice > 0` und die Abrasion an
`i0 > 0` — jede positive Restdicke floss und schliff. Am Saum arbeiteten damit
beide Erosionsgesetze gleichzeitig am selben Bett.

**Aufbau** (n = 256, Seed 1337, `quietCfg()` + `hydraulicPerYear = 0` +
`outletErode = 0`, damit im Vergleichsschritt AUSSCHLIESSLICH das Eis `h`
anfasst; 20k Jahre vorgelaufen, dann EIN Schritt mit dt = 500 aus demselben
Zustand). Verglichen wird ein Arm mit einer Schwelle oberhalb der größten
Eisdicke gegen einen Arm mit „Transport-Deckel 0 + `iceErodeK = 0`". Sind
Transport und Abrasion an die Schwelle gebunden, müssen beide bit-gleich sein.

| | Saum (0 < Eis ≤ Schwelle) | Zellen geflossen | Zellen geschliffen |
|---|---|---|---|
| vorher | 18 870 | **20 168** | **15 319** |
| Transport/Abrasion an der Schwelle | 1 798 | **0** | **0** |

Der Saum schrumpft um den Faktor 10, weil er vorher sein eigener Motor war: das
Eis unter der Schwelle floss weiter talwärts und legte dort neues Eis unter der
Schwelle an. Der Rest von 1 798 Zellen ist der echte Rand — dort speist die
Bilanz (Firn, Zufluss aus der Nachbarzelle), und die läuft bewusst weiter, sonst
könnte ein Schneefeld nie über die Schwelle wachsen und es entstünde nie ein
Gletscher.

Die Gegenprobe im selben Lauf: mit der PRODUKTIONS-Schwelle bewegt der Gletscher
in genau diesem Schritt 2 298 Zellen — vorher waren es 0, weil die Schwelle für
das Eis gar keine Rolle spielte und die beiden Arme identisch liefen. Genau
dieser Wert zeigt, dass der Vergleich nicht bloß einen stillstehenden Gletscher
gegen einen stillstehenden hält.

**Konsequenz:** `iceFlowSubStep` liest `iceMinThickness` an beiden Stellen
(Pass 1: kein Ausstrom, keine Erosions-Rate; Pass 2: keine Abrasion). Die Zone
unter der Schwelle ist damit fluvial UND nur fluvial, die Zone darüber glazial
UND nur glazial — die Maske `underIce` teilt sie ohne Überlappung und ohne
Lücke. Wächter: `Glacier.testThinIceNeitherFlowsNorGrinds`.

---

## §L — Eis an der Schrittweite: drei Kopplungen großer Schritte (Issue #174)

Befund aus der Test-Kaskade von #174 (`docs/zielbild-measurements.md`,
„Offene Befunde"): in der Produktion hing die Eismasse an der Schrittweite,
Jahr 20.000, dt 100 gegen 1000: 49,6 / 126,3 (Seed 1337), 65,3 / 31,5 (42),
162,3 / 57,1 (20). Schon `origin/main` zeigte es (77,4 / 128,1 usw.); der
Wächter aus §G (n = 256, `quietCfg`, lange Läufe, 15 % Schranke) lag auf der
alten Welt zufällig in einem ruhigen Bereich.

**Messweg.** Lange Läufe in zwei Schrittweiten laufen auch ohne Fehler
auseinander (Tropfen-Splitting, `docs/dt-invariance-measurements.md` §5), und
die Eismasse verstärkt jede Abweichung der Gipfelhöhe. Deshalb Schrittpaare:
aus EINEM Zustand (Jahr 5000, volle Physik `cfg`, nicht `quietCfg`) 1000 Jahre
als 1 × 1000, 10 × 100 und 64 × 15,625 (Zeitraffer-Takt),
`testIceStepPairDiagnostic`. Vor dem Fix schliff der Sprung nur 25–50 % dessen,
was der Zeitraffer schliff (Spanne der Absenkung unter dem Eis 51–76 %, der
Masse 3,2–4,7 %).

**Drei Ursachen**, alle Kopplungen eines großen Schritts an Größen vom
Schrittanfang, keine in der Bilanz selbst; jede allein zu beheben reichte nicht
(Ablationen über `RS_VARIANTS`):

1. **Instabiler Transport bei dickem Eis.** Die Sub-Taktung deckelte nur den
   Ausstrom-Anteil `kappa·ΣΔs⁺` am steilsten Hang. Der Fluss
   `kappa·I·(s_k − s_nb)` ist aber Diffusion der Eis-Oberfläche mit dem
   Koeffizienten `kappa·I`; deren Schachbrett-Modus wächst je Teilschritt um
   `|1 − 8·kappa·I|`. Dickes Eis auf flachem Bett lief damit instabil: bei
   dt = 1000 eine Schachbrett-Oberfläche (Rauheit × 70), die das Bett in
   EINEM Schritt im Mittel 0,065 tief schliff (10 × 100: 0,005). Jetzt gilt
   zusätzlich `kappa·I ≤ iceFlowSubCap/2 = 1/8` (`iceTransportScale`).
   Gegen 1/16 konvergiert (Masse < 0,01 %), gegen 1/4 nicht (−6 … −12 %).
2. **Pfützen-Verlandung füllte den Schliff wieder auf.** `fillShallowPonds`
   liest `hf` vom Schrittanfang und hielt alles, was der Gletscher im selben
   Schritt tiefer als 0,001 schliff, für eine Pfütze, nur in großen
   Schritten. Unter dem Eis (`underIce`) verlandet nichts mehr.
3. **Temperatur vom Schrittanfang.** Der Teilschritt rechnet sie jetzt aus
   dem Bett, das er vor sich hat (dieselbe Formel wie `updateClimate`, bei
   unverändertem `h` bit-gleich). Vorher 3 % mehr Eis je 1000-Jahr-Schritt
   als in zehn Schritten à 100.

**Nachher, Schrittpaare** (n = 256, Jahr 5000 → 6000, Wächter
`testIceIsFramerateIndependent`, Schranken Absenkung 15 %, Masse 3 %,
Fläche 5 %):

| Seed | Masse 1000 / 100 / 15,625 | Zellen | Absenkung unter Eis |
| ---: | :--- | :--- | :--- |
| 1337 | 66,65 / 65,85 / 65,86 | 1487 / 1483 / 1491 | 0,00116 / 0,00112 / 0,00112 |
| 42 | 2,663 / 2,617 / 2,622 | 100 / 100 / 101 | 0,00090 / 0,00092 / 0,00090 |
| 20 | 132,57 / 131,93 / 131,98 | 1600 / 1601 / 1609 | 0,00186 / 0,00183 / 0,00182 |

Dazu `testThickIceTransportIsStableForLargeSteps` (n = 64, ebene Eisplatte
1,0 mit Schachbrett ±0,001): 2000 Jahre als ein Schritt gegen 20 × 100,
Rauheit danach 1,1e-4 bzw. 1,4e-4 (klingt ab), größte Abweichung 2,6e-5.

**Nachher, Produktion** (`testIceDtSweepDiagnostic`, Einlauf der Brücke,
Jahr 20.000; M4 Max, 2026-10-17):

| Seed | dt | Eismasse | Eiszellen | größte Dicke |
| ---: | ---: | ---: | ---: | ---: |
| 1337 | 15 | 454,6 | 10 604 | 0,249 |
| 1337 | 100 | 450,1 | 10 546 | 0,243 |
| 1337 | 1000 | 434,4 | 10 547 | 0,236 |
| 42 | 15 | 69,8 | 3 022 | 0,099 |
| 42 | 100 | 68,1 | 3 000 | 0,099 |
| 42 | 1000 | 68,5 | 3 005 | 0,095 |
| 20 | 15 | 147,4 | 4 512 | 0,150 |
| 20 | 100 | 141,5 | 4 484 | 0,142 |
| 20 | 1000 | 138,6 | 4 415 | 0,142 |

Spanne der Masse über dt 15 … 1000: 4,5 % / 2,5 % / 6,0 % (vorher Faktor
2,5). Lesart: auf Seed 1337 trägt die Welt jetzt in JEDER Schrittweite rund
neunmal so viel Eis wie vorher bei dt 100 (450 statt 49,6): der alte Transport
lief schon bei dt 100 auf dem dicken Eis instabil und schliff das Eis mit dem
Bett weg. Der Gletscher ist damit im Bild deutlich größer; die Fläche bleibt
unter 5 % des Landes.

**Kosten** (`simperf --repeat 3`, Produktion, dt 100, interleaved 4 Runden
gegen den Integrationsstand `17218b1`, Rechner nicht ruhig): `updateIce`
3,5–4,9 → 6,5–10,3 ms je Schritt (das zweite Kriterium verdoppelt die
Teilschritte auf dickem Eis), der ganze Schritt im Median 59,8 → 62,9 ms
(+5 %). Im Zeitraffer (dt 15) sind die Teilschritte entsprechend weniger.

### Befund: der stabile Transport macht den Kamm zur Tafel (Ausgangslage)

Im Bild (Seed 1337, Jahr 20.000, F1/F2, maximiert) trägt der Kamm nach dem Fix
Hochflächen mit senkrechten Wänden statt Graten; die Vorlage
(`docs/references/zielbild/`) zeigt alpine Grate mit Kar-Gletschern. Deshalb
war der Fix zunächst NICHT im Integrationszweig (Revert dort, 2026-10-17); er ist
jetzt mit der Nachkalibrierung unten wieder drin. Kennzahlen
(Produktion, dt 1000 wie der `RS_STEP`-Vorlauf, oberste 5 % des Landes;
„flach" = Weltsteigung < 0,15, Zackigkeit = mittlere |h − Mittel 9 × 9|):

| Stand | flach 1337 / 42 / 20 | Zackigkeit | p95 der Höhe | Eiszellen |
| --- | --- | --- | --- | --- |
| alt (instabil) | 1,9 / 2,1 / 4,7 % | 0,0061 / 0,0049 / 0,0061 | 0,530 / 0,521 / 0,523 | 4502 / 955 / 2218 |
| Fix | 10,5 / 8,1 / 13,8 % | 0,0047 / 0,0037 / 0,0044 | 0,557 / 0,536 / 0,547 | 10547 / 3005 / 4415 |
| Fix ohne Kriterium `2·I_max` | 5,8 / 12,4 / 9,8 % | 0,0051 / 0,0036 / 0,0049 | 0,537 / 0,536 / 0,529 | 3284 / 1243 / 1381 |
| Fix ohne Pfützen-Sperre | 3,8 / 3,0 / 5,9 % | 0,0061 / 0,0046 / 0,0059 | 0,564 / 0,537 / 0,551 | 20894 / 5645 / 9028 (Eis läuft weg) |
| Fix, `iceErodeK` 1,25e-4 | 12,2 / 8,8 / 14,4 % | 0,0040 / 0,0036 / 0,0041 | 0,555 / 0,536 / 0,546 | 7303 / 2233 / 3317 |
| Fix, `iceErodeK` 2e-4 | 11,9 / 10,0 / 13,3 % | – | 0,550 / 0,535 / 0,542 | 2615 / 1294 / 1598 |
| Fix + Firn-Abgleiten am Steilhang 0,03…0,06 | 12,7 / 8,1 / 14,2 % | 0,0046 / 0,0038 / 0,0043 | 0,561 / 0,536 / 0,550 | 12940 / 3339 / 5567 |

Lesart: das alte Bild entstand aus dem Artefakt — das Schachbrett-Schleifen
zersägte die Eiskappe auf dem Kamm. Stabil liegt dort eine Kappe, die den
fluvialen Abtrag sperrt und auf ihrer flachen Oberfläche kaum schleift
(`E = K·q^m·S`, `S` klein); die eisfreien Täler daneben schneiden ein, an
der Eisgrenze entsteht eine Wand. Mehr Schliff senkt Gipfel und Eis, flacht
aber nicht weniger ab; Firn-Abgleiten am Steilhang hebt die Gipfel sogar
(weniger Schliff an den Flanken). Dazu kommt die Großform von #174: bei der
Generierung liegen auf Seed 1337 5,2 % des Landes über der Firn-Grenze, die
Kalibrierung von #35 ging von ~1,5 % aus. V→U (`testGlaciatedValleysWidenTowardsU`)
hält bei `iceErodeK` ≤ 1,25e-4 (Δb +0,14 / +0,24), bei 1,5e-4 nicht mehr
(+0,08 nach 30k).

### Vorgänger-Reihen (GPT-6.1-Sol, nicht von mir wiederholt)

Aus dem Verlauf des Vorgänger-Agenten übernommen, nur als Verlauf der Sackgassen
(Produktion, dt 1000, oberste 5 % des Landes; „flach" = Weltsteigung < 0,15). Was
ich von dort als Grundlage benutze, habe ich nachgemessen (nächster Abschnitt:
Ausgangszahlen, eisfreie dt-Drift 15 / 11 / 16 %, Ergebnis der Firn-Grenze bei
13 °C, Bit-Gleichheit der räumlichen Begrenzung).

| Variante | Befund |
| --- | --- |
| Firn-Zufuhr `iceFirnPerSnowYear` 1e-3 → 5e-4 und `iceErodeK` 1e-4 → 2e-4 (WIP-Stand) | Eisfläche 2,99 / 1,61 / 1,98 % des Landes, flach 6,6 / 4,8 / 8,4 %; V→U (Mechanik-Welt) Δb +0,261 / +0,199 nach 30k / 50k, n = 38 / 25 |
| Zufuhr 3e-4 / Schliff 3e-4 | V→U bei 50k nur Δb +0,032, n = 16 |
| Zufuhr 7,5e-4 / Schliff 1,5e-4 | V→U verfehlt das Signal schon bei 30k (Δb +0,044) |
| Zufuhr allein 1e-4 | höhere, kältere Gipfel, Eis wächst auf 7,31 % (Seed 1337) |
| weniger Firn-Zufuhr allgemein | weniger Schliff, Gipfel bleiben höher und kälter, Eis > 7 % |
| weniger Gefälle-Abhängigkeit des Schliffs | Eis 5,8 … 11 % |
| 1/10 Firn + 7,5 × Schliff | Seed 1337 flach 5,0 %, Zackigkeit 0,00516, Eis 3,38 %; Seed 42 Zackigkeit 0,00413; V→U-Wächter nur 6 … 8 auswertbare Profile |
| Karwand-Rückverlegung (Frost am Eisrand) | flach 10,1 … 10,5 %: löste die Kappe nicht |
| Meeresspiegel-Temperatur 13 °C (Firn-Grenze 0,65; nur Seed 1337 / 42 gemessen) | 1337: flach 2,7 %, Eis 1,41 %; 42 verliert fast alles Eis; bei 12 °C bleiben im V→U-Wächter keine auswertbaren Profile |
| `iceErodeK` 1,25e-4 / 2e-4, Firn-Abgleiten am Steilhang | Tabelle im Ausgangsbefund oben |

Alle Zufuhr-/Schliff-Wege verschieben die Kappe, lösen sie aber nicht, und sie
zahlen mit dem V→U-Signal. Der Grund steht in der Randbedingung des Eises: nicht
die Eis-Physik ist falsch geeicht, sondern wo die Firn-Grenze liegt.

### Entscheidung: die Firn-Grenze des EISES folgt der Großform

**Ursache.** Die Firn-Grenze `sea + climateSeaLevelTemp / climateLapseRate`
(0,5731 bei 11 °C) wurde in #33/#35 auf ~1,5 % des Landes geeicht
(`bandSnowPercentile`). Die Kamm-Großform von #174 trägt mehr Fläche in
Gipfelhöhe; bei der Generierung (Einlauf 3000 J.) liegen 5,17 / 2,14 / 3,01 %
des Landes (Seeds 1337 / 42 / 20) über der Grenze. Mit dem stabilen Transport
ist daraus eine Kappe geworden.

**Erster Versuch, verworfen: die Meeresspiegel-Temperatur auf 13 °C heben.** Das
verschiebt die Isotherme auf 0,65 und löst die Kappe (Tabelle unten), verschiebt
aber das GANZE Klima mit: Niederschlagsphase, Schneedecke, Waldgrenze und
Schmelzwasser. Der Schnee im Bild bricht ein (Anteil des Landes mit sichtbarer
Decke, Deckung > 0,05, dt 1000):

| Seed | Schnee sichtbar / Rampe, Meer 11 °C (`iceFirnTemp` −2) | Meer 13 °C (`iceFirnTemp` 0) | Meer 13 °C, eisfrei |
| ---: | :--- | :--- | :--- |
| 1337 | 8,49 / 5,38 % | 2,68 / 0,65 % | 2,73 / 1,35 % |
| 42 | 5,53 / 2,56 % | 0,86 / 0,03 % | 0,87 / 0,14 % |
| 20 | 6,62 / 3,70 % | 1,43 / 0,30 % | 1,38 / 0,55 % |

Seed 42 trägt damit praktisch keinen Schnee mehr, Seed 20 kaum, und die 11 °C
sind für Schnee, Wald und Phase kalibriert. Die Mechanik-Wächter hätten dafür an
22 Stellen die alten 11 °C pinnen müssen (zu breiter Regler). Die Reihe, mit der
ich die 13 °C gewählt hatte (jeder Lauf aus frisch generierter Welt, dt 100 und
1000):

| Meer °C | Seed | dt | Land über Firn | flach | Zackigkeit | Zack. / eisfrei | Eis, % des Landes |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 12 | 1337 | 100 | 2,86 % | 7,5 % | 0,00619 | – | 2,64 |
| 12 | 1337 | 1000 | 2,86 % | 8,6 % | 0,00505 | – | 2,66 |
| 12 | 42 | 100 | 0,88 % | 2,2 % | 0,00481 | – | 1,00 |
| 12 | 42 | 1000 | 0,88 % | 2,2 % | 0,00418 | – | 1,00 |
| 12 | 20 | 100 | 1,23 % | 2,6 % | 0,00634 | – | 1,24 |
| 12 | 20 | 1000 | 1,23 % | 4,3 % | 0,00480 | – | 1,25 |
| 12,5 | 1337 | 100 | 1,91 % | 3,4 % | 0,00652 | 92 % | 1,82 |
| 12,5 | 1337 | 1000 | 1,91 % | 4,2 % | 0,00518 | 87 % | 1,84 |
| 12,5 | 42 | 100 | 0,43 % | 1,4 % | 0,00498 | 97 % | 0,27 |
| 12,5 | 42 | 1000 | 0,43 % | 1,6 % | 0,00438 | 99 % | 0,28 |
| 12,5 | 20 | 100 | 0,78 % | 1,6 % | 0,00664 | 98 % | 0,96 |
| 12,5 | 20 | 1000 | 0,78 % | 3,3 % | 0,00508 | 94 % | 0,97 |
| 12,75 | 1337 | 100 | 1,55 % | 2,6 % | 0,00666 | 93 % | 1,61 |
| 12,75 | 1337 | 1000 | 1,55 % | 3,2 % | 0,00530 | 88 % | 1,63 |
| 12,75 | 42 | 100 | 0,28 % | 1,3 % | 0,00498 | 99 % | 0,18 |
| 12,75 | 42 | 1000 | 0,28 % | 1,5 % | 0,00449 | 102 % | 0,19 |
| 12,75 | 20 | 100 | 0,59 % | 1,3 % | 0,00641 | 95 % | 0,78 |
| 12,75 | 20 | 1000 | 0,59 % | 2,7 % | 0,00509 | 94 % | 0,77 |
| 13 | 1337 | 100 | 1,23 % | 2,3 % | 0,00683 | 96 % | 1,39 |
| 13 | 1337 | 1000 | 1,23 % | 2,7 % | 0,00539 | 91 % | 1,41 |
| 13 | 42 | 100 | 0,19 % | 1,3 % | 0,00504 | 101 % | 0,09 |
| 13 | 42 | 1000 | 0,19 % | 1,4 % | 0,00434 | 97 % | 0,09 |
| 13 | 20 | 100 | 0,45 % | 1,4 % | 0,00648 | 98 % | 0,56 |
| 13 | 20 | 1000 | 0,45 % | 1,8 % | 0,00519 | 97 % | 0,57 |
| 13,5 | 1337 | 100 | 0,76 % | 1,6 % | 0,00690 | – | 0,75 |
| 13,5 | 1337 | 1000 | 0,76 % | 1,9 % | 0,00558 | – | 0,76 |
| 13,5 | 42 | 100 | 0,07 % | 1,1 % | 0,00491 | – | 0,01 |
| 13,5 | 42 | 1000 | 0,07 % | 1,2 % | 0,00439 | – | 0,01 |
| 13,5 | 20 | 100 | 0,28 % | 1,2 % | 0,00662 | – | 0,24 |
| 13,5 | 20 | 1000 | 0,28 % | 2,6 % | 0,00519 | – | 0,24 |

**Entkopplung: `iceFirnTemp`.** Die Firn→Eis-Umwandlung beginnt jetzt unterhalb
einer eigenen Gleichgewichtslinien-Temperatur, `f_kalt = clamp((iceFirnTemp − T) /
iceFirnColdSpan, 0, 1)` (vorher `−T / …`, also implizit 0 °C). Physik: die
Gleichgewichtslinie (ELA) eines Gletschers liegt bei einer Jahresmitteltemperatur
einige Grad UNTER 0 °C, typisch −2 … −8 °C je nach Niederschlag (Ohmura et al.
1992), während Dauerschnee schon an der 0-°C-Isotherme liegen bleibt. Die
Firn-Grenze des Eises liegt bei `h = sea + (climateSeaLevelTemp − iceFirnTemp) /
climateLapseRate`; mit 11 °C und −2 °C ist das dieselbe Höhe 0,65 wie bei der
verworfenen 13-°C-Variante, aber nur für das Eis. Die Quelle (`updateIce`, die
Bounding-Box der Teilschritte und die Aktivitätsprüfung) liest dieselbe Größe.
`iceFirnTemp = 0` rechnet bit-identisch zum Stand davor (die `ifirn=0`-Zeilen
unten reproduzieren die Zahlen vor der Änderung Ziffer für Ziffer).

**Messreihe** (Produktion, 20.000 Jahre nach dem Einlauf, dt 100 und 1000, jeder
Lauf aus frisch generierter Welt; Werkzeug `testGlacierCrestShapeDiagnostic`,
2026-10-17, M4 Max, Zustand nach dem Rebase auf `0996441`; Zackigkeit = mittlere
|h − Mittel 9 × 9| der obersten 5 % des Landes, Quotient gegen den eisfreien Arm
(`iceEnabled = false`, gleicher Seed und Schrittweite); „Land über Eis-Firn" =
Anteil des Landes über `sea + (T₀ − iceFirnTemp)/Γ` direkt nach dem Einlauf, MIT
Eis; Schnee = `Terrain.snowCover`, Anteil des Landes mit Deckung > 0,05 bzw. in
der Rampe `snowBandCoverStart`):

| `iceFirnTemp` °C | Seed | dt | Land über Eis-Firn | flach | Zackigkeit | Zack. / eisfrei | Eis, % des Landes | Schnee sichtbar / Rampe |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| 0 | 1337 | 100 | 5,17 % | 9,8 % | 0,00533 | 78 % | 4,09 | 7,72 / 1,75 % |
| 0 | 1337 | 1000 | 5,17 % | 10,3 % | 0,00450 | 78 % | 4,07 | 8,35 / 1,66 % |
| 0 | 42 | 100 | 2,14 % | 4,6 % | 0,00492 | 98 % | 2,05 | 4,94 / 1,02 % |
| 0 | 42 | 1000 | 2,14 % | 6,2 % | 0,00395 | 89 % | 2,08 | 5,38 / 1,02 % |
| 0 | 20 | 100 | 3,01 % | 9,0 % | 0,00581 | 92 % | 2,63 | 5,79 / 1,35 % |
| 0 | 20 | 1000 | 3,01 % | 11,1 % | 0,00443 | 83 % | 2,64 | 6,42 / 1,39 % |
| −1 | 1337 | 100 | 2,84 % | 4,8 % | 0,00597 | 87 % | 3,96 | 7,96 / 4,86 % |
| −1 | 1337 | 1000 | 2,84 % | 4,9 % | 0,00533 | 92 % | 4,03 | 8,69 / 4,96 % |
| −1 | 42 | 100 | 0,86 % | 1,9 % | 0,00467 | 93 % | 1,65 | 5,12 / 2,45 % |
| −1 | 42 | 1000 | 0,86 % | 2,0 % | 0,00416 | 93 % | 1,66 | 5,47 / 2,51 % |
| −1 | 20 | 100 | 1,22 % | 1,7 % | 0,00597 | 94 % | 2,08 | 5,90 / 3,08 % |
| −1 | 20 | 1000 | 1,22 % | 3,3 % | 0,00490 | 92 % | 2,12 | 6,62 / 3,33 % |
| −1,5 | 1337 | 100 | 1,89 % | 2,5 % | 0,00610 | 89 % | 3,04 | 7,98 / 5,18 % |
| −1,5 | 1337 | 1000 | 1,89 % | 2,7 % | 0,00540 | 93 % | 3,10 | 8,63 / 5,36 % |
| −1,5 | 42 | 100 | 0,42 % | 1,4 % | 0,00473 | 94 % | 0,63 | 5,11 / 2,50 % |
| −1,5 | 42 | 1000 | 0,42 % | 1,5 % | 0,00424 | 95 % | 0,64 | 5,48 / 2,56 % |
| −1,5 | 20 | 100 | 0,77 % | 1,4 % | 0,00620 | 98 % | 1,70 | 6,01 / 3,37 % |
| −1,5 | 20 | 1000 | 0,77 % | 3,2 % | 0,00513 | 96 % | 1,73 | 6,68 / 3,65 % |
| −2 | 1337 | 100 | 1,22 % | 1,9 % | 0,00623 | 91 % | 2,44 | 7,95 / 5,26 % |
| −2 | 1337 | 1000 | 1,22 % | 1,9 % | 0,00546 | 94 % | 2,50 | 8,49 / 5,38 % |
| −2 | 42 | 100 | 0,18 % | 1,2 % | 0,00483 | 96 % | 0,21 | 5,05 / 2,49 % |
| −2 | 42 | 1000 | 0,18 % | 1,2 % | 0,00438 | 98 % | 0,22 | 5,53 / 2,56 % |
| −2 | 20 | 100 | 0,45 % | 1,3 % | 0,00608 | 96 % | 1,06 | 6,02 / 3,43 % |
| −2 | 20 | 1000 | 0,45 % | 2,7 % | 0,00511 | 96 % | 1,08 | 6,62 / 3,70 % |
| −2,5 | 1337 | 100 | 0,75 % | 1,4 % | 0,00625 | 91 % | 1,57 | 8,02 / 5,30 % |
| −2,5 | 1337 | 1000 | 0,75 % | 1,5 % | 0,00553 | 96 % | 1,62 | 8,70 / 5,59 % |
| −2,5 | 42 | 100 | 0,07 % | 1,0 % | 0,00492 | 98 % | 0,01 | 5,05 / 2,48 % |
| −2,5 | 42 | 1000 | 0,07 % | 1,1 % | 0,00443 | 99 % | 0,01 | 5,53 / 2,56 % |
| −2,5 | 20 | 100 | 0,27 % | 1,0 % | 0,00618 | 97 % | 0,49 | 5,99 / 3,41 % |
| −2,5 | 20 | 1000 | 0,27 % | 2,4 % | 0,00508 | 95 % | 0,54 | 6,71 / 3,69 % |
| −3 | 1337 | 100 | 0,45 % | 1,2 % | 0,00639 | 93 % | 1,03 | 7,99 / 5,32 % |
| −3 | 1337 | 1000 | 0,45 % | 1,3 % | 0,00546 | 94 % | 1,06 | 8,73 / 5,55 % |
| −3 | 42 | 100 | 0,00 % | 1,0 % | 0,00496 | 99 % | 0,00 | 5,08 / 2,50 % |
| −3 | 42 | 1000 | 0,00 % | 1,0 % | 0,00444 | 100 % | 0,00 | 5,49 / 2,56 % |
| −3 | 20 | 100 | 0,12 % | 0,8 % | 0,00631 | 100 % | 0,17 | 6,01 / 3,41 % |
| −3 | 20 | 1000 | 0,12 % | 2,1 % | 0,00517 | 97 % | 0,19 | 6,78 / 3,70 % |

Eisfreie Arme (Quotienten-Nenner, 11 °C; „flach" des eisfreien Reliefs 0,6 …
2,1 %):

| Seed | Zackigkeit dt 100 / 1000 | dt-Drift | flach dt 100 / 1000 | Land über 0,65 | Schnee sichtbar / Rampe (dt 1000) |
| ---: | :--- | ---: | :--- | ---: | :--- |
| 1337 | 0,00684 / 0,00578 | 15 % | 0,8 / 0,8 % | 1,41 % | 8,67 / 5,54 % |
| 42 | 0,00502 / 0,00446 | 11 % | 0,9 / 1,0 % | 0,21 % | 5,50 / 2,56 % |
| 20 | 0,00634 / 0,00532 | 16 % | 0,7 / 2,1 % | 0,60 % | 6,73 / 3,69 % |

Die Zackigkeit fällt auch OHNE Eis zwischen dt 100 und 1000 um 15 / 11 / 16 %:
Operator-Splitting der übrigen Sim (§5 in `docs/dt-invariance-measurements.md`),
nicht der Gletscher.

**Lesart.**

* Bei `iceFirnTemp = 0` (dem Stand davor) ist die Kappe in den Zahlen: flach
  10,3 / 6,2 / 11,1 % bei dt 1000, Zackigkeit nur 78 / 89 / 83 % des eisfreien
  Arms, Eis auf 4,1 / 2,1 / 2,6 % des Landes. Dass die Schnee-Rampe dort nur 1,7 /
  1,0 / 1,4 % des Landes deckt (eisfrei: 5,5 / 2,6 / 3,7 %), ist derselbe Befund
  von der anderen Seite: die Kappe schleift die Gipfel unter die Isotherme.
* −1 °C genügt nicht: Seed 1337 trägt 4,0 % Eis (Spanne 0,5 … 3 %), flach 4,8 /
  4,9 % und Zackigkeit nur 87 / 92 % des eisfreien Arms (dt 100 / 1000).
* **−2 °C** erfüllt alle Zahlen (nächster Abschnitt) und liegt bei Seed 1337 mit
  1,22 % des Landes über der Eis-Firn-Grenze im Zielbereich 1,2 … 1,5 % (so viel
  wie die verworfene 13-°C-Variante, 1,23 %).
* −1,5 °C: Eis 3,1 % auf Seed 1337 (über 3 %) und Quotient 89 / 93 % (dt 100 /
  1000).
  −2,5 / −3 °C: Seed 1337 bei 1,6 / 1,1 % Eis, Seed 20 bei 0,5 / 0,2 %, Seed 42 hat
  dann kein Eis mehr.
* Die Schneeflächen bleiben bei jedem `iceFirnTemp` ≤ −1,5 auf dem Wert der
  eisfreien Welt (Seed 1337 bei −2: 8,5 / 5,4 % gegen 8,7 / 5,5 %). Der Versatz greift
  also nur das Eis an.

**Gewählt: `iceFirnTemp = −2 °C`** (Logbuch bei `SimConfig.iceFirnTemp`). Zufuhr
und Schliff des Eises bleiben bei den Werten von #35 (`iceFirnPerSnowYear`
1e-3, `iceErodeK` 1e-4), die Nachjustierung war nicht nötig.

**Endstand** (Produktion, 20.000 Jahre, dt 100 / 1000):

| Seed | flach | Zackigkeit | eisfreie Baseline | Quotient | Eis | Land über Eis-Firn |
| ---: | :--- | :--- | :--- | :--- | :--- | ---: |
| 1337 | 1,9 / 1,9 % | 0,00623 / 0,00546 | 0,00684 / 0,00578 | 91 / 94 % | 2,44 / 2,50 % | 1,22 % |
| 42 | 1,2 / 1,2 % | 0,00483 / 0,00438 | 0,00502 / 0,00446 | 96 / 98 % | 0,21 / 0,22 % | 0,18 % |
| 20 | 1,3 / 2,7 % | 0,00608 / 0,00511 | 0,00634 / 0,00532 | 96 / 96 % | 1,06 / 1,08 % | 0,45 % |

dt-Drift der Zackigkeit zwischen dt 100 und 1000: mit Eis 12 / 9 / 16 %,
eisfrei 15 / 11 / 16 %: der Eis-Arm driftet nicht stärker als die Welt ohne
Eis. Seed 42 hat bauartbedingt (höchster Punkt 0,67 ohne Eis) kaum Land über der
Grenze (0,18 %) und damit fast kein Eis (0,21 %); Kar- und Talgletscher gibt es
auf den Seeds 1337 und 20. Wächter:
`GlacierCrestShape.testProductionCrestCarriesGlaciersNotACap`.

**Eismasse an der Schrittweite** (`testIceDtSweepDiagnostic`, Produktion, Jahr
20.000, Endstand; die Tabelle weiter oben ist der Stand bei `iceFirnTemp = 0`):

| Seed | dt 15 | dt 100 | dt 1000 | Spanne | Eiszellen 15 / 100 / 1000 |
| ---: | ---: | ---: | ---: | ---: | :--- |
| 1337 | 169,73 | 170,02 | 175,35 | 3,3 % | 6298 / 6342 / 6473 |
| 42 | 1,93 | 1,89 | 1,94 | 2,6 % (Masse < 2) | 304 / 304 / 319 |
| 20 | 32,11 | 32,66 | 34,06 | 6,1 % | 1728 / 1764 / 1798 |

`testIceIsFramerateIndependent` (Schrittpaare, n = 256, alte Welt mit
`iceFirnTemp = 0` gepinnt) und alle `DtInvariance`-Wächter sind grün
(Pflichtsuite 582 Tests, 0 Fehler).

**V→U.** Der Pflichtwächter `testGlaciatedValleysWidenTowardsU` ist ein
Mechanik-Wächter der gepinnten alten Welt (n = 384, `calibrationRangeLandform`,
`calibrationIceFirnTemp = 0`; mit der Produktions-Grenze 0,65 trüge sie kein
Eis). Er misst unverändert Δb **+0,287** (30k, n = 56) und **+0,162** (50k,
n = 54), Schranke +0,1.

In der PRODUKTION gezeigt (`testGlacierProductionValleyDiagnostic`, Eis-Arm gegen
eisfreien Arm, gepaart auf den am Ende vergletscherten Zellen, dt 100;
Produktionszellen sind 0,156 statt 0,34 Welteinheiten breit, deshalb
Halbbreiten W = 6 / 10 / 14 Zellen; `b` Eis / ohne Eis, Δ, n):

| Seed | Jahr | W 6 | W 10 | W 14 |
| ---: | ---: | :--- | :--- | :--- |
| 1337 | 10k | 1,702 / 1,579, +0,123 (2166) | 1,649 / 1,429, +0,220 (1611) | 1,430 / 1,215, +0,214 (1308) |
| 1337 | 20k | 1,762 / 1,641, +0,121 (1367) | 1,663 / 1,415, +0,248 (1024) | 1,451 / 1,225, +0,226 (781) |
| 1337 | 30k | 1,732 / 1,706, +0,025 (864) | 1,607 / 1,406, +0,201 (654) | 1,445 / 1,290, +0,155 (411) |
| 1337 | 50k | 1,656 / 1,541, +0,115 (219) | 1,185 / 1,004, +0,180 (150) | 1,081 / 0,725, +0,356 (57) |
| 20 | 10k | 1,675 / 1,491, +0,184 (679) | 1,587 / 1,274, +0,312 (402) | 1,458 / 1,088, +0,370 (250) |
| 20 | 20k | 1,710 / 1,540, +0,170 (352) | 1,547 / 1,254, +0,293 (207) | 1,294 / 1,006, +0,289 (116) |
| 20 | 30k | 1,792 / 1,471, +0,321 (207) | 1,608 / 1,338, +0,270 (134) | 1,201 / 0,887, +0,314 (73) |
| 20 | 50k | 1,836 / 1,785, +0,051 (175) | 1,671 / 1,530, +0,141 (120) | 2,036 / 1,004, +1,032 (45) |

**Lesart:** mit der Firn-Grenze bei 0,65 gehen die vergletscherten Täler in der
Produktion auf beiden Seeds, bei allen drei Halbbreiten und über den ganzen Lauf
Richtung U (alle 24 Δ positiv, +0,03 … +1,03). Das ist stabiler als bei der
verworfenen 13-°C-Variante (Seed 20 wechselte dort das Vorzeichen) und kleiner
als bei der Kappe, die weit mehr Eis über das Bett schleift (Δ +0,4 … +1,0 bei
10k … 20k auf Seed 1337), dort aber bei W 6 ab 30k ins Rauschen fiel.

**Bild** (maximiert, `RS_STEP=20000`, Diorama und Tal, Seeds 1337 / 42 / 20;
`docs/screenshots/zielbild-174/glacier_seed*_vorher-nachher.jpg`, links der
Integrationsstand `6a0dfde` (danach nur bit-identische Perf-Commits), rechts diese
Nachkalibrierung; dazu `glacier_seed1337_kamm_kappe-gegen-versatz.jpg` mit dem
Zwischenstand „dt-Fix, Firn bei 0 °C"). Ehrliche Bewertung:

* **Schnee wie vorher, Kappe weg.** Alle drei Seeds tragen Schneegrate und
  Schneefelder auf den Gipfeln (Seed 42 und 20 wieder mit weißen Spitzen, die bei
  13 °C fehlten); der Zwischenstand bei `iceFirnTemp = 0` zeigt dagegen auf Seed
  1337 eine geschlossene weiße Decke über dem ganzen Kamm.
* **Schnee und Eis sind im Render beide weiß.** Kar- und Talgletscher (Eis 2,5 /
  0,2 / 1,1 % des Landes) erkenne ich im Bild nicht getrennt von den
  Schneefeldern; die Kennzahlen („flach", Zackigkeit, Eisfläche) tragen den
  Befund, das Bild bestätigt nur „keine Kappe, Gipfel und Hörner".
* Auf Seed 1337 liegt im Diorama ein fast durchgehendes weißes Band auf dem Kamm,
  gleichmäßiger als in der Vorlage; auf Seed 42 trägt der Hauptkamm eine breite
  Schnee-Schulter mit Wand darunter. Ob diese Schulter von der Großform oder
  vom Eis kommt, habe ich nicht getrennt (Kennzahl „flach" der Seeds: 1,9 / 1,2 /
  1,3 … 2,7 %).
* Der Gletschersee im Trog des Integrationsstands (Seeds 1337 und 42) ist weg.
* Senkrechte, gestreifte Felswände gibt es in allen Ständen, auch ohne Eis; sie
  kommen aus der Relief-/Felsdarstellung steiler Zellen, nicht vom Gletscher.

**Kosten** (`simperf --repeat 1`, Produktion, Seed 1337 falls nicht anders
genannt, dt 100 nach 10.000 Jahren Einlauf, interleaved, Reihenfolge je Runde
getauscht, M4 Max, Load 7 … 13; ms je Schritt, Rohwerte sortiert):

| Vergleich | Läufe | Median Schritt | Median `updateIce` |
| --- | --- | --- | --- |
| nur die räumliche Begrenzung (Commit `perf(glacier)`, `iceFirnTemp` 0), 6 Runden | ohne: 64,3 64,7 65,4 65,6 65,6 71,7; mit: 62,4 62,7 62,9 62,9 63,3 64,3 | 65,5 → 62,9 ms | 10,96 → 8,99 ms |
| Endstand gegen Integration `0996441`, dt 100, 8 Runden | INT: 58,1 59,2 59,4 59,5 59,9 61,0 61,6 67,0; neu: 57,3 58,1 58,3 58,4 58,6 58,7 59,4 59,5 | 59,70 → 58,50 ms (−1,2) | 6,12 → 5,08 ms |
| Seed 42, dt 100, 6 Runden | INT: 42,0 42,3 42,6 42,7 42,8 43,4; neu: 41,1 41,2 41,8 42,2 42,5 48,9 | 42,65 → 42,00 ms (−0,65) | 2,38 → 1,30 ms |
| Zeitraffer dt 15 (`--dt 15 --steps 200`), 10 Runden | INT: 43,5 43,6 43,9 44,0 44,0 44,1 44,1 44,1 44,3 44,9; neu: 44,1 44,1 44,1 44,2 44,5 44,5 44,5 44,6 44,7 45,2 | 44,05 → 44,50 ms (+0,45) | 1,08 → 1,50 ms (+0,42) |

Im Zeitraffer (dt 15) ist der Endstand um 0,45 ms je Schritt langsamer, knapp
unter der Grenze von +0,5 ms: der Teilschritt läuft dort auf mehr Eis als im
Integrationsstand (Seed 1337 6473 Eiszellen bei dt 1000 gegen 4502 im Stand mit
dem instabilen Transport), und die einmalige Gitter-Suche (`iceTransportDomain`)
fällt bei nur einem Teilschritt stärker ins Gewicht. Die Begrenzung der
Teilschritte ist **bit-identisch**: `simperf --hash` vor und nach identisch auf den
Seeds 1337 (`1c3d7fd9de7716fa`) und 42 (`d19cd43ab2e35ce0`) sowie mit großem
Einlauf-Schritt (`--warmup 25 --warmup-dt 800`: 1337 `39e4122285a884f9`, 20
`69ca1799f79b8cd3`; Stand des Perf-Commits). Der Endstand hasht reproduzierbar
(zwei Läufe je Seed: 1337 `6ffeb97d52f8e8d9`, 42 `9f0fb0e9ad4d8493`); die Werte
sind per-Maschine und mit anderen Ständen nicht vergleichbar.

**Grenzen.**

* Das Eis ist auf Seed 42 praktisch aus (0,21 % des Landes) und auf Seed 20
  schlank (1,1 %): ein Regler kann nicht jedem Seed Gipfel über der Firn-Grenze
  geben.
* Der Zackigkeits-Quotient liegt auf Seed 1337 bei dt 100 mit 91 % knapp über der
  Schwelle von 90 %.
* `WorldSnapshot.version` steigt auf 8 (neuer Config-Schlüssel): Spielstände aus
  Version 7 werden abgelehnt; gespeicherte Welten behalten sonst ihr eigenes
  `iceFirnTemp`.
* Die Mechanik-Wächter der alten Großform pinnen `iceFirnTemp = 0`
  (`calibrationIceFirnTemp`): Glacier, `renderConfig`, Lithology,
  `testBraidingBuildsBars`, `testAgingTrajectoryOver100k`; dazu die Schranke in
  `testSnowZoneFollowsTheClimateNotAFixedLandFraction` von 0,85 auf 0,90 (gemessen
  0,864: die Schnee-Fläche schrumpft mit weniger Eis etwas weniger). Alle übrigen
  Wächter laufen unverändert.
* Die Reihen in §A/§B/§D stammen von `iceFirnTemp = 0` und gelten dafür.

## §M — Lawinen-Abgang des Firns: Gipfel über der Grenze bleiben stehen (Issue #174)

Alle Zahlen auf der Basis `d32e915` (Integrationszweig mit Gürtel-Kopplung im
1000-Jahr-Takt); „vorher“ = `iceAvalancheSlopeHi = 0`, `iceErodeSwathRadius = 2`,
`iceErodeK = 1e-4` (der Stand davor bis auf die Rundung der Schleifspur-Summe),
„nachher“ = die Standardwerte dieses Zweigs. Produktion, Einlauf + 20.000 Jahre,
M4 Max.

### Befund

Auch nach der Firn-Grenze bei 0,65 (§L) stehen auf dem Kamm Tafeln: Seed 1337
trägt mit Eis höchstens 0,670, ohne Eis 0,752, dazwischen eine harte Decke bei
0,65–0,66 (Zellen je 0,01-Höhenklasse `… 0.65: 900 · 0.66: 162 · 0.67: 2` gegen
`0.66: 739 · 0.70: 284 · 0.75: 6`); Seed 20: 0,660 gegen 0,727 (Bett bei z = 370
über ~48 Zellen konstant auf 0,631–0,633). Ursache: oberhalb der Eis-Firn-Grenze
bekommt JEDE Zelle Firn, auch eine 60°-Gipfelflanke, und das Eis schleift
(`E = K·(I·S)^m·S`) die Gipfel bis knapp unter die Grenze. In der Natur halten
Flanken über ~35–45° keinen Firn (Lawinen): Hörner und Grate bleiben eisfrei, und
die Lawinen NÄHREN die Kare darunter.

### Mechanik

`SimConfig.iceAvalancheSlopeLo/Hi` (1,2 / 1,9, Weltsteigung ≈ 50° / 62° in der
Darstellung, `Terrain.macroSlope` des Betts, Maßstab wie die Kennzahl „flach“):
der Anteil `φ = smoothstep` der Firn-Zufuhr `a` geht nicht in die Zelle, sondern
massen-erhaltend in die erste nicht-steile Zelle am Hangfuß (steilster Abstieg
über `h`, 8 Nachbarn, höchstens 40 Zellen, nicht ins Meer; Wächter
`testAvalancheMovesFirnSupplyWithoutLosingIt`). Die Steigung ist das Maximum der
Makrosteigung im 3 × 3 (`iceAvalancheReach = 1`): `macroSlope` ist eine
Zentraldifferenz über ±2 Zellen und verschwindet auf einer symmetrischen Spitze,
die Spitze trüge sonst Firn (Variante „nur eigene Zelle“ unten).

Die Karte (Quelle → Ziel, `φ`) entsteht EINMAL je Schritt (Operator-Splitting wie
`snow`/`flowWeight`): zeilenparallel in Scratch-Puffern, seriell zu einer
geordneten Liste kompaktiert (feste Summationsreihenfolge); je Teilschritt rechnet
`applyAvalancheFeed` mit der Bett-Temperatur `a` und trägt Quelle −, Ziel + in
`iceAvFeed` ein, Pass 2 liest nur den eigenen Index. Ein Eis-Fenster je Zeile
(Spaltenbereiche, die je Teilschritt um eine Zelle wachsen, statt das Rechteck
± nSub) und ein Schnell-Ausstieg vor den verzweigten Zufluss-Summen sind
bit-identisch zum Rechteck (`simperf --hash` vor und nach, auch mit
`--warmup 25 --warmup-dt 800`). `iceAvalancheSlopeHi = 0` = aus. `WorldSnapshot.version`
11.

### Verworfene und gewählte Varianten (Seed 20, dt 1000; Maximum der Höhe)

| Variante | Maximum | Zellen über Firn | Eis, % des Landes | Befund |
| --- | --- | --- | --- | --- |
| ohne Abgang | 0,660 | 245 | 1,06 | Tafel, 382 Zellen auf 0,625…0,640 |
| nur eigene Zelle, 0,7/1,2 … 1,4/2,2 | 0,665 … 0,679 | 302 … 403 | 1,29 … 1,51 | Gipfel bleiben gekappt |
| Reichweite 1, 1,0/1,6 | 0,727 | 496 | 1,31 | Gipfel stehen (eisfrei 0,727) |
| Reichweite 2, 1,0/1,6 | 0,727 | 506 | 1,14 | wie Reichweite 1, weniger Eis |
| eisfreier Arm | 0,727 | 600 | – | Vergleich |

Schwellen (Reichweite 1, Seed 1337 / 20, dt 1000, Eis in %; zu Beginn der
Messreihe auf der alten Basis): 1,0/1,6 → 2,73 / 1,39; **1,2/1,9** → 2,92 / 1,66
(Maximum 0,7503 / 0,7274, eisfrei 0,7521 / 0,7274); 1,4/2,2 → 2,89 / 1,74
(Maximum 0,7437). 1,4/2,2 kappt die Gipfel wieder leicht und kommt an die 3-%-Grenze.

Karten-Takt (Seed 1337, Eismasse nach 20.000 Jahren, dt 15 / 100 / 1000): eine
Karte je Schritt 229 / 201 / 199, alle 15 Sim-Jahre 251 / 246 / 261, je
Teilschritt 246 / 236 / 247 — der Takt ändert die Spanne der Langläufe nicht, die
Karte selbst ist dt-neutral (Eis allein auf festem Bett, 5000 Jahre: dt 15,6 / 100 /
1000 gleich auf 0,01 %). Gewählt: einmal je Schritt, die billigste Fassung.

**Dicken-Begrenzer verworfen.** Die Sub-Taktung hängt an der dicksten Säule und
der steilsten Oberfläche des ganzen Fensters (ON: Dicke bis 0,41, Abfall-Summe bis
1,08 gegen 0,28 / 0,12 vorher, 13–17 statt 8–11 Teilschritte). Eine feste
Schranke `I0` für die Teilschritt-Zahl (0,25) mit Flussbegrenzer bei 2·I0 senkte
die Teilschritte auf 8, aber die Eismasse auf Seed 1337 von 264 auf 212 (der
Transport dicker Stämme wird ungenauer, §E-Doktrin „1/4 gegen 1/8: −6 … −12 %“) und
das V→U-Signal auf W 14 von +0,06 auf −0,05. Qualität vor Kosten: verworfen.

### Endstand: vorher / nachher

flach = oberste 5 % des Landes, Weltsteigung < 0,15; Wände = Anteil der Zellen
über 0,55 mit Bett-Weltsteigung > 1,8 / > 2,5; Schnee = Landanteil mit Deckung
> 0,05 / in der Rampe; eisfrei = `iceEnabled = false` auf derselben Basis.

| Seed | dt | Stand | flach % | Zackigkeit (eisfrei) | Eis % | höchster Punkt (eisfrei) | Land über Firn % (eisfrei) | Wände >1,8 / >2,5 | Schnee |
| ---: | ---: | --- | ---: | --- | ---: | --- | --- | --- | --- |
| 1337 | 100 | vorher | 1,7 | 0,00604 (0,00685) | 2,33 | 0,6715 (0,7515) | 0,42 (1,22) | 29,0 / 13,5 | 7,69 / 5,08 |
| 1337 | 100 | nachher | 1,0 | 0,00735 | 2,80 | 0,7504 | 0,69 | 37,3 / 19,1 | 7,53 / 4,78 |
| 1337 | 1000 | vorher | 1,9 | 0,00534 (0,00577) | 2,41 | 0,6701 (0,7524) | 0,40 (1,29) | 24,9 / 10,0 | 8,34 / 5,26 |
| 1337 | 1000 | nachher | 1,2 | 0,00675 | 2,87 | 0,7508 | 0,65 | 34,0 / 15,9 | 8,22 / 5,02 |
| 42 | 1000 | vorher | 1,2 | 0,00432 (0,00440) | 0,21 | 0,6507 (0,6745) | 0,00 (0,13) | 20,3 / 2,7 | 5,37 / 2,50 |
| 42 | 1000 | nachher | 1,2 | 0,00425 | 0,42 | 0,6595 | 0,03 | 20,8 / 2,6 | 5,37 / 2,49 |
| 20 | 100 | vorher | 1,3 | 0,00604 (0,00650) | 1,02 | 0,6611 (0,7276) | 0,15 (0,52) | 25,6 / 8,6 | 5,80 / 3,30 |
| 20 | 100 | nachher | 0,9 | 0,00657 | 1,62 | 0,7277 | 0,37 | 32,6 / 14,8 | 5,89 / 3,19 |
| 20 | 1000 | vorher | 2,8 | 0,00507 (0,00532) | 1,06 | 0,6598 (0,7274) | 0,14 (0,53) | 21,6 / 4,7 | 6,58 / 3,63 |
| 20 | 1000 | nachher | 2,8 | 0,00580 | 1,69 | 0,7272 | 0,36 | 29,3 / 13,1 | 6,38 / 3,43 |

Die Höhenverteilung hat keine harte Decke mehr (Gipfel gleich dem eisfreien Arm:
1337 0,7508 gegen 0,7524, 20 0,7272 gegen 0,7274); Schnee und Schneerampe bleiben
unverändert (−0,2 Punkte), das Eis bleibt in 0,5…3 % (1337: 2,87 %). Die
Zackigkeit liegt über dem eisfreien Arm (Quotient 117 % bei 1337, 109 % bei 20,
dt 1000): Hörner stehen, daneben graben die lawinengenährten Kare tiefer. Seed 42
hat bauartbedingt (höchster Punkt 0,67 eisfrei) kaum Eis.

**Wände.** Der Anteil sehr steiler Bett-Zellen (> 2,5) liegt über dem „vorher“
(1337: 10,0 → 15,9 %, 20: 4,7 → 13,1 %) und, auf 1337, über dem eisfreien Relief
(12,2 %): es sind Kar-Rückwände am Eisrand (58–72 % der Zellen über 2,5 liegen im
Umkreis von drei Zellen um Eis, vorher 28 % / 22 %), keine Tafelränder. Profil quer
über den Kamm von 1337 (`testCrestProfileDiagnostic`, Bett-Höhe je dritte Zelle
quer, Mitte des längsten flachen Laufs): ohne Abgang gerundete Kuppe auf 0,655 mit
Eis (Steigung oben 0,3); mit Abgang eine Spitze auf 0,687 (eisfrei 0,700) ohne Eis
auf dem Gipfel, Eis im Kar am Fuß, davor eine Wand von 0,666 auf 0,613 in drei Zellen
(Steigung bis 4,5, eisfrei höchstens 2,3).

### Seed 1337, Diorama: die lange Wand im Nordwesten ist die Generierung

Im Diorama steht im Nordwesten ein langes Band mit flach gezackter Oberkante und
einer Wand darunter. Der eisfreie Arm auf derselben Basis
(`RS_NO_ICE=1`, lokal in `SimNode` gesetzt und wieder entfernt) zeigt dasselbe Band
am selben Ort mit derselben Form
(`docs/screenshots/zielbild-174/glacier-horns_seed1337_diorama_{nachher,eisfrei}.jpg`):
es kommt aus der Großform der Generierung (gerade Kammachse), nicht vom Eis — der
Abgang lässt es unverändert, es ist nichts zu beheben.

### Schrittweite (dt-Spanne)

Schrittpaare (`testIceStepPairDiagnostic`, Produktion, 1000 Jahre ab Jahr 5000 /
15.000 als 1 × 1000, 10 × 100, 64 × 15,625; Spanne Masse / Fläche): vorher
0,2 … 1,2 % / 0,02 … 0,6 %, nachher 0,1 … 2,5 % / 0,3 … 3,0 %. Wächter
`Glacier.testIceIsFramerateIndependentInProduction` (Schranken 3 % / 7 %).

20.000-Jahre-Läufe (`testIceDtSweepDiagnostic`, Eismasse dt 15 / 100 / 1000, Spanne):

| Seed | vorher | nachher |
| ---: | --- | --- |
| 1337 | 172,86 / 167,69 / 173,17, 3,2 % | 282,96 / 269,84 / 265,76, 6,1 % |
| 42 | 1,78 / 1,77 / 1,90, 6,8 % (Masse < 2) | 5,10 / 4,99 / 5,25, 5,0 % |
| 20 | 32,88 / 32,78 / 34,02, 3,6 % | 85,35 / 81,97 / 86,28, 5,0 % |
| 33 | 32,23 / 32,00 / 32,33, 1,0 % | 98,89 / 99,38 / 109,97, 10,0 % |

**Ursache der verbleibenden Streuung (Seed 33 mit 10 %; Seed 20 lag in einem
Zwischenstand bei 13,6 %, jetzt 5,0 %).** Nicht die Karte und nicht das Eis: (1) Der Eis-Transport allein auf
festem Bett ist dt-neutral (0,01 %, s. o.), und die Karten-Takt-Varianten ändern
nichts. (2) Friert man das Bett der beiden 20.000-Jahre-Arme ein und lässt das Eis
ins Gleichgewicht laufen, unterscheiden sich die Gleichgewichtsmassen (dt 100 gegen
1000) um +14,5 % (Seed 20) bzw. +6,8 % (33): der Unterschied steckt im GELÄNDE. (3)
Genauer: die Firn-Zufuhr je Quellzelle ist bei gleicher Höhe und gleichem `fCold` im
dt-1000-Arm um 8 … 10 % größer (mittlerer Schnee an den Quellzellen Seed 20: 0,356 →
0,390, 1337: 0,275 → 0,305; Σa +7,5 … 11,8 %), und `snow` folgt dem orographischen
Niederschlag `rain` (0,3555 → 0,3901): das ist das benannte Operator-Splitting-Drift
des Tropfen-Pfads (`docs/dt-invariance-measurements.md` §5; eisfreie Zackigkeit
dt 100 → 1000: −15 %), das glattere Gelände davor lässt mehr Niederschlag an den
Kamm. (4) Ohne Abgang puffert der Abtrag die Zufuhr (mehr Eis → Gipfel tiefer →
weniger Zufuhr); mit Abgang stehen die Gipfel, die Eismasse folgt der Zufuhr linear.
Das Eis erbt also die dt-Drift des Niederschlags. Sie lässt sich im Eis nicht
beheben; sie ist ein Ticket für den Tropfen-Pfad.

### V→U in der Produktion

`testGlacierProductionValleyDiagnostic` (Eis-Arm gegen eisfreien Arm, gepaart auf
den am Ende vergletscherten Zellen, dt 100, Δb gepoolt über Seeds 1337 / 20 / 33,
n-gewichtet; „unter Firn“ = Zellen unter der Firn-Grenze = Zungen und Talgletscher;
„Eis > 0,05“ = dicke Zellen):

| Jahr | Stand | W 6 | W 10 | W 14 | unter Firn (W 10) | Eis > 0,05 (W 10) |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 10k | vorher | +0,148 | +0,284 | +0,303 | +0,273 | +0,304 |
| 10k | nachher | +0,030 | +0,084 | +0,138 | +0,082 | −0,041 |
| 20k | vorher | +0,091 | +0,231 | +0,259 | +0,231 | +0,273 (n 112) |
| 20k | nachher | +0,053 | +0,140 | +0,116 | +0,133 | +0,140 |
| 30k | vorher | +0,063 | +0,205 | +0,299 | +0,180 | – |
| 30k | nachher | +0,059 | +0,111 | +0,146 | +0,100 | +0,354 |

Mit dem Abgang und der alten Schleifspur war das Signal weg (Zellen unter der
Firn-Grenze Δb −0,12 … 0,00 statt +0,2, Seed 1337 / 20, 10k … 30k). **Das war KEIN
Kar-Rückwand-Effekt und KEIN fehlender Eisfluss:** die Aufteilung nach Klassen
zeigt das Minus bei den DICKEN Eiszellen unter der Firn-Grenze (Δb −0,30 bis −0,36
bei Eis > 0,05, n 500 … 1600), die Kar-Zellen über der Grenze waren positiv. Das
Eis im Tal ist mit dem Abgang mehrfach dicker, die Rate `(I·S)^m·S` im Thalweg
entsprechend größer, und die Schleifspur (`iceErodeSwathRadius`) verteilt sie nicht
über die Talbreite: sie war mit 2 Zellen auf n = 384 / world 130 (Zelle 0,339)
geeicht, also 0,68 Welteinheiten Breite; die Produktion rechnet mit Zellen von
0,156, dort sind 2 Zellen nur 0,31 — die halbe Breite. Mit **4 Zellen** (9 × 9,
Verhältnis 2,17 · 2 = 4,3) werden die Talgletscher U-förmiger als der eisfreie
Arm: gepoolt W 6 / 10 / 14 bei 20k +0,053 / +0,140 / +0,116; 23 von 27 Einzelwerten
positiv; die vier negativen (−0,010 … −0,028) liegen auf W 6 (Seed 1337 20k / 30k,
Seed 20 10k) und W 14 (Seed 20 10k), dazu die dicken Zellen bei 10k gepoolt (−0,04). Schleifspur 3: positiv, aber W 14 −0,04 … −0,08; 5: alle positiv, aber
Eis 3,01 % auf 1337. `iceErodeK` 1,05e-4 statt 1e-4 hält Seed 1337 unter 3 %
(1e-4: 2,99 %; 1,25e-4 / 1,5e-4 verlieren das Signal auf W 14). Das Signal ist
nach wie vor kleiner als vorher (+0,05 … +0,14 gegen +0,06 … +0,30): die
Gletscher schleifen jetzt mehr in Karen und weniger breit. Wächter (neu):
`Glacier.testProductionGlaciersCarveTroughs` (Produktion, 3 Seeds, 20k, dt 1000,
gepoolt W 6 / 10 / 14 und Zungen > 0).

### Der Mündungstest

`WaterRendererTests.testRiverBandsReachTheSeaAtFullWidthAndOpacity` läuft auf der
ausgelieferten Konfiguration (kein Pin). Die Zählung „keine Spitze an irgendeiner
Mündung“ war an einer einzelnen Realisierung fragil (eine Mündung mit Halbbreite 0,57
von 3,20 an einer echten Biegung riss sie); jetzt über drei Seeds gepoolt, Spitzen
≤ 10 %, nicht-volle Mündungen ≤ 25 % (gemessen Mündungen / nicht voll / spitz,
ohne Abgang 27 / 1 / 0, mit ihm 31 / 3 / 0; mit anderen Schwellen 36 / 6 / 1 und
31 / 5 / 0; vor dem Fix lag jede dritte bis zweite Mündung darunter).
`ZielbildLandformTests`: Schranke der Aue-Zerklüftung 0,00156 → 0,00165 (mittleres
|Laplace| des Tieflands streut zwischen gleichwertigen Realisierungen um 3 … 6 %,
der Endstand liegt bei 0,001466 / 0,001562 / 0,001577).

### Kosten (`simperf --repeat 3`, Produktion, Seed 1337, 10.000 Jahre Einlauf)

Drei Arme interleaved (Basis `d32e915` als eigenes Binär, neu, neu mit
`--no-avalanche`), Reihenfolge je Runde rotiert, 8 Runden, gepaarte Differenzen,
M4 Max (Load 4 … 5, andere Builds auf dem Rechner); ms je Schritt:

| Messung | Basis | neu aus | neu an | an − Basis (Median, Spanne) |
| --- | --- | --- | --- | --- |
| dt 100, Schritt gesamt | 55,4 | 53,8 | 57,3 | **+2,4** (+0,9 … +3,3) |
| dt 100, `updateIce` | 3,3 | 2,4 | 5,0 | +1,83 (+1,56 … +2,27) |
| dt 15, Schritt gesamt | 39,4 | 39,4 | 40,6 | **+1,2** (+0,7 … +1,3) |
| dt 15, `updateIce` | 1,29 | 1,05 | 1,41 | +0,11 |

Pass-Tabelle dt 100 (einmal, Basis → neu an): `updateIce` 3,20 → 4,98, die übrigen
Pässe innerhalb ±0,5 ms (priorityFlood 13,19 → 13,52, belt.parallel 12,49 → 13,00).
Der Arm „aus“ ist 0,8 ms (`updateIce`) bzw. 1,9 ms (gesamt, gepaart) SCHNELLER als die
Basis: das Eis-Fenster je Zeile und der Schnell-Ausstieg sind bit-identisch
(Hash unverändert) und sparen mehr, als der Abgang kostet. Der Rest der Differenz im
Gesamtschritt gegen die Basis ist Welt-Streuung (die Pässe außerhalb des Eises
rechnen auf einer anderen Realisierung).

Zerlegung der +1,83 ms (dt 100): eine Lawinen-Karte ≈ 0,25 ms (0,13 Scan, 0,10
Kompaktieren), `applyAvalancheFeed` 0,11 ms je Schritt, den Rest macht die Welt: mehr
und dickeres Eis (Seed 1337 rund 15 Teilschritte je 100-Jahr-Schritt statt 8 … 11,
Eis-Fläche +20 %, Abfall-Summe bis 1,08), die Teilschritt-Zahl hängt an einer
Handvoll Säulen, s. o. (Begrenzer verworfen). Weitere Ersparnisse, die in diesen
Zahlen schon stecken: Wurzel statt `pow` für den Flussexponenten 0,5 (`pow` war der
größte Einzelposten), ein `exp` je Teilschritt für das Nährgebiet, zwei
Kastensummen statt 81 Lesezugriffen je Zelle für die Schleifspur.
