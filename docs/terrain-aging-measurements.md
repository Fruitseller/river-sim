# Alterungsverlauf: Messreihen zur abklingenden Hebung (Issue #13)

Headless gemessen mit einem temporären XCTest (`AgingSweep`, nach der Messung
wieder entfernt), Release-Build, Seed 1337, `n = 160` (sofern nicht anders
angegeben), Schrittweite `dt = 500` Jahre. Zweck: die offene Entscheidung aus
Issue #13 (Start am Orogenese-Höhepunkt vs. „U₀ so, dass Erosion überwiegt")
**messen** statt schätzen, und U₀ / U_floor / τ belegen.

Kennzahlen je Zeile:

- `relief` = `landRelief()` (max − min über Land). Auf diesem Terrain ist das
  praktisch `maxH − sea`: das Minimum liegt per Definition knapp über `sea`.
- `robust` = `landReliefRobust()` (95. Perzentil − Median der Landhöhen) — das
  Regelsignal des Servo-Bodens.
- `ridgeCurv` = `ridgeCurvature()`, die für dieses Ticket neu gebaute Kennzahl:
  mittleres ∇²z über Grat-/Wasserscheidenzellen (Einzugsgebiet ≤ 2 Zellen).
  **Negativ = konvex/spitz, gegen 0 = rund.** Das ist die in
  `docs/research-terrain-aging.md` §6 als fehlend benannte Alterungs-Diagnose.
- `water` = Anteil der Landzellen mit Füllhöhe > Gelände + 0.01 (See-Anteil).
- `U(t)` = wirkende Hebung pro 100 Jahre.

---

## 1. Die Entscheidung: Start am Orogenese-Höhepunkt

**Entschieden: Start am Orogenese-Höhepunkt.** Die Generierung erzeugt bereits
den fertigen, scharfen Gebirgszustand (ridged Multifraktal × Massiv-Feld ×
Insel-Falloff, danach einmalig die runevision-Pre-Erosion — `Terrain.generate`);
es gibt keine Aufbauphase, deren Höhepunkt man erst ansteuern müsste. `U(t)`
klingt deshalb **ab t = 0** ab, U₀ ist kein Anschub, sondern der Rest der
Orogenese. Ein U₀ über dem heutigen Niveau wurde gemessen und **verworfen**:

| Variante (100k Jahre) | maxH 0 → 100k | meanLand 0 → 100k | Urteil |
|---|---|---|---|
| D: U₀ = 0.006, floor 0.0006, τ = 40k | **0.6836 → 0.7647** (Peak 0.7805 bei 50k) | 0.3550 → 0.4173 (+18 %) | Wachstums-Puls — verworfen |
| F: U₀ = 0.003, floor 0.0003, τ = 40k | 0.6836 → 0.6739 (Peak 0.6831 bei 70k) | 0.3550 → 0.3720 (+5 %) | Berge wachsen ab 20k wieder — verworfen |
| Kandidat: U₀ = 0.0008, floor 0.00008, τ = 40k | 0.6836 → 0.5383 (monoton fallend) | 0.3550 → 0.3124 | gewählt |

(D und F wurden mit dem damals noch aktiven Servo gemessen, der Kandidat mit dem
Servo als Untergrenze. Das benachteiligt D/F nicht: in D regelte der Servo ab 40k
ohnehin auf 0 ab, weil das Relief über dem Ziel lag — das Wachstum kommt allein
aus U₀.)

D hebt den Gipfel um +12 % über den Startwert und die Landmasse um +18 % — genau
das „Berge wachsen", das ausdrücklich nicht gewollt ist. F bleibt zwar unter dem
Startwert, dreht aber ab 20k wieder nach oben (0.6484 → 0.6831). Nur ein U₀
**unter** dem heutigen Servo-Deckel (0.0015) hält `maxH` über den ganzen Lauf
monoton fallend.

---

## 2. Warum der Relief-Servo weg musste

Der Servo regelt auf `reliefTarget = 0.20`, das reale robuste Signal liegt aber
über den ganzen Lauf bei 0.09–0.18 — er läuft also **dauerhaft** und mit
steigender Stärke, je älter (= flacher) das Terrain wird. Das ist der „ewig
junge" Betriebspunkt aus dem Ticket:

