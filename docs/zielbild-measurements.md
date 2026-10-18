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

- **Erledigt: Eis hing an der Schrittweite, schon vor #174.** Produktion,
  Jahr 20.000, Eismasse bei dt 100 gegen 1000 auf `origin/main`: 77,4 / 128,1
  (1337), 0,29 / 1,04 (42), 117,1 / 179,5 (20); mit der neuen Form 49,6 / 126,3,
  65,3 / 31,5, 162,3 / 57,1. Der Wächter `testIceIsFramerateIndependent`
  (n = 256) lag auf der alten Welt zufällig in einem ruhigen Bereich. Drei
  Ursachen (instabiler Eis-Transport bei dickem Eis, Pfützen-Verlandung
  füllte den Gletscherschliff großer Schritte wieder auf, Temperatur vom
  Schrittanfang), behoben und neu bewacht: `docs/glacier-measurements.md` §L.
- **Stream-Map trackt die großen Läufe schlechter.** `testStreamMapMarksAndPersists`
  (n = 256, Zellgröße der Suite) misst auf der neuen Form einen Recall von
  0,15 statt > 0,40: die Tropfen folgen den großen D8-Läufen in der flachen
  Ebene seltener. Das betrifft Abnahmepunkt 21 (Hauptlauf ohne Lücke) und ist
  in Paket C auf dem Produktionsgitter nachzumessen.

  Nachgemessen (`testStreamMapRecallDiagnostic`, Produktion n = 720, Jahr
  20.000, Welten von `0fec08b`): auf dem Produktionsgitter liegen 41–58 % der
  großen D8-Läufe (Abfluss ≥ 10 × Bach-Schwelle) über der Track-Schwelle,
  gemalt sind sie zu 94–96 %, weil Band und Abfluss-Vertrauen sie tragen.
  Die Stream-Map entscheidet nur über die kleinen Zubringer: unter 3 ×
  Bach-Schwelle sind 20–28 % gemalt, mit einer perfekten Stream-Map
  („Orakel") wären es 74–82 %. Das ist gewollt (weniger, dünnere Bäche; die
  Stütze filtert verwaiste Linien). Die Hauptlauf-Lücke von Seed 1337
  (18 %, längste 39 Zellen; 42: 0 %, 20: 12 % an der Quelle) bleibt OHNE
  Stream-Map gleich (18,1 %): sie kommt aus der Entkopplung Gürtel ↔ D8
  (#187, unten), nicht aus der Stream-Map. Deshalb keine Änderung an der
  Stream-Map.

### Laufzeit und Determinismus nach Paket A

`simperf` (Produktion, Seed 1337, M4 Max, 2026-10-11), alt (`origin/main`
`55323b5`) und neu abwechselnd, je `--repeat 3`: alt 48,5 / 48,9 / 49,0 ms,
neu 43,8 / 44,1 / 44,3 ms je Schritt (Median 48,9 → 44,1). Keine Optimierung,
sondern eine andere Welt (weniger Seen und Läufe). Einlauf samt Generierung
5,2 / 5,3 s → 4,9 / 4,8 s. `simperf --hash` zweimal `ba89c2b11150f5a5`
(Punkt 49; der Wert gilt nur auf dieser Maschine).

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
   aus (`meanderBeltPull = 0`); mit #187 samt Code entfernt.
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
### Wald auf der neuen Großform (Abnahmepunkt 40)

`testCanopyCoverageDiagnostic`, Wald in % des Landes, Schwellen #168
(0,35/0,55) auf der Großform: 1337 16,4 / 15,4 / 14,4, 42 27,5 / 23,5 / 15,9,
20 24,4 / 18,6 / 13,6 (Jahr 2000 / 20.000 / 100.000; mit Paket D gemessen,
ohne D 28,6 auf Seed 42 — die Ursache ist die Großform, nicht das Material).
`CanopyRender` steht deshalb auf 0,40/0,60: 11,8–23,3 % über alle Seeds und
Jahre.

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
`MeanderBeltTests.testLongRunStaysBoundedWithBothCutoffs` (keine
Selbstkreuzung der Zentrumslinie, örtliche Sinuosität nach 60.000 Jahren
zwischen 1,5 und 10; ohne Störquelle lag sie bei 1,0; bis #187 stand die
obere Grenze bei 6, s. unten). Die Schranken liegen bewusst weit unter den Messwerten: ein
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
Sinuosität 3,3–5,1 (Grenze 6). Nach der Kern-Kalibrierung von #187
(Rate 0,03, Kern 1,0 Breiten) über 24 Rausch-Seeds: 131–169 Hals, 610–772
Chute, örtliche Sinuosität 4,6–8,1 (Median 6,1), Selbstkreuzungen 0 auf
allen; auf Linux kippte die Grenze 6 (Seed 7: 7,66). Ein enger Omega-Bogen
kurz vor dem Hals-Cutoff erreicht über 20 Breiten Bogenlänge allein schon
7–8, die Sinuosität ist also kein Knäuel-Maß. Der Wächter prüft seitdem das
Knäuel selbst (keine Selbstkreuzung, Gegenprobe
`testSelfCrossingsSeparatesKnotFromOmega`) und hält die Sinuosität nur grob
unter 10. Wellenlängen- und dt-Wächter laufen
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
16,4 / 17,6 ms. Punkt 47 erfüllt.

**Nachmessung auf dem Endstand** (Integrationszweig mit allen Review-Fixes:
Fels-Shader #177, Bänder #181, adaptive Presets #176; dieselben 162 Läufe,
2026-10-12):

| Betrieb | Läufe | größtes Mittel | größtes p95 | größtes p99 | Frames > 33,3 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Standbild | 54 | 27,9 ms | 30,0 ms | 30,2 ms | 0 |
| Kamerafahrt | 54 | 27,4 ms | 30,2 ms | 30,6 ms | 0 |
| Zeitraffer (nicht Teil von 47) | 54 | 33,1 ms | 79,0 ms | 92,0 ms | 2239 |

Größtes p95 je Kamera (Standbild / Fahrt): overview 15,3 / 15,3, detail 26,6 /
25,1, grazing 30,0 / 30,2, diorama 19,5 / 19,2, valley 17,0 / 17,1, close
18,2 / 19,6 ms. Punkt 47 bleibt erfüllt, die Marge in der flachen
Grazing-Kamera schrumpft aber auf ~3 ms: der neue Fels-Shader (damals bis
3 × 9 + 2 Rausch-Abfragen je Felspixel, nicht 3 × 8; seit „Fels und Wasser"
unten 3 × 4 + 2, solange die Fugen ausgeblendet sind) kostet dort rund 5 ms. Erster Hebel, falls das
Budget enger wird: die Kluft-Richtungen mit kleinem Gewicht früher
überspringen oder die Kluft-Auflösung mit der Distanz stärker ausblenden. Der Zeitraffer überschreitet das Budget an
Upload-Frames (p95 bis 71 ms) — Befund, nicht Abnahmekriterium.

Nachtrag: die Ursache waren nicht die Uploads, sondern Sim-Schritt und
Frame-Aufbereitung synchron im Takt-Frame. Seit sie auf einem
Hintergrund-Thread laufen, liegt der Zeitraffer auf der Kamera `detail` beim
Standbild (p95 ~25 ms statt ~98 ms auf ruhigem Rechner); Messprotokoll und
Nachmessung: `docs/perf-measurements.md` §L.

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
Diorama-Rahmung und Tal-/Nah-Ziel (E, #176). Die beiden danach offenen
Bildurteile (großer See bei flachem Blick milchig, Fels hell und glatt) sind
im Abschnitt „Fels und Wasser" am Ende dieses Dokuments untersucht und
behoben.

## Glas-Weichzeichner (Abnahmepunkt 43, Paket E)

Hinter jedem Glas-Panel liegt ein Weichzeichner (`game/ui/glass_blur.gdshader`,
Radius und Abdunklung im Theme, `RS_UI_BLUR=0` lässt ihn weg). Bildbelege:
`docs/screenshots/zielbild-174/glass-hud_*.jpg`: je Seed (1337, 42) und Kamera
Tal bzw. Nah die vier Bedien-Ausschnitte vorher (links, ohne Weichzeichner) und
nachher (rechts), dazu `…_gesamt.jpg` (ganzes Bild, Tal) und
`glass-hud_stress_hintergruende.jpg` (Lesbarkeit, s. u.). Aufnahmen
maximiert, Viewport (6016, 3260), `balanced`, Jahr 20.000, `RS_CAMERA`,
`RS_SHOT_UI`.

### Lesbarkeit

Der Weichzeichner allein macht Glas über Schnee mittelgrau; die gedämpfte
Schrift (Abschnittsüberschriften 60 %, Tempo 78 %) verlor dort Kontrast.
Deshalb multipliziert der Shader das verwischte Bild mit `GlassBackdrop/dim`
(Theme, `Color(0.66, 0.68, 0.72)`). Gemessen an einer Wegwerf-Szene mit
synthetischem Hintergrund unter der echten Bedienung (Schnee `#f2f5f9`,
dunkles Wasser `#0b2a3d`, Schachbrett Weiß/Schwarz 10 px als härtestes
Hochfrequenz-Muster; Bild `glass-hud_stress_hintergruende.jpg`, v. l. n. r.:
Schachbrett ohne, mit Weichzeichner, Schnee, Wasser). Panel-Hintergrund als
Pixelwert, daraus WCAG-Kontrast der Theme-Schriften (Weiß mit dem jeweiligen
Alpha über dem Panel):

| Hintergrund | Panel RGB | Label 92 % | Knopf 86 % | Tempo 78 % | Abschnitt 60 % |
| --- | --- | ---: | ---: | ---: | ---: |
| Schnee, ohne Abdunklung | 96 100 106 | 5,3 | 4,9 | 4,4 | 3,3 |
| Schnee, `dim` 0,66 | 67 72 81 | 8,1 | 7,3 | 6,4 | 4,5 |
| dunkles Wasser, `dim` 0,66 | 13 23 33 | 15,3 | 13,5 | 11,2 | 7,1 |

Mit der Abdunklung liegt jede Schrift auf dem hellsten realistischen Grund bei
mindestens 4,5 (WCAG AA für Fließtext), ohne sie fiel die kleinste (14 px,
60 %) auf 3,3. Der Weichzeichner selbst hilft der Lesbarkeit zusätzlich: das
Schachbrett (links) wird zu gleichmäßigem Grau, harte Kanten laufen nicht mehr
unter der Schrift durch. Der Wert ist EIN Theme-Eintrag; heller oder dunkler
zu stellen ändert nur diese Zeile.

### Kosten

Verfahren: die Messbühne (`game/studies/flusstal/Flusstal.gd`, neu
`RS_STUDY_UI=ab`) schaltet im SELBEN Prozess blockweise zwischen drei Zuständen
um: `hidden` (keine Bedienung, wie bisher bei Punkt 47), `plain` (Bedienung
ohne Weichzeichner) und `glass` (mit). Ein Block sind 90 Bilder, davon zählen
die letzten 78; die Reihenfolge der drei Zustände wird je Runde um einen
verschoben, Runde 0 wärmt Shader und Pipelines nur an und zählt nicht. Je Runde
ergibt sich so ein gepaarter Unterschied (`glass − plain` ist der Preis des
Weichzeichners, `plain − hidden` der der Bedienung ohne ihn), ausgewertet als
Median über die Runden. Das ist das verlangte Interleaving mit mehreren
Runden und hält Fremdlast, Takt und Wärme aus dem Vergleich: auf diesem Rechner
liefen während der Messung andere Agenten (`uptime` vor und nach jedem Lauf:
Load 31–114 auf dem M4 Max, also weit über Last 10). Absolute Bildzeiten liegen
deshalb über denen aus Punkt 47 (Grazing dort p95 30,0 ms im Standbild, hier
Median 30–36 ms); belastbar sind nur die Unterschiede.

```sh
RS_SEED=1337 RS_STEP=20000 RS_STEP_CHUNK=1000 RS_QUALITY=balanced \
RS_TARGET=-10,-20 RS_DIST=38.0 RS_YAW=0.7 RS_PITCH=1.35 \
RS_STUDY_VARIANT=baseline RS_STUDY_MODE=still RS_STUDY_UI=ab RS_STUDY_ROUNDS=14 \
scripts/start.sh --maximized res://studies/flusstal/Flusstal.tscn   # druckt STUDY_UI_AB
```

Kameras sind die der Matrix (`scripts/graphics-matrix.sh`: `grazing` = knappste
Kamera von Punkt 47, `valley` = Vorlage B), Betrieb `still` (Standbild) und
`orbit` (Kamerafahrt), maximiert, Viewport (3456, 2104) wie bei Punkt 47,
`balanced`, Jahr 20.000. 14 Runden je Lauf; Median der gepaarten Rundenwerte
in ms, in Klammern kleinster und größter Rundenwert (Ausreißer kommen von
Fremdlast):

| Seed / Kamera | Betrieb | Median `hidden` / `plain` / `glass` | `glass − plain`, Median | `glass − plain`, Block-p95 | `plain − hidden` |
| --- | --- | --- | --- | --- | --- |
| 1337 grazing | Standbild | 35,6 / 35,9 / 36,1 | **+0,52** (−28,6 … +32,4) | +0,52 | +0,14 |
| 1337 grazing | Fahrt | 37,6 / 37,7 / 38,6 | **+0,74** (−1,0 … +3,4) | +0,75 | −0,03 |
| 1337 valley | Standbild | 19,7 / 19,7 / 20,2 | **+0,49** (0,0 … +0,6) | +0,55 | +0,04 |
| 1337 valley | Fahrt | 20,7 / 20,6 / 20,7 | **+0,33** (−0,7 … +1,5) | +0,36 | +0,14 |
| 42 grazing | Standbild | 30,3 / 30,4 / 30,8 | **+0,52** (+0,35 … +0,58) | +0,51 | +0,03 |
| 42 grazing | Fahrt | 30,4 / 31,2 / 30,8 | **+0,40** (−2,1 … +1,7) | +0,99 | −0,08 |

Block-p95 heißt: je Block der p95 der 78 Bildintervalle, dann der gepaarte
Unterschied je Runde, davon der Median. Der über alle Bilder gepoolte p95
taugt unter dieser Last nicht (einzelne Fremdlast-Spitzen ziehen ihn hoch,
z. B. 65,7 ms gepoolt gegen 36,1 ms Median in der ersten Zeile); er steht in
der Rohausgabe `STUDY_UI_AB`.
Eine zweite Serie mit 12 Runden (ohne Block-p95; Standbild und Fahrt auf
1337 grazing und valley, 42 grazing, 42 valley Fahrt, dazu drei Läufe mit
`--resolution 3456x2104`, hier dieselbe Pixelzahl wie maximiert) ergab
`glass − plain` zwischen +0,39 und +0,77 ms, im Mittel +0,54 (9 Läufe).

Ergebnis: **der Weichzeichner kostet rund 0,5 ms je Bild** (0,3–0,8 ms, bei
Standbild wie Fahrt, nach p95 wie nach Median gleich), in der knappsten
Kamera 1,3–2,0 % der Bildzeit, im Tal-Standbild (kürzere Bildzeit) 2,5 %. Das Budget von Punkt 47 (p95 ≤ 33,3 ms;
Endstand dort Grazing 30,0 / 30,2 ms) bleibt damit erfüllt, die Reserve
schrumpft von rund 3 ms auf 2,5 ms. Die Bedienung selbst ohne Weichzeichner
(`plain − hidden`) ist nicht messbar (|Δ| ≤ 0,15 ms).

**Auflösung:** der Preis hängt an der Pixelzahl, nicht an der Panelfläche.
Auf dem 6016×3260-Viewport dieses Macs am externen Display (2,7-fache
Pixelzahl, dieselbe Messung mit 8 Runden bei Last 11–19, 1337 grazing,
Standbild) kostete er +1,2 ms (+0,43 … +1,52).

**Wohin die Zeit geht** (Nebenbefund, 6016×3260, 6 Runden, Last 15–120, also
nur Größenordnung; Varianten über einen Wegwerf-Schalter, nicht im Repo):
voller Shader +1,0 ms (zweiter Lauf; der erste +3,6 ms bei Last 55), ohne
Mip-Kette (nur Bildschirmkopie plus Shader) +0,4 und +0,6 ms, nur eine statt
neun Abfragen +0,9 und +1,0 ms. Godot kopiert den
Bildschirm EINMAL je Bild und baut dessen Mip-Kette, unabhängig davon, wie
viele Panels ihn lesen; je zur Hälfte geht der Preis auf die Kopie und auf die
Mip-Kette, der Shader auf den Panelflächen ist vernachlässigbar.
Verworfen: ein `BackBufferCopy` je Panel mit Rechteck-Kopie, um nur die
Panelflächen zu kopieren. Mit der Teil-Kopie las der Weichzeichner
schwarz (im Screenshot nahezu schwarze Panels, nicht abgelegt), die Mip-Stufen
waren offenbar nicht gefüllt; die Ursache ist nicht untersucht. Ohne Mip-Kette
bräuchte der Weichzeichner Dutzende Abfragen je Pixel; bei 0,5 ms Gesamtpreis
lohnt der Umbau nicht. Hebel, falls das Budget enger wird: Weichzeichner in
`performance` weglassen (eine Bedingung in `_setup_ui`).

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

Fortsetzung (Ansatz Avulsion, Kopplung ohne Erben, Neukalibrierung):
§ Gürtel und Entwässerung: Avulsion (#187).

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

Abwägung (Review-Befund „Seespiegel fällt ungedämpft", bewusst so belassen):
der Sägezahn, für den die Glättung da ist, entsteht beim ANSTIEG (Sill
zugeschüttet, `hf` springt fürs ganze Becken); der gedämpfte Spiegel steigt
während des ~100-jährigen Plugs nur um den Rest, und genau diesen Rest gibt
der sofortige Abfall wieder ab. Die sichtbare Amplitude bleibt damit dieselbe
(`testWaterLevelDampsFillJumps`). Ein See, der über seinen Auslass natürlich
ausläuft, senkt `hf` selbst nur mit der Inzisionsrate; der Spiegel folgt ihm
ohnehin stetig. Nur ein Becken, das in EINEM Schritt angezapft wird, ist
einen Sim-Schritt später leer; im Bild verteilt die Überblende der Uploads
(`RenderState.frame`) auch das über den Zeitraffer-Takt. Eine Dämpfung des
Abfalls bräuchte ein Kriterium „Boden wurde abgetragen" gegen „See läuft
aus", das der Spiegel allein nicht kennt, und brächte die Geister-Seen
zurück, sobald es danebenliegt.

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

## Fels und Wasser: die zwei offenen Bildbefunde (2026-10-17)

Zwei Bildurteile des Projekteigners blieben nach der Abnahme offen: der
große See wirkt bei flachem Blick milchig, und der Fels ist heller und
glatter als der schroffe Fels der Vorlagen A/B (Abnahmepunkte 31/32). Beides
ist reine Render-Arbeit, die Physik bleibt unberührt. Gemessen und gerendert
auf dem M4-Max-Referenz-Mac, offizielles Godot 4.7.2, eingebauter Bildschirm,
maximiert 3456×2104, `balanced`.

### Diagnose

Vor jeder Änderung wurden die Terme einzeln sichtbar gemacht: temporäre
Debug-Ausgaben in allen drei Wasser-Shadern und im Terrain-Shader (nicht im
Repo), jeweils als unbeleuchtete Emission oder mit abgeschaltetem Term.
Kameras: flach über den Kratersee von Seed 42 (Ziel 16/3,6, Distanz 14,
Pitch 0,2, Sonne im Rücken) und die Tal-Kamera von Seed 20 (Gegenlicht).

**Wasser.** Vier Ansichten derselben Szene:

| Ansicht | See (flach) | Meer am Horizont |
| --- | --- | --- |
| nur Albedo, ohne Godot-Spiegelung (`SPECULAR = 0`) | hellblau, flach | grauweiß, milchig |
| nur Godot-Spiegelung (`ALBEDO = 0`) | dunkles Marineblau mit Wellenstruktur | dunkelblau |
| Fresnel-Term | 0,2–0,3 | bis 0,8 |
| unbeleuchtete Albedo | mittelblau | blaugrau |

Der milchige Film kam also nicht aus der Spiegelung, sondern aus der
**Albedo**: alle drei Shader mischten bei streifendem Blick bis zu 55 % einer
festen Himmelsfarbe (0,62/0,70/0,76) in die Wasserfarbe. Godot behandelt
ALBEDO als diffuse Oberfläche, die Sonne (Energie 2) und das Umgebungslicht
beleuchteten diesen „Himmel" wie Farbe. Obendrauf rechnete Godot seine eigene
Spiegelung der Umgebung, mit `SPECULAR` bis 1,0 beim streifenden Blick
(F0 = 0,16 statt der 0,02–0,04 von Wasser): der Fresnel-Anstieg stand damit
doppelt im Bild. Der Wasserkörper selbst war mit 0,03/0,12/0,26 (linear) für
tiefes Wasser im Licht „Schwimmbad-Blau". Im Gegenlicht (Seed 20, Tal) zog
die Rauheit 0,34 bei steilem Blick die Sonne zu einem breiten milchigen
Fleck über Meer und Flussschleife.

**Fels.** Die Materialgewichte (Debug: Fels/Halde/Grund als RGB) liegen
richtig, die Wände SIND Fels. Die unbeleuchtete Albedo zeigte sie aber
hellgrau: die Felsfarben 0,20–0,33 sind lineare Werte (Godot), auf dem
Bildschirm 0,48–0,61, und die 28-%-Beimischung der Makrofarbe zog sie zum
CPU-Felston 0,37 hoch. Unter der warmen Sonne wurde daraus Hellbeige. Glatt
wirkten die Wände, weil die Klüftung nur TON war: die Normale kam aus dem
15-m-Sim-Gitter, der Verschiebung (#153) und dem feinen Rinnen-Detail, das auf
Fels so schwach lag wie auf Wiese. Das Kluftmuster dunkelte im Mittel um ~6 %
ab, ohne eigenes Licht und Schatten. Dazu kam ein Fehler aus dem Shader-Review
(unten): das Wertrauschen erstarrte weit weg von der Kartenmitte, Körnung und
Klüfte waren dort glatt.

### Lösung

**Wasser (alle drei Wege, Uniform-Vertrag `WaterRender` → `WaterUniforms`):**
- Keine Himmelsfarbe mehr in der Albedo. Den Himmel spiegelt Godot über
  `SPECULAR`/`ROUGHNESS`, der Wasserkörper tritt mit dem Fresnel-Anteil
  zurück (`× (1 − fresnel)`; Godot dämpft die diffuse Albedo nicht selbst).
  Entfallen: `skyReflectColor`, `fresnelSkyMix`.
- Ein Glanzwert statt der Paare steil/streifend: `waterSpecular` 0,5
  (F0 = 0,04), `waterRoughness` 0,08. Die Wellung der Normalen bricht den
  Sonnenglanz jetzt in Funkeln statt in einen milchigen Fleck.
- Dunklerer Wasserkörper: seicht 0,06/0,17/0,18, tief 0,010/0,050/0,085
  (vorher 0,18/0,37/0,42 und 0,03/0,12/0,26).
- Wächter: `WaterRenderTests.testAllWaterShadersShareTheSameWater` (Körper
  tritt mit Fresnel zurück, keine Himmelsfarbe in der Albedo, Rauheit und
  Specular aus `WaterRender`), `WaterUniformsTests` (Tabelle, Spiegel,
  default-freie Deklarationen), `game/tests/water_uniforms.gd`.

**Fels (`terrain.gdshader`, Kalibrierung `MaterialRender`):**
- Albedo dunkler und leicht kühl: Fels 0,07–0,15 (Bildschirm 0,29–0,42),
  Halde 0,22, steiniger Grund 0,17; der CPU-Felston der Makrofarbe
  (`TerrainColorRenderer`) 0,13 statt 0,37.
- Runsen als FORM: `rock_joints` liefert neben dem Ton eine Normalen-Neigung
  aus der analytischen Ableitung des Runsen-Rauschens (`vnoise_d`, dieselben
  vier Zellwerte), dazu feine, scharfkantige Grate (~9 m) in der Nähe.
  Tiefe `MaterialRender.jointRelief` 0,35 Kluftabstände; blendet wie das
  Muster mit der Pixelgröße aus.
- Das feine Rinnen-Detail (runevision) liegt auf Fels um bis zu
  `MaterialRender.rockReliefGain` 2,5 kräftiger (Normale und Abdunklung der
  Rinnenböden).
- Wächter: `MaterialTests` (Tabelle, Aufruf mit Pixelgröße und Normale,
  Runsen kippen die Normale), `game/tests/canopy.gd`.

**Shader-Review (Stand `0fec08b`), im selben Zug:**
1. `vnoise` hashte über `ehash` (Float-Produkt x·y·(x+y)); ab einigen
   Dutzend Zellen vom Ursprung verlor `fract` seine Bits. Jetzt `vhash`: der
   Zellindex wird zuerst auf [0, 17) gefaltet, das Produkt bleibt unter ~10⁴.
   Ein Ganzzahl-Hash (pcg2d) war die erste Fassung und kostete gemessen
   +2,5 ms je Bild (Tabelle unten).
2. Ableitungen nur im gleichförmigen Kontrollfluss: `fwidth` steht genau
   zweimal oben in `fragment()`; Klüftung, Körnung, Spalten und Kronen
   bekommen die Pixelgröße übergeben (Wächter
   `MaterialTests.testNoiseHashAndDerivativesStayDefined`).
3. Vertex-Normale mit dem Vorzeichen der Pixel-Normale (`-(hU - hD)`), die
   Godots Schatten-Normal-Bias liest (`RenderContractTests`).
4. Texelzentrierte Abbildung Welt → Textur in Terrain, Bändern, Meer und
   Wolkenkörpern (`world_uv`/`grid_uv`, `grid_n`): vorher bis zu einen halben
   Texel (~8 m) Versatz zum Rand hin.
5. Felsklüfte: Fugen und Schichtfugen nur, solange `crack_detail > 0`.
6. Ein Abgriff je Pixel für `relief_tex`, `water_tex` (See-Gate aus `w.g`),
   `hf_tex` im Vertex; `debug_difference_tex` nur in der Diagnose-Ansicht.
7. Der Wasser-Block (Kies, Kräuselung, Schimmer, Schaum, zehn
   Rauschabfragen) läuft nur auf nassen Pixeln.
8. Die Fluss-Tiefe des Raster-Wassers liest ihr Fenster aus `WaterRender`
   (`riverDepthLo/Hi`, vorher `smoothstep(0.05, 0.6, …)` im Shader).
9. Bänder: die Kräuselung quer läuft in Weltmaß (UV.x × Bandbreite aus der
   Jacobi-Matrix der Bildschirm-Ableitungen), und die Deckkraft des
   Vertex-Vertrags (auch `fadeUphill`, #187) schrumpft den ganzen Querschnitt,
   nicht nur das Wasser: vorher blieb bei ausgeblendeten Bändern das nasse
   Ufer voll breit als leere Rinne liegen.
10. Feines Rinnen-Detail default-frei über `ReliefRender`
    (`relief_detail_scale/shade/normal`, vorher Literal-Defaults, die Main.gd
    nie setzte); der verrutschte `world_uv`-Kommentar steht wieder an seiner
    Funktion.
11. Leistung: `triplanar_fbm` überspringt Projektionen unter 2 % Gewicht
    (stetig über abgesenkte, neu normierte Gewichte); auf flachem und mäßig
    steilem Land rechnet nur die Draufsicht. Das bezahlt Felsrelief und Hash.

### Frame-Zeiten (Abnahmepunkt 47)

Flusstal-Bühne wie `scripts/graphics-matrix.sh … timing` (Matrix-Kameras,
Jahr 20.000, `balanced`), 3456×2104, interleaved A B B A (Seed 42 und 20
zusätzlich B A A B), vor jedem Lauf gewartet, bis kein fremdes Godot mehr
lief. A = Integrationsstand `ca822ad`, B = dieser Stand. Median über die
Läufe:

| Seed | Kamera | Betrieb | Läufe | Mittel A → B | p95 A → B | Frames > 33,3 ms |
| ---: | --- | --- | ---: | --- | --- | --- |
| 1337 | grazing | Standbild | 2/2 | 24,7 → 24,2 ms | 25,4 → 24,8 ms | 0 / 0 |
| 42 | grazing | Standbild | 4/4 | 22,7 → 21,8 ms | 23,1 → 22,1 ms | 0 / 0 |
| 20 | grazing | Standbild | 4/4 | 23,9 → 23,1 ms | 24,4 → 24,0 ms | 0 / 0 |
| 1337 | detail | Standbild | 2/2 | 18,1 → 18,3 ms | 18,4 → 18,8 ms | 0 / 2 |
| 1337 | close | Standbild | 2/2 | 13,1 → 12,6 ms | 13,3 → 12,6 ms | 0 / 0 |
| 1337 | diorama | Standbild | 2/2 | 14,9 → 14,3 ms | 14,9 → 14,4 ms | 0 / 0 |
| 1337 | grazing | Kamerafahrt | 2/2 | 23,8 → 23,5 ms | 24,2 → 24,0 ms | 0 / 0 |

Die Änderung kostet nichts Messbares; auf der knappen Grazing-Kamera ist sie
0,5–0,9 ms billiger. `detail` liegt mit +0,2 ms im Rauschen der
Einzelläufe (dort zwei einzelne Ausreißer-Frames in einem B-Lauf).

Zwischenstände (gleiches Verfahren, 1337, Median Mittel/p95, je drei Läufe):

| Stand | grazing | detail |
| --- | --- | --- |
| A (`ca822ad`) | 24,7 / 25,4 ms | 18,7 / 19,3 ms |
| Ganzzahl-Hash pcg2d | 27,2 / 27,5 ms | 19,6 / 20,4 ms |
| gefalteter Float-Hash, ohne Triplanar-Sprung | 26,0 / 26,5 ms | 19,5 / 20,2 ms |

Die ersten Läufe dieser Reihe liefen neben fremden Godot-Prozessen und
Swift-Builds anderer Agenten (p95 auf grazing zwischen 43 und 69 ms im
selben Stand); sie sind verworfen.

### Bögen

`docs/screenshots/zielbild-174/look-rock-water_seed{1337,42,20}.jpg`: je Seed
die drei Vorlagen-Presets (F1 Diorama, F2 Tal, F3 Nah, `RS_CAMERA`, Jahr
20.000), oben vorher, unten nachher. `look-rock-water_lakes.jpg`: flach über
den großen See von Seed 1337 (Ziel −12/−10, Distanz 14, Yaw 3,14, Pitch 0,25)
und den Kratersee von Seed 42 (Ziel 16/3,6, Distanz 14, Yaw 0, Pitch 0,2).
Vorher ist der Stand `0fec08b` mit denselben Kameras; die Integration bis
`ca822ad` änderte am Bild nur die Wolkenschatten.

Godot-Vertragstests auf diesem Stand grün: `smoke`, `water_uniforms`,
`water_geometry`, `river_ribbons`, `relief`, `canopy`, `lighting`,
`ui_layout`, `graphics_study`, `build_stamp_parity`.

## Gürtel und Entwässerung: Avulsion (#187)

Ausgang: die Zentrumslinien des Gürtels und die D8-Entwässerung liefen
getrennt (§ Flüsse laufen bergauf, § Raster-Abkürzungen). Auftrag #187:
die Ursache in der Sim beheben, Ansatz „Avulsion" — ein überhöhtes Gerinne
springt in den tieferen Fließweg. Parallel lief ein zweiter Ansatz
(durchgehende Rinne mit monotoner Sohle); dieser Abschnitt misst nur die
Avulsion. Vorher = `0fec08b`, nachher = Branch `t3/174-belt-avulsion`,
Produktion, M4 Max.

```sh
RS_MEASURE=1 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter testBeltCouplingHistoryDiagnostic
# RS_SEED, RS_YEARS, RS_DT, RS_EVERY, RS_VARIANT, RS_SEGLOG=<Jahr> (Aufbau der Läufe)
```

`testBeltCouplingDistanceDiagnostic` und `testZielbildMeanderTimeMeanDiagnostic`
lesen seit #187 `RS_DT` (Schrittweite, Standard 1000).

### Was die Kopplung tut (`Terrain.coupleBeltToDrainage`)

Einmal je Schritt, auf dem frischen Abflussfeld, vor der Migration:

- **Welche Flüsse es gibt, sagt das D8-Netz.** Das große Netz (ab
  `meanderMinCells`) zerfällt in Hack-Abschnitte: an jedem Zusammenfluss läuft
  der größere Zufluss weiter, der kleinere endet IN der Zusammenfluss-Zelle
  (`Terrain.drainageSegments`, dieselbe Regel für die Trasse beim Generieren,
  `MeanderState.traceHorton`). Je Abschnitt ein Lauf. Der Abfluss eines
  Knotens ist das Einzugsgebiet der Abschnittszelle, an der er liegt, entlang
  des Laufs monoton; die Zusammenfluss-Zelle zählt zum größeren Fluss. Ein
  Erben über eine Berührung ist damit ausgeschlossen, und ein Fluss, den ein
  Pinselstrich seiner Linie beraubt hat, bekommt im nächsten Schritt wieder
  eine (Review-Befund 5).
- **Wo er liegt, sagt die alte Linie.** Jeder alte Knoten, der höchstens
  `0,5 · b + meanderBeltCouplingSlackCells` (4 Zellen) von einer
  Abschnittszelle liegt, gehört dorthin; zusammenhängende Strecken werden in
  den neuen Lauf übernommen, kurze Abweichungen eingeschlossen. Wo keine alte
  Strecke liegt, setzt die Kopplung die Abschnittszellen ein (geglättet).
- **Avulsion.** Verlässt eine Linie ihren Abschnitt über mindestens
  `meanderBeltAvulsionWidths` (2) Kanalbreiten, oder liegt das Gelände unter
  dem abgekoppelten Stück im Mittel mehr als `meanderBeltAvulsionDepths` (2)
  Bankfull-Tiefen über dem Abschnitt, springt der Fluss in den D8-Weg — als
  Ereignis mit der Rate 1/`meanderBeltAvulsionYears` (1000 Jahre),
  deterministisch aus Zeit und Ort. Das verlassene Gerinne eines wandernden
  Laufs wird ab `meanderBeltAbandonMinWidths` (5) Kanalbreiten Altarm (Alter
  am Schrittende, verkorkt und verlandet wie nach einem Cutoff), immer
  bekommt es eine `barAge`-Narbe.

Wächter: `BeltCouplingTests` (Kunstwelt: ein abgekoppeltes Stück springt,
der Altarm entsteht, der Oberlauf bleibt, kein geerbter Abfluss; bei sehr
großem τ springt nichts; eine Linie ohne Fluss verschwindet, der Fluss wird
getrasst), dazu Determinismus und Bank-Alter mit wandernden Läufen auf dem
kleinen Gitter.

### Befunde

1. **Ein erster Entwurf am Quellknoten verlor die Läufe.** Der D8-Weg ab der
   Quelle eines Laufs, gekappt am größeren Zusammenfluss, mit Sonderregeln für
   Anzapfung, geköpfte Läufe, neue Quellen und Übergabe des Unterlaufs: in
   20.000 Jahren (Seed 1337) 729 → 373 Läufe, ≥ `renderMinCells` 160 → 86,
   1595 Anzapfungen, 845 Neu-Quellen. Jede Verlagerung einer kleinen Quelle im
   Gebirge kappte einen ganzen Unterlauf. Die Hack-Abschnitte je Schritt
   ersetzen alle Sonderregeln durch eine: 570 ± 30 Läufe, stabil.
2. **Ohne Erben verlieren die Mäander ihre Sinuosität — unabhängig von der
   Avulsion.** Auf der alten Kalibrierung (Rate 0,02, Kern 1,5): 140 bis 155
   von 240 Punkten, Sinuosität 1,32–1,46, egal ob die Avulsion nach 2, 4 oder
   8 Breiten oder ohne Überhöhungs-Kriterium greift (Tabelle unten). Das
   bestätigt § Ursache in der Sim: Versuche — die gewundenen, frei wandernden
   Läufe der alten Kalibrierung trugen ihren Abfluss geerbt. Ein
   Schwellen-Schnitt (Sohle bis 3 Tiefen auf den tiefsten Bezug stromauf,
   der Kandidat aus § Ursache in der Sim) half dagegen nicht (135 von 240).
3. **Die Avulsion hing an der Schrittweite**, solange sie bei der ersten
   Prüfung sprang: Seed 1337, 8000 Jahre, dt 100 gegen 1000: 204 gegen 71
   Avulsionen. Das Abflussfeld flackert von Schritt zu Schritt; je öfter
   geprüft wird, desto öfter trifft die Prüfung eine Abweichung. Als Rate
   (τ = 1000 Jahre): 53 gegen 41.
4. **Neu kalibriert:** gekoppelt muss ein Bogen schneller wachsen, als das
   D8-Netz ihn abkürzt (Rate 0,02 → 0,03, Kern 1,5 → 1,0 Breiten, Spielraum
   1,5 → 4 Zellen). Reihe in `Config.swift` bei `meanderBeltKernelWidths`,
   `meanderBeltRate`, `meanderBeltCouplingSlackCells`.
5. **Schutthügel am Ende gesperrter Gürtelbetten.** Die Tropfen tragen über
   gesperrte Zellen (`bedLocked`, vorher `underIce`) ihre volle Fracht und
   laden sie an der ersten freien Zelle ab. Seit jeder D8-Abschnitt eine Linie
   hat, liegen Profil-Stempel fester Läufe auf viel mehr Wegen; am Ende eines
   solchen Stücks wuchs ein Hügel von 0,40 Höhe in EINEM 500-Jahr-Schritt
   (n = 160, Seed 1337, Zelle (5, 101): 0,318 → 0,722, über dem höchsten
   Gipfel — `TerrainAging` „Berge wachsen nicht" kippte; ohne Tropfen kein
   Hügel). Gesperrt ist mit Kopplung nur noch das Bett WANDERNDER Läufe: das
   Profil, das die Sperre schützt (Kolk, Gleithang), baut nur der wandernde
   Gürtel.
6. **Altarme.** Ohne Mindestlänge wurde jedes verlassene Stück ab 4 Knoten
   Altarm: Seed 1337, Jahr 20.000, 420 Altarme (Median 19 Knoten; vorher 63,
   Median 28). Ab 5 Kanalbreiten: 284 (Median 27). Der schnellere Gürtel
   schnürt trotzdem mehr und kleinere Bögen ab (Hals-Cutoffs bis Jahr 100.000
   auf 1337 / 42 / 20: 511 / 233 / 246, vorher 174 / 64 / 55), sichtbare junge
   Altarme im Tiefland im Mittel über 24 Seeds 14,6 / 10,6 statt 4,4 / 4,8.
7. **Laufzeit.** Die wandernden Läufe sind jetzt die ganzen Flüsse von der
   Quelle bis zur Mündung (vorher kurze, über das Erben mobile Zubringer):
   belt.stamp 3,8 → 8,0 ms, belt.migrate 3,6 → 6,0 ms je Schritt, dazu die
   Kopplung 3,9 ms, zusammen +22,7 % (66,0 gegen 53,8 ms). Seitdem stempelt
   der Teilschritt nur die flachen Knoten, die steilen Strecken wandernder
   Läufe bekommen wie die festen einen Linien-Carve je Schritt (belt.stamp
   7,2, belt.fixedStamp 1,3 → 1,5 ms); Quellsuche und Knoten-Zuordnung der
   Kopplung laufen parallel (1,4 / 1,1 → 0,9 / 0,3 ms), `attachTributaries`
   prüft nur gegen wandernde Vorfluter (2,9 → 1,2 ms; feste Läufe enden
   ohnehin am D8-Zusammenfluss). Ergebnis unter e.

Sweeps (24 Seeds, Zeitmittel wie § Zeitmittel-Abnahme, Summe erfüllter
Punkte 9–13 von 240; „Stand" = Kopplung und Review-Befunde):

| Variante | Summe | Matrix-Seeds | Sinuosität (Mittel 1. / 2. Fenster) |
| --- | --- | --- | --- |
| `0fec08b` | 188 | 29 | 1,84 / 1,88 |
| nur Review-Befunde, ohne Kopplung | 186 | 25 | 1,87 / 1,92 |
| Kopplung, alte Kalibrierung, Avulsion 2 Breiten + 2 Tiefen, sofort | 147 | – | 1,38 / 1,34 |
| … ohne Überhöhung; 4 / 8 Breiten | 146; 155 / 148 | 17; 24 / 17 | 1,40–1,46 |
| … als Rate (τ 1000) | 140 | 21 | 1,42 / 1,32 |
| … dazu Schwellen-Schnitt 3 Tiefen | 135 | 17 | 1,43 / 1,33 |
| Spielraum 4, Rate 0,03, Kern 1,2 / 1,0 | 177 / 201 | 24 / 29 | 1,53 / 1,47; 1,53 / 1,52 |
| Spielraum 4, Rate 0,04, Kern 1,0 / 0,9 / 1,2 | 221 / 216 / 197 | 30 / 29 / 26 | 1,64 / 1,57 (Kern 1,0) |
| Spielraum 3 / 6, Rate 0,03, Kern 1,0 | 207 / 203 | 28 / 27 | – |
| Rate 0,05, Kern 1,0 / 1,2 | 214 / 203 | 28 / 28 | – |
| + Altarm ab 5 Breiten, Rate 0,04 | 219 | 30 | 1,64 / 1,59 |
| + Tropfen-Sperre nur im wandernden Bett, Rate 0,03 / 0,035 / 0,04 | 210 / 213 / 207 | 30 / 29 / 29 | 1,58 / 1,53 (0,03) |
| **+ Laufzeit (Stand, Rate 0,03)** | **201** | **29** | **1,62 / 1,54** |

Die Zeilen ab „Spielraum 4" bilden ein Plateau von 200 bis 220; Rate 0,03
statt 0,035/0,04, weil jede Erhöhung vor allem Hals-Cutoffs bringt
(sichtbare Altarme 13,7 / 15,8 / 18,0).

### Kennzahlen vorher / nachher

**a. Kopplung** (`testBeltCouplingDistanceDiagnostic`, Anteil wandernder
Knoten höchstens 1,5 / 6 Zellen bzw. über 20 Zellen von einem D8-Gerinne mit
mindestens halbem Abfluss; Knotenzahl in Klammern). Die Diagnose taktet in
1000-Jahr-Schritten; dort wandert die Linie im Schritt gegen das
Abflussfeld vom Schrittanfang, das misst vor allem die Wanderung eines
Schritts. Deshalb zusätzlich dt 100 (Zeitraffer-nah), „alte Mechanik" =
derselbe Stand ohne Kopplung mit der alten Kalibrierung:

| Seed | Jahr | vorher (dt 1000) | nachher (dt 1000) | alte Mechanik (dt 100) | nachher (dt 100) |
| ---: | ---: | --- | --- | --- | --- |
| 1337 | 20.000 | 35 / 58 / 17 % (1881) | 36 / 64 / 4 % (2284) | 60 / 72 / 17 % | 85 / 95 / 0 % |
| 1337 | 100.000 | 30 / 52 / 15 % (1639) | 30 / 63 / 6 % (2308) | – | – |
| 42 | 20.000 | 48 / 77 / 6 % (662) | 35 / 75 / 0 % (979) | 60 / 74 / 16 % | 92 / 100 / 0 % |
| 42 | 100.000 | 55 / 70 / 14 % (664) | 28 / 64 / 6 % (957) | – | – |
| 20 | 20.000 | 44 / 67 / 3 % (1000) | 37 / 70 / 7 % (1229) | 81 / 90 / 0 % | 89 / 100 / 0 % |
| 20 | 100.000 | 47 / 71 / 5 % (720) | 36 / 73 / 5 % (1103) | – | – |

**b. Rohe Bänder bergauf** (`testRibbonUphillDiagnostic`, `fadesUphill =
false`; Anstiege über 30 m, je 1000 sichtbare Stützpunkte, größter Anstieg;
dazu der Anteil, den `fadeUphill` ausblendet):

| Seed, Jahr | vorher | nachher | ausgeblendet vorher → nachher |
| --- | --- | --- | --- |
| 1337, 20.000 | 27 (4,1), 227 m | 22 (2,3), 217 m | 19,5 → 7,3 % |
| 1337, 230.000 | 14 (5,0), 114 m | 3 (0,3), 52 m | 33,0 → 4,3 % |
| 42, 20.000 | 8 (3,9), 102 m | 3 (0,8), 52 m | 18,5 → 4,5 % |
| 42, 230.000 | 6 (3,6), 76 m | 3 (0,9), 97 m | 12,9 → 3,9 % |

**c. Hauptlauf-Lücke** (`testMainStemBandDiagnostic`, 100-Jahr-Schritte,
Seeds 1337 / 42 / 20): Jahr 2.300 5,6 / 9,8 / 29,2 % → 0,0 / 2,7 / 15,5 %;
Jahr 20.000 18,4 / 0 / 12,2 % → 4,5 / 9,9 / 18,4 %. Einzelzeitpunkte, stark
streuend (derselbe Code vor dem Laufzeit-Schritt: 0,0 / 9,2 / 4,2 und
5,1 / 0 / 0 %).

**d. Punkte 9–13 im Zeitmittel** (24 Seeds, Seeds mit erfülltem Punkt,
Mittel in Klammern), vorher → nachher:

| Punkt | 10.000–20.000 | 50.000–100.000 |
| --- | --- | --- |
| 9 Sinuosität 1,5–2,5 | 18 (1,84) → 18 (1,62) | 20 (1,88) → 16 (1,54) |
| 10 λ/Breite 10–14 | 15 (12,08) → 17 (12,01) | 12 (10,56) → 16 (11,65) |
| 11 Gürtel ≥ 3 × Amplitude | 23 (4,98) → 22 (7,10) | 24 (10,39) → 24 (12,95) |
| 12 Asymmetrie ≥ 2 | 18 (3,00) → 21 (3,04) | 24 (4,19) → 24 (3,81) |
| 13 ≥ 3 sichtbare Altarme | 16 (4,42) → 21 (14,57) | 18 (4,78) → 22 (10,55) |

Summe 188 → 201 von 240, Matrix-Seeds 29 → 29 von 30. λ ist jetzt auf allen
Stützstellen messbar (vorher bis 16 von 26 „n. m."): die wandernden
Abschnitte sind die ganzen Tieflandläufe der großen Flüsse. Matrix-Seeds
nachher:

| Seed | Fenster | 9 Sinuosität | 10 λ/Breite | 11 Gürtel/Amplitude | 12 Asymmetrie | 13 Altarme sichtbar | davon nass |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 1337 | 10.000–20.000 | 1,57 (1,40–1,96) | 13,4 (11,6–15,4) | 8,0 (6,0–9,5) | 2,85 (2,39–3,53) | 33,7 (28–39) | 6,5 |
| 1337 | 50.000–100.000 | 1,61 (1,36–1,82) | **14,3** (11,5–18,1) | 14,4 (10,5–20,1) | 3,57 (2,62–5,20) | 23,1 (12–31) | 1,5 |
| 42 | 10.000–20.000 | 1,54 (1,38–1,71) | 12,1 (10,9–13,0) | 7,9 (6,3–9,9) | 3,02 (2,29–3,73) | 12,0 (8–15) | 0,3 |
| 42 | 50.000–100.000 | 1,54 (1,27–2,06) | 12,2 (9,7–15,9) | 13,4 (8,3–26,6) | 4,07 (2,35–8,50) | 7,2 (2–14) | 0,9 |
| 20 | 10.000–20.000 | 1,53 (1,40–1,65) | 11,5 (9,0–16,6) | 6,5 (4,0–8,7) | 2,95 (2,20–3,55) | 21,7 (17–28) | 3,5 |
| 20 | 50.000–100.000 | 1,50 (1,22–1,79) | 10,9 (7,4–16,3) | 13,1 (8,7–22,2) | 4,10 (2,80–7,78) | 10,8 (5–20) | 1,8 |

Punkt 10 auf Seed 42 im zweiten Fenster (vorher offen, 8,3) ist erfüllt,
dafür liegt Seed 1337 dort knapp über 14. Punkt 14 (Zerklüftung, Wächter in
`ZielbildLandformTests`) und Punkt 15 (beide Cutoff-Arten bis Jahr 20.000)
grün; Hals- / Chute-Cutoffs bis Jahr 100.000: 511 / 95, 233 / 26, 246 / 80
(vorher 174 / 105, 64 / 43, 55 / 44). Avulsionen je ~100.000 Jahre über 24
Seeds: Median 270 (50–662); Seed 1337 / 42 / 20: 662 / 240 / 292.

**Im Zeitraffer-Takt (dt 100) hält das nicht.** Dasselbe Ensemble in
100-Jahr-Schritten: 167 von 240 (Matrix-Seeds 23 von 30), Sinuosität 1,35 /
1,28 (erfüllt auf 1 / 1 von 24 Seeds), λ/Breite 11,9 / 12,2, Gürtel/Amplitude
11,0 / 20,7, Asymmetrie 4,19 / 5,45, sichtbare Altarme 11,0 / 8,0. Die
Kopplung ersetzt Linienstücke, die ihr D8-Abschnitt nicht trägt, bei jeder
Prüfung; je Zeiteinheit bei dt 100 rund dreimal so viele wie bei dt 1000
(Seed 1337, 20.000 Jahre: 45.563 gegen 15.566 ersetzte Knoten wandernder
Größe), die Avulsionen selbst dagegen seltener (109 gegen 196: im großen
Schritt wandert die Linie weiter vom Abflussfeld des Schrittanfangs weg). Die alte Mechanik ist
dort ebenfalls nicht abgenommen: ohne Kopplung mit alter Kalibrierung bei
dt 100 173 von 240, Sinuosität 1,71 / 2,21 statt 1,87 / 1,92 bei dt 1000 —
sie driftet in die andere Richtung. Die Abnahme der Punkte 9–13 in
1000-Jahr-Schritten beschreibt also für keinen der beiden Stände den
Zeitraffer.

**e. Laufzeit** (`simperf --repeat 3`, Produktion, Seed 1337, M4 Max,
abwechselnd fünf Runden vorher / nachher, Minimum der drei Blöcke):
53,6 / 60,7 — 52,8 / 60,2 — 53,7 / 60,9 — 52,5 / 59,9 — 53,4 / 61,6 ms je
Schritt, Median 53,4 → 60,7 (+13,7 % gegen den Integrationsstand; gegen
`main` nicht interleaved gemessen, der Integrationsstand lag dort zuletzt bei
+4,5 %, § Zeitmittel-Abnahme). Pass-Tabelle nachher: belt.stamp 7,2 ms,
belt.migrate 5,5, belt.couple 2,5 (Abschnitte 0,9, Zuordnung 0,3, Strecken
0,2, Aufbau 1,1), belt.fixedStamp 1,5, belt.attach 1,2. `simperf --hash`
nachher zweimal `c25268a941dd4beb` (vorher `e505e21e35d719aa`).

**f. Pflichtsuite:** 534 Tests, 60 Messläufe übersprungen, 0 Fehler, 193 s.

### Review-Befunde (Sim-Review zu `0fec08b`), mitgelöst

1. **Alter je Teilschritt:** Bank und Altarm tragen ihr Alter am
   Schrittende (`dt − (si+1)·sub`), neue Altarme werden am Index verkorkt,
   verlanden im Entstehungsschritt nur über ihr Alter. Wächter
   `testBarAgesFollowTheSubsteps`: nach einem 1000-Jahr-Schritt 16 % der
   jungen Bänke bei Alter 0 (vorher alle), mittleres Alter 370 gegen 347
   Jahre in zehn 100-Jahr-Schritten.
2. **Teilschritt-Deckel** 256 → 4096 (Sicherheitsnetz); Kommentar an
   `meanderBeltRelaxYears` berichtigt.
3. **Testlücken:** `testBeltIsDeterministic` und die Bank-Alter mit
   wandernden Läufen (`meanderBeltMinCells` = 100, n = 128).
4. **`migrates()`** entscheidet mit Kopplung am letzten Innenknoten.
5. **Pinselstrich löscht den Hauptlauf:** der Fluss wird im nächsten Schritt
   aus D8 neu getrasst (`testRiverWithoutLineIsRetraced`).
6. **Frische Bank** nur, wo die Ablage die Zelle bis auf eine Viertel
   Kanaltiefe an die Bank-Oberkante hebt (ein Zustand statt einer
   schrittweitenabhängigen Menge); nur dann Bewuchs weg und Tropfen-Sperre.
7. **Laufzeit:** Alterung und Tropfen-Sperre auf Roh-Puffern parallel, das
   Bin-Gitter von `applyBeltCutoffs` wiederverwendet; Zug und Kohäsion samt
   Höhenabtastung entfernt (bit-gleich, beide standen auf 0).
8. **Aufräumen:** `meanderBeltSmoothYears`, `meanderBeltPull`,
   `meanderBeltPullDeadband`, `meanderBeltCohesion` entfernt (Spielstand
   Version 7); `migrateBelt`/`beltMaxRate(config:)` in die Tests verschoben;
   `Hydraulic.erode(underIce:)` heißt `bedLocked`.

Zwei Mechanik-Wächter pinnen die alte Gürtel-Kalibrierung (Rate 0,02, Kern
1,5), mit Begründung am Test: `MeanderBeltTests.testMigrationIsStepSizeInvariant`
misst die Numerik des Schemas (mit 0,03 / 1,0 wachsen die Bögen ∝ Rate/L²
rund 4,5-mal schneller, und der zeitliche Fehler erster Ordnung wächst mit:
ohne Störquelle 3,55 Zellen bei 27,8 Zellen Auslenkung) und
`TerrainAging.testAgingTrajectoryOver100k` (eine Realisierung auf n = 160;
1337 fällt mit 0,03 in der ersten Hälfte schneller und steht in 100k gleich
tief, 42 und 20 halten das Kriterium). Der Altarm-Median in
`ZielbildLandformTests` steht jetzt bei ≥ 15 (kleinstes Dreier-Mittel aus 24
Seeds 15,3; Median je Seed 14–46, vorher 18–96).

### Render-Pflaster (`fadeUphill`, Raster-Bank-Schranke)

- `fadeUphill` bleibt: rohe Bänder steigen weiter stellenweise über 30 m an
  (Tabelle b), aber die Blende nimmt nur noch 4–7 % der sichtbaren
  Stützpunkte statt 13–33 %.
- Die Raster-Bank-Schranke (`rasterBarBandReachCells`) bleibt. Sichtbarer
  Raster-Fluss auf Bänken ohne Band (ganze Karte, Jahr 2.305, Zeitraffer-Takt
  15 Jahre, Seeds 1337 / 42 / 20): vorher ohne Schranke 1.769 / 568 / 858,
  mit 713 / 232 / 383 Zellen; mit Kopplung ohne Schranke 445 / 223 / 181,
  mit 203 / 115 / 137 (gemessen auf dem Stand vor dem Laufzeit-Schritt). Die
  Abkürzungen über den Gleithang sind um 60–80 % seltener, aber nicht weg.

### Offen

- Zeitraffer-Takt: Punkte 9–13 und die Ersetzungs-Rate der Kopplung hängen
  an der Schrittweite (oben). Die Projektion auf ein flackerndes D8-Netz
  ersetzt bei kleinem dt öfter; was fehlt, ist ein D8-Netz, das der
  gestempelten Rinne verlässlich folgt (der zweite Ansatz, durchgehende
  Rinne mit monotoner Sohle), oder ein Gedächtnis der Kopplung über mehrere
  Schritte.
- Deutlich mehr und kleinere Altarme als vor #187 (Befund 6); ob das im Bild
  als Ried-Teppich wirkt, ist eine Bildfrage.
- Laufzeit: abgehakt. Der Ansatz „nur den flachen Abschnitt rechnen" ist unter
  der Kopplung (#187) erschöpft — wandernde Läufe sind fast vollständig flach
  (93 % der Knoten mobil, gemessen; `docs/perf-measurements.md` §R). Was die
  Teilschritte sonst noch kosten und welche Mikro-Umbauten gemessen NICHT
  zahlen, steht ebenfalls in §R.

## Felswände

17. Oktober 2026, Basis `aeed3b3`, M4 Max, offizielles Godot 4.7.2,
`balanced`, Jahr 20.000 mit dem Produktions-Einlauf und 1000-Jahr-Schritten.
Alle Aufnahmen maximiert bei 3456×2104. Der Befund hat zwei Anteile:
Die **feinen senkrechten Vorhanglinien erzeugt die Material-Klüftung**.
Die breiten, glatten Steilflanken existieren bereits im Sim-Höhenfeld.
Dieser Eingriff ändert deren Form und die Sim-Physik nicht.

### Zerlegung im selben Prozess

`CliffsDiagnostic.tscn` erbt die echte Anwendung über die Flusstal-Bühne.
Welt und Kamera bleiben fest, Wasser und Wolken stehen auf Phase 1,0.
Je Zustand werden 60 Bilder gezeichnet, dann wird der Viewport gespeichert.
Die Abschaltungen betreffen jeweils nur den genannten Term. Zuerst wurde
Seed 1337 im Tal zerlegt, danach Seed 20 und 42. Alle drei zeigen denselben
Zusammenhang. Das Altbild aus einem zweiten Prozess ist auf Seed 1337
bytegleich zur ersten Aufnahme, alle 21.814.272 RGB-Bytes stimmen überein.

| Gegenprobe | Ergebnis |
| --- | --- |
| `detail_enabled = false` | Feine Vorhanglinien bleiben. Die Draufsicht des Erosionsdetails ist nicht deren Hauptquelle. |
| `relief_enabled = false` | Silhouetten und breite Rippen ändern sich, die feinen senkrechten Linien bleiben. Der Bake erzeugt sie nicht. |
| `material_joint_depth = 0` und `material_joint_relief = 0` | Feine Linien verschwinden; breite Steilflanken bleiben. |
| Nur `material_joint_relief = 0`, Seed 42 | Fast derselbe glatte Eindruck wie ganz ohne Klüftung. Die Normalen tragen den Hauptanteil. |
| Nur `material_joint_depth = 0`, Seed 42 | Das Vorhangmuster bleibt sichtbar. Es ist keine bloße Albedo-Streifung. |
| Streckung 5 → 1 bei sonst gleichem Shader | Lange Linien zerfallen in kurze Facetten. Die bereits triplanare Projektion streckte das Muster ausdrücklich in Welt-Y. |
| Neutrales Grau, ohne Detail/Bake/Material/Wald; zusätzlich echte Dreiecksnormalen | Breite Wandformen und einzelne Rasterfacetten bleiben, die feinen Materiallinien fehlen. |

Ein festgelegter Innenausschnitt der rechten Talwand von Seed 1337,
Pixelrechteck `[2330, 590, 2490, 775)`, vermeidet Schnee, Bewuchs und
Silhouette. Kennzahl ist der Mittelwert absoluter Grauwertdifferenzen
benachbarter Pixel in x beziehungsweise y, Grauwert 0…255. Lange vertikale
Linien ändern sich quer viel stärker als längs. Die Kennzahl ist ein
Reproduktionssignal für diesen Ausschnitt, kein allgemeines Qualitätsmaß.

| Zustand | quer Δx | längs Δy | Δx/Δy |
| --- | ---: | ---: | ---: |
| vorher | 4,974 | 1,122 | 4,435 |
| ohne feines Erosionsdetail | 4,758 | 1,036 | 4,594 |
| ohne Bake | 5,830 | 1,156 | 5,045 |
| ohne Klüftung | 1,418 | 0,454 | 3,125 |
| nachher | 5,225 | 2,676 | 1,952 |

Beleg: `docs/screenshots/zielbild-174/cliffs_diagnose_seed1337.jpg`.
Die Bake-Abschaltung verändert die Geometrie und verschiebt deshalb den
Ausschnitt leicht; die anderen Schalter und vorher/nachher tun das nicht.

### Anteil des Höhenfelds

Das Harness exportiert die unveränderten Sim-Höhen als Float32.
Auswertung mit Weltmaß 112,4789, Gitter 720 und Überhöhung 24. Die zentrale
Steigung misst über ±1 Zelle auf Land oberhalb Meer + 0,012; die größte
Kante ist dagegen die direkte Differenz zweier Nachbarzellen. Zellabstand
15,64 m, eine Welteinheit entspricht hier etwa 100 m.

| Seed | Steigung p99 | größte zentrale Steigung | Land > 80° | größte direkte Höhenkante |
| ---: | ---: | ---: | ---: | ---: |
| 1337 | 3,727 | 10,356 | 0,218 % | 1,741 Welteinheiten / 174 m |
| 42 | 3,272 | 7,462 | 0,062 % | 1,353 / 135 m |
| 20 | 3,811 | 10,091 | 0,182 % | 2,205 / 220 m |

Beispiel Seed 20, größte Kante nahe Welt-x/z 8,53/42,00, Höhenprofil in
z-Richtung in Welteinheiten:
`10,379; 10,191; 9,951; 9,638; 8,746; 6,542; 6,211; 6,058; 5,451; 5,117`.
Hier fällt die Höhe innerhalb einer Zelle um 2,205 Welteinheiten. Solche
Steilstufen sind echt. Sie erklären einen Teil des blockigen Umrisses,
aber nicht das feine, nach Abschalten der Klüftung verschwundene Muster.
Eine Änderung dieser Großform wäre eine gesonderte Sim-/Mesh-Aufgabe und
wurde hier nicht vorgenommen.

### Änderung und Bildurteil

`MaterialRender.jointStretch` sinkt von 5 auf 1,5. Die zweite Runsen-Oktave
und die feinen Facetten kreuzen die erste Richtung um 36,87°. Die beiden
Drehwerte 0,8/0,6 stehen in `MaterialRender`, reisen über
`MaterialUniforms` und die Brücke und werden default-frei im Shader gelesen.
Die analytischen Rausch-Ableitungen werden mit der transponierten Drehung
in die Wandebene zurückgeführt. Anzahl der Rauschabfragen, Kluftabstände,
Normalentiefe, Materialgewichte und Relief-Bake bleiben gleich.

Verworfen: nur Streckung 1. Sie entfernt die langen Linien, wirkt aber an
nahen Wänden schuppenartig. Nur Streckung 2 lässt noch mehr parallele
Bündel stehen. Die gekreuzten Oktaven mit 1,5 brechen die Richtung besser.
Der zufällig gefundene Präzisionsverlust des Float-Hashs im feinen
Erosionsfilter wurde nicht verändert: dessen Abschaltung beseitigt den
hier untersuchten Fehler nicht.

Bögen, jeweils links F1-Diorama, rechts F2-Tal, oben vorher, unten nachher:

- `docs/screenshots/zielbild-174/cliffs_seed1337_vorher-nachher.jpg`
- `docs/screenshots/zielbild-174/cliffs_seed42_vorher-nachher.jpg`
- `docs/screenshots/zielbild-174/cliffs_seed20_vorher-nachher.jpg`

Alle Bilder wurden angesehen. Auf 1337 und 42 fällt die Unterbrechung der
langen Linien besonders an den breiten hellen Wänden auf; auf Seed 20
auch im Gegenlicht der linken Talwand. Das Ergebnis wirkt kleinteiliger
gebrochen und weniger wie ein gestreifter Vorhang. In der Nähe bleibt das
Facettenmuster als prozedurales Relief erkennbar. Die breiten glatten
Wandflächen und ihre Umrisse bleiben weit von der gebrochenen Großform der
Vorlage entfernt. Die Änderung ist dafür keine vollständige Lösung.

### Reproduktion

```sh
GODOT=/Users/piotr/git/river-sim/.tools/godot-macos/Godot.app/Contents/MacOS/Godot
git show aeed3b3:game/shaders/terrain.gdshader > /tmp/cliffs-before.gdshader
RS_SEED=1337 RS_STEP=20000 RS_CAMERA=valley RS_QUALITY=balanced \
  RS_STUDY_VARIANT=baseline RS_STUDY_MODE=still \
  RS_CLIFF_MODES=before,full,no_detail,no_relief,no_joints,bare,faces \
  RS_CLIFF_BEFORE=/tmp/cliffs-before.gdshader RS_CLIFF_OUTPUT=/tmp/cliffs-shots \
  "$GODOT" --path game --maximized --screen 1 \
  res://studies/flusstal/CliffsDiagnostic.tscn
```

`before` setzt zusätzlich die historische Material-Streckung 5; die anderen
Modi verwenden die aktuelle Kalibrierung. Für die ursprüngliche Zerlegung
auf dem alten Stand das Harness dort mit `full,no_detail,no_relief,no_joints`
verwenden. Die zusätzliche neutrale Dreiecksansicht ist rein diagnostisch;
sie verändert keine Produktions-Normale.

### Frame-Zeiten, Punkt 47

A = Shader von `aeed3b3` mit Streckung 5, B = neue Fassung mit 1,5 und
gekreuzten Oktaven. Beide laufen im **selben Prozess und auf derselben
unveränderten Welt**. `CliffsTiming.tscn` wechselt je 90 gezeichnete Bilder
A/B; jede zweite Runde dreht die Reihenfolge um. Runde 0 wärmt beide
Pipelines, die ersten 12 Bilder jedes Blocks zählen nicht. Je Variante
bleiben acht Blöcke mit je 78 Bildintervallen. VSync und FPS-Deckel sind
wie in der Flusstal-Messung aus. Die Tabelle nennt den Median der acht
Blockmittel beziehungsweise der acht Block-p95, nicht ein zusammengefasstes
p95 aller Welten.

Grazing verwendet die festen Matrix-Kameras aus `graphics-matrix.sh`;
der Tal-Lauf das adaptive F2-Preset. Der Kamerabogen fährt je Block dieselben
Winkel, 0,002 rad je gerendertem Bild, insgesamt 0,18 rad. Das ist eine
kontrollierte kurze Fahrt für den Shadervergleich, keine Wiederholung der
gesamten 162-Läufe-Matrix von Punkt 47. Alle gültigen Läufe maximiert bei
3456×2104, `balanced`, Gitter 720. Vor jedem Start und an jeder Blockgrenze
wurde auf fremde Godot-Prozesse geprüft. Ein anfänglicher Lauf bei
6016×3260 mit fremder GPU-Last wurde verworfen; ebenso ein Lauf mit eigenem
Swift-Build und ein abgebrochener Start während einer fremden Aufnahme.

Die **vollständigen Rohwerte** stehen in
[`cliffs-frame-times.jsonl`](cliffs-frame-times.jsonl), einschließlich der
Warmrunde und aller aufsteigend sortierten Einzelintervalle. Nur Runden
1…8 gehen in die Tabelle ein. Shader-SHA-256, Kameras, Viewport und
Vergleichszustände stehen dabei. Es werden Frame-Abstände gemessen, keine
isolierten GPU-Zeitstempel; die shaderbedingte Mehrzeit ergibt sich aus dem
interleavten Vergleich.

| Seed | Kamera | Betrieb | Mittel A → B | p95 A → B | Frames > 33,3 ms A/B |
| ---: | --- | --- | --- | --- | ---: |
| 1337 | grazing | Standbild | 24,09 → 24,17 ms | 24,56 → 24,63 ms | 0 / 0 |
| 42 | grazing | Standbild | 22,69 → 22,81 ms | 23,27 → 23,41 ms | 0 / 0 |
| 20 | grazing | Standbild | 23,12 → 23,08 ms | 23,55 → 23,54 ms | 0 / 0 |
| 1337 | grazing | Kamerabogen | 24,45 → 24,45 ms | 24,83 → 24,97 ms | 0 / 0 |
| 20 | grazing | Kamerabogen | 22,68 → 22,49 ms | 23,28 → 22,97 ms | 0 / 0 |
| 20 | valley | Standbild | 14,88 → 14,99 ms | 15,28 → 15,45 ms | 0 / 0 |

Die größte Mehrzeit im Median der Blockmittel beträgt +0,12 ms auf Seed 42.
Alle gemessenen Grazing-p95 bleiben unter 33,3 ms. Der Vergleich zeigt keine
Mehrkosten in der Größenordnung von 1 ms. Die Aussage gilt für diese
Kameras und kurzen Fahrten; sie ersetzt keine vollständige Abnahmematrix.

### Verifikation

Lokaler Extension-Build ausschließlich mit `RS_NO_SHARED_BUILD=1` und dem
absoluten `scripts/build.sh`-Pfad, jeweils mit „gebaut und signiert“ am
Ende; Build-Stempel geprüft. Der Projektimport hat die Extension registriert
und die Ressourcen importiert; Godot stürzte erst beim anschließenden
Herunterfahren mit Signal 11 ab. Die Bildläufe danach waren erfolgreich.

SimCore-Pflichtsuite in Release mit Swift-5-Sprachmodus: Basis und Endstand
je 582 Tests, 67 erwartete Mess-Test-Skips, keine Fehler. Nach
`git rebase t3/issue-174-integration` nochmals bestanden, 212,2 s.
`MaterialTests` prüft zusätzlich die beiden neuen Tabellenwerte, deren
default-freie Shader-Deklarationen und die Orthogonalität der Drehung.
Godot-Verträge über `scripts/godot-test.sh`: `SMOKE_OK`,
`WATER_UNIFORMS_OK`, `RELIEF_OK`, `CANOPY_OK`, `LIGHTING_OK`.
Beim Relief-Test meldet der Dummy-Renderer zusätzlich `Invalid image` beim
Regenerieren, der Vertrag endet mit `RELIEF_OK`; die geprüfte Produktions-
und Shader-Verdrahtung ist bestanden.

## Delta (Abnahmepunkt 26)

Punkt 26: „≥ 1 Delta mit ≥ 3 Distributären und Sandinseln (mind. 2 Seeds)",
im Bild ein natürliches, gelapptes Delta (Vorlage
`docs/references/zielbild/b-flusstal-delta-ui.jpg`). Vorher lagen die
Delta-Arm-Bänder an Meeresmündungen unter der opaken Meeresebene
(`docs/river-belt-render-measurements.md` §D), und die Sim baute keinen
Ablagerungskörper, auf dem Arme hätten liegen können. Jetzt baut sie ihn
(`Terrain.deltaDeposit`, Kalibrier-Logbuch `SimConfig.deltaTrapFraction`
ff.). Mit dem Delta kamen drei Befunde an Küste und Mündung dazu, die im
selben Bild stehen (§ Render).

```sh
RS_MEASURE=1 RS_CACHE=/tmp/delta-welten swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter testDeltaBudgetDiagnostic
```

(`SimCoreTests/RiverDelta.swift`. Schalter: `RS_SEEDS`, `RS_YEARS_LIST`,
`RS_DT` (Schrittweite der Alterung, Standard 1000 wie `RS_STEP`), `RS_OUT`
(Draufsicht-PPM je Mündung), `RS_BUDGET=1` (Pass-Bilanz über 1000 Jahre),
`RS_DELTA=off` bzw. `trap=…,dist=…,rad=…,elong=…,gen=…,wmin=…,jit=…,min=…`
für Varianten. Der Cache-Ordner muss je Variante und Schrittweite ein
eigener sein.) Produktions-Config, Einlauf 3000 Jahre; die Welten sind
dieselben wie im Spiel mit `RS_SEED` und `RS_STEP` (seit caed8b5 liefert
`generate` auf benutztem Terrain die frische Welt). „Große Mündung" =
D8-Mündung ab 5000 Zellen Einzugsgebiet. Messrechner M4 Max, mit anderen
Agenten geteilt.

### Befund

Längsprofil durch die größte Mündung (Seed 1337, Jahr 2000, h − sea je
Zelle in Fließrichtung, Mündung bei 0; gemessen auf `0fec08b`):

```
−10 … −1: +0,0225 … +0,0031   0: +0,0004   +1 … +20: −0,0023 … −0,0761
```

Eine gleichmäßige Rampe von ~0,0025–0,003 je Zelle durch die Küstenlinie,
ohne Ablagerungskörper und ohne Ebene. Auf dem Integrationsstand
(`e2574d1`, `RS_DELTA=off`) an allen neun Welten (Seeds 1337/42/20, Jahre
2000/20.000/100.000): ein Distributär, keine Sandinsel.

Pass-Bilanz um die größte Mündung (Seed 1337, Jahr 20.000, 10 × 100 Jahre,
Σ Δh in Zellen·Höhe je 1000 Jahre, Integrationsstand):

| Pass | Einzugsgebiet (21.586 Zellen) | Meer in 25 Zellen um die Mündung |
| --- | ---: | ---: |
| `outletIncision` | −7,90 | −0,002 |
| `belt.stamp` / `belt.fixedStamp` | −7,55 / −7,35 | +0,07 / +0,04 |
| `Hydraulic.erode` | −0,20 | −0,10 |
| `braidPass` | −0,03 | −0,001 |
| `wavePass` | −0,01 | +0,18 (vom Land der Zone) |

Fluvial kommt im Meer vor der Mündung praktisch nichts an. Inselweit trägt
`outletIncision` 75,5 je 1000 Jahre ab; davon liegt danach nichts mehr
irgendwo.

### Ursache

1. **Die Fracht kommt nicht an.** Die fluviale Erosion der Produktion ist
   detachment-begrenzt: was `outletIncision` und `channelCarve` abtragen,
   ist danach weg (AGENTS.md: Masse-Erhaltung gilt nicht). Die Tropfen
   tragen nur ihre eigene, kleine Fracht und laden sie am Eintritt in Wasser
   über `poolDepth` (0,03) ab, gedämpft auf den großen Läufen; `braidPass`
   exportiert, was eine Meereszelle erreicht.
2. **Im Meer gibt es keine Strömung.** Meer ist Senke (`hf ≤ sea`), D8 und
   MFD enden an der Küste. Die Verzweigung um eine Mündungsbarre, die echte
   Distributäre erzeugt, kann die Sim nicht aus dem Abfluss ableiten — auch
   dann nicht, wenn Fracht ankommt (s. „Ebene" unter Verworfen).

### Lösung

**Fracht.** Was `outletIncision` und `channelCarve` in einem Schritt
abtragen, als Höhensumme davor minus danach (`deltaHeightSum`, 64 feste
Blöcke, bit-gleich), je Landzelle gemittelt; jede Mündung ab
`deltaMinCells` (4000) Zellen bekommt davon Einzugsgebiet × mittleren
Abtrag, `deltaTrapFraction` (1,0) bleibt liegen. Die erste Fassung summierte
den Abtrag je Zelle entlang D8 bis zur Mündung (ein See hielt seinen Anteil
fest). Das kostete gemessen 1,3–1,5 ms je Schritt, auch in der Braid-Schleife
mitgeführt (`braidPass` 2,2 → 3,6–4,1 ms, drei verstreute Zugriffe je
Landzelle), bei einem Ziel von 0,5 ms für das ganze Delta. Verloren gehen
damit Relief und Klima des einzelnen Einzugsgebiets und der Rückhalt in
Seen; die Summe über alle Mündungen bleibt unter dem Abtrag der Insel.
`deltaMinCells` 4000 statt 2000: kleinere Läufe setzten Barren-Sprenkel vor
die Küste, und der Pass kostete 0,60 statt 0,50 ms.

**Ablagerung: ein Baum aus Mündungsbarren.** Der Fluss behält an der
Mündung seinen Strahl, legt einige Rinnenbreiten voraus eine Barre ab und
teilt sich um sie (Wright 1977; Edmonds & Slingerland 2007, JGR 112). Die
Sim rechnet kein Wasser im Meer, deshalb steht das als Ablage-Regel:

- Rinnenbreite b aus dem Abfluss (`WaterRender.ribbonHalfWidthCells`, die
  Kurve von Band und Gürtel), Barre `deltaBarDistanceWidths` (2) · b voraus.
- Barre als Tropfen: Radius `deltaBarRadiusWidths` (0,9) · b quer und
  stromauf, stromab `deltaBarElongation` (2)-fach gestreckt, Umriss mit 2.
  und 3. Harmonischer gebrochen; Scheitel `deltaTopset` (0,0015) über dem
  Meer, Fuß beim doppelten Radius gleich tief darunter.
- Ist eine Barre voll, teilt sich der Rest nach Abflussanteil auf zwei
  Töchter: Anteil ½ ± `deltaJitter`/2, der stärkere Ast läuft gerader,
  Winkel um ±`deltaBifurcationAngle`/2 (≈ 34°, Coffey & Shaw 2017), Breite
  b·√Anteil — bis `deltaGenerations` (3) oder bis eine Tochter schmaler als
  `deltaMinHalfWidth` (1,2 Zellen) würde. Abstände, Winkel und Umriss
  schwanken um `deltaJitter` (0,3), Rauschen am 8×8-Block der Mündung.
- Vor jeder Barre die Uferwälle der Rinne, von der Wurzel seewärts.
- Richtung: Lauf (8 Zellen stromauf) und Küstennormale (Meeresschwerpunkt
  im Fenster ±8, eigenes Delta-Land zählt als Meer) zu gleichen Teilen. Die
  Mündung wandert je 1000 Jahre bei der Hälfte bis zwei Dritteln der großen
  Mündungen um 0–2 Zellen, beim Rest um 5–72 (Seed 1337, Jahr 11.000 bis
  20.000, je Schritt); allein nach dem D8-Lauf pflanzte jeder Schritt einen
  anders gedrehten Baum.
- Gefüllt wird bis zur Ziel-Oberfläche auch über eigener Schüttung, die
  schon Land ist, und abgeschnürte Rinnen und Lagunen im Bereich des Baums
  verlanden zuerst (bis 0,3 Scheitel). Rinnen, die zum Meer offen sind,
  bleiben frei: das sind die Distributäre.

dt: die Fracht ist ∝ dt, die Oberflächen sind feste Obergrenzen, die
Reihenfolge ist fest (Wurzel, Töchter Generation für Generation, je Barre
nach Abstand): viele kleine Schritte laufen gegen dieselbe Form wie ein
großer (Wächter `testSameLoadInFewerStepsBuildsTheSameDelta`, ±2 %).

### Kennzahl

`DeltaMetrics.shape`: Sandinsel = Land in 45 Zellen um die Mündung ohne
Landverbindung nach außen, ab 6 Zellen. Distributäre = 1 + größte Zahl von
Inseln, die ein Bogen um die Mündung (seewärts ±100°) quert. Sand = Anteil
der Inselzellen, die `TerrainColorRenderer` hell malt (A-Kanal ≥ 0,5).
Lagune = Zellen unter dem Meeresspiegel ohne Verbindung zum Meer in den
Zonen der großen Mündungen.

Gemessen auf dem Integrationsstand `3bc20cc` (der Stand danach, `3def64f`,
ist bit-gleich: Perf-Runde 5, Fingerprints mit Delta unverändert; die
Tabellen davor auf `6a0dfde` sahen ebenso aus, dort fehlte nur Seed 42 im
Jahr 2000 bei Schrittweite 100). Schrittweite 1000 Jahre (wie `RS_STEP`):

| Seed | Jahr | bestes Delta: Abfluss | Arme | Inseln / Zellen | Sand | Mündungen mit ≥ 3 Armen + Insel | Lagune |
| --- | --- | ---: | ---: | --- | ---: | --- | ---: |
| 1337 | 2000 | 10.309 | 4 | 2 / 122 | 99 % | 5 von 13 | 0 |
| 1337 | 20.000 | 22.123 | 3 | 2 / 71 | 100 % | 3 von 9 | 105 |
| 1337 | 100.000 | 5497 | 5 | 2 / 260 | 82 % | 7 von 13 | 2 |
| 42 | 2000 | 31.123 | 2 | 1 / 66 | 100 % | **0 von 6** | 0 |
| 42 | 20.000 | 10.725 | 3 | 1 / 90 | 91 % | 5 von 7 | 0 |
| 42 | 100.000 | 9915 | 3 | 2 / 48 | 100 % | 1 von 6 | 1 |
| 20 | 2000 | 11.465 | 3 | 1 / 60 | 100 % | 1 von 6 | 0 |
| 20 | 20.000 | 7192 | 3 | 2 / 106 | 92 % | 1 von 9 | 1 |
| 20 | 100.000 | 15.092 | 4 | 1 / 108 | 92 % | 4 von 10 | 2 |

Schrittweite 100 Jahre (dieselben Welten, chaotisch auseinandergelaufen):

| Seed | Jahr | bestes Delta: Abfluss | Arme | Inseln / Zellen | Sand | Mündungen mit ≥ 3 Armen + Insel | Lagune |
| --- | --- | ---: | ---: | --- | ---: | --- | ---: |
| 1337 | 2000 | 14.770 | 5 | 1 / 49 | 100 % | 4 von 10 | 0 |
| 1337 | 20.000 | 24.727 | 3 | 1 / 119 | 47 % | 1 von 12 | 1 |
| 1337 | 100.000 | 6582 | 3 | 2 / 83 | 98 % | 6 von 14 | 10 |
| 42 | 2000 | 12.076 | 3 | 1 / 129 | 78 % | 2 von 7 | 0 |
| 42 | 20.000 | 7652 | 3 | 1 / 121 | 88 % | 3 von 7 | 0 |
| 42 | 100.000 | 5614 | 3 | 1 / 63 | 100 % | 2 von 8 | 0 |
| 20 | 2000 | 11.792 | 3 | 1 / 128 | 78 % | 3 von 6 | 0 |
| 20 | 20.000 | 8469 | 4 | 1 / 27 | 100 % | 3 von 9 | 0 |
| 20 | 100.000 | 6295 | 4 | 2 / 90 | 100 % | 4 von 7 | 0 |

Ohne Pass (`RS_DELTA=off`, Schrittweite 1000) an allen neun Welten
1 Distributär, keine Insel, 0 Deltas, Lagune 0. Punkt 26 ist bei
Schrittweite 100 auf allen drei Seeds in allen drei Jahren erfüllt, bei
Schrittweite 1000 auf allen außer Seed 42 im Jahr 2000 (bestes: 2 Arme, eine
Insel von 66 Zellen) — also in jedem Jahr auf mindestens zwei Seeds. Die
Inseln sind größer als in der ersten Fassung (bestes Delta 27–260 statt
13–145 Zellen, meist 60–130), größere tragen Bewuchs mit Sandrand (Sand
47–100 % statt immer 100 %).

Lagunen entstehen innerhalb eines großen Schritts (Barren und Wälle
schnüren eine Rinne ab) und verlanden im nächsten: inselweit gezählt
(Seed 1337 ab Jahr 20.000, auf `6a0dfde`) je 1000 Jahre 58, 0, 62, 44, 1, 10,
13 Zellen, je 100 Jahre 58, 0, 0, 0, 1, 1, 2. Das Raster malt sie nicht mehr
als See, solange ihr Spiegel nahe am Meer liegt (§ Render, Lagunen).

### Verworfen

Kennzahl je Variante: große Mündungen mit ≥ 3 Distributären und Sandinsel,
Seeds 1337 / 20 / 42, Jahre 2000 / 20.000 / 100.000. Die oberen Zeilen
stammen von der ersten Fassung (Stand `0fec08b` vor #187 bzw.
Integrationsstand `e2574d1`), die unteren aus dieser Runde (Integrationsstand
`6a0dfde`, nur Jahr 20.000, Seeds 1337 / 42 / 20).

| Variante | 1337 | 20 | 42 | Befund |
| --- | --- | --- | --- | --- |
| Ebene: Fracht vom Mündungspunkt aus nach Abstand bis `sea + 0,0015 − 0,0002·d` | — | — | — | Küstenebene bis 34 Zellen vorgebaut (Seed 1337, Jahr 100.000), ein einziger Lauf darüber, kein Arm |
| Barren-Baum ohne Uferwälle, trap 0,5, dist 3, rad 1 | — | — | — | Inseln als lose Untiefen vor der Küste, ohne Rinne zur Mündung |
| Barren-Baum mit Wällen, trap 0,5, dist 3, rad 1 | 1/0/4 | 0/0/2 | 0/0/1 | Barren in ~0,05 Tiefe, tauchen selten auf |
| dto., dist 2, rad 0,75 | 3/3/6 | 0/2/3 | 0/2/2 | Seed 20 und 42 bis Jahr 2000 ohne Delta |
| trap 1,0, dist 2, rad 0,75, Mündungen ab 320 Zellen | 5/3/3 | 3/4/3 | 1/4/3 | Barren-Sprenkel auch vor Bächen |
| dto. plus Erosionsbasis `sea − 0,002` an der Mündung | 9/2/5 | 1/0/3 | 2/1/0 | Seed 20 bei Jahr 20.000 ohne Delta; brach drei Wächter (Generierung) |
| erste Fassung: trap 1,0, dist 2, rad 0,75, Kreisbarren, 2 Generationen, Mündungen ab 2000 | 6/4/10 | 2/1/5 | 1/4/1 | Inseln 13–145 Zellen, alle Sand; Kosten s. unten |

| Variante (Jahr 20.000) | 1337 | 42 | 20 | Befund |
| --- | --- | --- | --- | --- |
| Hüllkurven-Fächer: Rinnen als Strecken, um jede ein Ablagerungsgürtel, Rinnen bis `sea − 0,002` aufgefüllt, Front davor | 0 von 13 | — | — | eine Ebene ohne Insel: Wellen und Diffusion schütten die seichten Rinnen zu, der Lauf verlängert sich darüber |
| dto. plus Rinnen-Spülung (Rinnen je Schritt aufs Bett ausgeräumt) | 1 von 11 | — | — | die Mündung wandert, jeder Schritt spült einen anderen Baum frei: ein Kamm gerader Rinnen durch alte Lappen |
| dto. kompakt (kurze Wurzel, schmale Gürtel), über eigene Inseln weiter | 10 von 15 | 0 von 7 | 2 von 7 | geradkantige Inseln in einer ausgespülten Lagune; im Bild kein Delta |
| Barren-Baum mit D8-Fracht, Tropfen 1,5, rad 0,75 | 4 von 11 | 3 von 7 | 2 von 7 | Inseln klein, fast nur Sand |
| dto., rad 0,9 | 4 von 10 | 2 von 7 | 2 von 6 | |
| dto., Tropfen 2 | 2 von 10 | 4 von 7 | 4 von 6 | |
| dto., rad 0,9 und Tropfen 2 | 3 von 11 | 4 von 8 | 3 von 8 | Inseln 95–162 Zellen mit Bewuchs: übernommen |
| Gezeitendurchbruch (Rinne durch niedrige Sandschwellen nach den Wellen) | Lagune 56 statt 6 | 0 / 0 | 0 / 0 | je eine Realisierung, kein Nutzen messbar; ersetzt durch Verlandung der abgeschnürten Lagunen im Baum |
| D8-Summe der Fracht in der Braid-Schleife | | | | `braidPass` +1,3–1,5 ms; ersetzt durch Einzugsgebiet × mittleren Abtrag |

„—" = vor der Kennzahl gemessen bzw. nicht gerechnet. Die Ebene und der
Hüllkurven-Fächer sind dieselbe Lehre: Fracht allein macht kein Delta, und
seichte Rinnen hält in dieser Sim nichts offen. Die Barren-Rinnen bleiben
offen, weil sie nie aufgefüllt werden (Schelftiefe), und Inseln entstehen
dort, wo die Barren aus dem Wasser ragen. Die Erosionsbasis am
Meeresspiegel statt am Meeresboden (`outletIncision`) war physikalisch
begründet, änderte aber schon die Generierung (Breach) und kippte
`testFlattenDropsOldMeanderState`, `testMaskIncludesVisibleRasterLakes` und
`testBuiltBandsAndRasterHandOverWithoutGapOrDoubleWater`, ohne die Deltas
zu verbessern — nicht übernommen.

### Render: Küste und Mündung

**Grauer Küstenstreifen.** Der Terrain-Shader malte jede Zelle bis
`sea + 0,012` nur in der Makrofarbe, ohne Material (die CPU-Seite war in
#174 C schon auf die Wasserlinie umgestellt). Auf flachen Küsten lag damit
ein grauer Streifen ohne Bewuchs und Sand, 10–40 Zellen breit, und die
Delta-Inseln (Scheitel 0,0015) hatten nie Bewuchs. Jetzt endet die Ausnahme
an der Wasserlinie (`hval <= sea_level`).

**Flüsse erreichen das Meer nicht** (Befund aus der Bildrunde auf
`6a0dfde`). Gemessen an Seed 1337, Jahr 20.000, je D8-Mündungskette und
Band-Stützpunkt:

- Kein Strandwall: die Höhe fällt an fünf von sechs großen Mündungen
  gleichmäßig bis ans Meer (z. B. 617/395: +0,0058, +0,0046, +0,0037,
  +0,0023, +0,0012, +0,0003, dann −0,0003); an einer lag eine Schwelle von
  +0,0009 vor einer Senke.
- Meereszellen haben keinen D8-Empfänger: die Mündungskette
  (`mouthPath`) endete an der ersten Meereszelle. See-Übergabe (2 Zellen),
  ihr Minimum-Filter und der Enden-Taper lagen damit auf dem Strand: die
  Deckkraft fiel auf den letzten 1,5 Zellen vor der Wasserlinie von 1 auf
  0,3–0,6.
- Die D8-Kette setzte am Ende der Gürtel-Linie unter 30–80° an; am Knick
  verengte der Krümmungs-Deckel das Band auf 0,2–1,9 statt 3,2 Halbbreiten
  (die dunkle Spitze), über `ribbonMaxHalfWidthSlope` zwei bis drei Zellen
  stromauf nachgezogen.
- Der Strandsaum lag über dem Gerinne: Sand-Byte 255 auf den letzten zwei
  bis vier Landzellen jeder großen Mündung.

Behoben: die Mündung läuft geradeaus entlang der Laufrichtung, bis zu
`mouthRayLandCells` (3) Zellen über Land, dann `mouthSeaCells` (5) Zellen
ins Meer (sonst die D8-Kette, ebenfalls bis 5 Zellen ins Meer, dreifach
geglättet); eine Gürtel-Linie, die selbst ins Meer läuft, endet an der
Wasserlinie. Die See-Übergabe blendet erst zwischen 2 und 4 Zellen unter
Wasser aus, der Taper liegt nur noch auf dem Stück im Meer; unter der
opaken Ozean-Ebene ist das Band dort unsichtbar. Der Knick wird über
`mouthJunctionSmoothSamples` (10) Stützpunkte geglättet. `mouthSearchCells`
16 statt 8: über eine junge Deltaebene läuft ein Fluss weiter als 8 Zellen
bis zum Meer, dort lief das Band sonst spitz aus und das D8-Raster malte
den Rest als breite dunkle Flecken. Jenseits der Wasserlinie liegt die
Mündung unter der Ozean-Ebene, sobald die gerenderte Oberfläche unter dem
Meer liegt (wie die Delta-Arme); mit dem Gelände-Maximum, das an
Uferlinien Querstreifen verhindert, stand sie sonst als dunkler Keil über
dem Meer (Seed 20, Mündung 358/641). `CoastMaterial.clearRiverBeds` nimmt
den Strand auf 8 Zellen stromauf in der Band-Halbbreite vom Gerinne.

Wächter `testRiverBandsReachTheSeaAtFullWidthAndOpacity` (Produktionswelt
Seed 1337, Jahr 1000; je Fluss-Band, das ins Meer läuft, Deckkraft und
Halbbreite an der letzten Landstelle gegen die zehn Stützpunkte davor):
auf `6a0dfde` ohne den Fix 15 von 15 Mündungen nicht voll an der
Wasserlinie (Deckkraft 0,07–0,59), 4 spitz (Halbbreite < ¼); mit dem Fix
2 von 15 (eine echte Biegung an der Wasserlinie, ein Band unter einem früher
gebauten), 0 spitz; auf `3bc20cc` 1 von 12, 0 spitz. Dazu
`testSeaMouthRunsStraightUnderTheSeaPlane` und
`testBeachIsClearedOverTheRiverBedAtTheMouth`.

**Sand-Rauten.** Der Strandsaum entstand per Breitensuche im
Chebyshev-Abstand: quadratische Ausläufer, die bilinear gefiltert als Rauten
und Treppen im Sand standen, obwohl das Gelände darunter glatt war. Jetzt
Vereinigung kreisförmiger Säume je Küstenpunkt (`beachReach`), und der
Sand-Kanal läuft durch einen 3×3-Binomialfilter nur über Land
(`TerrainColorRenderer.softenSand`): die Kante ist zwei Zellen weich, Strand
und junge Gleithang-Bank zeigen keine Zellraster-Kanten mehr. Delta-Inseln
und angeschlossene Deltaebenen (flach, dicke frische Schüttung) tragen einen
Sandrand von `deltaIslandBeachCells` (2,6) Zellen, dahinter Bewuchs; dicke
Sedimentkörper werden nie Felsküste.

**Felsküste auf flacher Terrasse** (Befund Seed 42, Südküste). Den
Steilküsten-Anteil eines Küstenpunkts bestimmte das Rückland-Relief im
Radius 8: eine flache Uferterrasse vor einem Berg wurde ganz Fels, als
dunkles Geröll auf ebenem Boden. Jetzt die Kliffhöhe im Radius 3
(`cliffRiseLo/Hi` 0,012…0,024, gemessen p75–p90 der Küstenpunkte), und Fels
aus diesem Anteil nur auf der Kliffwand selbst (eigene Makro-Steigung über
`cliffFaceSlopeLo/Hi` 0,0024…0,0036: der ganze Saum liegt bei p50
0,0011–0,0023, der Saum unter einem Kliff bei p50 0,0029–0,0033). Felszellen
(≥ 0,5) im Saum bis 3 Zellen, Jahr 20.000, Seeds 1337/42/20 (auf
`6a0dfde`, die Welten vorher und nachher verschieden): vorher 668/735/1729,
davon 369/235/445 auf Boden flacher als 0,003; nachher 210/480/1334, davon 0. Wächter
`testFlatTerraceBelowAMountainIsNoRockCoast` (vorher rot). Offen bleibt das
Felsband aus dem Materialmodell (#174 D, Weltsteigung ≥ 1,5 auf konvexen
Stufen): an der Südküste von Seed 42 steht die Küstenstufe so steil, das
Band ist heller als vorher, aber da (Bogen unten).

**Brandung.** `oceanSurfDepth` 0,02 statt 0,045 (Wassersäule 0,0012 statt
0,0027): auf den seichten Delta-Flächen lag sonst über die ganze Fläche
Schaum in Rausch-Flecken. An offener Küste fällt der Grund ohnehin binnen
einer Zelle durch das Fenster.

**Lagunen.** Abgeschnürtes Wasser mit Boden unter dem Meer und Spiegel
höchstens `lagoonMaxRise` (0,003) darüber malt das Raster nicht als See
(`WaterFieldRenderer`): es liegt unter der Ozean-Ebene und ist Meerwasser im
Bild.

### Wächter, Gegenproben, Laufzeit

- SimCore-Pflichtsuite (`-c release`, `-swift-version 5`) auf `3bc20cc`:
  593 Tests, 68 übersprungen (Messläufe), 0 Fehler — darin `DtInvariance`,
  `RelaxationTests`, `LongRunCollapse`, die Braid- und Playa-Wächter,
  `FingerprintTests`, `DeltaTests` und die neuen Mündungs- und
  Küsten-Wächter.
- Wächter des Passes (`DeltaTests`, Kerbtal-Testwelt):
  `testMouthBarsBuildIslandsBetweenOpenDistributaries` (≥ 3 Distributäre,
  Insel ≥ 20 Zellen, nie über dem Scheitel, Mündungsrinne bleibt Wasser),
  `testZeroTrapFractionLeavesTheTerrainUntouched`,
  `testSameLoadInFewerStepsBuildsTheSameDelta` (40 × 0,3 gegen 20 × 0,6:
  gleiche Inselfläche und Ablage ±2 %; rot, solange die Richtung am eigenen
  Delta-Land hing oder halb gefüllte Zellen nach einem kleinen Schritt
  stillstanden).
- Drei Wächter laufen weiter mit `deltaTrapFraction = 0` (Testkonfigs
  pinnen, was sie nicht prüfen; gemessen mit der ersten Fassung):
  `TerrainAging.testAgingTrajectoryOver100k`, `testMeanderOxbowSiltsUp`,
  `testBuiltBandsAndRasterHandOverWithoutGapOrDoubleWater`.
- `generate` setzt die Delta-Arbeitspuffer mit zurück
  (`testGenerateOnUsedTerrainYieldsFreshWorld` grün);
  `deltaMouthCells` ist in `StateInventoryTests` als Arbeitspuffer
  einsortiert.
- Godot-Vertrag (Extension lokal gebaut, `build-stamp --check` grün):
  `smoke.gd`, `water_geometry.gd` (16 Mündungen im Wasser, 0 mit Spalt),
  `river_ribbons.gd`, `water_uniforms.gd`, `graphics_study.gd`,
  `build_stamp_parity.gd`, `canopy.gd`, `relief.gd`, `lighting.gd`,
  `ui_layout.gd` mit ihrer Erfolgsmarke. `river_ribbons.gd` war zwischendurch
  rot: eine Gürtel-Linie, die an der Wasserlinie gekürzt wurde, verlor ihren
  Strahler-3-Anschluss (der lag im Stück im Meer); gekürzt wird jetzt nur,
  wenn er auf dem Rest liegt.
- Determinismus (auf `3bc20cc`): `simperf --hash` zweimal
  `08d32575d5cd353a` (Seed 1337), zweimal `0fd978609f8cc241` (Seed 42);
  Integration `6ffeb97d52f8e8d9` / `9f0fb0e9ad4d8493` — die Physik ändert
  sich gewollt.
- Laufzeit, `simperf --repeat 1` (30 Schritte à 100 Jahre nach 10.000 Jahren
  Einlauf), Integration und Delta abwechselnd, Reihenfolge je Runde
  getauscht, M4 Max unter Fremdlast:
  - auf `6a0dfde`, 8 Runden (Lastmittel ~10): Integration 76,6 / 80,3 /
    65,1 / 63,0 / 59,9 / 62,0 / 59,8 / 59,6 ms je Schritt (Median 62,5),
    Delta 65,9 / 70,2 / 73,3 / 65,0 / 65,8 / 63,4 / 64,3 / 63,5 (Median
    65,4); Median der Rundendifferenzen **+2,95 ms**.
  - auf `3bc20cc`, 16 Runden (Lastmittel 15–17, stark verrauscht):
    Integration 72,5 / 72,9 / 71,7 / 78,6 / 69,7 / 77,8 / 80,2 / 72,7 /
    85,3 / 84,8 / 91,5 / 67,6 / 90,3 / 69,5 / 68,9 / 78,3 (Median 75,4),
    Delta 79,1 / 79,1 / 81,1 / 82,8 / 84,3 / 77,6 / 73,5 / 75,4 / 88,9 /
    89,6 / 81,7 / 73,4 / 62,9 / 71,2 / 75,9 / 73,9 (Median 78,4); Median der
    Rundendifferenzen +3,9 ms.

  Die beiden Pässe selbst: `deltaDeposit` 0,48–0,70 ms, `deltaYield`
  (Höhensummen und Mündungssuche, 64 parallele Blöcke) 0,16–0,20 ms bei
  Lastmittel ~10, unter Lastmittel 16 bis 1,3 ms — zusammen ~0,7 ms, das Ziel
  0,5 ms ist damit nicht erreicht. Der Rest ist die andere Welt: im
  Messfenster mehr Mäander-Knoten und Altarme (`6a0dfde`: 11.820 statt 11.596
  bzw. 226 statt 191, Mediane aus je 4 Läufen, `belt.stamp`/`belt.migrate`
  +2,1 ms; `3bc20cc`: 11.707 statt 11.437 bzw. 208 statt 203). Die erste
  Fassung lag bei +3,0 ms, davon 1,7–1,9 ms in den Pässen.

### Bögen

Maximiert auf dem eingebauten Bildschirm (3456 × 2104, `--screen 1`), Jahr
20.000, `RS_STEP=20000`, Stand `3bc20cc` + Delta,
`docs/screenshots/zielbild-174/`:

| Bild | Welt, Kamera |
| --- | --- |
| `delta_seed1337_nah.jpg` | Seed 1337, `RS_TARGET="40.91,9.07" RS_DIST=10 RS_PITCH=1.2` (Mündung 621/418, Delta-Lappen mit Lagune) |
| `delta_seed1337_nah-2.jpg` | Seed 1337, `RS_TARGET="-46.38,15.57" RS_DIST=10 RS_PITCH=1.2` (63/459) |
| `delta_seed1337_close.jpg` | Seed 1337, `RS_CAMERA=close` |
| `delta_seed1337_valley.jpg` | Seed 1337, `RS_CAMERA=valley` |
| `delta_seed42_nah.jpg` | Seed 42, `RS_TARGET="-11.97,22.29" RS_DIST=10 RS_PITCH=1.2` (283/502) |
| `delta_seed20_nah.jpg` | Seed 20, `RS_TARGET="-13.53,-17.60" RS_DIST=10 RS_PITCH=1.2` (273/247) |
| `delta_muendung_vorher-nachher.jpg` | Seed 1337 (oben) und 42 (unten), `RS_CAMERA=close`: links `6a0dfde`, rechts jetzt (Ausschnitte; die Welten unterscheiden sich, weil das Delta die Physik ändert) |
| `delta_felskueste_seed42_vorher-nachher.jpg` | Seed 42, `RS_CAMERA=diorama`, Südküste: oben `6a0dfde`, unten jetzt |

Selbst angesehen: die Flüsse laufen voll breit bis an die Wasserlinie, ohne
Sand über dem Gerinne; vor den großen Mündungen liegen tropfenförmige
Barren-Inseln mit Sandrand, größere mit Bewuchs in der Mitte, dazwischen
türkise Meerwasser-Rinnen; auf Seed 1337 ein Delta-Lappen mit Inseln und
Rinnen. Keine Rauten und Treppen im Sand, kein grauer Küstenstreifen, keine
Geröll-Fläche auf flachen Terrassen. Ehrliche Grenzen:

- Ein vielarmiger, gelappter Vogelfuß wie in Vorlage B ist es nicht. Die
  Deltas bleiben klein (bestes je Welt 27–260 Inselzellen ≈ 0,007–0,06 km²),
  weil die Mündungen wandern (s. Lösung) und jeder Lappen jung ist; alte
  Lappen tragen die Wellen ab.
- Inseln, die an einer Rinne liegen, haben dort gerade Kanten (die Rinnen
  sind gerade Strecken); im Meer vor alten Mündungen stehen einzelne
  Barren-Inseln ohne Lauf dahinter.
- Neben einigen Mündungen malt das D8-Raster einen dunklen Wasserfleck (ein
  zweiter D8-Abfluss über die Deltaebene ohne Band), und quert ein Fluss eine
  Lagune, liegt sein Band über der Schwelle als gerader dunkler Streifen
  (Seed 1337, `delta_seed1337_nah.jpg`). Seichte Lagunen und Delta-Flächen
  tragen stellenweise noch Brandungsschaum. Biegt ein Lauf direkt an der Wasserlinie, verengt der
  Krümmungs-Deckel das Band dort zackig (Seed 20); im Wächter 2 von 15
  Mündungen, keine läuft spitz aus.
- An steilen Küstenstufen bleibt das Felsband des Materialmodells (#174 D).
