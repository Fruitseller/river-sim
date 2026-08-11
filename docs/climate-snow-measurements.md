# Klima-Vertikale: Messreihen (Issue #33)

Rohdaten zur Kalibrierung von Temperaturfeld und Schneedecke. Modellherleitung
und Primärquellen: `docs/research-climate-cryosphere.md`. Kalibrier-Logbuch:
`SimConfig.climateEnabled` ff. Wächter: `SimCoreTests/ClimateSnow.swift` und
`SimCoreTests/HeightBandTests.swift`.

Alle Läufe Produktionspfad (`SimConfig()`-Defaults, nur `n` gesenkt, wo die
Laufzeit es verlangt), Seed 1337, `dt = 500`.

---

## 1. Die Kalibrier-Entscheidung: Höheneinheit → Temperatur

Es gibt keinen vertikalen Meter-Maßstab (`h` ist normiert). Der Gradient hat
deshalb zwei Freiheitsgrade, und beide sind gesetzt, nicht gemessen:

```
Γ  = 6,5 K/km (ICAO-Standardatmosphäre) × H_ref,  H_ref = 4000 m  →  Γ = 26 K/Einheit
T₀ = 11 °C auf Meereshöhe
⇒  0-°C-Isotherme bei  h = sea + T₀/Γ = 0.15 + 11/26 = 0.5730
```

Anschlusspunkt an den alten Perzentil-Schnee: `bandSnowPercentile` = p98.5 lag
bei der Generierung auf **0.5699** (n=832, Seed 1337,
`docs/height-band-measurements.md`). Die Isotherme trifft ihn auf 0.003 genau —
der Look bleibt beim Umstieg erhalten, aber ab dem ersten Schritt bewegt das
Klima die Grenze statt eines Flächenanteils.

Höhen der Insel unter dieser Skala (n=832, Seed 1337):

| | Jahr 0 | 10k | 30k |
| --- | --- | --- | --- |
| `maxH` | 0.7457 | 0.6726 | 0.6359 |
| Gipfelhöhe über See | 2383 m | 2290 m | 2244 m |
| Temperatur am Gipfel | −4,49 °C | −2,59 °C | −1,63 °C |

Die verworfenen Maßstäbe (H_ref = 2000 / 8000 m) und warum, stehen bei
`SimConfig.climateLapseRate`.

---

## 2. Sweep `snowMeltPerKYear` — die Breite des Übergangs

n=192, Seed 1337. „Saumbreite" = Höhenspanne, über die der Gleichgewichts-Vorrat
`S* = a/μ` von der Rampen- auf die Sichtbarkeitsschwelle fällt (Faktor 19),
gerechnet als `18/(c·τ₀·Γ)`. Landanteile: sichtbar = Deckung > 0.05, Rampe =
> `snowBandCoverStart` (0.5), voll = ≥ `snowBandCoverFull`.
Wächter/Quelle: `ClimateSnow.testMeltRateSweepDiagnostic`.

| c = `snowMeltPerKYear` | Saumbreite [Höheneinheiten] | J0 sichtbar / Rampe / voll | J20k sichtbar / Rampe / voll | J20k `snowStart` |
| --- | --- | --- | --- | --- |
| 0.02 | 0.0692 | 9.08 % / 1.65 % / 0.74 % | 6.42 % / 0.72 % / 0.33 % | 0.5638 |
| **0.06** | **0.0231** | **4.98 % / 1.38 % / 0.73 %** | **3.25 % / 0.54 % / 0.33 %** | **0.5692** |
| 0.20 | 0.0069 | 2.35 % / 1.30 % / 0.73 % | 1.21 % / 0.49 % / 0.33 % | 0.5716 |

**Gewählt c = 0.06.** Die substanzielle Schneefläche (1.38 %) trifft die alte
Perzentil-Kalibrierung (1.5 %) fast auf den Punkt. 0.02 verwäscht den Saum über
9 % des Landes — ein Schleier statt Gipfelschnee. 0.20 drückt ihn auf 0.007
Höheneinheiten, also unter die Höhendifferenz einer einzelnen Zelle an mittleren
Hängen: eine harte, aliasende Kante, die beim Altern flimmern würde.

