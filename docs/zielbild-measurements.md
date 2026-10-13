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
- **Korridore:** 4er-Zusammenhangskomponenten des Tieflands. „Flecken" zählt
  die ab 0,25 % der Landzellen; „Land in 4 größten" ist der Landanteil der
  vier größten. Das ist die Lesart von „≥ 20 % Tiefland in ≤ 4 Korridoren"
  (Punkt 1): bei einer Schwelle von 0,003 Höhe je Zelle zählt jede Talsohle
  im Hügelland als eigener Fleck, „höchstens vier Flecken" wäre damit eine
  Aussage über Talsohlen, nicht über Korridore.
- **Küsten-Reichweite:** größte Küstendistanz (4er-BFS) in einem der vier
  größten Korridore, sofern er die Küste berührt, geteilt durch die größte
  Küstendistanz der Insel. 1,00 = reicht bis zum küstenfernsten Punkt.
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
- **Wellenlänge / Amplitude:** Wendepunkte = Vorzeichenwechsel der über ±1
  Kanalbreite (mindestens ±2 Knoten) geglätteten Krümmung (bis zur Ist-Messung
  vor Paket A: ±2 Knoten); Wellenlänge = Luftlinie über zwei Halbwellen,
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

Spalte „Land in 4 größten" und „Küsten-Reichweite" nach der Definition oben
(nachgemessen auf `origin/main`, Jahr 2000 und 20.000; die erste Fassung
dieser Tabelle zählte die Reichweite über alle Flecken):

| Seed | Jahr | Tiefland | Flecken ≥ 0,25 % | Land in 4 größten | Küsten-Reichweite | Land am Rand | min. Randabstand | Eiszellen | Zerklüftung Tiefland |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1337 | 2000 | 35.5 % | 24 | 13 % | 0.00 | 659 | 0 | 11409 | 0.00361 |
| 1337 | 20000 | 48.0 % | 17 | 23 % | 0.51 | 725 | 0 | 5214 | 0.00211 |
| 1337 | 100000 | 65.9 % | 10 | – | – | 780 | 0 | 931 | 0.00124 |
| 42 | 2000 | 43.3 % | 12 | 32 % | 0.00 | 0 | 44 | 776 | 0.00304 |
| 42 | 20000 | 50.5 % | 13 | 41 % | 0.39 | 0 | 45 | 136 | 0.00200 |
| 42 | 100000 | 60.5 % | 8 | – | – | 0 | 44 | 0 | 0.00138 |
| 20 | 2000 | 42.7 % | 14 | 26 % | 0.00 | 280 | 0 | 11645 | 0.00298 |
| 20 | 20000 | 53.3 % | 14 | 40 % | 0.76 | 288 | 0 | 5782 | 0.00180 |
| 20 | 100000 | 68.2 % | 7 | – | – | 351 | 0 | 1469 | 0.00112 |

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
  Es zerfällt aber in 12–24 Flecken; die vier größten tragen in Jahr 2000
  nur 13–32 % des Landes, und keiner davon berührt die Küste. Paket A muss
  das Tiefland also zusammenhängend machen, nicht vermehren.
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

### Laufzeit-Anteil des Mäanders (Ist, für Abnahmepunkt 48)

`simperf --repeat 3` (Produktion, Seed 1337, M4 Max, 2026-10-11): 47,0 ms je
Schritt (Minimum aus 3 Blöcken, 48,2 / 47,0 / 47,5). `migrateMeander` 3,15 ms
(6,6 %), `meanderStamp` 1,75 ms (3,7 %), zusammen 10,3 %. Die Perf-Welt trägt
937 Läufe mit 19.453 Knoten und 3907 Altarme.

## Nach Paket A (Großform, `rangeLandform`)

Gleiche Messung, Großform aus `RangeSkeleton` (`SimCore/Sources/SimCore/Landform.swift`):

