# Zielbild-Messreihe (Issue #174)

Kennzahlen des Abnahmebogens aus Issue #174, headless gemessen. Definitionen
stehen EINMAL in `SimCore/Tests/SimCoreTests/ZielbildMetrics.swift`; die
Wächter der Pakete A und B lesen dieselben Funktionen.

```sh
RS_MEASURE=1 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter testZielbildBaselineDiagnostic
```

Produktions-Config (`SimConfig.production`, n = 720, world = 112,4789) mit
Einlauf (`productionSettleYears` = 3000), getaktet in 1000-Jahr-Schritten.

## Definitionen

- **Tiefland:** Landzelle (`hf > sea`) mit `macroSlope / cellSize <
  meanderFlatSlope`. `macroSlope` ist Höhe je ZELLE, die Mäander-Schwelle Höhe
  je WELTEINHEIT (Gate in `MeanderState.lateralStep`); ohne die Division wäre
  die Schwelle um den Faktor 6,4 zu scharf.
- **Korridor:** 4er-Zusammenhangskomponente des Tieflands ab 0,25 % der
  Landzellen. „in Korridoren" = Anteil des Tieflands in diesen Komponenten.
- **Küsten-Reichweite:** größte Küstendistanz (4er-BFS) in einem Korridor, der
  die Küste berührt, geteilt durch die größte Küstendistanz der Insel.
  1,00 = ein Korridor reicht bis zum küstenfernsten Punkt.
- **Zerklüftung Tiefland:** mittlerer Betrag des diskreten Laplace über die
  Tieflandzellen (Höhe je Zelle).
- **Hauptlauf:** Mäanderlauf mit der größten Abfluss-Summe über seine Knoten.
  Nicht „größter Abfluss am Ende": `traceChannels` bricht den Stamm an jedem
  Zusammenfluss, der Lauf mit dem größten Endabfluss ist deshalb meist ein
  Stummel aus wenigen Knoten vor der Mündung (Seed 1337: 13 Knoten).
- **Tieflandabschnitt:** längster Knotenbereich des Hauptlaufs, dessen
  Längsneigung über ±3 Knoten unter `meanderFlatSlope` liegt.
- **Breite:** bis Paket B gibt es keine Sim-Breite; gemessen wird die
  Band-Breite `2 · WaterRender.ribbonHalfWidthCells` am mittleren Abfluss des
  Abschnitts (Deckel 6,4 Zellen).
- **Wellenlänge / Amplitude:** Wendepunkte = Vorzeichenwechsel der über ±2
  Knoten geglätteten Krümmung; Wellenlänge = Luftlinie über zwei Halbwellen,
  Amplitude = größter Abstand einer Halbwelle zu ihrer Sehne.
- **Gürtel:** bis Paket B (`barAge`) die Ausdehnung der im Lauf je
  überstrichenen Zellen quer zur Talachse (Mittel über ±12 Knoten), Median.
- **Asymmetrie:** mittlere Tiefe unter der höheren Uferkante (±(b/2 + 2)) am
  Außenufer geteilt durch die am Innenufer, Abstand max(1, b/4), nur Bögen mit
  |Krümmung| über dem Median.
- **Altarme:** Schwerpunkt im Tiefland; „offen" = jünger als
  `WaterRender.oxbowVisibleYears`. Cutoffs = über den Lauf aufsummierte neue
  Altarme (Alter 0 nach einem Schritt).

## Ist-Stand vor Paket A und B (2026-10-11, Basis `55323b5`, M4 Max)

### Großform

| Seed | Jahr | Tiefland | Korridore | in Korridoren | Küsten-Reichweite | Land am Rand | min. Randabstand | Eiszellen | Zerklüftung Tiefland |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1337 | 2000 | 35.5 % | 24 | 66 % | 0.30 | 659 | 0 | 11409 | 0.00361 |
| 1337 | 20000 | 48.0 % | 17 | 86 % | 0.51 | 725 | 0 | 5214 | 0.00211 |
| 1337 | 100000 | 65.9 % | 10 | 97 % | 1.00 | 780 | 0 | 931 | 0.00124 |
| 42 | 2000 | 43.3 % | 12 | 85 % | 0.00 | 0 | 44 | 776 | 0.00304 |
| 42 | 20000 | 50.5 % | 13 | 92 % | 0.39 | 0 | 45 | 136 | 0.00200 |
| 42 | 100000 | 60.5 % | 8 | 97 % | 0.80 | 0 | 44 | 0 | 0.00138 |
| 20 | 2000 | 42.7 % | 14 | 80 % | 0.19 | 280 | 0 | 11645 | 0.00298 |
| 20 | 20000 | 53.3 % | 14 | 90 % | 0.76 | 288 | 0 | 5782 | 0.00180 |
| 20 | 100000 | 68.2 % | 7 | 98 % | 1.00 | 351 | 0 | 1469 | 0.00112 |

