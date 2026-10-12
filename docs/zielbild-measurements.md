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
  Amplitude = größter Abstand einer Halbwelle zu ihrer Sehne. Seit der
  Kalibrierung von Paket B (zweiter PR) verschmelzen Halbwellen unter einer
  halben Kanalbreite Höhe mit ihren Nachbarn (`ZielbildMetrics.bends`): sie
  bleiben in den eigenen Ufern und sind kein Bogen. In Tabellen davor zählte
  jeder Vorzeichenwechsel; „roh" in den Tabellen unten ist diese alte Lesart.
- **Gürtel:** bis Paket B (`barAge`) die Ausdehnung der im Lauf je
  überstrichenen Zellen quer zur Talachse (Mittel über ±12 Knoten), Median.
  Seit der Kalibrierung: Talachse über eine Mäanderwellenlänge entlang des
  Laufs (λ · Sinuosität, mindestens ±12 Knoten); die festen ±12 Knoten (±18
  Zellen) lagen bei ausgebildeten Bögen (λ ≈ 60–80 Zellen) unter einer halben
  Welle, die „Talachse" folgte dem Lauf. Seit dem vierten Schritt von
  Paket B: Abstand der Tangenten an die äußersten überstrichenen Zellen
  parallel zur Talachse über diese Wellenlänge, die Querschnitte starten am
  Lauf statt am Talachsen-Punkt; `beltAll` mittelt Amplitude und Gürtel nur
  über Läufe mit Bogen (§ Paket B — Gürtel-Messung und Wellenlänge).
- **Asymmetrie:** mittlere Tiefe am Außenufer geteilt durch die am Innenufer,
  Abstand max(1, b/4), nur Bögen mit |Krümmung| über dem Median. Bezug seit der
  Kalibrierung: Wasserspiegel bei bankfull = die NIEDRIGERE der beiden
  Uferkanten (Oberkante je Seite über 0,75–1,25 Halbbreiten). Davor der höchste
  Punkt im Querschnitt — an jedem Prallhang gegen eine Talwand war das die
  Wand (10–50 Kanaltiefen hoch), das Verhältnis maß die Wand statt der
  Wassertiefe (im selben Bogen ≈ 0,7 statt ≈ 2,4).
- **Altarme:** Schwerpunkt im Tiefland; „offen" bzw. „jung" = jünger als
  `WaterRender.oxbowVisibleYears`. „Nass" = davon so, wie
  `RiverRibbonRenderer` sie malt: ab `WaterRender.oxbowMinimumNodes` Knoten und
  mindestens ein Drittel der Knoten über offenem Wasser (`waterLevel − h` über
  `WaterRender.pondContourLo`). Cutoffs = über den Lauf aufsummierte neue
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

### Stand gegen den Abnahmebogen (erster PR)

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

## Paket B — Kalibrierung auf dem Produktionsgelände (zweiter PR)

Werkzeuge in `MeanderBeltCalibration` (alle hinter `RS_MEASURE`):
`testBeltVariantsDiagnostic` druckt seitdem auch das MITTEL über die
Stützstellen der zweiten Laufhälfte (alle 2000 Jahre: Jahr 10.000–20.000 bzw.
50.000–100.000) — ein einzelner Zeitpunkt streut auf demselben Seed um
±0,3 Sinuosität und um den Faktor 2–3 in der Asymmetrie. Dazu
`RS_DETAIL` (Mobilität, Bremse, Längsgefälle je Lauf), `RS_WAVES`
(Halbwellen), `RS_PROFILE` (mittleres Querprofil der gemessenen Bögen),
`RS_OXBOW` (Wasser in jungen Altarmen), `testBeltIsolationDiagnostic` (Läufe
einer Produktionswelt ohne Stempel auf eingefrorenem Gelände bzw. einer
Ebene) und `testBeltKernelSpreadDiagnostic` (Streuung der Kern-Wächter).

### Befunde

1. **Der Kern ist konvektiv instabil, die Tiefland-Abschnitte sind zu kurz.**
   Howard–Knutson mit reinem Stromauf-Kern: Bögen wachsen, während sie stromab
   wandern, und brauchen 2–3 Wellenlängen Lauf, um aus Rauschen heranzuwachsen.
   Auf drei geraden Läufen ohne Gelände spülte der Kern seine Anfangszacken in
   ~60.000 Jahren hinaus (Sinuosität 1,00 ab Jahr 62.000, gerade Linie mit
   Spirale am festen Ende). Die wandernden Läufe der Produktionswelt sind
   15–60 Breiten lang mit festen Enden (Zusammenfluss, Mündung). Auf einer
   EBENE, ohne jede Gelände-Kopplung, wurden genau diese Läufe zu
   domänengroßen Schleifen (Radius ~10 Breiten) oder zu geraden Linien — die
   globalen Moden eines begrenzten, konvektiv instabilen Systems. Das Gelände
   war also nicht die Ursache.
   Hebel: Stromab-Anteil im Kern (`meanderBeltDownstreamWeight` 0,8 bei
   Stromauf 1,2; die Summe 2,0 hält die lineare Wellenlängen-Wahl, die
   Differenz setzt die Wanderung stromab) und eine Störquelle
   (`meanderBeltNoise`, Howard & Knutson 1984).
2. **Das Querprofil entstand, überlebte den Schritt aber nicht.** Direkt nach
   dem Stempel lag die äußere Hälfte 0,72 Tiefen unter bankfull, die innere
   0,29 (Verhältnis 2,5); am Schrittende war das mittlere Profil über die
   gemessenen Bögen ein symmetrisches V (η = ±0,5: 0,91 / 0,88 Tiefen über
   der Sohle). Vier Ursachen, jede einzeln gemessen:
   - Knoten-Knicke: die Krümmung über ±½ Breite trug |κ|·b bis 5, der Stempel
     kippte das Profil von Knoten zu Knoten. Jetzt Bogen-Krümmung über ±1
     Breite (`MeanderState.bendCurvature`, dieselbe Quelle für den Render).
   - Tropfen: der radiale Pinsel grub jeden Schritt ein V in das Bett. Jetzt
     tragen die Tropfen im Gürtelbett weder ab noch lagern sie ab
     (`Terrain.beltDropletGate`, dieselbe Doktrin wie `channelCarve`).
   - Sohlen-Ratsche: der Stempel trug ab, wo das Bett über dem Ziel lag, legte
     aber nur INNEN ab; Kolke außen blieben unter dem über ±2 Knoten
     gemittelten Ziel, der Bezug sank je Teilschritt. Das Gerinne lag ~2
     Tiefen unter der eigenen Aue, das Rest-Budget je Knoten 29
     Tiefen·Zellen (danach 13). Jetzt Ablage über die volle Breite.
   - Relaxation τ = 150 Jahre: das Bett lief der wandernden Linie um Zellen
     hinterher, am Prallhang lag die äußere Hälfte höher als die innere.
     Jetzt τ = 10 Jahre.
   Dazu Kolk-Schiefe 1,5 → 2,5 (Gleithang innen knapp unter bankfull) und der
   Deckel des Ziels auf die Bank-Oberkante: ab κ·η < −1 lag es sonst über
   bankfull.
3. **Die Messung maß an zwei Stellen etwas anderes als den Abnahmepunkt**
   (s. Definitionen): Wendepunkte aus flachen Halbwellen (0,0–0,3 Breiten
   hoch, 1–3 Breiten Sehne) drückten λ um 1–3 Breiten, und die Asymmetrie
   bezog sich an Prallhängen gegen eine Talwand auf die Wand. Die
   Gürtel-Achse über ±12 Knoten wurde ebenfalls korrigiert; sie fällt dadurch
   NIEDRIGER aus (s. Punkt 11 unten).