| Seed | Jahr | Tiefland | Flecken ≥ 0,25 % | Land in 4 größten | Küsten-Reichweite | Land am Rand | min. Randabstand | Eiszellen | Zerklüftung Tiefland |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1337 | 2000 | 60.3 % | 13 | 48 % | 1.00 | 0 | 50 | 16319 | 0.00179 |
| 1337 | 20000 | 65.4 % | 4 | 63 % | 0.97 | 0 | 52 | 4543 | 0.00136 |
| 1337 | 100000 | 74.2 % | 3 | 73 % | 1.00 | 0 | 56 | 1008 | 0.00126 |
| 42 | 2000 | 66.0 % | 5 | 62 % | 1.00 | 0 | 82 | 6199 | 0.00183 |
| 42 | 20000 | 68.0 % | 6 | 64 % | 1.00 | 0 | 83 | 965 | 0.00156 |
| 42 | 100000 | 71.0 % | 1 | 70 % | 1.00 | 0 | 85 | 529 | 0.00150 |
| 20 | 2000 | 57.6 % | 6 | 52 % | 1.00 | 0 | 65 | 9613 | 0.00166 |
| 20 | 20000 | 59.9 % | 11 | 51 % | 1.00 | 0 | 66 | 2263 | 0.00141 |
| 20 | 100000 | 65.3 % | 3 | 64 % | 0.99 | 0 | 69 | 398 | 0.00136 |

Abnahmepunkte 1–4 auf allen drei Seeds erfüllt; Wächter
`ZielbildLandformTests` (Pflichtsuite, Jahre 2000 und 20.000), `LongRunCollapse`
grün. Die Zerklüftung des Tieflands sinkt um 40–50 % (Gegenprobe für Punkt 14
in Paket B: Referenz sind ab jetzt diese Werte).

Mäander-Kennzahlen unverändert schlecht (Paket B steht aus): λ/Breite 0,8–4,2,
Asymmetrie 0,6–0,8, 900–1800 Cutoffs je 20.000 Jahre.

Verworfen beim Kalibrieren (Karten über `testZielbildMapDiagnostic`):

- **Ebene direkt hinter dem Gebirge** (Hügel nur bis 2,4 R): die Ebene ist ein
  Kegel, von dem viele kleine Läufe parallel zur Küste rinnen; die Täler
  sammeln nichts. Hügelland bis 3,6 R, die Täler schneiden hinein.
- **Kamm mit Massiv-Faktor 0,65–1,0**: ein Hochplateau über der
  Frostgrenze (h ≈ 0,6), 29.500 Eiszellen auf Seed 1337 gegen 11.400 vorher.
  0,40–0,90 lässt die Gipfel variieren.
- **Vorberge auf 2,5-facher Frequenz** (eigene `ridged01`-Ebene): mehr kleine
  flache Talsohlen, 14–25 statt 5–12 Flecken in Jahr 2000.
- **Randabstand in absoluten Zellen** (24 + 70): fraß auf den Testgittern
  (n = 96…256) einen Großteil des Landes. Jetzt 3,3 % + 10 % von `n`.
- **Ellipse über die kurze Achse normiert** (alter Stand): bei `aRatio` 0,55
  ragte die lange Halbachse bis 1,8 Gitter-Halbbreiten, der Randabstand
  schnitt die Insel zu steilen, geraden Küsten.

### Offene Befunde aus der Test-Kaskade

- **Eis hängt an der Schrittweite, schon vor #174.** Produktion, Jahr 20.000,
  Eismasse bei dt 100 gegen 1000 auf `origin/main`: 77,4 / 128,1 (1337),
  0,29 / 1,04 (42), 117,1 / 179,5 (20); mit der neuen Form 49,6 / 126,3,
  65,3 / 31,5, 162,3 / 57,1. Der Wächter `testIceIsFramerateIndependent`
  (n = 256) lag auf der alten Welt zufällig in einem ruhigen Bereich.
- **Stream-Map trackt die großen Läufe schlechter.** `testStreamMapMarksAndPersists`
  (n = 256, Zellgröße der Suite) misst auf der neuen Form einen Recall von
  0,15 statt > 0,40: die Tropfen folgen den großen D8-Läufen in der flachen
  Ebene seltener. Das betrifft Abnahmepunkt 21 (Hauptlauf ohne Lücke) und ist
  in Paket C auf dem Produktionsgitter nachzumessen.

### Laufzeit und Determinismus nach Paket A

`simperf` (Produktion, Seed 1337, M4 Max, 2026-10-11), alt (`origin/main`
`55323b5`) und neu abwechselnd, je `--repeat 3`: alt 48,5 / 48,9 / 49,0 ms,
neu 43,8 / 44,1 / 44,3 ms je Schritt (Median 48,9 → 44,1). Keine Optimierung,
sondern eine andere Welt (weniger Seen und Läufe). Einlauf samt Generierung
5,2 / 5,3 s → 4,9 / 4,8 s. `simperf --hash` zweimal `ba89c2b11150f5a5`
(Punkt 49; der Wert gilt nur auf dieser Maschine).