Bemerkenswert an der Tabelle: `snowStart` ist über den Sweep praktisch konstant
(0.564 … 0.572). Der Regler verschiebt den SAUM, nicht die Grenze — genau die
Rollentrennung, die man von einem Übergangsbreiten-Parameter erwartet.

---

## 3. Produktionsauflösung: die Zone folgt dem Klima

n=832, Seed 1337 (`ClimateSnow.testProductionResolutionDiagnostic`).
Landanteile wie oben; `Smax` = größter Schneevorrat auf Land.

| | sichtbar | Rampe | voll | `snowStart` | `snowFull` | `maxH` | T(Gipfel) | `Smax` |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Jahr 0 | 3.33 % | 1.39 % | 0.02 % | 0.5721 | 0.6683 | 0.7457 | −4,49 °C | 0.660 |
| 10k | 3.61 % | 1.15 % | 0.02 % | 0.5716 | 0.6424 | 0.6726 | −2,59 °C | 0.455 |
| 30k | 3.21 % | 0.90 % | 0.03 % | 0.5716 | 0.6161 | 0.6359 | −1,63 °C | 0.438 |

**Das ist die Kernaussage des Tickets, in zwei Zahlenspalten:**

* `snowStart` **steht** (0.5721 → 0.5716, also 0.0005 = eine Histogramm-Bin-Breite)
  — die Grenze ist eine Temperatur, keine Verteilungs-Eigenschaft.
* Der **Flächenanteil sinkt** (1.39 % → 0.90 %, −35 %) — weil die Insel unter der
  Isotherme abgetragen wird.

Vor #33 war es genau umgekehrt: der Anteil lag per Konstruktion konstant bei
1.51 % → 1.49 %, und `snowStart` wanderte mit dem sinkenden Terrain nach unten
(n=160, 60k Jahre: 0.5658 → 0.5072, `docs/height-band-measurements.md`).

**`snowBandCoverFull` von 0.85 auf 0.8 gesenkt.** Mit 0.85 lag der
Voll-Schnee-Anteil in Produktionsauflösung schon bei der Generierung unter
0.005 % des Landes, und `snowFull` (0.7005) rutschte nach 30k Jahren ÜBER den
Gipfel (0.6361 gegen maxH 0.6359) — das Band war dann leer. Mit 0.8
(`S ≥ 4·snowCoverRef = 0.4`) bleibt `snowFull` über den ganzen Lauf unter dem
Gipfel (0.6683 / 0.6424 / 0.6161 gegen maxH 0.7457 / 0.6726 / 0.6359). Dass das
Voll-Band mit der alternden Insel trotzdem ausdünnt (`Smax` 0.660 → 0.438), ist
gewollt und nicht wegkalibrierbar: das Klima trägt auf 2244 m weniger
Dauerschnee als auf 2383 m.

Das Voll-Band ist seit #33 ohnehin nur noch ein BAND-Parameter — die Färbung
liest die Deckung je Zelle, nicht `snowAmount`.

---

## 4. dt-Invarianz

`ClimateSnow.testSnowBalanceIsDtInvariant`: dieselben 4000 Jahre einmal in EINEM
Schritt und einmal in 400 Schritten à 10 Jahren, gegen ein eingefrorenes
Höhenfeld (n=128, Seed 1337) — so misst der Test die Bilanz und nicht die
Operator-Splitting-Drift des vollen `step()`.

Größte Abweichung über alle Zellen: **9,99e-16** bei einem Vorrat bis 0.808 —
also gut eine ULP. Das ist Gleitkomma-Rundung über 400 Teilschritte, keine
Modell-Abweichung: die Relaxationsform teleskopiert exakt
(`e^(−μdt)^N = e^(−μ·N·dt)`, und `S*` hängt nur an T und rain, nicht an dt).
Der Wächter schrankt auf 1e-12.

