# Quereinschnitt der Flussbetten (Issue #108)

Messprotokoll zu der Meldung „gealterte Flussbetten aggradieren aufs
Umgebungsniveau — Wasser liegt ohne Taleinschnitt auf dem Hang".

## A. Die Kennzahl

**Mittlerer Quereinschnitt** = Mittel der Höhen ±2..3 Zellen SENKRECHT zur
D8-Fließrichtung minus der Zellhöhe, über alle Landzellen mit ≥ 1000 Zellen
Einzugsgebiet. Positiv = das Bett liegt tiefer als seine Flanken (Rinne), 0 =
das Bett liegt auf Umgebungsniveau (der gemeldete Fehler). Angaben in **Welt-Y**
(Sim-Höhe × `RenderContract.heightScale` = 24), weil der Nutzer eine sichtbare
Rinne im Mesh meldet, keine Sim-Höhe.

Implementierung: `SimCoreTests/ChannelIncision.swift`
(`ChannelIncision.measure`) — die Formel ist 1:1 die des Issues, das dort als
Godot-Skript stand. Sie liegt in SimCore, weil Agenten die GDExtension nicht
bauen (AGENTS.md § Verifikation über CI) und die Aussage eine Sim-Aussage ist.

Messläufe (alle gegatet, `RS_MEASURE=1`):

```sh
RS_MEASURE=1 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter testCrossIncisionOverTimeDiagnostic
RS_MEASURE=1 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter testIncisionLeverSweepDiagnostic
```