### Wald auf der neuen Großform (Abnahmepunkt 40)

`testCanopyCoverageDiagnostic`, Wald in % des Landes, Schwellen #168
(0,35/0,55) auf der Großform: 1337 16,4 / 15,4 / 14,4, 42 27,5 / 23,5 / 15,9,
20 24,4 / 18,6 / 13,6 (Jahr 2000 / 20.000 / 100.000; mit Paket D gemessen,
ohne D 28,6 auf Seed 42 — die Ursache ist die Großform, nicht das Material).
`CanopyRender` steht deshalb auf 0,40/0,60: 11,8–23,3 % über alle Seeds und
Jahre.
## Paket B (Mäandergürtel, `meanderBelt`) — Stand des ersten PR

### Was der Gürtel tut

`Terrain.meanderBeltStep` ersetzt im Produktionspfad `migrateMeander` +
`meanderStamp` (die bleiben unverändert für `meanderBelt = false`):

- **Breite** `b(Q)` aus `WaterRender.ribbonHalfWidthCells` (dieselbe Kurve wie
  das Band), Abfluss je Knoten = größtes Einzugsgebiet im 3×3, entlang des Laufs
  monoton.
- **Migration nach Howard–Knutson.** Stromauf integrierte Krümmung (Γ = 2,
  Kernlänge L = 1,2 Breiten) explizit, CFL-getaktet je Lauf; der lokale Term
  (Ω = −1) ist eine Diffusion der Linie mit κ = |Ω|·Rate·b² und läuft
  IMPLIZIT (Rückwärts-Euler, tridiagonal). Lineare Analyse:
  σ(k) ∝ k²·(Γ/(1+(kL)²) − 1), Maximum bei (1+(kL)²)² = Γ, also
  λ ≈ 9,8·L ≈ 12 Breiten. Gemessen ohne Gelände (`MeanderBeltTests`):
  λ/b 10,2 / 10,4 / 15,7, dt 50 gegen 1500 Jahre 0,09 Zellen Abstand.
- **Erodierbarkeit** (Mobilität aus der Längsneigung, Talwand-Bremse,
  Ufer-Kohäsion) skaliert BEIDE Terme.
- **Stempel** über die volle Breite: Sohle `z_bf − D·(1 − η²)(1 + skew·a·η)`
  (Kolk außen), Material des Prallhangs als Bank innen bis knapp unter bankfull,
  `barAge` als Zustandsfeld. `channelCarve` gräbt seine Rinne nicht in
  Tiefland-Läufe des Gürtels.
- **Cutoffs:** Hals ab 1 Breite, Chute ab 1,5 Breiten Sehne bei 8-facher
  Schleifenlänge und Abfluss ab 4000 Zellen; höchstens 150 Breiten Schleife.
- **Netz:** Hauptstamm zuerst getrasst (längster Fließweg), Zubringer enden an
  ihrem Vorfluter und folgen ihm.

### Befunde beim Kalibrieren (Werkzeuge: `MeanderBeltCalibration`)

Jeder Punkt ist gemessen; verworfen, was nicht trug:

1. **Lokaler Term explizit** (als Teil der Rate): nur bis dt ≈ ds²/(2κ) ≈ 3
   Jahre stabil. Die Linie zackte im Knotenabstand, 1000–3000 Cutoffs je
   20.000 Jahre, die CFL-Teilschritte liefen in jeden Deckel.
2. **Lokaler Term als Glättung** mit Faktor `1 − e^(−4κ·dt/ds²)`: sättigte
   schon bei dt = 50 auf 1, die Diffusion wuchs mit der ZAHL der Teilschritte
   (19 % Kanalbreite Abstand zwischen dt 50 und 1500). Die scheinbar gute
   Wellenlänge (10 Breiten bei Kernlänge 3,5) war ein Artefakt davon; mit der
   impliziten Fassung und Kernlänge 3,5 wuchs nichts mehr (Analyse oben: nur
   λ > 22 Breiten wachsen dort, langsam).