| Jahr | A: heute (Servo, U = 0) relief / robust / ridgeCurv / servo |
|---:|---|
| 0 | 0.5335 / 0.1782 / −0.0453 / 0.00047 |
| 20000 | 0.4669 / 0.1396 / −0.0294 / 0.00129 |
| 40000 | 0.4757 / 0.1304 / −0.0291 / 0.00149 |
| 60000 | 0.4970 / 0.1460 / −0.0301 / 0.00116 |
| 80000 | 0.5086 / 0.1572 / −0.0299 / 0.00092 |
| 100000 | 0.5097 / 0.1621 / −0.0305 / 0.00081 |

Das Relief fällt bis 30k und wird danach vom Servo **wieder hochgeregelt**
(0.457 → 0.510); die Gratkrümmung bleibt ab 10k flach bei ≈ −0.030. Genau ein
Plateau, kein Alterungsverlauf. Dieselbe Messung auf Produktionsauflösung
(`n = 832`) steht in Abschnitt 5.

Die abklingende Hebung mit noch aktivem Servo (Variante C, U₀ = 0.0015) ändert
daran nichts: sobald `U(t)` unter den Servo fällt, übernimmt der Servo und das
Relief dreht wieder hoch (0.4685 bei 30k → 0.5054 bei 100k). **Der Servo muss
Untergrenze werden, sonst ist die abklingende Hebung wirkungslos.**

---

## 3. U₀ / U_floor / τ — der Sweep (Servo aus, 200k Jahre)

`relief` bei 0 / 100k / 200k, `ridgeCurv` bei 0 / 100k / 200k, `water` bei 100k:

| Variante | relief 0 → 100k → 200k | ridgeCurv 0 → 100k → 200k | water 100k |
|---|---|---|---|
| K: U = 0 (reiner Zerfall) | 0.5335 → 0.3509 → **0.2680** | −0.0453 → −0.0199 → −0.0152 | 0.066 |
| I: U₀ 0.0004, floor 0.00004, τ 40k | 0.5335 → 0.3647 → 0.3135 | −0.0453 → −0.0212 → −0.0162 | 0.034 |
| **H: U₀ 0.0008, floor 0.00008, τ 40k** | 0.5335 → **0.3883** → **0.3359** | −0.0453 → **−0.0219** → −0.0186 | **0.052** |
| Q: U₀ 0.0008, floor 0.00008, τ 30k | (s. Abschnitt 4) | | |
| N: U₀ 0.0008, floor 0, τ 60k | 0.5335 → 0.3994 → 0.3449 | −0.0453 → −0.0238 → −0.0180 | 0.036 |
| J: U₀ 0.0015, floor 0.00008, τ 20k | 0.5335 → 0.3853 → 0.3299 | −0.0453 → −0.0225 → −0.0190 | 0.045 |
| G: U₀ 0.0015, floor 0.00015, τ 40k | 0.5335 → 0.4336 → 0.3813 | −0.0453 → −0.0279 → −0.0222 | **0.029** |

Ausschlaggebend waren drei Dinge:

1. **K (gar keine Hebung) fällt bei 200k auf relief 0.268** — unter die
   Einebnungs-Schwelle 0.30 des `LongRunCollapse`-Wächters. Ohne `U_floor`
   erodiert die Insel über die Spielzeit hinaus weg; der Floor ist das, was den
   „Appalachen-Sockel" hält (H bei 200k: 0.336, +25 % gegenüber K).
2. **G (U₀ = 0.0015) altert zu langsam und trocknet die Seen aus:** der
   See-Anteil fällt auf 0.029 (100k) bzw. 0.002 (200k) — die diskreten Seen, die
   der Ziel-Look braucht, verschwinden. Ursache: mehr Hebung → mehr Gefälle →
   die Auslass-Inzision räumt jedes Becken frei. H hält 0.052 bei 100k.
3. **Der Alterungs-Kontrast** bei H ist der größte der brauchbaren Varianten:
   Relief −27 % und Gratkrümmung **−52 % im Betrag** über 100k, gegenüber
   −4 % / −33 % im heutigen Servo-Betrieb (A).

---

## 4. isoHighClamp testweise gelockert — muss bleiben

`isoHighClamp = 10` (praktisch aus), sonst Kandidat H bzw. I:

| Variante | maxH 0 → 20k → 40k → 60k → 100k → 200k | relief 200k |
|---|---|---|---|
| H (Clamp 0.90) | 0.6836 → 0.6206 → 0.5752 → 0.5639 → 0.5383 → 0.4859 | 0.3359 |
| L (H, Clamp aus) | 0.6836 → 0.6334 → **0.6424 → 0.6426** → 0.6145 → 0.5516 | 0.4016 |
| M (I = U₀ 0.0004, Clamp aus) | 0.6836 → 0.6211 → 0.5842 → 0.5722 → 0.5432 → 0.4813 | 0.3313 |

Ohne den Deckel **wächst der Gipfel zwischen 20k und 60k wieder** (0.6334 →
0.6426) und das Relief plateaut bei ~0.49 statt zu altern. Bei U₀ = 0.0004 (M)
wäre der Deckel entbehrlich — dann ist die Hebung aber so klein, dass sie den
Sockel nicht mehr trägt (I bei 200k: relief 0.3135 gegen 0.3359). **Entscheidung:
`isoHighClamp = 0.90` bleibt**, jetzt aber mit einer anderen Rolle: er begrenzt
nicht mehr ein Runaway (das gibt es ohne Servo nicht mehr), sondern verhindert,
dass die Rest-Hebung die höchsten Grate erneut anhebt.

---

## 5. Der Servo als Untergrenze

Kandidat mit Servo, 200k Jahre, gemessen wird der ANTEIL der Schritte, in denen
`reliefServoRate() > 0`:

| reliefTarget | Anteil aktiver Schritte | Ende (200k): relief / robust / ridgeCurv |
|---|---|---|
| 0.20 (alt) | **1.000** | 0.4961 / 0.1729 / −0.0309 |
| 0.09 | 0.000 | 0.3359 / 0.1050 / −0.0186 |
| 0.07 | 0.000 | 0.3359 / 0.1050 / −0.0186 |

Beim alten Ziel läuft der Servo in **jedem** Schritt und löscht die Alterung
vollständig (Relief endet 0.4961 statt 0.3359, Gratkrümmung −0.0309 statt
−0.0186). Ab 0.09 ist er über 200k Jahre nie aktiv, die Trajektorie also
identisch mit „Servo aus".

Gesetzt wurde **`reliefTarget = 0.05`**, nicht 0.07: das Minimum des robusten
Signals über 100k Jahre streut über Seeds von 0.0684 bis 0.1255 (Tabelle unten),
0.07 läge über dem Minimum von Seed 99. 0.05 hält ~27 % Abstand unter das
Minimum aller gemessenen Seeds und fängt trotzdem eine echte Peneplanation ab.

## 6. Multi-Seed (Kandidat, n = 160, 100k Jahre)

| Seed | relief 0 → 100k | maxH 0 / Peak / 100k | ridgeCurv 0 → 100k | min. robustes Signal |
|---|---|---|---|---|
| 1337 | 0.5335 → 0.3883 | 0.6836 / **0.6836** / 0.5383 | −0.0453 → −0.0219 | 0.0962 |
| 7 | 0.3605 → 0.3078 | 0.5106 / **0.5106** / 0.4578 | −0.0173 → −0.0253 | 0.1079 |
| 99 | 0.3491 → 0.2356 | 0.4991 / **0.4991** / 0.3856 | −0.0288 → −0.0169 | 0.0684 |
| 2024 | 0.3761 → 0.2392 | 0.5262 / **0.5262** / 0.3892 | −0.0306 → −0.0169 | 0.0859 |
| 555 | 0.4355 → 0.2686 | 0.5855 / **0.5855** / 0.4186 | −0.0429 → −0.0330 | 0.1255 |

Der **maxH-Spitzenwert des Laufs ist bei jedem Seed exakt der Startwert** — es
gibt zu keinem Zeitpunkt eine Wachstumsphase. Das Relief fällt bei jedem Seed.

Die Gratkrümmung rundet bei 4 von 5 Seeds aus; **Seed 7 ist die Ausnahme**
(−0.0173 → −0.0253, also schärfer). Seed 7 startet als weiches Rollhügel-Terrain
(relief 0.36, betragsmäßig kleinste Startkrümmung aller Seeds) und wird zuerst
einmal von der Inzision ZERSCHNITTEN, bevor die Diffusion die neuen Grate wieder
rundet. Das ist kein Fehler der Kennzahl, sondern der reale Verlauf: ein junges
glattes Terrain muss erst Täler bekommen. Der Wächter `TerrainAging` misst
deshalb auf dem kanonischen Seed 1337.