**Durch den VOLLEN Zeitschritt** (`testSnowThroughFullStepsIsDtInvariant`,
n=192, Seed 1337, 20.000 Jahre, Servo und Hebungs-Sockel aus wie in
`DtInvariance`):

| dt | mittlerer Vorrat über Land | Rampen-Anteil | `snowStart` |
| --- | --- | --- | --- |
| 50 | 0.00247 | 0.50 % | 0.5702 |
| 500 | 0.00265 | 0.52 % | 0.5697 |
| 2000 | 0.00243 | 0.50 % | 0.5702 |

Spanne 8,3 % (Vorrat) bzw. 3,8 % (Fläche) gegen die 20-%-Schranke; die Grenze
selbst bewegt sich um 0.0005, also eine Histogramm-Bin-Breite. Der Rest ist
NICHT der Klimapass, sondern die bekannte Operator-Splitting-Drift des
Tropfen-Passes, die über dieselben Schrittweiten schon das Relief um 9,8 %
verschiebt (`DtInvariance`-Klassendoku) — der Schnee liest die Höhe und erbt
sie.

Zum Vergleich die verworfene klassische degree-day-Form
`S ← max(0, S + (a − m)·dt)`: sie bricht am Ausapern, weil das `max` in einem
großen Schritt Schmelzguthaben verwirft, das dieselbe Zeit in kleinen Schritten
noch gegen frischen Schneefall verrechnet hätte. Dieselbe Fehlerklasse, die
Issue #2 bei der Tropfenzahl (`max(1, …)`) behoben hat.

`dt = 0` ist ein exakter No-Op auf der Bilanz (`e⁰ = 1`) — darauf verlässt sich
der Sculpt-Pfad in `SimNode.recomputeFlow`, der nur die Temperatur nachziehen
will (`ClimateSnow.testZeroStepLeavesTheBalanceUntouched`).

---

## 5. Orographie: was eine Höhenschwelle nicht kann