3. **Kohäsion und Talwand-Bremse nur auf dem Wachstumsterm:** dort überwog die
   Diffusion, die Linie wurde gerade statt stehen zu bleiben (Rate 1,5 Zellen je
   1000 Jahre, Bewegung 0,2, Sinuosität fallend).
4. **Zug zur tieferen Uferseite** (Rückstellkraft gegen Abkoppeln): in jedem
   V-Tal ~4-mal stärker als der Wachstumsterm, Sinuosität 1,2. Standard jetzt
   aus (`meanderBeltPull = 0`), der Schalter bleibt.
5. **Bremse Ufer gegen gegenüberliegendes Ufer** direkt am Kanal: reagierte auf
   jedes sanfte Quergefälle. Ersetzt durch die Talwand 3,5 Breiten weit.
6. **Ohne jede Bremse:** die Ebene im Osten von Seed 1337 wurde zum Knäuel aus
   Schlingen durch Schlingen.
7. **Trasse in Index-Reihenfolge:** der Hauptlauf mit dem größten Abfluss war
   ein Stummel aus 30 Knoten (eine kurze Quelle nahe der Küste besaß den
   Unterlauf); feste Enden und Rand-Ausblendung lassen auf Stummeln keinen Bogen
   wachsen.
8. **Zubringer ohne Anschluss:** zwei, drei parallele Bänder durch denselben
   Gürtel. Mit Anschluss über den Abfluss AN DER STELLE zerhackte der Vergleich
   jeden Hauptlauf an jedem Zusammenfluss (die Mündungszelle des Zubringers
   trägt den Abfluss des Vorfluters) — verglichen wird jetzt der ganze Lauf.
9. **Rinne von `channelCarve`** (≈ 35 m) im Tiefland: hielt jede Schlinge fest.

### Laufzeit (Abnahmepunkt 48)

`simperf --repeat 3`, Produktion, Seed 1337, M4 Max, abwechselnd:
`origin/main` 48,8 / 49,2 ms, Gürtel 49,8 ms je Schritt (davon Gürtel ≈ 7 ms:
Migration 2,0, Stempel 1,8, Zubringer 2,2, feste Läufe 0,8). Gegen Paket A
allein (44,1 ms, andere Welt) +13 %. Die erste Fassung mit EINER
Teilschrittzahl für alle ~700 Läufe kostete 99 ms je Schritt (Gürtel 69 %),
mit Dictionary-Bins in Cutoff- und Zubringer-Suche 36 ms.
`simperf --hash` zweimal `615a48df5b50668c`.

### Kennzahlen, alle Mäanderläufe (Abfluss-gewichtet), nach Paket B

| Seed | Jahr | Läufe | Sinuosität | λ/Breite | Amplitude | Gürtel | Gürtel/Amplitude | Asymmetrie |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1337 | 2000 | 12 | 1.21 | 11.2 | 3.6 | 7.4 | 2.0 | 1.06 |
| 1337 | 20000 | 8 | 1.14 | 13.9 | 3.4 | 17.7 | 5.1 | 1.02 |
| 1337 | 100000 | 9 | 1.12 | 8.6 | 4.5 | 23.4 | 5.2 | 0.97 |
| 42 | 2000 | 8 | 1.59 | 11.8 | 6.1 | 12.9 | 2.1 | 1.26 |
| 42 | 20000 | 6 | 1.86 | 5.6 | 3.7 | 30.5 | 8.3 | 0.84 |
| 42 | 100000 | 6 | 1.20 | – | 2.1 | 25.8 | 12.3 | 1.17 |
| 20 | 2000 | 5 | 1.26 | 15.2 | 8.0 | 6.5 | 0.8 | 0.81 |
| 20 | 20000 | 7 | 1.18 | 6.7 | 2.7 | 16.6 | 6.1 | 1.08 |
| 20 | 100000 | 4 | 1.07 | 4.2 | 1.8 | 18.1 | 9.9 | 1.13 |

Hals- / Chute-Cutoffs bis Jahr 100.000: 85 / 6 (1337), 35 / 3 (42), 38 / 6 (20).
Zerklüftung des Tieflands in Jahr 20.000: 0,00124 / 0,00132 / 0,00124 (nach
Paket A 0,00136 / 0,00156 / 0,00141) — die Bank auf bankfull macht die Aue
glatter, nicht krustiger.