## 7. Produktionsauflösung (n = 832, Seed 1337, 100k Jahre)

Neu (abklingende Hebung, Servo als Untergrenze):

| Jahr | relief | robust | maxH | ridgeCurv | water | meanLand | U(t) |
|---:|---|---|---|---|---|---|---|
| 0 | 0.5953 | 0.1851 | 0.7453 | −0.9769 | 0.047 | 0.3547 | 0.000800 |
| 20000 | 0.4964 | 0.1655 | 0.6464 | −0.0508 | 0.135 | 0.3617 | 0.000517 |
| 40000 | 0.4671 | 0.1504 | 0.6171 | −0.0472 | 0.054 | 0.3621 | 0.000345 |
| 60000 | 0.4501 | 0.1392 | 0.6001 | −0.0434 | 0.046 | 0.3606 | 0.000241 |
| 80000 | 0.4467 | 0.1318 | 0.5967 | −0.0410 | 0.052 | 0.3577 | 0.000177 |
| 100000 | **0.4413** | 0.1226 | **0.5913** | **−0.0389** | 0.057 | 0.3541 | 0.000139 |

Alt (heutiger Stand: Servo als Haupt-Hebung, keine abklingende Hebung):

| Jahr | relief | robust | maxH | ridgeCurv | water | meanLand | servo |
|---:|---|---|---|---|---|---|---|
| 0 | 0.5953 | 0.1851 | 0.7453 | −0.9769 | 0.047 | 0.3547 | 0.000320 |
| 20000 | 0.4963 | 0.1650 | 0.6463 | −0.0517 | 0.159 | 0.3584 | 0.000749 |
| 40000 | 0.4671 | 0.1479 | 0.6171 | −0.0436 | 0.172 | 0.3683 | 0.001115 |
| 60000 | 0.4969 | 0.1514 | 0.6469 | −0.0456 | 0.136 | 0.3806 | 0.001042 |
| 80000 | 0.5192 | 0.1582 | 0.6692 | −0.0471 | 0.139 | 0.3891 | 0.000896 |
| 100000 | **0.5340** | 0.1650 | **0.6840** | **−0.0476** | 0.145 | 0.3938 | 0.000749 |

Der Unterschied ist auf Produktionsauflösung deutlicher als im Testgrid:

- **Relief:** neu −26 % (0.5953 → 0.4413) und monoton. Alt fällt bis 40k auf
  0.4671 und steigt dann **wieder auf 0.5340** — der Servo baut das Gebirge nach.
- **maxH:** neu monoton 0.7453 → 0.5913. Alt: 0.6171 bei 40k → 0.6840 bei 100k,
  also +11 % Wachstum in der zweiten Hälfte.
- **meanLand:** neu praktisch konstant (0.3547 → 0.3541 = die Landmasse wird
  weder auf- noch abgebaut). Alt +11 % (0.3547 → 0.3938) — sichtbares „Wachsen".
- **Gratkrümmung** (ab 20k, nach dem Einschwingen der frischen Oberfläche):
  neu −0.0508 → −0.0389 (−23 % Betrag, monoton rundend). Alt −0.0517 → −0.0476
  mit Umkehr ab 40k (−0.0436 → −0.0476, also wieder SCHÄRFER).

Der t=0-Wert der Gratkrümmung (−0.9769) ist ein Artefakt der frischen
Noise-Oberfläche: die Zell-Rauigkeit dominiert und ÷dx² verstärkt sie mit der
Auflösung (−0.045 bei n=160, −0.143 bei n=320, −0.977 bei n=832). Nach ~20k
Sim-Jahren liegen alle drei Auflösungen bei −0.03 … −0.05. Für Alterungs-
Vergleiche wird die Kennzahl deshalb erst nach dem Einschwingen abgelesen (so
macht es auch der Wächter `TerrainAging`).

Auflösungs-Kontrolle n = 320 (Kandidat, 100k): relief 0.5680 → 0.4185, maxH
0.7180 → 0.5685 monoton, ridgeCurv (20k → 100k) −0.0433 → −0.0345. Derselbe
Verlauf, nur zwischen den Werten von n = 160 und n = 832.