`ClimateSnow.testAccumulationCarriesTheOrographicSignal` (n=256, Seed 1337):
das Höhenband von T = +1 °C bis 0.06 Einheiten darüber, in Bins von 0.005
Höheneinheiten zerlegt und je Bin nach Regen-Gewicht (#10, Landmittel exakt 1.0)
in nass (> 1.1) und trocken (< 0.9) geteilt. Nach Höhe GEPAART und geometrisch
gepoolt wie das Hangknick-Signal in `Lithology` — ungepaart wäre die Kennzahl
konfundiert, weil der Vorrat über das Band um mehr als eine Größenordnung fällt
und nass/trocken nicht gleich über die Höhe verteilt sind.

Gemessen im Band 0.535 … 0.595 über 8 gepaarte Bins: **Faktor 2.008** (nass
gegen trocken). Auf gleicher Höhe trägt die Luvseite also gut doppelt so viel
Schnee wie der Regenschatten. Genau das ist der qualitative Unterschied zum
Perzentil-Schnee: eine Höhenschwelle kann per Konstruktion kein horizontales
Signal tragen. Die Zusicherung des Wächters liegt bei > 1.15 — bewusst weit
unter dem Messwert, weil die Kennzahl an der Regenverteilung dieses Seeds hängt.

---

## 6. Abgeschaltet ist bit-identisch

`ClimateSnow.testDisabledClimateIsBitIdenticalPhysics` (n=128, Seed 1337):
`climateEnabled = false` gegen `= true`, verglichen bei der Generierung und nach
3000 Jahren über `h`, `rock`, `sed`, `veg`, `vegClass`, `hf`, `area`,
`streamMap` — alle bit-gleich, weil das Klima in keinen Pass koppelt. Auch die
Nicht-Schnee-Bänder (`vegFull`, `vegRamp`, `rockStart`, `rockFull`,
`coniferLow/High`) sind identisch: die Umstellung rührt ausschließlich an
`snowStart`/`snowFull`.

Abgeschaltet sind `temperature`, `snow` und `ice` **leer** (nicht 0-gefüllt), und
`Terrain.snowCover(k)` liefert exakt `HeightBands.snowAmount(h[k])`
(`testDisabledClimateFallsBackToThePercentileBands`) — der „Faktor 1.0"-Fall des
Tickets, dasselbe Muster wie `lithologyEnabled` und `rainWeightedFlow`.

---

## 7. Kosten

`ClimateSnow.testClimatePassCostDiagnostic`, n=832, Mittel über 200 Durchläufe.

| Pass | vorher | nachher |
| --- | --- | --- |
| `updateClimate` (Temperatur + Bilanz, parallel) | — | **0,96 ms** |
| `updateHeightBands` (inkl. Schnee-Zählpass) | 1,38 ms (Issue #4) | **2,31 ms** |

Unterm Strich **+1,9 ms je `step()`** in Produktionsauflösung, also rund 11 %
eines 16,7-ms-Frames im Echtzeit-Zeitraffer. Zum Vergleich: Issue #4 hat mit
den Höhenbändern 1,4 ms (8 %) gekostet.

Der erste Wert war anfangs **3,12 ms** — dominiert von einem `exp` je Zelle.
Der Pass überspringt jetzt Zellen ohne Zufuhr UND ohne Vorrat (`a == 0 &&
S == 0`), für die die Relaxation ohnehin exakt 0 liefert. Das ist
BIT-IDENTISCH, keine Näherung, und trifft die große Mehrheit der Zellen: das
ganze Meer und alles Land unter der Regen/Schnee-Grenze (h < 0.458 bei
Produktionswerten). Beleg, dass nichts kippt: sämtliche Messwerte in §2/§3
sind vor und nach der Abkürzung identisch.

Der zweite Posten ist der Schnee-Zählpass in `updateHeightBands`
(`Terrain.snowAreaFractions`, ~0,9 ms) — ein SEQUENZIELLER Integer-Zählpass über
alle Zellen. Sequenziell, weil das Ergebnis bit-genau reproduzierbar sein muss;
Integer-Summen ließen sich zwar auch parallel exakt bilden (Teilsummen je
Chunk), das wäre aber dieselbe Optimierung, die bei `landHeightQuantiles` schon
als offener Punkt notiert ist (Histogramm-Fill je Thread) — sie gehört gemeinsam
gemacht, nicht halb.

---

## 8. Offene Punkte

* **Kein Multi-Seed.** Alle Zahlen hier stammen von Seed 1337. Die Kalibrierung
  hängt an der Höhenverteilung dieser Insel; Seeds mit deutlich flacherem Relief
  (Seed 7 ist als „weiches Rollhügel-Terrain" dokumentiert,
  `SimConfig.upliftDecayStartPer100y`) haben womöglich gar keinen Schnee. Das
  wäre kein Fehler — genau dafür ist die Grenze eine Temperatur —, ist aber nicht
  gemessen.
* **Kein visueller Abgleich.** Der Extension-Build kostet auf Linux 21–27 min;
  die Schnee-Färbung ist headless über `snowCover` gepinnt
  (`testSnowCoverIsTheSingleSourceForColouring`), aber nicht am Bild geprüft.
* **Für #35 relevant:** die Insel ist mit T(Gipfel) = −4,5 °C (Jahr 0) am kalten
  Ende nur knapp unter Frost, und nach 30k Jahren nur noch −1,6 °C. Ein
  Eisfeld, das daraus wächst, bliebe klein. Wenn #35 sichtbare Trogtäler will,
  ist `climateSeaLevelTemp` der Regler dafür (eine Kaltzeit senkt T₀, nicht Γ) —
  und das ist dann eine eigene, eigens zu vermessende Kalibrier-Entscheidung.
* **Kein Jahresgang.** Der Gradfaktor absorbiert Tageszahl und Saisonalität
  (`docs/research-climate-cryosphere.md` §2.2). Ein echter Jahresgang stünde im
  ROADMAP-Backlog („Klima-Jahreszeiten") und würde diese Kalibrierung neu
  aufmachen.