### Stand gegen den Abnahmebogen

| Punkt | Stand |
| --- | --- |
| 9 Sinuosität 1,5–2,5 | **offen**: 1,1–1,9 |
| 10 Wellenlänge 10–14 Breiten | **teilweise**: Kern ohne Gelände 10–16, im Gelände 4–15 (Jahr, Seed) |
| 11 Gürtel ≥ 3 × Amplitude | erfüllt ab Jahr 20.000 (5,1–12,3), in Jahr 2000 noch nicht |
| 12 Querprofil-Asymmetrie ≥ 2 | **offen**: ~1; der Stempel setzt das Profil (Proben zeigen den Kolk außen), aber die Bögen sind mit 2–4 Zellen Amplitude kaum breiter als der Kanal |
| 13 ≥ 3 Altarme im Tiefland | **teilweise**: 1–6 offen je Seed und Jahr |
| 14 Aue nicht zerklüfteter | erfüllt (Wächter) |
| 15 Hals- und Chute-Cutoff | erfüllt (Wächter) |
| 16 `barAge` im Inventar | erfüllt (`FingerprintTests`, `StateInventoryTests`, Snapshot v6) |
| 17 dt-Invarianz | Kern erfüllt (`MeanderBeltTests`); die Gelände-Wächter (`DtInvariance`) laufen auf der Mechanik vor #174 (`calibrationMeanderBelt`) |
| 18 Braid-/Playa-Wächter | grün, ebenfalls auf der alten Welt |

## Flüsse laufen bergauf (Befund im Zeitraffer, Jahr 230.000)

Befund des Projekteigners (Seed 1337, um Jahr 230.000): „als würden manchmal
die Flüsse hochfließen, während sie so einen schönen Bogen bilden".
Werkzeug: `RiverUphill.swift` (`RibbonUphill.measure` am fertigen
`RibbonMesh`), alle hinter `RS_MEASURE`:

```sh
RS_MEASURE=1 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter testRibbonUphillDiagnostic
```

`testRibbonUphillMapDiagnostic` (Karte als PPM, `RS_CROP`, Längsprofil eines
Laufs mit `RS_CHANNEL`, Welt-Cache `RS_CACHE`) und
`testRibbonUphillHistoryDiagnostic` (Läufe an ihrem festen Quellknoten über
die Zeit) für die Ursache. Gemessen wird die Höhe, auf die der Renderer das
Band legt (Spiegel über Wasser, sonst Gelände unter der Mitte), gegen das
laufende Minimum stromauf; ein Anstieg zählt, wo er auf sichtbaren
Stützpunkten (Deckkraft ≥ 0,25) liegt. Welt: Produktion mit Einlauf,
1000-Jahr-Schritte, M4 Max.

### Ursache

