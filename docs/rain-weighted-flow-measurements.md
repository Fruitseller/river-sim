# Niederschlagsgewichteter Abfluss — Messung an/aus (Issue #9)

Der Schalter `SimConfig.rainWeightedFlow` (Default **aus**) gewichtet die
Abfluss-Akkumulation beider Netze mit dem Niederschlagsfeld und startet die
Erosions-Tropfen niederschlagsgewichtet:

- **aus** — `area`/`areaMFD` akkumulieren reine Zellfläche (`cellArea` je Zelle),
  Tropfen starten gleichverteilt. Das ist der Stand vor Issue #9.
- **an** — die Akkumulation startet je Zelle mit `cellArea · rain[k]`
  (`Terrain.seedFlowAccumulator`, dieselbe Regel für D8 **und** MFD; die
  Rollentrennung bleibt: `area` erodiert, `areaMFD` rendert/braided), und die
  Tropfen-Startpunkte werden per Ablehnungs-Stichprobe mit `rain` gewichtet
  (`Hydraulic.spawnPosition`).

Die **Rekalibrierung ist bewusst NICHT Teil dieser Messung** (Issue #10) — hier
wird nur der rohe Effekt festgehalten. Ohne Normierung (kein `rain / mittleres
rain`) fällt der Gesamtabfluss auf das Landmittel des Regens (~0.40 … 0.48),
alle in ZELLEN kalibrierten Gates greifen also später. Das ist der dominierende
Effekt in den Tabellen unten und muss beim Lesen mitgedacht werden.

## Methode

Alle Zahlen aus `SimCoreTests/RainWeightedFlow.swift` (Release-Lauf), Seed 1337,
sonst Default-`SimConfig`:

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