### Verworfen (Mittel Jahr 10.000–20.000 bzw. Jahr 20.000, alle Läufe)

| Variante | Sinuosität | λ/b | Asymmetrie | Grund |
| --- | --- | --- | --- | --- |
| nur Störquelle 0,005 / 0,01 / 0,02 | 1,05–1,35 | 0–17 | 0,8–1,3 | Gelände-Läufe zu kurz für den konvektiven Kern |
| Talwand-Bremse 4 / 8 / aus | 1,14–2,04 | 0–24 | 0,6–1,3 | kein Hebel; aus: Schleifen über die Ebene |
| Rate 0,03 (Kern 1,2) | 1,01–1,24 | 6–10 | 0,8–1,1 | frühere Cutoffs, Sinuosität fällt |
| Stromab 0,5 (Stromauf 1,5) | 1,23–1,45 | 7–8 | 0,9–1,1 | zu wenig Wachstum am Ort |
| Stromab 1,0 (symmetrisch) | — | — | — | Ebene: Schlingen bis Sinuosität 21 |
| Kernlänge 1,8 / 2,5 | 1,05–1,5 | 7–20 | — | Wachstum ∝ 1/L² zu langsam |
| Lokalterm −0,6 (Kern 1,6) | 1,40–2,07 | 6,0–6,4 | 1,1–1,2 | zu kurze Bögen |
| Gürtel NACH Tropfen und Diffusion im Schritt | 1,53–1,95 | 7–12 | 1,3–2,0 | half, aber ändert die `step()`-Reihenfolge; die Tropfen-Sperre trägt dasselbe ohne |
| Pfropf über die volle Kanalbreite | 1,68–1,75 | 7–11 | 2,4–2,9 | nasse Altarme unverändert (0,5–2,0), s. Punkt 13 |
| Bett-Tiefe 0,0035 (Breite/Tiefe 12) | 1,53–2,00 | 9–15 | 2,5–4,4 | nasse Altarme unverändert, unnötig |

### Kennzahlen, alle Mäanderläufe, vorher / nachher

Gleicher Metrik-Code (`ZielbildMetrics` dieses PR) auf beiden Ständen;
„vorher" = Mechanik des ersten PR (`be90e77`). Einzelzeitpunkte:

| Seed | Jahr | Sinuosität | λ/b (roh) | Asymmetrie (roh) | Gürtel/Amplitude | Altarme jung / nass |
| ---: | ---: | --- | --- | --- | --- | --- |
| 1337 | 20000 | 1,14 → 1,32 | – → 12,4 | 1,00 → 4,12 | 3,7 → 4,4 | 3 / 0 → 11 / 3 |
| 1337 | 100000 | 1,12 → 1,68 | – → – | 0,98 → 1,45 | 3,8 → 13,6 | 6 / 3 → 4 / 1 |
| 42 | 20000 | 1,86 → 1,71 | – → 10,7 | 1,50 → 1,52 | 6,1 → 1,8 | 1 / 0 → 0 / 0 |
| 42 | 100000 | 1,20 → 1,51 | – → – | 1,14 → 2,37 | 12,3 → 46,1 | 3 / 0 → 8 / 1 |
| 20 | 20000 | 1,18 → 1,65 | – → 8,5 | 0,99 → 1,47 | 6,5 → 6,1 | 2 / 0 → 3 / 1 |
| 20 | 100000 | 1,07 → 1,83 | – → – | 1,12 → 2,49 | 6,6 → 20,0 | 1 / 1 → 6 / 1 |

„–" bei λ: kein Abschnitt trägt drei Wendepunkte (vorher: Läufe gerade;
nachher in Jahr 100.000: die wandernden Abschnitte sind durch Cutoffs und
angeschlossene Zubringer auf 10–20 Breiten zerfallen, kürzer als zwei Bögen).

Nachher, Mittel über die Stützstellen der zweiten Laufhälfte (in der
Spalte Gürtel/Amplitude gingen nicht messbare Stützstellen hier noch als 0 ein;
die verbindliche Zeitmittel-Tabelle steht in § Paket B — Zeitmittel-Abnahme):

| Seed | Fenster | Sinuosität | λ/b (roh) | Asymmetrie (roh) | Gürtel/Amplitude (roh) | Altarme jung / nass |
| ---: | --- | ---: | --- | --- | --- | --- |
| 1337 | 10.000–20.000 | 1,60 | 10,9 (7,2) | 2,39 (1,42) | 3,1 (4,9) | 10,5 / 2,2 |
| 42 | 10.000–20.000 | 1,70 | 13,1 (10,5) | 2,66 (1,58) | 4,7 (6,5) | 1,2 / 0,5 |
| 20 | 10.000–20.000 | 1,59 | 9,2 (6,5) | 1,79 (1,23) | 3,0 (4,0) | 2,5 / 0,3 |
| 1337 | 50.000–100.000 | 1,62 | 10,0 (7,0) | 2,51 (1,68) | 10,8 (13,8) | 6,5 / 0,5 |
| 42 | 50.000–100.000 | 1,73 | 10,6 (9,2) | 2,57 (1,69) | 8,2 (11,4) | 7,8 / 0,6 |
| 20 | 50.000–100.000 | 1,69 | 11,0 (8,6) | 2,34 (1,42) | 15,7 (20,6) | 4,6 / 0,3 |

Gegenprobe auf drei weiteren Seeds (7, 99, 123), Mittel 10.000–20.000:
Sinuosität 1,67 / 1,65 / 1,33, λ/b 9,3 / 12,5 / –, Asymmetrie 2,94 / 1,75 /
1,31. Seed 123 trägt kaum wandernde Abschnitte.

Zerklüftung des Tieflands in Jahr 20.000: 0,00120 / 0,00128 / 0,00124 (Wächter
0,00156). Cutoffs Hals / Chute bis Jahr 100.000: 123 / 23, 80 / 8, 89 / 13.

### Warum kaum ein Altarm Wasser trägt (Punkt 13)

Ein abgeschnürter Bogen ist im Render nur dann Wasser, wenn
`waterLevel − h` über `pondContourLo` = 0,003 liegt. Die Bankfull-Tiefe ist
0,0021 (5 m bei 100 m Breite). Und das Tiefland ist für einen Mäanderfluss
steil: 1 Sim-Höhe ≈ 2,4 km, 1 Welteinheit ≈ 100 m, `meanderFlatSlope` = 0,02
entspricht 48 % Gefälle. Gemessen auf den wandernden Knoten (Jahr 20.000,
`RS_DETAIL`): Längsgefälle im Median 3,6 / 4,8 / 3,7 KANALTIEFEN JE
KANALBREITE, nur 6–10 % der Knoten unter 0,5. Ein Bogen, der ein bis zwei
Breiten talab reicht, fällt entlang seiner Länge um mehrere Kanaltiefen; als
Senke hält er Wasser nur im tiefsten Kolk. Gemessen in jungen Altarmen: die
Umgebung ihres Mittelknotens liegt 1–3 Tiefen UNTER ihrem Bett. Weder ein
Pfropf über die volle Kanalbreite noch ein tieferes Bett (Breite/Tiefe 12)
änderten die Zahl der nassen Altarme (0,2–2,7 im Mittel). Wassergefüllte
Altarme brauchen ein um eine Größenordnung flacheres Tiefland (Paket A) oder
eine Altarm-Darstellung ohne Wassersäule (Paket C: Ried und
Vegetationsbogen aus `BarMaterial`, schon vorhanden).