Alle Zahlen: n = 720, Produktions-Config (`hydraulicSkipWaterSpawns`,
`meanderSpatialCutoffIndex`), Seed 1337, 3000 Jahre Einlauf (PR #106),
Schrittweite 1000 Jahre, dieser Linux-Host.

**Die Absolutwerte des Issues sind ~2× größer** (Jahr 0: 0.31 statt 0.155
Welt-Y). Das ist die dokumentierte Plattform-Streuung: Bit-Gleichheit gilt nur
pro Maschine (System-libm, AGENTS.md), und in einem chaotischen System wächst
das zu einer anderen Welt-Realisierung. Der VERLAUF ist identisch reproduziert —
Kollaps in den ersten 25k Jahren um ~70 %, danach flach.

## B. Diagnose: wer hält den Einschnitt flach?

Ein Arm je abgeschaltetem/verstelltem Pass, 25k Jahre, beide Hebel dieser Runde
schon an (Welt-Y):

| Arm | 0k | 5k | 10k | 15k | 20k | 25k |
| --- | --- | --- | --- | --- | --- | --- |
| Referenz | 0.458 | 0.209 | 0.133 | 0.098 | 0.088 | 0.081 |
| `hillDiffusion = 0` | 0.800 | 0.543 | 0.404 | 0.381 | 0.304 | **0.275** |
| `outletErode` ×3 | 0.651 | 0.347 | 0.245 | 0.191 | 0.161 | **0.152** |
| `puddleFillYears = 0` | 0.476 | 0.258 | 0.170 | 0.142 | 0.127 | **0.110** |
| `meanderEnabled = false` | 0.401 | 0.243 | 0.184 | 0.138 | 0.110 | 0.104 |
| `braidingEnabled = false` | 0.440 | 0.200 | 0.139 | 0.108 | 0.087 | 0.077 |
| `erodeRadius = 1` | 0.636 | 0.236 | 0.136 | 0.097 | 0.079 | 0.070 |
| `minSlope = 0.002` | 0.475 | 0.206 | 0.123 | 0.081 | 0.074 | 0.069 |

Befunde:

1. **Die Hangdiffusion ist der Haupttäter** (×3.4). Sie sieht die Rinne als
   Krümmung und füllt sie — genau der Prozess, den im echten Kanal die Strömung
   wieder abräumt.
2. Die **Auslass-Inzision** ist der zweitgrößte Hebel (×1.9), aber als
   Ratenänderung eine Kalibrier-Kaskade („6e-5 überkarvt bei 100k",
   `SimConfig.outletErode`) — nicht angefasst.
3. Die **Pfützen-Verlandung** trägt ein gutes Drittel bei (×1.36).
4. **Braiding ist unschuldig** (die Bänke sind kein Netto-Auffüller), und die im
   Issue genannte Alternative **`minSlope` wasserabhängig ist wirkungslos** —
   0.002 statt 0.01 macht den Einschnitt sogar leicht flacher (0.069). Sie ist
   damit gemessen verworfen.

## C. Die ausgelieferten Hebel

100k Jahre, je Arm eine Zeile (Welt-Y), `grat` = `ridgeCurvature()`
(Alterungs-Signal, „betragsmäßig kleiner = runder = älter"):

| Arm | 0k | 25k | 50k | 75k | 100k | grat | relief | maxH |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| beide aus (= vor #108) | 0.155 | 0.045 | 0.050 | 0.067 | 0.059 | −0.0414 | 0.429 | 0.579 |
| nur Diffusions-Schutz | 0.306 | 0.081 | 0.078 | 0.085 | 0.092 | −0.0494 | 0.429 | 0.579 |
| nur Depositions-Dämpfer | 0.170 | 0.051 | 0.054 | 0.062 | 0.067 | −0.0417 | 0.429 | 0.579 |
| **beide an (= Produktion)** | **0.458** | **0.081** | **0.108** | **0.125** | **0.086** | −0.0499 | 0.429 | 0.579 |
| + Pfützen-Ausschluss (geparkt) | 0.553 | 0.110 | 0.160 | 0.147 | 0.158 | −0.0380 | 0.429 | 0.579 |

Die beiden Hebel sind **überadditiv**: einzeln +0.033 und +0.008 bei 100k,
zusammen +0.027 … +0.058 über das Fenster (25k ×1.8, 50k ×2.2, 75k ×1.9,
100k ×1.5, Jahr 0 ×3.0). Relief und maxH bleiben unverändert — die Hebel
verschieben die FORM der Täler, nicht die Höhenstatistik.

`grat` wandert von −0.0414 auf −0.0499: die Grate bleiben etwas schärfer, weil
ein geschütztes Kanalnetz auch die Hänge daran länger steil hält. Der Wert liegt
weiter in derselben Größenordnung wie die in PR #106 dokumentierten ≈ −0.03 …
−0.05 nach dem Einschwingen; mit dem geparkten dritten Hebel wäre er sogar
runder als vorher (−0.0380).

### Schwelle und Stärke des Kanal-Schutzes

25k Jahre, `channelFlowFullCells = 10 × MinCells`, `grat320` =
`ridgeCurvature(maxAreaCells: 320)` (Hang-Proxy):

| damp | MinCells | 25k | grat | grat320 |
| --- | --- | --- | --- | --- |
| aus | — | 0.051 | −0.0438 | −0.0058 |
| 0.15 | 1000 | 0.069 | −0.0536 | −0.0086 |
| **0.15** | **320** | **0.081** | −0.0578 | −0.0099 |
| 0.15 | 100 | 0.091 | −0.0633 | −0.0128 |
| 0.15 | 40 | 0.081 | −0.0654 | −0.0126 |
| 0.05 | 320 | 0.094 | −0.0599 | −0.0096 |
| 0.05 | 100 | 0.098 | −0.0632 | −0.0122 |
| 0.05 | 40 | 0.100 | −0.0701 | −0.0145 |

Mehr Schutz kauft ab 320 Zellen fast nichts mehr, kostet aber Alterung (beide
Krümmungs-Signale wachsen betragsmäßig): 320 / 0.15 ist der Arbeitspunkt.

## D. Gegenproben (Kalibrier-Kaskade)

Die komplette SimCore-Pflichtsuite ist grün (328 Tests). Die im Issue verlangten
Wächter im Einzelnen:

| Wächter | Ergebnis |
| --- | --- |
| `testBraidingBuildsBars` | grün, Bank-Fläche an 234 / aus 121 (Seeds 8:4) — **besser** als der auf `main` notierte Stand 132/119 bei 8:2 |
| `testChannelBedSurvivesDroplets` | grün, Bett-Tiefe +0.0247 (vorher +0.0156 notiert), verlandete Betten 3.6 % gegen 4.9 % |
| `LongRunCollapse` | grün |
| `DtInvariance` | grün (nur mit dem geparkten Pfützen-Hebel riss sie, s. §E) |
| Playa-Wächter (#11) | grün |
| `Glacier.testNoFluvialErosionUnderIce*` | grün, nach einer Korrektur AM TEST (s. §E) |
| `WaterRendererTests` Band↔Raster | grün, Schranke von 0.02 auf 0.03 angehoben (s. §E) |

## E. Was NICHT ausgeliefert wird, und die zwei Test-Korrekturen

**Pfützen-Ausschluss in Flussbetten** (`SimConfig.puddleFillSkipsFlowCells`,
Default `false`): gemessen der stärkste Hebel (100k 0.086 → 0.158), aber die
Pfützen im Bett bleiben dann STEHEN. Stehendes Wasser im Bett ist genau die
Wassersäule, an der die Render-Übergabe Band ↔ Raster hängt
(`WaterRender.lakeRawWetDepth`, Issue #34):

- `WaterRendererTests.testBuiltBandsAndRasterHandOverWithoutGapOrDoubleWater`:
  Doppelmalungs-Kennzahl 0.024 → **0.243** (Schranke 0.03),
- `DtInvariance.testSameTimeSameResultAcrossStepSizes`: Seeanteil dt 10 gegen
  dt 2000 0.0040 gegen 0.107 (Schranke 0.8 relative Abweichung),
- `DtInvariance.testDrainageIsFramerateIndependentWithoutDroplets`: 0.30 statt
  ≤ 0.10.

Der Hebel taugt also, braucht aber vorher einen Pass, der die Pits im Bett
ENTWÄSSERT statt sie nur nicht mehr zu füllen. Offener Punkt.

**`Glacier.quietCfg()` schaltet jetzt auch `waveRelax = 0`.** `wavePass` ist kein
fluvialer Pass und deshalb nicht `underIce`-gegatet (wie die Hangdiffusion, die
`quietCfg` aus demselben Grund längst abschaltet) — er schiebt aber Material vom
NACHBARN auf die Eiszelle. Mit dem Depositions-Dämpfer liegt das Sediment ein
Stück weiter flussabwärts, und im Wellenband trafen 2 vergletscherte Zellen
(h − sea = 0.044/0.047 < `waveBand` 0.06, Δh 9e-6 und 2e-4). Gegenprobe
gemessen: mit `waveRelax = 0` sind es 0 Zellen, mit abgeschaltetem Dämpfer
ebenfalls 0 — der Wächter hat den Wellenpass gemessen, nicht das Gate.

**Die Doppelmalungs-Schranke steht auf 0.03 statt 0.02.** Die beiden Regeln der
Übergabe lesen die Wassersäule unterschiedlich: der Raster-Pfad ZELLWEISE
(`rawWet[k]`), der Band-Fade BILINEAR am Stützpunkt (bewusst so, s. Kommentar an
`lakeHandoverFade`). Mit den tieferen Betten ist der Pond-Gradient über eine
Zelle steiler, und der Rest wuchs auf gemessen 0.0244 — ein einzelner Stützpunkt
mit 2,4 % Deckkraft. Wie ein echter Bruch aussieht, steht oben: 0.243.

## F. Abnahme

Die Kennzahl ist die halbe Abnahme; die andere Hälfte ist der Blick ins Fenster
(Issue #108: „die Läufe müssen in einer sichtbaren Boden-Rinne liegen, Krümmung
im Mesh, nicht nur Wasser-Shader"). Auf diesem Host ist kein Godot-Fenster
verfügbar (Agenten bauen die GDExtension nicht, AGENTS.md), die A/B-Screenshots
macht deshalb der Nutzer:

```sh
RS_STEP=100000 RS_QUALITY=quality RS_SHOT=/tmp/nach.png "$GODOT" --path game --maximized
```

Zu prüfen ist die BODEN-Geometrie unter den Läufen (Wasser-Shader ausblenden
hilft: `RS_FLATTEN` nicht, sondern schlicht flach über das Tal blicken) und ob
die Rinne im 720er-Mesh sichtbar ist — mit `RS_QUALITY=balanced` als Gegenprobe,
dass die Rinne nicht am Render-Grid hängt.
