# Höhenbänder aus Perzentilen — Messreihe (Issue #4)

Grundlage der Kalibrierung in `SimConfig.band*Percentile` und der Wächter in
`SimCoreTests/HeightBandTests.swift`. Alle Läufe auf Produktions-Defaults
(nur `n` variiert), Seed 1337, Schrittweite 500 Jahre. Gemessen wird über die
**Landzellen** (`h > sea`, sea = 0.15).

Messwerkzeug war ein temporärer Test (`HeightDistributionMeasure`), der die
Landhöhen sortiert, Quantile zieht und die Zonenanteile zählt; er ist nach der
Messung wieder entfernt worden — die Werte sind hier und in den Doc-Kommentaren
festgehalten.

> **Stand-Hinweis (Aug 2026, Issue #33):** Alles zum **SCHNEE** in diesem Dokument
> beschreibt den Zustand VOR der Klima-Vertikalen. Seither ist die Schneegrenze
> kein Perzentil mehr, sondern wird aus dem Schneefeld (Massenbilanz aus
> Temperatur und Niederschlag) zurückgerechnet: der Flächenanteil ist gemessen
> statt gesetzt, und die Grenze bleibt als Temperatur an ihrer Höhe stehen,
> statt mit der abflachenden Insel zu sinken. Die Zahlen hier bleiben als
> Vergleichsarm gültig und werden in `docs/climate-snow-measurements.md`
> gegenübergestellt. Vegetation, Fels und Nadelband sind unverändert
> perzentil-gekoppelt.

## 1. Ausgangslage: die absoluten Schwellen lagen außerhalb des Höhenbands

n=832, Seed 1337, Stand vor der Änderung (Landhöhen-Quantile):

| Jahr | p10 | p50 | p88 | p91 | p92 | p95 | p98.5 | p99.5 | p99.9 | max |
|------|-----|-----|-----|-----|-----|-----|-------|-------|-------|-----|
| 0     | 0.2346 | 0.3415 | ~0.478 | 0.4986 | 0.5050 | 0.5279 | 0.5699 | 0.6018 | 0.6395 | 0.7457 |
| 10k   | 0.2502 | 0.3457 | ~0.481 | 0.4954 | 0.5021 | 0.5245 | 0.5645 | 0.5925 | 0.6241 | 0.6724 |
| 20k   | 0.2519 | 0.3518 | ~0.482 | 0.4929 | 0.4992 | 0.5228 | 0.5616 | 0.5876 | 0.6126 | 0.6487 |
| 30k   | 0.2520 | 0.3552 | ~0.481 | 0.4900 | 0.4962 | 0.5196 | 0.5596 | 0.5833 | 0.6026 | 0.6372 |

Die damals absoluten Schwellen, in Perzentile derselben Verteilung übersetzt:

| Schwelle | Bedeutung | Jahr 0 | 30k |
|----------|-----------|--------|-----|
| 0.26 / 0.48 | Nadelbaum-Band (`treeInstanceBuffer`) | p17.1 / p87.8 | p11.4 / p89.1 |
| 0.50 | Vegetation voll geeignet (`updateVegetation`) | p91.2 | p92.6 |
| 0.58 | Beginn Hochlagen-Graurampe (Färbung) | p98.9 | p99.4 |
| 0.60 | Höhenabfall des Grüns (Färbung) | p99.5 | p99.9 |
| 0.68 | Vegetation aus (`updateVegetation`) | p99.99 | p100 |
| 1.05 | **Schnee** (Färbung) | **p100 — 0 Zellen** | **p100 — 0 Zellen** |

Das ist der Befund aus Issue #4: die Schneezone war zu **keinem** Zeitpunkt
besetzt, die Graurampe traf 1.1 % → 0.6 % des Landes, und die
Vegetations-Obergrenze 0.68 lag über 99.99 % aller Landzellen.

## 2. Gewählte Perzentile

Siehe `SimConfig` (Kalibrier-Logbuch am Wert). Kurzfassung:

| Band | Perzentil | Vorher absolut | Absicht |
|------|-----------|----------------|---------|
| `bandVegFullPercentile` | 0.91 | 0.50 (= p91.2) | deckungsgleich → Vegetations-Physik unverschoben |
| `bandVegRampSpanFactor` | 1.0 · (p95 − p50) | 0.68 (= p99.99) | obere Vegetationsgrenze als **Rampenbreite** statt als zweites Perzentil (§5) |
| `bandRockPercentile` | 0.92 | 0.58 (= p98.9) | Fels-Verlauf über die obersten 8 % statt über 1 % |
| `bandRockFullPercentile` | 0.995 | 0.98 (nie erreicht) | volle Ausgrauung real erreichbar |
| `bandSnowPercentile` | 0.985 | 1.05 (nie erreicht) | oberste 1.5 % des Landes |
| `bandSnowFullPercentile` | 0.9985 | 1.13 (nie erreicht) | oberste 0.15 % = die Gipfel |
| `bandConiferLow/HighPercentile` | 0.15 / 0.88 | 0.26 / 0.48 | Nadelbaum-Band wie gehabt |

## 3. Nachher: Bänder und Zonenanteile

n=832, Seed 1337 (`bands` = abgeleitete Höhen, `anteil` = Anteil der Landzellen):

| Jahr | maxH | veg voll…aus | Fels ab…voll | Schnee ab…voll | Schnee-Rampe | voll weiß | Fels-Rampe |
|------|------|--------------|--------------|----------------|--------------|-----------|------------|
| 0   | 0.7457 | 0.4984…0.6848 | 0.5047…0.6019 | 0.5697…0.6302 | 1.51 % | 0.15 % | 8.03 % |
| 10k | 0.6725 | 0.4955…0.6753 | 0.5023…0.5926 | 0.5643…0.6161 | 1.51 % | 0.15 % | 7.97 % |
| 20k | 0.6483 | 0.4930…0.6661 | 0.4994…0.5877 | 0.5614…0.6058 | 1.50 % | 0.15 % | 7.96 % |
| 30k | 0.6361 | 0.4901…0.6563 | 0.4964…0.5833 | 0.5594…0.5980 | 1.49 % | 0.15 % | 7.97 % |

Fels, Schnee und die Zonenanteile sind direkt gemessen. Die obere
Vegetationsgrenze ist aus denselben Messwerten **gerechnet**
(`vegFull + (p95 − p50)`, §5); die Messreihe selbst lief noch mit der
verworfenen Perzentil-Variante. Der Unterschied zur Laufzeit liegt bei der
Histogramm-Bin-Breite (0.000488), weil der Code Bin-Mitten statt sortierter
Quantile nimmt.

Bei n=832 sind 1.5 % ≈ 7 200 Zellen in der Schneerampe und ≈ 720 Zellen voll
weiß — die Zone ist bei der Generierung und nach 30 000 Jahren besetzt
(Abnahmekriterium 2) und ihr Flächenanteil bleibt konstant
(Abnahmekriterium 3).

### Langer Lauf: zieht die Zone beim Abflachen mit?

n=160, Seed 1337, 100 000 Jahre — der Fall, an dem absolute Schwellen scheitern
(die abklingende Hebung aus Issue #13 senkt das Terrain dauerhaft):

| Jahr | maxH | Schnee ab | veg voll | Schnee-Rampe | voll weiß | Fels-Rampe |
|------|------|-----------|----------|--------------|-----------|------------|
| 0    | 0.6864 | 0.5658 | 0.4945 | 1.51 % | 0.15 % | 8.00 % |
| 20k  | 0.6341 | 0.5404 | 0.4715 | 1.52 % | 0.15 % | 7.97 % |
| 40k  | 0.5871 | 0.5233 | 0.4540 | 1.50 % | 0.16 % | 8.03 % |
| 60k  | 0.5807 | 0.5072 | 0.4383 | 1.52 % | 0.15 % | 7.98 % |
| 80k  | 0.5719 | 0.4901 | 0.4251 | 1.52 % | 0.15 % | 8.02 % |
| 100k | 0.5571 | 0.4754 | 0.4129 | 1.48 % | 0.16 % | 8.00 % |

Die Grenzen sinken um 16 % (Schnee) bzw. 17 % (Vegetation) mit dem Gipfel — die
Flächenanteile bleiben. Genau das leisten absolute Schwellen nicht: sie wären
über den Lauf entweder leer geblieben oder (bei tiefer Wahl) zur halben Insel
gewachsen.

## 4. Rückwirkung auf die Physik (Kalibrier-Kaskade)

`veg` geht über `vegDamp` in die Erosion ein, die Vegetations-Höhengrenze ist
also **kein** reiner Render-Wert. Deshalb liegt `bandVegFullPercentile` exakt auf
der alten 0.50, und die Rampenbreite kommt aus der robusten Relief-Spanne (§5).

Direkt gemessen (n=192, Seed 1337, Produktions-Defaults, 20 000 Jahre), drei
Arme: `main` · Rampe aus p99.9 (verworfen) · Rampe aus (p95 − p50) (umgesetzt):

| Kennzahl | main | p99.9-Rampe | Relief-Spanne |
|----------|------|-------------|---------------|
| meanVeg bei der Generierung | 0.309141 | 0.307196 (−0.63 %) | 0.308648 (−0.16 %) |
| Relief nach 20k | 0.479810 | 0.474314 (−1.15 %) | 0.476393 (−0.71 %) |
| maxH nach 20k | 0.629825 | 0.624319 (−0.87 %) | 0.626402 (−0.54 %) |
| robustes Relief nach 20k | 0.156250 | 0.155273 | 0.154785 |
| Landzellen nach 20k | 24464 | 24475 | 24454 |

Die Generierung selbst ist in allen Armen bit-identisch (`meanH`, `relief`,
`maxH` bei Jahr 0 gleich) — Vegetation wirkt erst über die Erosionsschritte.
Der verbleibende Unterschied nach 20 000 Jahren ist mit −0.5 … −0.7 % Relief die
unvermeidliche Folge davon, dass die Vegetationsgrenze jetzt mitwandert.

## 5. Warum die obere Vegetationsgrenze KEIN zweites Perzentil ist

Der erste Entwurf setzte sie auf p99.9. Das ist robust, macht die Rampe aber
schmaler als die alte (0.4984…0.6395 statt 0.50…0.68), weil die Verteilung oben
gestaucht ist: die alte 0.68 liegt bei p99.99, und ein Perzentil dort hinge an
den obersten paar Zellen (bei n=160 an zweien).

Eine schmalere Rampe ist keine Kosmetik. Gemessen kippten damit zwei knapp
gepinnte Wächter aus Issue #12:

- `testEndorheicMechanicsSurviveLithology`: τ=500 max Sprung 0.004287 gegen τ=0
  0.004098 (erwartet: τ=500 kleiner). Auf `main` steht dort 0.004288 / 0.007028.
- `testHardnessContrastHoldsSlopeBreak`: Referenzarm-Signal 1.0816 gegen die
  Schranke |Signal − 1| < 0.08. Auf `main`: 1.0517.

Gegenprobe auf `main` (also ohne dieses Ticket), um Ursache von Zufall zu trennen:

- `vegTimeConstant` 250 → 254 kippt `testEndorheicMechanicsSurviveLithology`
  ebenfalls (τ=500 0.009327 gegen τ=0 0.005066) — die Kennzahl ist ein
  Maximum über 200 Schritte und reagiert auf jede kleine Störung.
- Die Vegetations-Rampe 0.18 → 0.17 (kleinere Störung als die p99.9-Variante)
  hebt das Referenzarm-Signal von 1.0517 auf 1.0791, also direkt an die
  Schranke. Diese Kennzahl hängt **systematisch** an der Rampenbreite: die
  Härteklassen des Lithologie-Felds sind höhenkorreliert, ein steilerer
  Höhenabfall der Vegetation verteilt den Erosionsschutz also mit ihnen.

### Nachtrag: wie empfindlich diese Wächter wirklich sind

Die beiden #11-Beckenwächter (`testBasinLevelIsRateLimited`,
`testDriedBedIsRenderedAsPlaya`) pinnen deshalb jetzt die alten Bänder
(`SimConfig.heightBandsOverride = .legacyAbsolute`) — dieselbe Doktrin, mit der
dort schon `lithologyEnabled = false` steht: sie prüfen die MECHANIK an EINEM
konkreten Becken, nicht die Produktions-Kalibrierung.

Der erste Pin-Versuch notierte die alten Schwellen als Abstand über `sea`. Damit
wurde die Rampenbreite `0.68 − 0.5 = 0.18000000000000005` statt `0.18` — eine
einzige ulp, auf ~9 % der Landzellen, in jedem Zeitschritt. Das genügte:
`testBasinLevelIsRateLimited` sprang auf 0.00319 gegen die 0.002-Schranke, und
die Salzpfannenfläche fiel von 1098 auf 3 Zellen. Ursache ist kein Rauschen,
sondern eine diskrete Kante: Becken wechseln zwischen „gedeckelt" und „offen",
und ein Rollenwechsel setzt den Spiegel per Konstruktion instantan
(`capEndorheicBasins`). `HeightBands` speichert die Rampe deshalb als BREITE
(Literal 0.18), nicht als Differenz zweier Grenzen — nur so reproduziert
`legacyAbsolute` die Vor-#4-Arithmetik exakt.

Deshalb kommt die Breite aus der **robusten Relief-Spanne** `p95 − p50` — dem
Quantilpaar, das schon `landReliefRobust()` benutzt (beide Quantile aus
zehntausenden Zellen). Bei der Generierung sind das 0.1864 gegen die alten 0.18
(+3.6 %), nach 30 000 Jahren 0.1662: die Rampe schrumpft mit der alternden
Landschaft, statt als fixe Höhe stehen zu bleiben. Mit dieser Variante sind
beide #12-Wächter wieder grün (τ=500 0.003246 gegen τ=0 0.006120;
Referenzarm 1.0643, Wirkarm 1.1720).