### Laufzeit und Determinismus (Abnahmepunkte 48 und 49)

`simperf --repeat 3`, Produktion, Seed 1337, M4 Max, abwechselnd je drei
Runden: `origin/main` (`55323b5`) 48,2 / 48,5 / 48,7 ms, Kalibrierung 52,3 /
52,6 / 52,7 ms je Schritt (Median 48,5 → 52,6, +8,5 %). Gegen Paket B ohne
Kalibrierung (Stand `t3/issue-174-c2`, Physik gleich B): 47,0 / 48,1 / 47,2 →
52,3 / 52,9 / 53,1 ms (Median 47,2 → 52,9, +12 %); die Mehrkosten sind mehr
CFL-Teilschritte (höhere Rate, größere Bögen). `simperf --hash` zweimal
`2c172d2f0483d989`.

SimCore-Pflichtsuite lokal: 466 Tests, 0 Fehler, 2:42 min.

### Stand gegen den Abnahmebogen (nach der Kalibrierung, überholt)

Überholt durch § Paket B — Zeitmittel-Abnahme (Bewertung je Seed im
Zeitmittel, danach nachkalibriert). Stand dieses Schritts:

| Punkt | Stand |
| --- | --- |
| 9 Sinuosität 1,5–2,5 | **erfüllt im Zeitmittel** (1,59–1,73 auf allen drei Seeds, beide Fenster); Einzelzeitpunkte 1,32–1,83, Seed 1337 in Jahr 20.000 darunter |
| 10 Wellenlänge 10–14 Breiten | **weitgehend**: Zeitmittel 9,2–13,1; in Jahr 100.000 als Einzelzeitpunkt nicht messbar (Abschnitte kürzer als zwei Bögen) |
| 11 Gürtel ≥ 3 × Amplitude | in Jahr 100.000 erfüllt (8–46); in Jahr 20.000 Zeitmittel 3,0–4,7, Einzelzeitpunkt Seed 42: 1,8 (größere Bögen bei noch jungem Gürtel; mit der alten Achse 3,1–6,5) |
| 12 Querprofil-Asymmetrie ≥ 2 | **erfüllt im Zeitmittel** außer Seed 20 in Jahr 10.000–20.000 (1,79); Einzelzeitpunkte 1,45–4,12 |
| 13 ≥ 3 Altarme im Tiefland | jung (< 6000 Jahre): 1–11; **wassergefüllt: 0–3, physikalisch durch das Tieflandgefälle begrenzt** (s. oben) |
| 14 Aue nicht zerklüfteter | erfüllt (Wächter) |
| 15 Hals- und Chute-Cutoff | erfüllt (Wächter, Gelände und Kern) |
| 16 `barAge` im Inventar | unverändert erfüllt |
| 17 dt-Invarianz | Kern: Abstand dt 50 ↔ 1500 nach 3000 Jahren 0,33 Zellen (Grenze 0,96); die Störquelle ist nur in Verteilung invariant |
| 18 Braid-/Playa-Wächter | grün (alte Welt, `calibrationMeanderBelt`) |
| 48 Laufzeit ≤ +15 % | +8,5 % gegen `origin/main` |
| 49 Determinismus | `--hash` zweimal gleich |

Wächter dieses PR: `ZielbildLandformTests` (Mittel über die drei Seeds in
Jahr 20.000: Sinuosität > 1,35, Asymmetrie > 1,4; vorher 1,39 und 1,16) und
`MeanderBeltTests.testLongRunStaysBoundedWithBothCutoffs` (örtliche
Sinuosität nach 60.000 Jahren zwischen 1,5 und 6; ohne Störquelle lag sie
bei 1,0). Die Schranken liegen bewusst weit unter den Messwerten: ein
Einzelzeitpunkt streut stark, und Linux rechnet mit anderer System-libm eine
andere Realisierung.

## Paket B — Zeitmittel-Abnahme (dritter Schritt)

**Entscheidung des Projekteigners:** die Mäander-Punkte 9–13 werden über
ZEITMITTEL je Seed gewertet: Fenster Jahr 10.000–20.000 und 50.000–100.000,
Stützstellen alle 2000 Jahre (6 bzw. 26), Kennzahl `ZielbildMetrics.beltAll`
über alle Mäanderläufe. Einzelzeitpunkte sind nur Streuung (min–max unten).
Altarme (Punkt 13) = sichtbare junge Altarme im Tiefland: jünger als
`WaterRender.oxbowVisibleYears`, ab `WaterRender.oxbowMinimumNodes` Knoten
(darunter zeichnen weder das Wasserband noch das Ried aus `BarMaterial`
etwas), Schwerpunkt im Tiefland. Seit #181 ist ein trockener junger Altarm
als Ried-Bogen sichtbar; Wasserfüllung verlangt der Punkt nicht.

```sh
RS_MEASURE=1 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter testZielbildMeanderTimeMeanDiagnostic
```

