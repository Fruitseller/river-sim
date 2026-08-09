# Niederschlagsgewichteter Abfluss — Messung an/aus (Issues #9 und #10)

`SimConfig.rainWeightedFlow` gewichtet die Abfluss-Akkumulation beider Netze mit
dem Niederschlagsfeld und startet die Erosions-Tropfen niederschlagsgewichtet:

- **aus** — `area`/`areaMFD` akkumulieren reine Zellfläche (`cellArea` je Zelle),
  Tropfen starten gleichverteilt. Das ist der Stand vor Issue #9; der Arm bleibt
  als Referenz/Gegenprobe erhalten.
- **an** (Default seit #10) — die Akkumulation startet je Zelle mit
  `cellArea · rainWeight[k]` (`Terrain.seedFlowAccumulator`, dieselbe Regel für
  D8 **und** MFD; die Rollentrennung bleibt: `area` erodiert, `areaMFD`
  rendert/braided), und die Tropfen-Startpunkte werden per Ablehnungs-Stichprobe
  mit demselben Feld gewichtet (`Hydraulic.spawnPosition`).

**Dieses Dokument hat zwei Teile.** §0–§D sind die Messung aus Issue #9 mit dem
ROHEN Regen als Gewicht (`rainWeight = rain`, Default damals aus). §E–§G sind
Issue #10: die Kalibrier-Entscheidung, ihre Messung in Produktionsauflösung und
die verworfenen Alternativen. Wer nur den heutigen Stand wissen will, liest §E
und §F — die Tabellen in §A/§C2 zeigen den **verworfenen** unnormierten Arm.

Der dominierende Effekt in §A–§D: ohne Normierung fällt der Gesamtabfluss auf das
Landmittel des Regens (~0.36 … 0.48), alle in ZELLEN kalibrierten Gates greifen
also später. Genau das behebt §E.

## Methode

Alle Zahlen aus `SimCoreTests/RainWeightedFlow.swift` (Release-Lauf), Seed 1337,
sonst Default-`SimConfig` (§A–§D: Stand Issue #9, dort war der Schalter der
einzige Unterschied zwischen den Armen und das Gewicht das ROHE `rain`).

```sh
RS_MEAS_N=640 RS_MEAS_YEARS=50000 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter testRainWeightMeasurementDiagnostic
swift test -c release --package-path SimCore -Xswiftc -swift-version -Xswiftc 5 \
    --filter testRainWeightLuvLeeIsSeedRobustDiagnostic
```

Kennzahlen (Definitionen wie in `docs/river-baseline-metrics.md`, ergänzt):

| Kennzahl | Definition |
|---|---|
| Kanalzellen | Landzelle mit `areaMFD / cellArea ≥ renderMinCells` (320) — die Render-Definition aus `SimNode.waterFieldBytes` |
| Drainagedichte Luv/Lee | Anteil der Kanalzellen an den Landzellen der West- (Luv, Wind kommt aus Westen) bzw. Osthälfte |
| Relief | `landRelief()` = max − min über Land; `reliefRobust` = `landReliefRobust()` (95. Perzentil − Median) |
| Seeanteil | `lakeStats(depth: 0.03).fraction` = Anteil der Landzellen mit Wassertiefe > 0.03 (die See-Render-Schwelle); „größter See" = größte zusammenhängende Fläche in Zellen |

## 0) Ausgeschaltet = bit-identisch zum Stand vor Issue #9

Gegen `main` (`a7064e3`) direkt gemessen, nicht nur argumentiert: ein temporärer
Test hat in BEIDEN Arbeitsbäumen denselben Fingerabdruck gezogen (FNV-Hash über
die Bit-Muster von `h`, `area`, `areaMFD`, `streamMap`, `veg` nach Generierung +
5 × 1000 Jahren, n = 192, Seeds 1337 und 99, einmal Default-Config und einmal
produktionsnah mit `hydraulicSkipWaterSpawns` + `meanderSpatialCutoffIndex`).
Alle 12 Hashes stimmen exakt überein, z. B. Seed 1337 Default
`h = 02d0731f4e9fb6dd`, `area = 3e2ccf262d9dd7f6`, `areaMFD = 205d2fa2417e6a94`.

Dazu läuft die vollständige SimCore-Suite (63 Tests, alle auf der
Default-Konfiguration kalibriert) unverändert grün. Im Code gibt es genau zwei
Verzweigungen: `seedFlowAccumulator` (ohne Schalter der alte
`pa.update(repeating: cellArea)`-Pfad) und `Hydraulic.spawnPosition` (ohne
Gewichtsfeld dieselben zwei Zufallsziehungen wie bisher).

## A) Verlauf an/aus, n = 640, Seed 1337

| Jahr | gew. | Kanalzellen | Dichte Luv | Dichte Lee | Luv/Lee | Relief | reliefRobust | Seeanteil | größter See |
|-----:|:----:|------------:|-----------:|-----------:|--------:|-------:|-------------:|----------:|------------:|
|     0 | aus | 9156 | 0.0336 | 0.0302 | 1.11 | 0.5621 | 0.1846 | 0.0246 |  3287 |
|     0 | an  | 5687 | 0.0218 | 0.0168 | **1.30** | 0.5660 | 0.1836 | 0.0250 |  3248 |
|  5000 | aus | 13911 | 0.0472 | 0.0529 | 0.89 | 0.5284 | 0.1816 | 0.0844 |  8679 |
|  5000 | an  | 10280 | 0.0379 | 0.0332 | **1.14** | 0.5298 | 0.1812 | 0.0423 |  9341 |
| 20000 | aus | 15886 | 0.0524 | 0.0629 | 0.83 | 0.4937 | 0.1670 | 0.1043 | 16963 |
| 20000 | an  | 13039 | 0.0459 | 0.0459 | **1.00** | 0.4984 | 0.1636 | 0.0441 |  9451 |
| 50000 | aus | 13646 | 0.0474 | 0.0494 | 0.96 | 0.4514 | 0.1460 | 0.0452 |  3842 |
| 50000 | an  | 12293 | 0.0462 | 0.0373 | **1.24** | 0.4644 | 0.1465 | 0.0691 | 19561 |

**Kanalzellen** liegen eingeschaltet durchgehend niedriger (−38 % bei t=0, −26 %
bei 5k, −18 % bei 20k, −10 % bei 50k) — der Regen-Faktor < 1 verkleinert jede
akkumulierte Fläche, die Render-Schwelle `renderMinCells` = 320 Zellen bleibt
aber stehen. **Kein physikalischer Effekt, sondern genau die offene Kalibrierung
(#10):** die Zell-Gates müssten auf „Abfluss-Zellen" umgerechnet werden. Dass
der Abstand mit der Zeit schrumpft, passt dazu — die Läufe wachsen nach.

**Drainagedichte Luv/Lee** ist die eigentliche Zielgröße und verschiebt sich in
jedem Zeitschnitt Richtung Luv: 1.11→1.30, 0.89→1.14, 0.83→1.00, 0.96→1.24.
Der Ausgangswert < 1 bei 5k/20k ist keine Anomalie, sondern zeigt, wie stark die
Insel-Geometrie (wo die großen Einzugsgebiete zufällig liegen) das Signal
überdeckt, solange der Abfluss das Klima gar nicht kennt.

**Relief** ändert sich kaum und bleibt eingeschaltet minimal höher (20k: 0.4984
gegen 0.4937; 50k: 0.4644 gegen 0.4514) — die schwächere Gesamt-Erosion trägt
etwas weniger ab. `reliefRobust` läuft praktisch deckungsgleich (0.1636 gegen
0.1670 bzw. 0.1465 gegen 0.1460): die Alterung bleibt intakt, der Schalter
verschiebt keinen Relief-Haushalt.

**Seeanteil** schwankt zwischen den Armen ohne klare Richtung (20k: 0.0441 gegen
0.1043, 50k: 0.0691 gegen 0.0452). Das ist Becken-Einzelereignis-Rauschen: ob
ein großes Becken bei 20k schon durchgeschnitten („gebreacht") ist, entscheidet
über zweistellige Prozentpunkte — sichtbar auch am „größten See" (16963 gegen
9451 bzw. 3842 gegen 19561). Aus diesen Zahlen lässt sich **keine** Wirkung des
Schalters auf die Verseeung ableiten; sie sind als Nullpunkt für #10 notiert.

## B) Richtung über mehrere Seeds (n = 192, 20.000 Jahre)

| Seed | Dichte Luv (aus→an) | Dichte Lee (aus→an) | Luv/Lee aus | Luv/Lee an |
|-----:|--------------------:|--------------------:|------------:|-----------:|
| 1337 | 0.0456 → 0.0378 | 0.0574 → 0.0313 | 0.795 | **1.208** |
|    7 | 0.0276 → 0.0193 | 0.0171 → 0.0107 | 1.619 | **1.812** |
|   99 | 0.0235 → 0.0191 | 0.0280 → 0.0179 | 0.841 | **1.067** |
| 2024 | 0.0124 → 0.0081 | 0.0208 → 0.0142 | 0.596 | 0.567 |
|  555 | 0.0000 → 0.0000 | 0.0092 → 0.0021 | – | – |
|   42 | 0.0124 → 0.0106 | 0.0265 → 0.0214 | 0.468 | **0.494** |
| **gepoolt** | | | **1.048** | **1.362 (×1.30)** |

Gepoolt heißt: Kanal- und Landzellen aller Seeds zusammengezählt, dann eine
Dichte je Hälfte. Nötig, weil kleine trockene Inseln Hälften ganz ohne
Kanalzellen haben (Seed 555 hat inselweit 47 bzw. 11 Kanalzellen) — deren
Einzel-Verhältnis ist 0 bzw. undefiniert und würde ein Mittel der Verhältnisse
dominieren. 4 von 5 auswertbaren Seeds verschieben sich Richtung Luv, Seed 2024
minimal dagegen (0.596 → 0.567); gepoolt ×1.30. Wächter:
`testRainWeightLuvLeeIsSeedRobustDiagnostic` (fordert ≥ ×1.05).

## C) Nachweis der Richtung ohne Gate-Effekt (Abnahmekriterium 4)

Die Drainagedichte hängt an einer Zell-Schwelle und damit an der offenen
Kalibrierung. Der eigentliche Nachweis ist deshalb gate-frei formuliert:
**Abfluss je Einzugsgebiets-Zelle** = `area[k] / (Zellen im Einzugsgebiet ·
cellArea)`. Das ist genau der mittlere Niederschlag über dem Einzugsgebiet von
`k`; bei GLEICH GROSSEM Einzugsgebiet trägt eine Luv-Zelle also genau dann mehr
Abfluss, wenn dieser Wert höher liegt. Die Zellzahl des Einzugsgebiets rechnet
der Test unabhängig aus dem `receiver`-Netz nach (Kahn-Topologie).

n = 128, Seed 1337, Einzugsgebiete ≥ 30 Zellen (`testRainWeightedFlowFavorsLuv`,
`testRainWeightedMFDFavorsLuv`):

| Feld | Luv (West) | Lee (Ost) | Verhältnis |
|---|---:|---:|---:|
| `area` (D8, speist die Erosion) | 0.6895 | 0.4992 | **×1.38** |
| `areaMFD` (Render/Braiding) | 0.6575 | 0.4627 | **×1.42** |
| ausgeschaltet, beide Felder | 1.0000 | 1.0000 | ×1.00 (exakt) |

Ausgeschaltet ist der Wert **exakt** 1.0 (reine Fläche, auf 1e-9 geprüft) — die
Richtung kommt also nachweislich aus dem Regen und nicht aus der Geometrie.

Tropfen-Startpunkte (`testRainWeightedSpawnsFollowRain`, 20.000 Ziehungen auf
einem Feld mit Gewicht 1.0 West / 0.5 Ost): 13505 West gegen 6495 Ost = ×2.08 bei
erwarteten ×2.0 — die Ablehnungs-Stichprobe trifft die Zielverteilung im Rahmen
der Stichprobe (Rest-Verzerrung durch den Neuziehungs-Deckel < 1 %). Ohne
Gewichtsfeld bleibt die Verteilung gleichmäßig.

## C2) Produktionsgitter n = 832, frisch generiert (Jahr 0)

`RS_MEAS_N=832 RS_MEAS_YEARS=0`, Seed 1337:

| gew. | Kanalzellen | Dichte Luv | Dichte Lee | Luv/Lee | Relief | Seeanteil | Regen Land | gew. Starts auf Land |
|:----:|------------:|-----------:|-----------:|--------:|-------:|----------:|-----------:|---------------------:|
| aus | 17042 | 0.0359 | 0.0353 | 1.02 | 0.5953 | 0.0264 | 0.364 | 0.469 |
| an  |  9409 | 0.0212 | 0.0167 | **1.27** | 0.5957 | 0.0288 | 0.361 | 0.467 |

Dieselbe Richtung wie bei n = 640, aber der Gate-Effekt ist stärker (−45 %
Kanalzellen): das Landmittel des Regens ist **auflösungsabhängig** — 0.563 bei
n = 192, 0.398 bei n = 640, 0.364 bei n = 832. Der orographische Sweep in
`computeRain` trocknet je ZELLE ab, ein feineres Gitter hat also mehr
Abtrocknungsschritte über dieselbe Insel. Für #10 heißt das: eine Rekalibrierung
über einen festen Faktor wäre auflösungsgebunden — der Regen selbst müsste
weltmaßstäblich normiert werden (Abtrocknung ∝ `cellSize`) oder das Gewicht auf
sein Landmittel normiert.

## D) Was #10 aus dieser Messung mitnehmen sollte

> **Nachtrag (#10, erledigt):** Punkt 4 (Normierung) ist gewählt und macht 1–3
> gegenstandslos — die Gates zählen weiter Zellen, die Raten bleiben, die Tropfen
> gehen nicht mehr verloren. Belege: §E (Entscheidung + Invarianten), §F (Verlauf
> in Produktionsauflösung), §G (die verworfenen Wege 1–3 mit Messwerten).

1. **Zell-Gates umrechnen.** `renderMinCells` (320), `braidMinCells` (120),
   `meanderMinCells` (85), `floodplainMinArea` (500) und die
   `outletIncision`-Gates zählen „Zellen"; eingeschaltet zählen sie
   „regen-gewichtete Zellen". Landmittel des Regens im gemessenen Lauf:
   0.398 (t=0) … 0.482 (50k) — die Gates sind also faktisch um Faktor ~2 zu hoch.
2. **Erosionsraten nachziehen.** `kRock`/`outletErode` sehen A^m mit halbiertem
   A; bei m = 0.5 fehlt ~30 % Inzisionsleistung.
3. **Tropfen gehen an den Ozean verloren.** Über dem Meer regnet es am meisten
   (Landmittel 0.398 gegen 0.895 über See). Der Anteil der Landzellen liegt bei
   0.690, der Anteil der gewichteten Tropfen-Starts auf Land nur bei 0.494
   (t=0) bzw. 0.548 (50k) — in der Produktionskonfiguration
   (`hydraulicSkipWaterSpawns = true`, Ozean-Starts werden verworfen) kommen also
   **21–28 % weniger Tropfen aufs Land**. Das ist ein reiner Kalibrier-Effekt,
   kein physikalischer: entweder die Tropfenzahl anheben oder das Startgewicht
   auf Land maskieren.
4. **Normierung erwägen.** `rain / mittleres Land-rain` als Gewicht würde den
   Gesamtabfluss konstant halten und den Effekt auf die reine Umverteilung
   reduzieren — dann bleiben alle Zell-Kalibrierungen gültig, und die
   Auflösungs-Abhängigkeit aus (C2) fällt mit heraus. Bewusst nicht in #9
   entschieden, weil es eine Kalibrier-Entscheidung ist: das Landmittel des
   Regens driftet über den Lauf (0.398 → 0.482 bei n = 640) und hinge als
   globale Größe an jedem Schritt vom Gesamtzustand ab.

---

## E) Issue #10 — die Kalibrier-Entscheidung: Normierung auf das Landmittel

Aus §D standen zwei Wege offen: (1) das rohe `rain` als Gewicht behalten und
alle in Zellen kalibrierten Gates plus die Erosionsraten nachziehen, oder (2) das
Gewicht auf sein Landmittel normieren. **Gewählt: (2).** Der Grund ist gemessen,
nicht ästhetisch — der Umrechnungsfaktor von Weg (1) ist keine Konstante:

| Landmittel `rain` | Wert |
|---|---:|
| n = 192, Seed 1337 | 0.563 |
| n = 640, Seed 1337 | 0.398 |
| n = 832, Seed 1337 | 0.357 |
| n = 832, Seed 7 | 0.544 |
| n = 832, Seed 99 | 0.488 |
| n = 832, Seed 1337, nach 50k Jahren | 0.443 |

`computeRain` trocknet je ZELLE ab, also hängt das Landmittel an der Auflösung;
und weil es ein Mittel über die Landzellen ist, hängt es zusätzlich an Größe und
Form der Insel — also am Seed — und driftet über den Lauf, während die Insel
abflacht. Eine feste Gate-Umrechnung müsste für n = 96 (Testkonfigs), n = 832
(Produktion) und jede Insel gleichzeitig stimmen. Sie kann es nicht (§G.1).

**Das Gewicht** (`Terrain.updateRainWeight`):

    w[k] = rain[k] / Landmittel(rain)    auf Land
    w[k] = 1.0                           über See

Zwei Invarianten, die alles Weitere tragen (Wächter:
`testRainWeightIsNormalizedToLandMean`, `testWeightedFlowKeepsDrainageTotal`,
`testWeightedSpawnsKeepTheLandBudget`):

1. **Σ w über Land = Zahl der Landzellen.** Der Gesamtabfluss ist exakt der der
   ungewichteten Akkumulation; der Schalter wirkt als reine Umverteilung Lee→Luv.
   Gemessen: `totalOutletArea / Zellzahl` = 1.0000 an wie aus (n = 832, alle drei
   Seeds, alle Zeitschnitte), Landmittel des Gewichts 1.0000 (Drift über 50k
   Jahre: 0.9998 — das ist die Zelle-für-Zelle verschobene Küstenlinie zwischen
   `computeRain` und der Messung, nicht die Normierung).
2. **Über See ist das Gewicht neutral** (1.0 = das Landmittel). Damit verwirft
   `hydraulicSkipWaterSpawns` denselben Anteil Ozean-Starts wie ungewichtet:
   Anteil der Tropfen-Starts auf Land = Anteil der Landzellen, gemessen auf vier
   Stellen gleich (0.6900 / 0.3277 / 0.4560 für Seed 1337 / 7 / 99). Der in §D.3
   gemessene Verlust von 21–28 % Land-Tropfen ist damit gegenstandslos, ohne die
   Tropfenzahl anzufassen.

Die Auflösungs-Abhängigkeit fällt mit heraus: das Landmittel des Gewichts ist
1.000000 bei n = 96, 192 und 320 (gemessen im Wächter).

**Konsequenz:** kein Zell-Gate (`renderMinCells`, `braidMinCells`,
`meanderMinCells`, `floodplainMinArea`), keine Erosionsrate (`kRock`,
`outletErode`) und keine Tropfen-Startdichte (`hydraulicPerYear`) musste
verschoben werden. Die Belege stehen einzeln am jeweiligen Wert in `Config.swift`
und gesammelt in §F/§G.

## F) Verlauf an/aus in PRODUKTIONSAUFLÖSUNG (n = 832, Produktionspfad)

Produktionspfad = `hydraulicSkipWaterSpawns` + `meanderSpatialCutoffIndex` wie in
`SimNode.productionConfig()`; „an" ist der normierte Stand aus §E. Erzeugt mit
der temporären Messbank aus Issue #10 (`RecalMeasure.swift`, nach der Kalibrierung
entfernt — dieselben Kennzahlen liefert `testRainWeightMeasurementDiagnostic`).

### Seed 1337

| Jahr | gew. | Kanalzellen | Dichte Luv | Dichte Lee | Luv/Lee | Relief | reliefRobust | Seeanteil | größter See |
|-----:|:----:|------------:|-----------:|-----------:|--------:|-------:|-------------:|----------:|------------:|
|     0 | aus | 17432 | 0.0363 | 0.0370 | 0.98 | 0.5954 | 0.1851 | 0.0246 |  5614 |
|     0 | an  | 16329 | 0.0385 | 0.0258 | **1.49** | 0.5957 | 0.1855 | 0.0261 |  5397 |
|  5000 | aus | 25555 | 0.0525 | 0.0550 | 0.95 | 0.5311 | 0.1816 | 0.0774 | 15043 |
|  5000 | an  | 25258 | 0.0556 | 0.0471 | **1.18** | 0.5312 | 0.1831 | 0.0958 | 16592 |
| 20000 | aus | 28386 | 0.0585 | 0.0602 | 0.97 | 0.4967 | 0.1685 | 0.0925 | 15732 |
| 20000 | an  | 27184 | 0.0593 | 0.0512 | **1.16** | 0.4981 | 0.1714 | 0.1036 | 16853 |
| 50000 | aus | 25076 | 0.0512 | 0.0535 | 0.96 | 0.4574 | 0.1484 | 0.0524 |  6698 |
| 50000 | an  | 27465 | 0.0587 | 0.0538 | **1.09** | 0.4592 | 0.1558 | 0.0980 | 45684 |

### Seed 7 (kleine trockene Insel) und Seed 99

| Seed | Jahr | Kanalzellen aus → an | Luv/Lee aus → an | Relief aus → an | robust aus → an | Seeanteil aus → an |
|-----:|-----:|---------------------:|-----------------:|----------------:|----------------:|-------------------:|
| 7 |     0 |  7847 →  7605 (−3.1 %) | 1.44 → **1.90** | 0.3877 → 0.3862 | 0.1162 → 0.1167 | 0.0003 → 0.0004 |
| 7 |  5000 |  8357 →  8303 (−0.6 %) | 1.16 → **1.58** | 0.3606 → 0.3596 | 0.1157 → 0.1162 | 0.0000 → 0.0000 |
| 7 | 20000 |  9055 →  8794 (−2.9 %) | 0.97 → **1.24** | 0.3381 → 0.3380 | 0.1162 → 0.1182 | 0.0000 → 0.0000 |
| 7 | 50000 |  8417 →  8083 (−4.0 %) | 1.12 → **1.43** | 0.3499 → 0.3521 | 0.1143 → 0.1167 | 0.0000 → 0.0000 |
| 99 |     0 | 10331 →  9706 (−6.1 %) | 0.65 → **0.91** | 0.3720 → 0.3707 | 0.1060 → 0.1060 | 0.0073 → 0.0099 |
| 99 |  5000 | 16850 → 16267 (−3.5 %) | 0.47 → **0.69** | 0.3242 → 0.3257 | 0.0942 → 0.0957 | 0.0000 → 0.0000 |
| 99 | 20000 | 14326 → 14153 (−1.2 %) | 0.59 → **0.81** | 0.2925 → 0.2967 | 0.0791 → 0.0820 | 0.0000 → 0.0000 |
| 99 | 50000 | 11788 → 11523 (−2.2 %) | 0.84 → **1.19** | 0.2858 → 0.2937 | 0.0781 → 0.0811 | 0.0000 → 0.0000 |

**Bänder (Abnahmekriterium „Terrain-Look im Rahmen"):**

- **Kanalzellen** −6.3 % … +9.5 % über 12 gemessene Zeitschnitte × Seeds, ohne
  Richtung (unnormiert waren es −45 % bei Jahr 0). Band: ±10 %.
- **Relief** −0.4 % … +2.8 %, `reliefRobust` 0.0 % … +5.0 % — beide leicht nach
  oben, wie schon in #9: die Umverteilung nimmt der Lee-Seite Erosionsleistung ab,
  ohne sie der Luv-Seite überproportional zuzuschlagen. Band: ±5 %.
- **Seeanteil** unverändert bei den Seeds ohne Becken (7, 99: ≤ 0.0099 in beiden
  Armen). Bei Seed 1337 an durchgehend etwas höher (0.0261/0.0958/0.1036/0.0980
  gegen 0.0246/0.0774/0.0925/0.0524). Der 50k-Wert ist ein einzelnes noch nicht
  durchgeschnittenes Becken — größter See 45684 gegen 6698 Zellen. Dieselbe
  Einzelereignis-Streuung hat §A schon mit **umgekehrtem** Vorzeichen gemessen
  (dort lag bei 20k der AUS-Arm höher: 0.1043 gegen 0.0441). Der ungewichtete Arm
  durchläuft über seine eigene Trajektorie 0.0246 … 0.0925; alle An-Werte außer
  dem 50k-Ausreißer liegen darin. Kein systematischer Effekt → keine
  Ratenänderung (Gegenprobe: §G.2).
- **Drainagedichte Luv/Lee** — die Zielgröße — verschiebt sich in **allen zwölf**
  Zeitschnitten Richtung Luv, ×1.20 … ×1.52 (Seed 99 Jahr 50k: 0.84 → 1.19).

## G) Verworfene Alternativen (mit Messwerten)

### G.1 Rohes Gewicht + neu gerechnete Gates

Rohes `rain` als Gewicht (Stand #9) und der Render-Schwelle den auf Seed 1337
passenden Faktor gegeben (320 · 0.357 ≈ **114** statt 320). Kanalzellen bei
n = 832, Jahr 0, gegen den ungewichteten Referenzarm:

| Seed | ungewichtet | roh + Gate 114 | normiert + Gate 320 |
|-----:|------------:|---------------:|--------------------:|
| 1337 | 17432 | 15062 (**−13.6 %**) | 16329 (−6.3 %) |
|    7 |  7847 |  9298 (**+18.5 %**) |  7605 (−3.1 %) |
|   99 | 10331 | 10927 (**+5.8 %**)  |  9706 (−6.1 %) |

Eine Konstante, drei Inseln, 32 Prozentpunkte Spanne — und die Testkonfigs
(n = 96 … 256, Landmittel 0.563) lägen noch einmal woanders. Verworfen.

### G.2 Erosionsraten nachziehen (#9 §D.2)

- `kRock` 3.5e-5 → 4.9e-5 (×1.4): **wirkungslos**. Kanalzellen 16329/25258/27184
  und Relief 0.5957/0.5312/0.4981 (Jahr 0/5k/20k, n = 832, Seed 1337) sind mit dem
  Default-Lauf identisch — die Konstante steht nur in `transportLimited`, dem
  Nicht-Droplet-Zweig, den die Produktion nicht fährt. Damit ist auch belegt, dass
  #9 §D.2 an der falschen Stellschraube gerechnet hat.
- `outletErode` 3.0e-5 → 4.2e-5 (×1.4): Kanalzellen 16293/24043/26283 statt
  16329/25258/27184 — **weiter weg** vom ungewichteten Referenzarm
  (17432/25555/28386); Relief bei 20k 0.4957 statt 0.4981; Seeanteil
  0.0258/0.0728/0.0991 statt 0.0261/0.0958/0.1036 (ungewichtet
  0.0246/0.0774/0.0925). Der Seeanteil kommt bei 5k näher, bei 20k praktisch
  nicht, bezahlt wird es mit Kanalzellen und Relief. Für eine Ein-Seed-Becken-
  streuung zu teuer → verworfen.

### G.3 Tropfenzahl anheben (#9 §D.3)

`hydraulicPerYear` 2.0 → 2.8 (×1.4): Kanalzellen 16299/25259/27345 — auf dem
Kanalnetz wirkungslos —, `reliefRobust` bei 20k 0.1675 statt 0.1714. Die Prämisse
(21–28 % weniger Land-Tropfen) gilt normiert ohnehin nicht mehr (§E.2), also reine
Zusatz-Erosion ohne Nutzen → verworfen.

### G.4 Feste Normierungskonstante / weltmaßstäblicher Regen

- Normierung auf einen festen Zahlenwert (z. B. 0.40): dieselbe Auflösungs- und
  Seed-Bindung wie G.1, nur unsichtbar gemacht.
- `computeRain` weltmaßstäblich machen (Abtrocknung ∝ `cellSize`) statt zu
  normieren: löst die Auflösungs-, nicht die Seed-Abhängigkeit, und zieht
  Vegetation, Biom-Färbung und Auwald-Klassen mit (alle lesen `rain` roh) — also
  die halbe Klima-Kalibrierung. Bleibt als eigenständige Verbesserung offen
  (ROADMAP).

**Bekannte Kosten der gewählten Lösung:** das Landmittel ist eine GLOBALE Größe,
die je Schritt aus dem Gesamtzustand fällt. Genau diese Kopplung teilt aber die
Drift heraus, die sonst der Kalibrierung davonliefe: das rohe Landmittel steigt
über 50k Jahre um +24 % (0.357 → 0.443), während die Insel abflacht — der
Gesamtabfluss bliebe also nicht einmal innerhalb eines Laufs konstant.