Das Band liegt auf dem Gelände unter der Lagrange-Zentrumslinie, und nichts
hält dieses Gelände stromab fallend: die Linie ist nicht an die
D8-Entwässerung gebunden. Das gilt seit den Bändern (#34) und auch auf
`origin/main` (vor #174). Der Gürtel (#174 B, `be90e77`) macht es häufig:
`refreshBeltDischarge` nimmt das größte Einzugsgebiet im 3×3 und trägt es als
laufendes Maximum stromab. Berührt eine Linie einen größeren Fluss, erbt sie
dessen Abfluss für den Rest ihres Laufs, auch wenn sie ihn wieder verlässt.
Beispiel Seed 1337: ein Zubringer mit festem Kopf bei Zelle (138, 336) trägt
210.000 Jahre lang 9–90 Zellen Abfluss; in Jahr 220.000 erreicht der
Hauptlauf seinen Kopf, die ganze Linie bekommt 10.072 Zellen, wird mobil
(`meanderBeltMinCells`) und wächst in 10.000 Jahren von 48 auf 105 Knoten,
83 % davon ohne ein Viertel ihres Abflusses im D8-Netz darunter, Gelände vom
Kopf zum Ende 0,182 → 0,203 (≈ 50 m bergauf). Das Abfluss-Vertrauen von
#174 C2 (`ac5a85b`, `ribbonTrust`) hält solche Läufe unabhängig von der
Stream-Map sichtbar.

Anstiege über 30 m auf sichtbaren Band-Stützpunkten (je 1000 Stützpunkte):

| Stand | 1337 J20.000 | 1337 J230.000 | 42 J20.000 | 42 J230.000 |
| --- | --- | --- | --- | --- |
| `origin/main` (alte Welt) | 10 (0,5) | 71 (4,6) | 2 (0,3) | 9 (2,8) |
| #174 vor dem Fix | 33 (4,8), max 230 m | 16 (5,6), max 114 m | 10 (4,6), max 110 m | 8 (4,7), max 76 m |
| #174 mit Fix | 0, max 16 m | 0, max 16 m | 0, max 16 m | 0, max 16 m |

Vor dem Fix lagen in Jahr 230.000 57 % (1337) bzw. 51 % (42) der
Anstiegs-Summe auf Stücken ohne D8-Lauf mit halbem Abfluss in 3 Zellen;
38 % bzw. 28 % aller sichtbaren Stützpunkte hatten weniger als ein Viertel
ihres Abflusses im D8-Netz darunter.

### Fix

`RiverRibbonRenderer.fadeUphill` (Render, die Sim bleibt bit-gleich): liegt
das Gelände unter dem Band mehr als `WaterRender.ribbonUphillFadeStart`
(0,004 ≈ 10 m) über dem tiefsten Punkt stromauf, blendet das Band aus, voll
ab `ribbonUphillFadeEnd` (0,008 ≈ 19 m); dort malt das Raster das echte
D8-Wasser über `bandCoverage`. Die Höhen bleiben, wie `river_ribbons.gd` sie
verlangt. Sichtbare Band-Stützpunkte: 6879 → 5523 (1337 J20.000),
2843 → 1900 (1337 J230.000), 2182 → 1763 / 1687 → 1446 (42). Hauptlauf
(`testMainStemBandDiagnostic`, Jahr 20.000): Lücke unverändert 16,3 / 0 /
12,2 % (1337 / 42 / 20), Band-Anteil 1337 67,1 → 66,1 %, Band-Zellen ohne
D8-Lauf in 3 Zellen 2649 → 1540.

Wächter: `RibbonUphillTests` (Kunstwelt mit Rücken quer zur Linie; vor dem
Fix 23 Kantenpaare bis 0,0275 über dem Spiegel stromauf sichtbar).

Offen (Sim, Paket B): das Erben des Abflusses in `refreshBeltDischarge` lässt
abgekoppelte Linien weiter wandern und ihre Rinne stempeln; der Fix
versteckt nur das Band.

### Ursache in der Sim: Versuche (nicht übernommen)

Auftrag nach dem Render-Fix: das Erben des Abflusses in
`refreshBeltDischarge` (#179) abstellen und abgekoppelte Linien nicht weiter
wandern lassen. `testRibbonUphillDiagnostic` misst seitdem die ROHEN Bänder
(`RiverRibbonRenderer.fadesUphill = false`) und den ausgeblendeten Anteil;
`testBeltCouplingDistanceDiagnostic` den Abstand wandernder Knoten zum
nächsten D8-Gerinne mit mindestens halbem Abfluss.

**Befund: der kalibrierte Gürtel lebt von der Abkopplung.** Produktion, Seed
1337, Jahr 20.000: nur 35 % der wandernden Knoten liegen höchstens 1,5 Zellen
von ihrer Rinne, 58 % höchstens 6, 17 % weiter als 20 Zellen. Die Bögen, die
die Punkte 9–13 erfüllen, sind zu einem großen Teil Linien, die neben der
D8-Entwässerung mäandern und ihren Abfluss nur über das laufende Maximum
tragen. Jede Regel, die das Erben wirklich stoppt, nimmt ihnen Abfluss und
Mobilität:

| Variante (Werte Seeds 1337 / 42 / 20, Fenster 10.000–20.000) | Sinuosität | sichtbare Altarme | rohe Anstiege > 30 m (1337 J20k / J230k, 42 J20k / J230k) |
| --- | --- | --- | --- |
| Produktion | 1,79 / 1,63 / 1,63 | 10,7 / 3,2 / 4,5 | 33 / 16, 10 / 8 |
| Deckel: Abfluss ≤ größtes D8-Einzugsgebiet in 6 Zellen | 1,18 / 1,19 / 1,24, λ meist n. m. | 20,8 / 6,7 / 9,0 | 20 / 4, 4 / 5 |
| Deckel 10 / 15 / 20 Zellen + Schwelle 3 | 1,30–2,33 je Seed, λ und Gürtel/Amplitude bis 26 von 26 n. m. | 1,2–12,2 | – |
| Zuwachs zählt erst nach 2 Breiten Weiterführung + Bergauf-Bremse 3 | 1,20 / 1,52 / 1,43 | 1,7 / 1,3 / 1,2 | – |
| Zuwachs nach 1 Breite | – | – | 19 / 7, 2 / 6 |
| Bergauf-Bremse 3 Bankfull-Tiefen allein | 1,70 / 1,81 / **1,40** | 5,8 / **1,7** / **2,7** | 20 / 10, 7 / 3 |
| Bergauf-Bremse 6 allein | – | – | 18 / 14, 7 / 7 |
| Bett-Schwellen bis 3 Tiefen schneiden allein | 1,76 / 1,83 / 1,64 | 6,7 / 3,0 / 5,7 | – |

„–" = nicht gemessen. Keine Variante bringt die rohen Anstiege unter das
Niveau, das der Render-Fade ohnehin abfängt (größter roher Anstieg weiter
38–170 m), und jede, die das Erben stoppt, kippt die Punkte 9–13 (Sinuosität
unter 1,5, sichtbare Altarme unter 3). Das Schwellen-Schneiden (der Stempel
gräbt den Bezug auf den tiefsten Bezug stromauf, wenn der Anstieg höchstens
3 Tiefen beträgt) koppelt am meisten an (Knoten ≤ 1,5 Zellen von der Rinne
35 → 47 %, ≤ 6 Zellen 58 → 71 %) und hält die Kennzahlen am ehesten
(verfehlt: λ 1337 im zweiten Fenster 7,4, Altarme 42 im zweiten Fenster 1,9,
Asymmetrie 20 im ersten 1,77).

Folgerung: die Ursache ist die fehlende Kopplung von Gürtel und
D8-Entwässerung, nicht die Abfluss-Regel allein. Ein Sim-Fix braucht zuerst
eine Rinne, der das D8-Netz folgt (Kandidat: Schwellen-Schneiden), danach
eine Neukalibrierung von Paket B auf dem 24-Seed-Ensemble, und erst dann die
Regel gegen das Erben. Bis dahin hält `fadeUphill` die Bänder vom Hang fern
(Produktion, Seeds 1337 / 42, ausgeblendet von den rohen sichtbaren
Stützpunkten: 19,7 / 19,2 % in Jahr 20.000, 46,0 / 12,6 % in Jahr 100.000,
33,2 / 14,3 % in Jahr 230.000).

## Geister-Seen im Mäandergürtel (Befund im Zeitraffer, Jahr 2.305)

Befund des Projekteigners (Seed 1337, Jahr 2.305, Schrägsicht): in den
Mäanderschlingen und neben den Bändern lagen große, fleckige,
halbdurchsichtige Seen, durch die der Sand der Bänke schien, ohne klare
Uferlinie. Werkzeug: `BeltLakes.swift`, hinter `RS_MEASURE`:

```sh
RS_MEASURE=1 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter testBeltLakesDiagnostic
RS_MEASURE=1 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter testBeltLakeHistoryDiagnostic
```

Gemessen werden die Seen, die `terrain.gdshader` malt (See-Gate ≥
`lakeGateLo` und Wassersäule `waterLevel − h` über `pondContourLo`), als
4er-Komponenten. „Im Gürtel" heißt: die Mehrheit der Zellen liegt im
Kanal-plus-Bank-Streifen eines wandernden Laufs, auf einer Bank
(`barAge ≥ 0`) oder an einem Altarm. Produktion mit Einlauf,
100-Jahr-Schritte, M4 Max.

### Ursache

Die Seen standen nicht im Wasser der Physik. `Terrain.waterLevel` (der
Darstellungs-Spiegel) relaxierte mit τ = 350 Jahren in BEIDE Richtungen auf
den Füllstand `hf`. Auf trockenem Boden ist `hf = h`, der Spiegel war dort
also eine verzögerte Kopie des Geländes. Der Gürtel-Stempel (#179, `be90e77`)
gräbt das Bett aber in wenigen Jahrzehnten eine Kanaltiefe tief, seit der
Kalibrierung (#183, `c1ecdff`, `meanderBeltRelaxYears` 150 → 10) binnen
~10 Jahren. Jede frisch abgetragene Zelle trug damit für Jahrhunderte einen
Geister-See der Tiefe des Abtrags; im Kanal selbst gab das Band an diese
Fläche ab (seit `c6a3d3c` malt nur eine Seite), daneben stand sie über den
Bänken. Ihre Tiefe fiel mit dem Spiegel langsam durch die Tiefen-Rampe des
Shaders: daher halbdurchsichtig und fleckig.

Geister-Zellen = Spiegel > hf + 0,01 bei Wassersäule über `pondContourLo`,
Seed 1337, Jahr 2.200–2.400, 10-Jahr-Schritte:

| Stand | Geister-Zellen Gürtel / sonst | Säule hf / Spiegel (Gürtel) |
| --- | --- | --- |
| ohne Gürtel (`meanderBelt = false`) | 64–99 / 44–166 | 0,0005 / 0,014 |
| Gürtel, Relaxation 150 J. (≈ #179) | 693–701 / 802–1127 | 0,0005 / 0,017–0,018 |
| Gürtel, Produktion (#183) | 1117–1364 / 1312–1495 | 0,0003–0,0006 / 0,019–0,021 |
| nach dem Fix | 0 / 0 | – |

Die hf-Säule der Geister-Zellen liegt bei 0,0005 (trocken), der Spiegel bei
0,02, rund zehn Bankfull-Tiefen (D = 0,0021 bei 6,4 Zellen Breite).

### Fix

`Terrain.relaxWaterLevel` dämpft nur noch den Anstieg (den Sill-Plug des
Sägezahns, für den die Glättung da ist); fällt `hf`, folgt der Spiegel
sofort. Die Physik liest `waterLevel` nicht: Fingerabdruck ohne
`waterLevel` (Produktion, Seed 1337, 100 × 100 J. Einlauf + 30 × 100 J.)
vorher und nachher `c7c4f28eb407f835`. `simperf --hash` ändert sich, weil
`waterLevel` im Inventar steht: `1625b1e4b83c85f4` → `e505e21e35d719aa`
(nachher zweimal gleich). Zielbild-Punkte 9–13 inkl. „davon nass" und die
Cutoff-Zahlen auf 1337 / 42 / 20 unverändert (Tabelle § Zeitmittel-Abnahme,
Nachher). `simperf --repeat 3`, fünf Runden abwechselnd vorher / nachher:
56,9 / 54,7 — 54,8 / 55,5 — 56,4 / 55,2 — 57,4 / 59,6 — 54,2 / 54,2 ms je
Schritt, Median 56,4 / 55,2 (Rauschen). Wächter:
`LakeLevelStability.testWaterLevelNeverStandsAboveFill` (rot ohne Fix: Spiegel
0,24 über `hf`), `testWaterLevelDampsFillJumps` grün.

Gemalte Seen vorher → nachher (Anzahl / Zellen; „halbdurchs." = Zellen mit
Tiefen-Rampe unter 0,5):

| Seed, Jahr | im Gürtel | halbdurchs. im Gürtel | außerhalb |
| --- | --- | --- | --- |
| 1337, 2.300 | 7 / 646 → 5 / 202 | 294 → 46 | 5 / 5584 → 3 / 5420 |
| 1337, 20.000 | 3 / 151 → 1 / 35 | 69 → 14 | 2 / 4456 → 2 / 4453 |
| 42, 2.300 | 0 / 0 → 1 / 1 | 0 → 0 | 1 / 11 → 1 / 2 |
| 42, 20.000 | 4 / 316 → 1 / 38 | 157 → 18 | 0 → 0 |

Was im Gürtel bleibt, ist echtes Wasser (`hf − h` über `lakeRawWetDepth`
auf allen gemalten Kernzellen): auf Seed 1337 ein tiefes Becken bei Welt
(−21,2; 5,4), 174 Zellen, im Mittel 38 D tief, das ohne Gürtel genauso
steht (334 Zellen). Kandidaten für die Seen aus dem Bericht (aus der Karte
zugeordnet, nicht im Bild bestätigt): die Geister-Komponenten bei Welt
(13,8; 6,8) (67 Zellen, Spiegel im Mittel 14,7 D über dem Boden, hf 4,6 D,
45 Zellen im Kanal) und (9,9; −11,4) (46 Zellen).