`RS_SEED` wählt einen Seed (die Läufe lassen sich parallel starten, je Seed
~10–15 s auf dem M4 Max), `RS_VARIANT` Parameter-Varianten wie
`MeanderBeltCalibration`. **Nicht messbare Stützstellen gehen nicht als 0 ins
Mittel**, sie werden ausgelassen und gezählt („n. m."): λ ohne Abschnitt mit
drei Wendepunkten, Gürtel/Amplitude bei Amplitude unter 0,5 Zellen,
Asymmetrie ohne Bogen über dem Krümmungs-Median (`ZielbildMetrics.Series`).

### Vorher (Stand nach der Kalibrierung, `280f5d2`)

Mittel (min–max der Einzelzeitpunkte):

| Seed | Fenster | 9 Sinuosität | 10 λ/Breite | 11 Gürtel/Amplitude | 12 Asymmetrie | 13 Altarme sichtbar | davon nass |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1337 | 10.000–20.000 | 1,60 (1,32–2,08) | 10,9 (8,9–14,2) | 3,5 (1,9–4,4) | 2,39 (1,61–4,12) | 5,5 (4–8) | 2,2 |
| 1337 | 50.000–100.000 | 1,62 (1,30–2,04) | 10,0 (4,3–15,7), 1 n. m. | 11,5 (5,1–29,9) | 2,51 (1,45–4,24) | 3,7 (1–8) | 0,5 |
| 42 | 10.000–20.000 | 1,70 (1,54–2,04) | 13,1 (10,7–14,1), 1 n. m. | 4,9 (1,8–15,5) | 2,66 (1,52–7,03) | **0,5** (0–1) | 0,5 |
| 42 | 50.000–100.000 | 1,73 (1,40–2,07) | 10,6 (5,5–16,4), 7 n. m. | 8,3 (1,8–46,1) | 2,57 (1,38–5,33) | **1,8** (0–4) | 0,6 |
| 20 | 10.000–20.000 | 1,59 (1,32–1,89) | **9,2** (8,4–10,4) | 3,0 (1,8–6,1) | **1,79** (1,43–2,98) | **1,5** (0–2) | 0,3 |
| 20 | 50.000–100.000 | 1,69 (1,44–2,65) | 11,0 (4,3–14,2), 10 n. m. | 16,5 (2,9–46,9), 1 n. m. | 2,34 (1,29–5,64) | **1,4** (0–4) | 0,3 |

Verfehlt im Zeitmittel: Punkt 13 auf Seed 42 und 20 in beiden Fenstern,
Punkt 10 und 12 auf Seed 20 im ersten Fenster; Punkt 11 dort genau auf der
Grenze (3,0).

### Befund: der Gürtel schnürte Knicke ab, keine Bögen

Junge Altarme im Tiefland JEDER Größe gab es genug (Mittel 50.000–100.000:
6,5 / 7,8 / 4,6), sichtbar davon nur 3,7 / 1,8 / 1,4. Die Altarme waren zu
klein für den Render: Median 15 Knoten auf Seed 42 und 20 (Schwelle 20). Je
neuem Altarm (`testOxbowOriginDiagnostic`): bei voller Kanalbreite
(b ≈ 6,4 Zellen) 3–5 Breiten Bogenlänge, also ein Ring vom Durchmesser einer
Kanalbreite — ein Knick an einem Spiralkern, kein Mäanderbogen (ein
abgeschnürter Bogen ist 1–2 Wellenlängen lang, 10–30 Breiten). Auf der Karte
(`testBeltRiverViewDiagnostic`, Altarme unter 20 Knoten jetzt cyan, dazu
die Linien als Text für vergrößerte Ausschnitte) lagen die kleinen Altarme
im Kern eingerollter Schleifen.

Ursache: die örtliche Sättigung (`meanderBeltSinuosityStart/Full` = 2,0 /
2,8 über ±10 Breiten). Ein Bogen, dessen Hals sich schließt (Omega-Form),
hat dort eine örtliche Sinuosität über 3; das Wachstum stand also still,
bevor ein Hals zuging. Mit 3,0 / 4,0 wachsen die Bögen bis zum Cutoff: der
Altarm-Median in Jahr 20.000 steigt von 18 / 16 / 18 auf 28 / 54 / 37
Knoten, auf der Karte liegen die jungen Altarme als ganze Hufeisen neben dem
Lauf. Zwei Folgen, beide nachgezogen: die weiteren Bögen ließen die
Asymmetrie fallen (Mittel 10.000–20.000 auf 8 Seeds 2,01 → 1,67), weil der
Kolk erst bei Krümmungsradius / Breite = `meanderBeltPoolGain` voll
ausgebildet ist (2,5 → 4); und die größeren Bögen blieben an Aue-Stufen an
der Talwand-Bremse hängen, der junge Gürtel blieb schmal
(`meanderBeltBrakeDepths` 2 → 3: Gürtel/Amplitude 10.000–20.000 auf 12
Seeds 2,9 → 4,7). `meanderBeltPoolSkew` 2,5 → 3 ist auf 24 Seeds neutral
(Summe erfüllter Punkte 180 → 182 von 240); unter den gleichwertigen
Kandidaten ist es der mit den meisten erfüllten Punkten auf den
Matrix-Seeds (28 statt 24 von 30) — das ist Realisierung, nicht Physik, und
steht deshalb hier.

### Ensemble statt drei Seeds

Ein Zeitmittel über sechs Stützstellen streut je Seed noch stark, und jede
Parameter-Änderung zieht eine neue Realisierung. Gewählt wurde deshalb auf
24 Seeds (Matrix-Seeds plus 7, 99, 123, 5, 11, 3, 64, 777, 2024, 1, 2, 4, 6,
8–10, 12–16). Tabelle: Seeds mit erfülltem Punkt im Zeitmittel, in Klammern
das Mittel über die Seeds.

| Punkt | 10.000–20.000 vorher | nachher | 50.000–100.000 vorher | nachher |
| --- | --- | --- | --- | --- |
| 9 Sinuosität 1,5–2,5 | 18 (1,68) | 18 (1,84) | 17 (1,72) | 20 (1,88) |
| 10 λ/Breite 10–14 | 9 (10,3) | 15 (12,1) | 6 (9,1) | 12 (10,6) |
| 11 Gürtel ≥ 3 × Amplitude | 16 (3,8) | 17 (4,1) | 23 (13,4) | 24 (15,6) |
| 12 Asymmetrie ≥ 2 | 13 (2,52) | 18 (3,00) | 18 (2,60) | 24 (4,19) |
| 13 ≥ 3 sichtbare Altarme | 4 (1,7) | 16 (4,4) | 3 (1,7) | 18 (4,8) |

Summe erfüllter Punkte: 127 → 182 von 240.

### Verworfen

| Variante | Befund |
| --- | --- |
| Krümmungsdeckel im Kern, \|κ\|·b ≤ 0,3 / 0,5 | unterdrückt die Knicke, aber fast jeden Cutoff: Sinuosität 1,2–1,5, sichtbare Altarme 0–1,5 (Matrix-Seeds) |
| Chute ab 1500 Zellen statt 4000 | mehr Altarme, aber weiter klein (Seed 20: 31 von 41 unter 20 Knoten), Sinuosität Seed 42 1,3 |
| Chute-Sehne 2,5 Breiten, Schleife ≥ 6 × Sehne | ebenso; Asymmetrie 1,6–2,2 |
| Sättigung 2,5 / 3,5 | Zwischenstufe: Altarme 3,4 / 4,3 im Mittel (8 Seeds), Sinuosität Seed 20 1,35 |
| Sättigung 3,0 / 4,0 allein | Altarme auf 7 von 8 Seeds erfüllt, Asymmetrie 10.000–20.000 1,67 (1 von 8) |
| Sättigung 3,5 / 5,0 | Asymmetrie 10.000–20.000 1,64 (0 von 8) |
| dazu Störquelle 0,015 | Asymmetrie 1,66, Sinuosität 1,43 (8 Seeds) |
| dazu Gain 3,5 statt 4 | 88 von 120 erfüllten Punkten (12 Seeds) gegen 98 |
| dazu Bremse 2,5 / 4 | 91 / 85 von 120 |
| dazu Kernlänge 1,3 / 1,4 | Summe gleich (183 von 240 bei 1,3), λ 50.000–100.000 schlechter (7 von 24) |

### Nachher (Standard-Config)

| Seed | Fenster | 9 Sinuosität | 10 λ/Breite | 11 Gürtel/Amplitude | 12 Asymmetrie | 13 Altarme sichtbar | davon nass |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1337 | 10.000–20.000 | 1,79 (1,32–2,38) | 13,8 (8,0–17,5) | 3,1 (1,9–5,5) | 2,43 (1,74–3,55) | 10,7 (9–12) | 2,2 |
| 1337 | 50.000–100.000 | 1,85 (1,24–4,94) | 12,4 (5,0–15,8), 1 n. m. | 10,3 (3,8–21,2) | 3,67 (1,84–12,97) | 11,2 (4–17) | 3,6 |
| 42 | 10.000–20.000 | 1,63 (1,20–1,98) | 12,8 (11,9–14,4), 3 n. m. | 5,5 (1,5–11,3) | 3,13 (2,32–5,15) | 3,2 (1–5) | 1,0 |
| 42 | 50.000–100.000 | 1,63 (1,02–2,18) | **8,3** (3,5–19,4), 16 n. m. | 28,0 (8,7–96,8), 1 n. m. | 2,58 (1,23–6,72) | 4,8 (2–8) | 1,7 |
| 20 | 10.000–20.000 | 1,63 (1,44–1,78) | 11,9 (5,4–16,0) | **2,6** (1,8–3,6) | 2,66 (1,53–4,31) | 4,5 (2–8) | 1,3 |
| 20 | 50.000–100.000 | 1,72 (1,38–2,23) | 10,6 (4,8–16,7), 15 n. m. | 11,6 (1,8–60,5) | 2,35 (1,24–4,45) | 3,3 (1–6) | 1,0 |

Hals- / Chute-Cutoffs bis Jahr 100.000: 174 / 105 (1337), 64 / 43 (42),
55 / 44 (20); vorher 123 / 23, 80 / 8, 89 / 13.

Verfehlt: Punkt 11 auf Seed 20 im ersten Fenster (2,6; vorher 3,0) und
Punkt 10 auf Seed 42 im zweiten (8,3 aus nur 10 messbaren von 26
Stützstellen: die Abschnitte zerfallen dort zwischen Cutoffs und
angeschlossenen Zubringern auf unter zwei Bögen). Beides liegt im Ensemble
in der Realisierungs-Streuung (Punkt 11 im ersten Fenster: 17 von 24 Seeds,
Punkt 10 im zweiten: 12 von 24). Ein Parameter, der genau diese zwei Zellen
dreht, wäre an die Realisierung angepasst, nicht an die Physik.

### Kern-Wächter

Auf der unbegrenzten Ebene (`MeanderBeltTests`, drei Läufe à 20.000 Zellen)
wachsen die Bögen jetzt bis zum Chute-Cutoff, bevor ein Hals zugeht: über acht
Rausch-Seeds 0–2 Hals- neben 323–501 Chute-Cutoffs in 60.000 Jahren
(vorher 3–12 Hals). Der Langlauf-Wächter führt deshalb einen Lauf unter der
Chute-Schwelle (3000 Zellen): 59–76 Hals, 201–343 Chute, örtliche
Sinuosität 3,3–5,1 (Grenze 6). Wellenlängen- und dt-Wächter laufen
unverändert (der Kern erreicht dort die Sättigung nicht): dt 50 ↔ 1500 nach
3000 Jahren 0,33–0,59 Zellen über acht Rausch-Seeds (Grenze 0,96).

### Laufzeit und Determinismus

`simperf --repeat 3`, Produktion, Seed 1337, M4 Max, abwechselnd fünf
Runden `origin/main` (`55323b5`) / Kalibrierung (`280f5d2`) / Zeitmittel:
54,5 / 57,9 / 59,5 — 55,3 / 57,5 / 58,1 — 55,2 / 58,1 / 56,4 — 55,6 / 58,2 /
56,9 — 56,5 / 57,5 / 57,8 ms je Schritt. Median 55,3 / 57,9 / 57,8: gegen
`origin/main` +4,5 %, gegen die Kalibrierung unverändert. Der Rechner lief an
diesem Tag ~14 % langsamer als bei der Messung oben; verglichen wird nur
innerhalb der Runden. `simperf --hash` zweimal `1625b1e4b83c85f4`.

SimCore-Pflichtsuite lokal: 468 Tests, 0 Fehler, 181 s;
`testRangeLandformMeetsTheAcceptanceSheet` 11,6 → 12,0 s.

### Wächter

`ZielbildLandformTests.testRangeLandformMeetsTheAcceptanceSheet` nimmt im
selben 20.000-Jahre-Lauf das Zeitmittel des ersten Fensters (sechs
Stützstellen je Seed, kein zusätzlicher Lauf) und prüft das Mittel über die
drei Seeds. Die Schranken liegen unter dem kleinsten Dreier-Mittel aus den
24 Seeds (alle 2024 Kombinationen): Linux zieht mit anderer System-libm eine
andere Realisierung, ein Wächter je Seed wäre dort Zufall.

| Kennzahl | Wächter | kleinstes Dreier-Mittel (24 Seeds) | Matrix-Seeds |
| --- | --- | --- | --- |
| Sinuosität | > 1,25 | 1,30 | 1,68 |
| λ/Breite | 7,5–16,5 | 8,2 (größtes 14,6) | 12,8 |
| Gürtel/Amplitude | > 2,7 (bis zum vierten Schritt > 1,7) | 2,80 (alte Messung 1,77) | 5,4 (3,7) |
| Asymmetrie | > 1,7 | 1,76 | 2,74 |
| sichtbare Altarme | > 0,8 | 1,03 | 6,1 |
| Median Altarm-Knoten (Jahr 20.000) | ≥ 20 | 20,7 | 39,7 |

Das zweite Fenster (bis Jahr 100.000) läuft nur im Diagnostic (je Seed
~10 s lokal, auf dem CI-Runner ein Mehrfaches).

### Stand gegen den Abnahmebogen (Zeitmittel je Seed, überholt)

Überholt durch § Paket B — Gürtel-Messung und Wellenlänge (Punkt 11 mit der
korrigierten Gürtel-Messung).

| Punkt | Stand |
| --- | --- |
| 9 Sinuosität 1,5–2,5 | **erfüllt** auf allen drei Seeds in beiden Fenstern (1,63–1,85); Einzelzeitpunkte 1,02–4,94 |
| 10 Wellenlänge 10–14 Breiten | **erfüllt** außer Seed 42 im Fenster 50.000–100.000 (8,3; 16 von 26 Stützstellen nicht messbar) |
| 11 Gürtel ≥ 3 × Amplitude | **erfüllt** außer Seed 20 im Fenster 10.000–20.000 (2,6); im zweiten Fenster 10–28 |
| 12 Querprofil-Asymmetrie ≥ 2 | **erfüllt** auf allen drei Seeds in beiden Fenstern (2,35–3,67) |
| 13 ≥ 3 sichtbare Altarme im Tiefland | **erfüllt** auf allen drei Seeds in beiden Fenstern (3,2–11,2); davon wassergefüllt 1,0–3,6 |
| 14 Aue nicht zerklüfteter | erfüllt (Wächter) |
| 15 Hals- und Chute-Cutoff | erfüllt (Wächter, Gelände und Kern) |
| 16 `barAge` im Inventar | unverändert erfüllt |
| 17 dt-Invarianz | Kern unverändert (0,33–0,59 Zellen, Grenze 0,96) |
| 18 Braid-/Playa-Wächter | grün (alte Welt, `calibrationMeanderBelt`) |
| 48 Laufzeit ≤ +15 % | +4,5 % gegen `origin/main` |
| 49 Determinismus | `--hash` zweimal gleich |

## Paket B — Gürtel-Messung und Wellenlänge (vierter Schritt)

Ausgang: 28 von 30 Prüfungen im Zeitmittel, Ensemble (24 Seeds wie oben) 182
von 240. Offen waren Punkt 11 auf Seed 20 im Fenster 10.000–20.000 (2,6) und
Punkt 10 auf Seed 42 im Fenster 50.000–100.000 (8,3, nur 10 von 26
Stützstellen messbar). Geprüft wurde zuerst die Messung, mit den Kennzahlen
je Lauf und Stützstelle (Abschnittslänge, Sehne, Wendepunkte, λ, Amplitude,
Gürtel) und dem Mobilitätsprofil entlang jedes Laufs. Die Physik ist in
diesem Schritt unverändert, geändert wurde nur `ZielbildMetrics`.

```sh
RS_MEASURE=1 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter testZielbildMeanderTimeMeanDiagnostic
# Messung von vorher: zusätzlich RS_BELT_AXIS=1
```

### Punkt 11: die Gürtel-Messung sah den eigenen Bogenzug nicht

Seed 20, Jahr 10.000, längster Lauf (224 mobile Knoten, Sinuosität 1,90,
λ 15,3 Breiten): Amplitude 5,15 Breiten, gemessener Gürtel 5,9 Breiten,
Verhältnis 1,2. Ein Bogenzug mit Amplitude A belegt quer zum Tal aber
mindestens 2A + b = 11,3 Breiten, schmaler kann der Gürtel nicht sein. Zwei
Fehler:

1. **Querschnitt ab dem Talachsen-Punkt.** Die Messung lief EINEN Querschnitt
   vom Schwerpunkt der Knoten über eine Wellenlänge aus und brach nach 1,5
   Zellen Lücke ab. Der Schwerpunkt liegt zwischen den Bögen; trägt die
   Innenseite eines Bogens dort keine Bank (Gelände über der Bank-Oberkante,
   kein Budget), endet die Messung, bevor sie den Lauf erreicht.
2. **„Nicht messbar" als 0 im Mittel über die Läufe.** `beltAll` mittelte
   Amplitude und Gürtel über alle Läufe, auch über die ohne Bogen (unter zwei
   Wendepunkten, Amplitude 0). λ und Asymmetrie zählten dort schon nur die
   messbaren Läufe, und `Series` schließt dasselbe für die Stützstellen aus.

Korrektur, auf alle Seeds gleich: Gürtel = Abstand der beiden Tangenten an
die äußersten überstrichenen Zellen, parallel zur Talachse, über eine
Wellenlänge. Das ist die Lehrbuch-Definition (Linien an die Außenkanten der
Bögen) und wörtlich der Abnahmepunkt („Ausdehnung von `barAge ≥ 0` quer zum
Tal"). Die Querschnitte starten an jedem zweiten Knoten im Fenster, die
Lückenregel bleibt. Amplitude und Gürtel mitteln nur über Läufe mit Bogen.

Jede Hälfte einzeln, Ensemble (Seeds mit erfülltem Punkt 11, in Klammern das
Mittel über die Seeds):

| Messung | 10.000–20.000 | 50.000–100.000 | Seed 20, 10.000–20.000 |
| --- | --- | --- | --- |
| vorher (ab Achse, alle Läufe) | 17 (4,05) | 24 (15,6) | 2,6 |
| nur: Mittel über Läufe mit Bogen | 2 (2,12) | 24 (6,0) | 1,9 |
| nur: Querschnitte ab dem Lauf | 23 (8,86) | 24 (25,6) | 7,2 |
| beide (neu) | 23 (4,98) | 24 (10,4) | 5,8 |

Lesart: über die Läufe mit Bogen allein lag die alte Messung im jungen Fenster
bei ~2, also unter 2 + b/A, der Untergrenze jedes Bogenzugs. Sie maß dort
nicht den Gürtel. Die Hülle allein bläht das Verhältnis über die Läufe ohne
Bogen auf (Gürtel ohne Amplitude), erst beides zusammen ist konsistent. Die
neue Messung ist im alten Fenster STRENGER (Seed 42: 28,0 → 13,8; Seed 20:
11,6 → 7,1) und im jungen großzügiger. Am Lauf von oben misst sie 13,5
Breiten: 2A + b plus 2,2 Breiten überstrichen, Verhältnis 2,6.

Zur Mechanik: der junge Gürtel ist tatsächlich schmal. In den ersten 20.000
Jahren wachsen die Bögen weitgehend am Ort (am Lauf oben 2A + b plus 2,2
Breiten), erst die Wanderung verbreitert ihn (zweites Fenster 7–14). Das ist
das erwartete Bild. Ein Schwellenwert-Hebel wäre hier nur an die Messung
angepasst gewesen.

### Punkt 10 auf Seed 42 (50.000–100.000): Messung begrenzt, Physik auch

Je Stützstelle und Lauf: die mobilen Abschnitte sind 40–170 Knoten lang
(10–50 Breiten Bogenlänge). Sie beginnen dort, wo der Abfluss
`meanderBeltMinCells` erreicht, und enden am Zusammenfluss oder an der
Mündung, nicht an kurzen Steilstücken (Mobilitätsprofil: Lücken von ein, zwei
Knoten sind selten, Zusammenlegen ist kein Hebel). Eine volle Welle (drei
Wendepunkte) braucht λ · S ≈ 19 Breiten Bogenlänge plus die angeschnittenen
Enden. Die Läufe zerfallen in zwei Gruppen:

- gewundene Zubringer (Abfluss 2000–3700, unter `meanderChuteMinCells`, also
  nur Hals-Cutoffs): Sinuosität 2,5–5,7, Sehne des ganzen Abschnitts 8–11
  Breiten, λ 5–8 Breiten. Das sind die meisten messbaren Stützstellen;
- flache, lange Bögen am Stamm (Sinuosität 1,05–1,2, Halbwellen mit 10–20
  Breiten Sehne): im Abschnitt nur zwei Wendepunkte, nicht messbar.

Die Kennzahl misst also, was sie soll, auf dem, was da ist. Die gemessenen
Werte liegen bis auf einen (19,4) bei 3,5–9,9, das Mittel 8,3 ist kein
Ausreißer weniger Stützstellen.

Geprüfte Korrekturen der Messung, verworfen:

- **λ aus Halbwellen** (2 × Sehne zwischen benachbarten Wendepunkten, messbar
  ab zwei Wendepunkten): auf denselben 205 Abschnitten mit mindestens drei
  Wendepunkten (Seeds 1337, 42, 20, 7, 99, 5; Jahr 10.000–100.000) liegt sie
  im Mittel 14 % über der Definition (Luftlinie über zwei Halbwellen; 7 % bei
  Sinuosität unter 2, 21 % darüber, Dreiecksungleichung). Seed 42 käme auf
  11,7, das Ensemble für Punkt 10 auf 19 / 17 von 24 Seeds, aber durch eine
  großzügigere Kennzahl, nicht durch bessere Bögen.
- **Mindestlänge des Abschnitts** (Sehne ≥ 14 Breiten, damit die Zielwelle
  hineinpasst; entfernt die Verzerrung zu kurzen Wellen): auf Seed 42 blieben
  3 von 12 gemessenen Abschnitten (λ 18,9 / 9,9 / 8,0). Ein Mittel aus drei
  Stützstellen ist keine Abnahme.

Parameter, im Ensemble gegen den Stand (Messung jeweils gleich):

| Variante | Ensemble | Matrix-Seeds | Seed 42 λ, 50.000–100.000 |
| --- | --- | --- | --- |
| Stand, alte / neue Gürtel-Messung | 182 / 188 | 28 / 29 | 8,3 |
| Chute ab 3000 Zellen statt 4000 (alt) | 176 | 26 | 15,6 |
| Chute ab 2500 (alt) | 177 | 26 | 12,8 |
| Chute ab 2000 (alt) | 176 | 26 | 11,5 |
| Kernlänge 1,7 statt 1,5 (neu) | 162 | 23 | 12,4 |
| Kernlänge 1,9 (neu) | 164 | 24 | 13,4 |

Jede Variante dreht λ auf Seed 42 in den Zielbereich, verliert aber im
Ensemble (Chute: λ, Sinuosität oder Asymmetrie; Kernlänge:
sichtbare Altarme 16 → 7–10 von 24). Das ist Anpassung an eine
Realisierung. Punkt 10 bleibt auf Seed 42 im zweiten Fenster offen. Im
Ensemble erfüllen ihn dort 12 von 24 Seeds (Mittel 10,6); ein Hebel dafür
müsste die gewundenen Zubringer unter der Chute-Schwelle oder die Länge
der mobilen Abschnitte angehen, nicht die Messung.

### Nachher (Standard-Config, neue Gürtel-Messung)

| Seed | Fenster | 9 Sinuosität | 10 λ/Breite | 11 Gürtel/Amplitude | 12 Asymmetrie | 13 Altarme sichtbar | davon nass |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1337 | 10.000–20.000 | 1,79 (1,32–2,38) | 13,8 (8,0–17,5) | 5,4 (3,6–8,6) | 2,43 (1,74–3,55) | 10,7 (9–12) | 2,2 |
| 1337 | 50.000–100.000 | 1,85 (1,24–4,94) | 12,4 (5,0–15,8), 1 n. m. | 11,1 (6,1–19,5) | 3,67 (1,84–12,97) | 11,2 (4–17) | 3,6 |
| 42 | 10.000–20.000 | 1,63 (1,20–1,98) | 12,8 (11,9–14,4), 3 n. m. | 5,1 (2,8–8,3) | 3,13 (2,32–5,15) | 3,2 (1–5) | 1,0 |
| 42 | 50.000–100.000 | 1,63 (1,02–2,18) | **8,3** (3,5–19,4), 16 n. m. | 13,8 (4,5–55,9), 1 n. m. | 2,58 (1,23–6,72) | 4,8 (2–8) | 1,7 |
| 20 | 10.000–20.000 | 1,63 (1,44–1,78) | 11,9 (5,4–16,0) | 5,8 (3,4–8,0) | 2,66 (1,53–4,31) | 4,5 (2–8) | 1,3 |
| 20 | 50.000–100.000 | 1,72 (1,38–2,23) | 10,6 (4,8–16,7), 15 n. m. | 7,1 (2,5–14,6) | 2,35 (1,24–4,45) | 3,3 (1–6) | 1,0 |

Ensemble, Seeds mit erfülltem Punkt (Mittel über die Seeds), vorher → nachher:

| Punkt | 10.000–20.000 | 50.000–100.000 |
| --- | --- | --- |
| 9 Sinuosität 1,5–2,5 | 18 (1,84) → 18 | 20 (1,88) → 20 |
| 10 λ/Breite 10–14 | 15 (12,1) → 15 | 12 (10,6) → 12 |
| 11 Gürtel ≥ 3 × Amplitude | 17 (4,05) → 23 (4,98) | 24 (15,6) → 24 (10,4) |
| 12 Asymmetrie ≥ 2 | 18 (3,00) → 18 | 24 (4,19) → 24 |
| 13 ≥ 3 sichtbare Altarme | 16 (4,42) → 16 | 18 (4,78) → 18 |

Summe 182 → 188 von 240, Matrix-Seeds 28 → 29 von 30.

### Laufzeit, Determinismus, Wächter

`SimCore/Sources` ist in diesem Schritt unverändert, Laufzeit und Physik sind
die des Zeitmittel-Schritts (+4,5 % gegen `origin/main`, oben).
`simperf --hash` zweimal `1625b1e4b83c85f4`, gleich wie dort.
SimCore-Pflichtsuite lokal: 471 Tests, 0 Fehler, 183 s;
`testRangeLandformMeetsTheAcceptanceSheet` 12,1 s (vorher 12,0 s). Der
Wächter für Gürtel/Amplitude steht jetzt bei > 2,7 (kleinstes Dreier-Mittel
aus 24 Seeds 2,80, Matrix-Seeds 5,4), s. Tabelle in § Wächter.

### Stand gegen den Abnahmebogen (Zeitmittel je Seed)

| Punkt | Stand |
| --- | --- |
| 9 Sinuosität 1,5–2,5 | **erfüllt** auf allen drei Seeds in beiden Fenstern (1,63–1,85) |
| 10 Wellenlänge 10–14 Breiten | **erfüllt** außer Seed 42 im Fenster 50.000–100.000 (8,3; 16 von 26 Stützstellen nicht messbar); offen, ohne Anpassung an die Realisierung nicht erreicht (s. oben) |
| 11 Gürtel ≥ 3 × Amplitude | **erfüllt** auf allen drei Seeds in beiden Fenstern (5,1–13,8), korrigierte Messung |
| 12 Querprofil-Asymmetrie ≥ 2 | **erfüllt** auf allen drei Seeds in beiden Fenstern (2,35–3,67) |
| 13 ≥ 3 sichtbare Altarme im Tiefland | **erfüllt** auf allen drei Seeds in beiden Fenstern (3,2–11,2) |
| 14–18, 48, 49 | unverändert (s. vorige Tabelle) |

## Bildprüfung und Frame-Zeiten auf dem Referenz-Mac (Abnahmepunkte 47, Bildpunkte)

Gemessen auf dem Integrationsstand aller Pakete (Draft #180: A, B mit
Kalibrierung, C Teil 1 und 2, D, E samt Review-Fixes), lokal gebaut auf dem
M4-Max-Referenz-Mac (MacBook Pro, Display 3456×2234, maximiertes Fenster
3456×2104), Steam-Godot 4.7.2, `scripts/graphics-matrix.sh` (Flusstal-Bühne,
Variante `baseline`). Lokaler Extension-Build und Messung auf ausdrückliche
Freigabe des Projekteigners (AGENTS.md verbietet Agenten den lokalen Build
sonst, s. dort).

### Punkt 47: Frame-Zeiten (`balanced`, maximiert)

`RS_MATRIX_CAMERA=<cam> scripts/graphics-matrix.sh baseline <out> timing`,
3 Seeds × 3 Stadien (0 / 20.000 / 100.000 Jahre) je Kamera, Betrieb Standbild
(`still`) und Kamerafahrt (`orbit`), 108 Läufe, alle Viewport (3456, 2104).
Gemessen vor den Review-Fixes am Fels-Shader und den Bändern (die
Shaderkosten der Fixes sind nicht nachgemessen).

| Betrieb | Läufe | größtes Mittel | größtes p95 | größtes p99 | Frames > 33,3 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Standbild | 54 | 23,0 ms | 23,7 ms | 23,9 ms | 0 |
| Kamerafahrt | 54 | 23,6 ms | 25,1 ms | 25,3 ms | 0 |
| Zeitraffer (nicht Teil von 47) | 54 | 27,1 ms | 71,4 ms | 113,1 ms | 2208 |

Größtes p95 je Kamera (Standbild / Fahrt): overview 17,0 / 17,8, detail 23,7 /
23,0, grazing 23,7 / 25,1, diorama 14,6 / 14,5, valley 15,6 / 16,2, close
16,4 / 17,6 ms. Punkt 47 erfüllt. Der Zeitraffer überschreitet das Budget an
Upload-Frames (p95 bis 71 ms) — Befund, nicht Abnahmekriterium.

### Vorher/Nachher-Bögen

`docs/screenshots/zielbild-174/seed<S>_<J>.jpg`: je Seed und Stadium alle neun
Matrix-Kameras, oben `main` (vor #174), unten der Integrationsstand.
`presets_20k.jpg` / `presets_100k.jpg`: die drei Vorlagen-Ansichten über die
Tasten-Presets F1 (Diorama, Vorlage C), F2 (Tal, Vorlage B), F3 (Nah,
Vorlage A) auf allen drei Seeds (`RS_CAMERA`, adaptiv, maximiert).

Die festen Matrix-Kameras (`detail`, `coast`, `snow`, …) sind für die Welten
VOR der Großform aus Paket A gewählt und zeigen auf der neuen Welt teils andere
Ausschnitte; für das Urteil über die Vorlagen sind die Preset-Bögen gedacht.

Beim Durchsehen gefundene und behobene Befunde (je im zuständigen PR):
Fels mit gleichmäßigem Liniennetz (D, #177), blockige Raster-Treppe unter dem
Hauptlauf und rechtwinklige Bandenden an Kaskaden (C Teil 2, #181),
Diorama-Rahmung und Tal-/Nah-Ziel (E, #176). Offen als Bildurteil: der große
See wirkt bei flachem Blick milchig (Himmelsspiegelung der allgemeinen
Wasser-Optik, nicht aus #174), Fels insgesamt eher hell und glatt gegenüber
dem schroffen Fels der Vorlagen.

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

## Raster-Abkürzungen im Mäandergürtel (Befund im Zeitraffer, Jahr 2.305)

Befund des Koordinators nach dem Geister-See-Fix (Seed 1337, Jahr 2.305,
`RS_TARGET="13.8,6.8"`, Draufsicht): breite, flache, blockige blaue Flächen
mit treppigen, rechteckigen Ufern in und zwischen den Schlingen, teils quer
zum Hauptlauf, dazu kleine runde blaue Punkte neben den Bändern. Werkzeug:
`testBeltLakeZoomDiagnostic` in `BeltLakes.swift` (Ausschnitt als BMP mit
`RS_DUMP`, Komponenten-Tabelle, ganze Karte; Zeitraffer-Takt 15 Jahre wie
`Main.gd`, `RS_TIME=1` misst das Wasserfeld).

### Was die Flächen sind

Keine Seen: im Ausschnitt (±110 Zellen) malt der See-Kanal nichts, und unter
keiner der Flächen steht Wasser (`hf − h` über `pondContourLo` auf 0–2
Zellen je Komponente). Es ist der Fluss-Kanal (R) des Raster-Wassers, also
D8-Läufe mit 3.000–14.000 Zellen Abfluss (Hauptlauf-Klasse), 7–17 Zellen
breit. Zwei Arten:

| Komponente (Zellen) | Breite | D8-Abfluss | Band ≤ 3 Zellen | auf Gleithang-Bank | Art |
| ---: | ---: | ---: | ---: | ---: | --- |
| 476 | 17 | 13.361 | 110 | 383 | Abkürzung über den Gleithang zwischen zwei Bandbögen |
| 102 | 9 | 9.823 | 99 | 9 | Abkürzung am Band entlang |
| 1.249 | 38 | 9.891 | 28 | 287 | Hauptlauf ohne Band (das Band endet stromauf, das Raster übernimmt) |

Die Abkürzung entsteht, weil Gürtel-Linie und D8-Entwässerung nicht
gekoppelt sind (§ Flüsse laufen bergauf): der D8-Lauf fließt über die Bank
quer durch die Schlinge, das Band malt den Bogen außen herum. Die
Bergauf-Blende ist nicht die Ursache: ohne `fadeUphill` blieben die
Komponenten unverändert (476 / 102 / 1.249 Zellen).

**Treppenform:** das R-Feld ist ein Zellraster. Der Lauf folgt den D8-Zellen
(acht Richtungen, also selbst eine Treppe), wird mit zwei
4er-Dilatationen (`widenThresholds`) und einem 3×3-Blur verbreitert und im
Shader bilinear gelesen und mit `smoothstep(riverMaskLo, riverMaskHi)`
geschwellt. Die Kontur läuft deshalb an Zellkanten entlang. Bei einem
Ein-Zellen-Bach fällt das nicht auf, bei einem auf der flachen Bank voll
verbreiterten Hauptlauf schon. Seen haben eine Kontur je Pixel aus
`waterLevel − h`, Raster-Flüsse keine.

**Runde Punkte:** Ein- bis Drei-Zell-Flecken des Rasters im Band-Korridor
neben der Bandkante, wo das Band nicht deckt. Korridor-Zellen waren ganz vom
Kohärenz-Gate (`streamGate`, 28 Zellen) ausgenommen, damit der Saum
überlebt; die Ausnahme galt aber auch für alles, was der Korridor darüber
trug. Nach Blur und Uferring im Shader standen sie als runde Punkte.

### Fix (`WaterFieldRenderer`, Kalibrierung `WaterRender`)

- Auf Gleithang-Bänken (`barAge ≥ 0`) trägt das Raster nur den Saum, wenn
  höchstens `rasterBarBandReachCells` = 16 Zellen entfernt ein sichtbares
  Band (Deckung ≥ 0,3 an seiner Zentrumslinie) mit mindestens dem halben
  Abfluss läuft (`rasterBarBandDischargeRatio`). Reichweite 8 ließ von der
  Abkürzung 158 Zellen stehen, 16 nahm sie ganz, 32 schnitt schon den
  bandlosen Hauptlauf an (1.249 → 730).
- Die Gate-Ausnahme des Korridors gilt nur noch für den Saum.

Ganze Karte, Jahr 2.305, vorher → nachher:

| Seed | sichtbare Raster-Flecken unter 28 Zellen | sichtbarer Raster-Fluss auf Bänken ohne Band |
| ---: | --- | --- |
| 1337 | 150 (479 Zellen) → 2 (2) | 1.769 → 713 Zellen |
| 42 | 93 (338) → 0 | 568 → 232 |
| 20 | 97 (346) → 0 | 858 → 383 |

Hauptlauf (`testMainStemBandDiagnostic`, D8-Hauptlauf, Anteil der Zellen
ohne Band und ohne Raster), vorher → nachher:

| Seed | Jahr 2.300 | Jahr 20.000 |
| ---: | --- | --- |
| 1337 | 2,0 → 5,6 % (längste 6 → 12) | 16,8 → 18,4 % |
| 42 | 4,5 → 9,8 % (längste 11 → 18) | 0 → 0 % |
| 20 | 19,5 → 29,2 % (längste 62 → 85) | 12,2 → 12,2 % |

Die Kennzahl zählt Zellen des D8-Pfads. Wo der D8-Lauf die Schlinge
abkürzt, malt jetzt das Band den Fluss außen herum, die Abkürzung selbst
zählt als Lücke. Auf Seed 1337 / Jahr 2.300 kommen 1,0 Punkte aus dem
Korridor-Gate und 2,6 aus der Bank-Schranke; auf Seed 20 fast alles aus der
Schranke (allein 28,3 %; in der Karte ist es der D8-Lauf quer durch die
große Schlinge im Osten). Nicht
abgefangen: der bandlose Hauptlauf (Komponente 1.249) bleibt Raster und
damit treppig; dort fehlt das Band, nicht die Schranke.

Kosten: `WaterFieldRenderer.bytes`, Produktion Seed 1337 / Jahr 2.305, M4
Max, Median über 15 Aufrufe, drei Runden abwechselnd vorher / nachher:
8,36 / 9,65 — 9,07 / 9,46 — 8,65 / 9,87 ms (rund +1 ms je Wasser-Update).
Ein Vollbild-Maximumfilter über die Reichweite kostete +2 ms und wurde
durch die Suche nur an Bank-Zellen mit Raster-Fluss ersetzt. Die Sim ist
unberührt.

Wächter: `RasterBeltTests` (beide rot ohne den Fix: 9 Flecken unter dem
Gate, 17 Raster-Zellen auf Bänken neben dem eigenen Band).