### Mäandergürtel, Hauptlauf

| Seed | Jahr | Tiefland-Knoten | Abfluss | Sinuosität | Breite | Wellenlänge | λ/Breite | Amplitude | Gürtel | Gürtel/Amplitude | Asymmetrie | Altarme offen / Tiefland | Cutoffs Hals / Chute |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1337 | 2000 | 293 | 68789 | 2.21 | 6.40 | 7.0 | 1.1 | 1.4 | 2.5 | 1.8 | 0.52 | 112 / 112 | 86 / 0 |
| 1337 | 20000 | 539 | 72816 | 2.41 | 6.40 | 7.1 | 1.1 | 1.5 | 6.5 | 4.4 | 0.67 | 650 / 2058 | 2075 / 0 |
| 1337 | 100000 | 69 | 50 | 3.01 | 6.40 | 17.4 | 2.7 | 4.5 | 3.5 | 0.8 | 0.89 | 358 / 1530 | 8202 / 0 |
| 42 | 2000 | 733 | 48247 | 2.91 | 6.40 | 12.7 | 2.0 | 2.7 | 1.5 | 0.5 | 0.99 | 28 / 28 | 18 / 0 |
| 42 | 20000 | 646 | 48522 | 2.48 | 5.65 | 8.9 | 1.6 | 1.8 | 6.0 | 3.4 | 0.77 | 253 / 761 | 773 / 0 |
| 42 | 100000 | 676 | 8 | 3.06 | 3.88 | 10.1 | 2.6 | 1.8 | 28.5 | 15.5 | 0.80 | 150 / 603 | 3113 / 0 |
| 20 | 2000 | 592 | 67382 | 2.60 | 6.40 | 7.0 | 1.1 | 1.5 | 2.5 | 1.7 | 0.59 | 122 / 122 | 71 / 0 |
| 20 | 20000 | 657 | 47006 | 2.72 | 4.20 | 7.1 | 1.7 | 1.6 | 8.0 | 4.9 | 0.76 | 432 / 1470 | 1454 / 0 |
| 20 | 100000 | 656 | 30052 | 2.57 | 2.98 | 9.3 | 3.1 | 1.9 | 26.0 | 13.5 | 0.77 | 263 / 1028 | 5258 / 0 |

### Lesart

- **Tiefland fehlt nicht, es ist zerstückelt.** Schon ab Jahr 2000 liegen
  35–43 % der Landzellen unter der Mäander-Schwelle, mit dem Alter bis 68 %.
  Abnahmepunkt 1 (≥ 20 %) hält also schon heute. Es zerfällt aber in 12–24
  Flecken, und der größte küstennahe reicht in Jahr 2000 nur 0–30 % ins
  Inselinnere. Paket A muss das Tiefland also zusammenhängend machen
  (Korridore ≤ 4, Punkt 2), nicht vermehren.
- **Die Mäander sind keine Mäander.** Die Sinuosität des Hauptlaufs liegt mit
  2,2–3,1 sogar über dem Ziel, aber die Wellenlänge beträgt nur 1–3
  Kanalbreiten (Ziel 10–14) bei einer Amplitude von 1,5–2 Zellen: die
  Sinuosität kommt aus Zacken in der Größe der Bandbreite, nicht aus Bögen.
- **Asymmetrie verkehrt:** 0,5–1,0, das Innenufer ist gleich tief oder tiefer
  als das Außenufer (Ziel ≥ 2). Die Ufer-Rückkopplung versetzt eine Zelle bei
  ±1,6 Zellen, das Querprofil des Bandes sieht sie nicht.
- **Zu viele Cutoffs:** 770–2075 Hals-Cutoffs in 20.000 Jahren, gleichzeitig
  250–650 offene Altarme im Tiefland. Ziel sind ≥ 3 sichtbare; die vielen
  kleinen Schlingen-Seen sind ein Kandidat für den „Tümpel-Teppich" aus
  Paket C.
- **Lauf löst sich von der Entwässerung:** in Jahr 100.000 endet der
  Hauptlauf auf Seed 1337 und 42 auf Zellen mit 50 bzw. 8 Zellen
  Einzugsgebiet. Die Zentrumslinie ist dort von der D8-Rinne weggewandert;
  `refreshDischarge` liest an der Knotenposition, nicht am Gerinne.
- **Rand:** Seed 1337 und 20 haben Land im äußersten Gitterring (Punkt 3).
- **Gletscher:** Seed 42 hat ab Jahr 100.000 kein Eis mehr (Punkt 4 verlangt
  „ab Jahr 20.000").
