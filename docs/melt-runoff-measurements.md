# Schmelzwasser speist den Abfluss — Messreihen (Issue #36)

Seit Issue #33 hat die Welt eine Schneedecke (`Terrain.snow`, SWE-Bilanz), sie war
aber hydrologisch stumm: der Abfluss kannte nur den Regen. Issue #36 speist die
**Ablation** in die Abfluss-Akkumulation — durch den EINEN Trichter
`Terrain.flowWeight`, den `seedFlowAccumulator` (D8 `area` **und** MFD `areaMFD`)
und die Tropfen-Startpunkte (`Hydraulic.spawnPosition`) gemeinsam lesen.

```
m(k)   = snowMeltPerKYear · max(0, T) · S                 Schmelzfluss [SWE/Jahr]
roh(k) = rain[k] − withhold · rain[k] · f_schnee(T)  +  m(k) / snowAccumPerYear
w(k)   = roh(k) / Landmittel        (Land)                 s. §D für den Divisor
w(k)   = 1.0                        (See, neutral)
```

Die Umrechnung `m / snowAccumPerYear` ist keine freie Konstante, sondern die
Umkehrung der Akkumulation (`a = snowAccumPerYear · rain · f_schnee`): eine Zelle,
die ihren gesamten Festniederschlag wieder abschmilzt, bekommt genau
`rain · f_schnee` zurück. Daraus folgt die Obergrenze des Beitrags im
eingeschwungenen Zustand — `m/snowAccumPerYear ≤ rain`, das Gewicht kann sich
höchstens verdoppeln (gemessene Maxima §B: 1.61 → 1.97).

**Nicht dabei:** der Grundumsatz-Sockel `1/snowTurnoverYears` der Ablationsrate.
Der ist bei `SimConfig.snowTurnoverYears` als Sublimation/Windverfrachtung **und**
als Anschlusspunkt der Firn→Eis-Umwandlung (#35) besetzt; beides fließt nicht ab.
Folge: oberhalb der 0-°C-Isotherme (kein Schmelzterm) liefert eine Zelle keinen
Beitrag — das Wasser kommt aus dem **Ablationssaum** darunter.

## Methode

Alle Zahlen aus `SimCoreTests/MeltRunoff.swift` (Release-Lauf), Default-`SimConfig`
bis auf `n` und den jeweiligen Arm:

```sh
swift test -c release --package-path SimCore -Xswiftc -swift-version -Xswiftc 5 \
    --filter testMeltRunoffMeasurementDiagnostic       # §B (Arme über die Zeit)
    --filter testMeltRunoffIsSeedRobustDiagnostic      # §C/§D/§E (gepoolt)
    --filter testSnowyIslandScanDiagnostic             # §A (Reichweite)
    --filter testRunoffWeightCostDiagnostic            # §J (Kosten)
RS_MEAS_N=640 RS_MEAS_YEARS=50000 swift test … --filter testMeltRunoffMeasurementDiagnostic  # §G
```

Die vier Arme (`MeltRunoff.Arm`):

| Arm | Config | Bedeutung |
|---|---|---|
| `aus` | `meltRunoffEnabled = false` | Stand vor #36 (nur Regen) — Referenzarm |
| `A-renorm` | Default | Renormierung: Landmittel des ROHEN Gewichts → 1 |
| `B-zusatz` | `meltRunoffNormalized = false` | Zusatzwasser: Divisor bleibt das Landmittel des Regens |
| `C-einlag` | `meltRunoffWithholdSolid = 1` | zusätzlich massenkonsistente Einlagerung des Festniederschlags |

Kennzahlen (Ergänzung zu `docs/river-baseline-metrics.md`):

| Kennzahl | Definition |
|---|---|
| Abfluss je Einzugszelle | `area[k] / (Zellen(k) · cellArea)` = mittlerer Abfluss ÜBER dem Einzugsgebiet von `k`; nur Läufe mit ≥ 30 Einzugszellen. Die Normierung auf die Zellzahl macht Gebirgs- und Tieflandflüsse vergleichbar (dieselbe Konstruktion wie im Luv/Lee-Nachweis von #10) |
| schneegespeist / schneefrei | mittlere Schneedeckung des Einzugsgebiets ≥ 0.05 bzw. ≤ 0.002. Klassifiziert wird in ALLEN Armen über `snowCover` — das Schneefeld selbst koppelt nicht an die Gewichtung zurück, die Klassifikation ist also arm-unabhängig |
| ΣAbfluss | `totalOutletArea() / Zellzahl` — die Erhaltungs-Invariante (1.0000 = Gesamtabfluss wie ungewichtet) |
| Gewicht Mittel/max | Landmittel und Maximum von `flowWeight`; das Maximum steuert die Annahmequote der Tropfen-Ablehnungs-Stichprobe |
| Kanalzellen | Landzelle mit `areaMFD / cellArea ≥ renderMinCells` (320) — die Render-Definition aus `SimNode.waterFieldBytes` |

## A) Reichweite: welche Inseln haben überhaupt Schnee?

`testSnowyIslandScanDiagnostic`, n = 192, Seeds 1…40, 20.000 Jahre, Aus-Arm.
Das Feature hängt an der Gipfelhöhe: unter `h ≈ 0.46` (T = `snowRainTemp`) fällt
kein Schnee, und die Schnee-*Deckung* wird erst über `h ≈ 0.55` sichtbar.

| Klasse | Seeds | Anteil |
|---|---|---|
| Schneefrei nach 20k J. (Deckung ≤ 0.1 % der Landfläche) | 24 von 40 | 60 % |
| Schnee vorhanden | 16 von 40 | 40 % |
| **alpin** (≥ 40 schneegespeiste Läufe) | 2, 6, 20, 33 (+1337) | ~12 % |

Beispielzeilen (maxH J0 → J20k, sichtbarer Schneeanteil des Landes J0 → J20k,
schneegespeiste Läufe):

```
Seed 20   0.7515 → 0.7106   0.0469 → 0.0453   306
Seed 6    0.6814 → 0.6513   0.0670 → 0.0709   255
Seed 1337 0.6932 → 0.6305   0.0498 → 0.0374   201
Seed 33   0.6940 → 0.6340   0.0256 → 0.0128   102
Seed 2    0.6464 → 0.6062   0.0277 → 0.0221    50
Seed 7    0.5259 → 0.4787   0.0001 → 0.0000     0   ← flach, Feature stumm
Seed 99   0.4952 → 0.4567   0.0000 → 0.0000     0   ← flach, Feature stumm
Seed 2024 0.5376 → 0.4765   0.0001 → 0.0000     0   ← flach, Feature stumm
```

Konsequenz für die Messung: die Standard-Seeds der übrigen Messreihen (7, 99,
2024) sind bei n = 192 **vollständig schneefrei**. Ein Mittel über beliebige Seeds
würde deshalb überwiegend Rauschen mitteln; §C poolt über die alpinen Seeds und
nennt den Aus-Arm daneben.

## B) Die vier Arme über die Zeit (n = 192, Seed 1337)

`testMeltRunoffMeasurementDiagnostic`. Jahr 0 ist in allen vier Armen
**identisch** — die Generierung entwässert bewusst schmelzfrei (`computeFlow`
läuft dort, bevor `updateClimate` die erste Schneedecke setzt), damit die
kalibrierte Welt-Erzeugung bit-identisch bleibt.

| Arm | Jahr | Abfluss/Einzugszelle schneegespeist | schneefrei | Verhältnis | ΣAbfluss | Gewicht max | Kanalzellen | Relief | Seeanteil |
|---|---|---|---|---|---|---|---|---|---|
| alle | 0 | 0.8735 (342) | 1.0058 (341) | 0.8684 | 1.0000 | 1.782 | 629 | 0.5432 | 0.0208 |
| aus | 5.000 | 0.8818 (285) | 1.0916 (352) | 0.8078 | 1.0000 | 1.722 | 1008 | 0.5237 | 0.0943 |
| aus | 20.000 | 0.8942 (201) | 1.0624 (569) | 0.8417 | 1.0000 | 1.610 | 1153 | 0.4805 | 0.1249 |
| A-renorm | 5.000 | 1.0011 (261) | 1.0143 (399) | 0.9870 | 1.0000 | 2.376 | 1050 | 0.5274 | 0.1242 |
| A-renorm | 20.000 | 1.0474 (185) | 1.0344 (660) | **1.0126** | **1.0000** | 1.972 | 1133 | 0.4805 | 0.1122 |
| B-zusatz | 5.000 | 1.0480 (261) | 1.0582 (339) | 0.9903 | 1.0223 | 2.448 | 1031 | 0.5307 | 0.0802 |
| B-zusatz | 20.000 | 1.0697 (188) | 1.0826 (661) | 0.9881 | **1.0175** | 1.997 | 1136 | 0.4843 | 0.1024 |
| C-einlag | 5.000 | 0.8023 (259) | 1.1186 (367) | 0.7172 | 1.0000 | 1.744 | 917 | 0.5341 | 0.0639 |
| C-einlag | 20.000 | 0.8219 (220) | 1.0767 (598) | **0.7634** | 1.0000 | 1.619 | 1091 | 0.5118 | 0.1066 |

Ablesbar:

1. **Die Richtung stimmt.** Der Aus-Arm zeigt schneegespeiste Läufe **trockener**
   als schneefreie (0.84): Gipfel liegen im Regenschatten ihres eigenen
   Luvhangs, `computeRain` trocknet auf dem Aufstieg ab. Mit Schmelzwasser dreht
   das Verhältnis auf 1.01 — **+20 %** gegenüber dem Aus-Arm auf demselben Seed.
2. **Nebenwirkungen bleiben im Rauschen.** Relief 0.4805 (aus) gegen 0.4805 (A),
   Kanalzellen 1153 gegen 1133 (−1.7 %), Seeanteil 0.125 gegen 0.112. Kein
   Zell-Gate musste nachgezogen werden.
3. **Das Gewichtsmaximum bleibt zahm** (1.61 → 1.97, Faktor 1.22): die
   Ablehnungs-Stichprobe der Tropfen-Starts behält ihre Annahmequote.

## C) Richtung über mehrere Seeds (n = 192, 20.000 Jahre)

`testMeltRunoffIsSeedRobustDiagnostic`, alpine Seeds aus §A. Verhältnis
schneegespeist/schneefrei je Seed:

| Seed | aus | A-renorm | B-zusatz | C-einlag | Schnee sichtbar (A) |
|---|---|---|---|---|---|
| 1337 | 0.8417 | 1.0126 | 0.9881 | 0.7634 | 3.4 % |
| 2 | 0.9381 | 1.1211 | 1.0744 | 0.8846 | 2.1 % |
| 6 | 0.9361 | 1.1730 | 1.1274 | 0.8184 | 6.8 % |
| 20 | 0.8258 | 0.9222 | 0.9123 | 0.7570 | 4.4 % |
| 33 | 0.6757 | 0.6762 | 0.6834 | 0.6174 | 1.1 % |
| **gepoolt** | **0.8377** | **0.9594** | **0.9648** | **0.7648** | |

Gepoolt (nicht „Mittel der Verhältnisse", dieselbe Begründung wie im Luv/Lee-Test
von #10: kleine Inseln haben wenige schneegespeiste Läufe) hebt die Schmelze den
Abfluss schneegespeister Einzugsgebiete um **+14.5 %**. Vier der fünf Seeds
liegen zwischen +12 % und +25 %; **Seed 33 ist neutral** (+0.1 %) — dort deckt der
Schnee nur 1.1 % des Landes und die 102 schneegespeisten Läufe des Aus-Arms sind
mehrheitlich Gebiete mit einem Streusel Schnee im Oberlauf, nicht mit einem
Ablationssaum. Der Effekt skaliert also mit der Schneefläche, wie er soll.

ΣAbfluss ist in `aus`, `A` und `C` über alle Seeds exakt 1.0000; in `B` liegt er
bei 1.0078 … 1.0175 (s. §D).

## D) Die Designentscheidung: Renormierung (A) gegen Zusatzwasser (B)

Die Frage des Tickets. Die gesamte Kalibrierung ruht auf
**Σ Gewicht über Land = Zahl der Landzellen** (Issue #10): nur so behalten alle in
ZELLEN kalibrierten Gates ihre Bedeutung — Braid-Gates, `renderMinCells`,
Mäander-Schwellen, `minAreaCells` des Breach-Spin-ups — und nur so bleibt
`totalOutletArea() == Zellzahl` eine Invariante.

**Gewählt: A (Renormierung).** Gemessen kostet sie nichts und liefert dasselbe:

| | A-renorm | B-zusatz |
|---|---|---|
| ΣAbfluss (5 Seeds) | 1.0000 exakt | 1.0078 … 1.0175 |
| gepooltes Verhältnis schneegespeist/schneefrei | 0.9594 | 0.9648 |
| Zell-Gates neu zu vermessen | keine | alle |

Die Richtung und die Größe des Effekts sind in beiden Armen praktisch gleich
(+14.5 % gegen +15.2 %) — der Unterschied liegt weit innerhalb der Seed-Streuung
(+0.1 … +25 %). B kauft also 0.8 … 1.8 % mehr Gesamtwasser für die volle
Kalibrier-Kaskade, und dieser Faktor hängt an Seed und Auflösung (bei den
schneefreien Seeds ist er exakt 0). Genau diese Seed-/Auflösungs-Bindung hat #10
mit der Normierung abgeschafft (dort: Landmittel des Regens 0.36 … 0.56 je
Seed/Auflösung).

**Physikalische Lesart der Renormierung.** Sie behauptet nicht, dass Schmelzwasser
kein zusätzliches Wasser ist, sondern verteilt den **Abflusskoeffizienten** um:
ein schneegespeistes Einzugsgebiet führt je Einheit Niederschlag mehr Wasser als
warmes, bewachsenes Tiefland (kaum Verdunstung, keine Vegetation,
Schmelzspitzen) — real 0.7…0.95 gegen 0.2…0.4. Genau dieses Verhältnis ist der
Effekt, den das Ticket beschreibt. Die Gesamtwassermenge der Insel ist dagegen
eine kalibrierte Größe (Tropfenzahl, Erosionsraten, Braid-Gates hängen daran) und
kein Messergebnis dieses Tickets.

B bleibt als Schalter erhalten (`meltRunoffNormalized = false`): er ist der
Referenzarm, mit dem belegt ist, dass die Renormierung die Richtung nicht macht,
sondern nur die Summe hält. Wächter: `testExtraWaterArmRaisesTheDrainageTotal`
(die Summe MUSS dort steigen) gegen
`testNormalizedMeltKeepsTheDrainageTotal` (im Produktions-Arm exakt gepinnt).

## E) Verworfener Arm C: massenkonsistente Einlagerung

`meltRunoffWithholdSolid = 1` ist die **buchhalterisch korrekte** Variante: was als
Schnee fällt, fließt nicht sofort ab, sondern erst beim Schmelzen — kein Wasser
wird doppelt gezählt. Gemessen ist sie trotzdem falsch, und zwar in der
Richtung des Ticket-Ziels:

| | aus | A-renorm | C-einlag |
|---|---|---|---|
| gepoolt schneegespeist/schneefrei | 0.8377 | 0.9594 | **0.7648** |
| Kanalzellen Seed 6 | 162 | 161 | 125 |

**Warum.** Ohne Eistransport (#35) schmilzt der Schnee genau dort, wo er fällt.
Über der 0-°C-Isotherme (bei Produktionswerten `h > 0.573`) gibt es keinen
Schmelzterm — die Dauerfrostzone gibt ihren gesamten Niederschlag an einen
Speicher, der nur über den Sublimations-Sockel `1/snowTurnoverYears` wieder
leerläuft, und dieser Sockel ist bewusst kein Abfluss. Ergebnis: die
Kammlinien-Quellflüsse trocknen aus (Kanalzellen auf der alpinsten Insel −23 %),
und der Abfluss unter den schneereichsten Gebieten sinkt um 8.7 % gegenüber dem
Aus-Arm statt zu steigen.

Der Arm bleibt als Stellschraube (Default 0) erhalten: **mit #35** wandert das
eingelagerte Wasser als Eis talwärts und schmilzt am Gletschertor — dann ist die
Einlagerung die richtige Buchung, und der Sockel wird dort in `Terrain.ice`
gebucht statt verworfen (so steht es schon bei `snowTurnoverYears`).

Zwischenstand der Ehrlichkeit: der gewählte Arm A zählt den Festniederschlag
einmal als Regen und einmal als Schmelze. Das ist die bewusste Vereinfachung
dieses Tickets — sie ist der Preis dafür, dass das Wasser ohne Eisdynamik
überhaupt im Ablationssaum ankommt, und sie wird von der Renormierung wieder
eingefangen (Σ bleibt die Zellzahl).

## F) Abgeschaltet ist bit-identisch zum Stand vor #36

Nicht argumentiert, sondern gemessen (dieselbe Methode wie §0 der
`rain-weighted-flow-measurements.md`): ein temporärer Test hat in BEIDEN
Arbeitsbäumen — `origin/main` und diesem Zweig mit `meltRunoffEnabled = false` —
denselben FNV-Fingerabdruck über die Bitmuster von `h`, `area`, `areaMFD`,
`streamMap`, `veg` und `snow` gezogen (n = 192, Seeds 1337 und 99, nach
Generierung + 5 × 1000 Jahren, einmal Default-Config und einmal produktionsnah mit
`hydraulicSkipWaterSpawns` + `meanderSpatialCutoffIndex`).

Alle 24 Hashes stimmen exakt überein:

```
                    origin/main == dieser Zweig mit meltRunoffEnabled = false
seed=1337 prod=0    h=747a4680d087e927 area=6195a0e639707c60 mfd=f5a2565b717c58e7
                    stream=9fa5617b8597a6ab veg=051d10f1fc41b3fa snow=c314b02aa1aab7cc
seed=1337 prod=1    h=6eacb99802f17e66 area=da20932d4f23a4f9 mfd=0fae27012ae1e55a
                    stream=63b94aba1b7ccfc6 veg=981a3f7013186e4a snow=2f1746445f71fdd6
seed=99   prod=0    h=1bf236032fe3e67c area=b6430d0258a96438 mfd=245f8545d8009eda
                    stream=6204dc6e82d8c706 veg=b5e13fa30c7ca396 snow=495c59031ef7f9b3
seed=99   prod=1    h=36d64bb1eaa8ab17 area=8772af0e046ab218 mfd=f035ecdea7563707
                    stream=ddcc13559832dade veg=d6c8fed6c4dfc4eb snow=24252270910b9c71
```

(`prod=1` = produktionsnah mit `hydraulicSkipWaterSpawns` + `meanderSpatialCutoffIndex`.)

Im Code gibt es genau vier Verzweigungen: `updateRunoffWeight` (leeres Feld →
`flowWeight` IST `rainWeight`), `seedFlowAccumulator` und der `rainWeight:`-
Parameter der beiden `Hydraulic.erode`-Aufrufe (beide lesen `flowWeight`) sowie
das Leeren der Kryo-Felder am Anfang von `generate` (für ein frisches `Terrain`
sind sie ohnehin leer — die Zeile greift nur beim `generate` auf einem BESTEHENDEN
Terrain, und dort ist sie eine Determinismus-Korrektur, s. §I).

In-Suite-Wächter dazu: `testDisabledMeltRunoffIsBitIdentical` (Aus-Arm gegen eine
Welt, in der es nichts zu schmelzen gibt: `snowAccumPerYear = 0` → identische
Felder), `testWithoutClimateThereIsNoRunoffWeight`,
`testUnweightedFlowIgnoresTheMelt`.

## G) Produktionsauflösung (n = 640, Seed 1337, 50.000 Jahre)

`RS_MEAS_N=640 RS_MEAS_YEARS=50000 … --filter testMeltRunoffMeasurementDiagnostic`.
Dieselbe Aussage wie §B, nur mit ~11× mehr Zellen und über den doppelten
Zeithorizont — und mit deutlich mehr Läufen je Klasse (3845/13106 statt 342/341),
die Kennzahl ist hier also viel besser aufgelöst:

| Arm | Jahr | schneegespeist | schneefrei | Verhältnis | ΣAbfluss | Gewicht max | Kanalzellen | Relief |
|---|---|---|---|---|---|---|---|---|
| alle | 0 | 0.7490 (3845) | 1.0050 (13106) | 0.7452 | 1.0000 | 2.691 | 8520 | 0.5654 |
| aus | 20.000 | 0.8170 (2867) | 1.0730 (12148) | 0.7614 | 1.0000 | 2.212 | 15537 | 0.4946 |
| aus | 50.000 | 0.8365 (1976) | 1.0592 (14329) | 0.7897 | 1.0000 | 2.102 | 14159 | 0.4642 |
| A-renorm | 20.000 | 0.9702 (2676) | 1.0540 (12812) | **0.9205** | 1.0000 | 2.323 | 15507 | 0.4948 |
| A-renorm | 50.000 | 1.0152 (1847) | 1.0951 (12093) | **0.9270** | 1.0000 | 2.042 | 8797 | 0.4642 |
| B-zusatz | 20.000 | 1.0116 (2639) | 1.1474 (10296) | 0.8817 | 1.0209 | 2.374 | 8836 | 0.4940 |
| B-zusatz | 50.000 | 1.0712 (1739) | 1.1402 (11970) | 0.9394 | 1.0190 | 2.095 | 8632 | 0.4614 |
| C-einlag | 20.000 | 0.6931 (3091) | 1.0697 (12078) | 0.6480 | 1.0000 | 2.219 | 15760 | 0.5067 |
| C-einlag | 50.000 | 0.7139 (2355) | 1.1723 (12003) | 0.6090 | 1.0000 | 2.099 | 8273 | 0.4837 |

* **Der Effekt wächst mit der Auflösung nicht weg:** +20.9 % bei 20k (0.7614 →
  0.9205), +17.4 % bei 50k. Das Vorzeichen von C bleibt auch hier umgekehrt
  (−15 % bei 50k).
* **Relief praktisch identisch** (0.4642 in beiden Armen bei 50k; C liegt mit
  0.4837 4 % höher, weil ihm oben Abfluss fehlt) — die Alterungs-Kalibrierung ist
  nicht angetastet.
* **Kanalzellen taugen bei 50k NICHT als Arm-Vergleich:** 14159 (aus) gegen 8797
  (A) sieht dramatisch aus, ist aber Becken-Chaos, nicht Systematik — derselbe
  Arm streut über die Zeit genauso stark (8520 → 15537 → 14159), und B liegt schon
  bei 20k bei 8836, wo A 15507 hat. Bei n = 192 (§B), wo die Becken kleiner und
  zahlreicher sind, liegen die Arme mit −1.7 % zusammen. Die belastbaren
  Kennzahlen für „nichts kaputt" sind Relief, ΣAbfluss und die Gewichtsverteilung.
* **Gewichtsmaximum:** 2.212 → 2.323 (+5 %). Der harte Deckel
  (`meltRunoffCapPerRain`) greift hier nirgends; er ist nur für den Sculpt-Fall da
  (s. §H).

## H) Der Deckel des Schmelzbeitrags

Im Lauf bindet er nie (§B/§G: das Gewichtsmaximum steigt um 5 … 30 %, die
Obergrenze wäre +100 %). Er existiert für **einen** Fall, und der ist gemessen:
der Spieler trägt eine beschneite Kuppe ab (`flatten` → `SimNode.recomputeFlow`).
Dann steht die Temperatur sofort im Warmen, die Schneebilanz aber noch auf dem
alten Vorrat — `updateClimate(dt: 0)` zieht bewusst nur die Temperatur nach, damit
ein zeitloser Sculpt-Schritt die persistierte Bilanz nicht um ein ULP verschiebt.

`MeltRunoff.testMeltContributionIsCappedAtTheLocalRain` (n = 192, Seed 1337,
40 `flatten`-Striche auf der schneereichsten Zelle):

```
max runoffWeight/rainWeight = 1.9298      (Deckel: ≤ 2.0)
ungedeckelt wäre der Schmelzterm dieser Zelle ×213 des lokalen Regens
```

Ohne Deckel wäre das für einen Schritt eine Punkt-Quelle im Abflussfeld — und die
Ablehnungs-Stichprobe der Tropfen-Starts normiert auf das FELD-Maximum, ein
Ausreißer drückt also die Annahmequote aller anderen Zellen fast auf 0. Mit Deckel
bleibt der Eingriff „mehr Schmelze", und die Bilanz apert im nächsten echten
Schritt regulär aus.

**Der Deckel muss NACH der Normierung greifen** (PR-Review). Am Rohwert allein
gedeckelt hält die Zusage `≤ (1 + Deckel)·rainWeight` nicht, sobald die
Einlagerung mitläuft: `meltRunoffWithholdSolid > 0` nimmt kalten Zellen ihren
Festniederschlag, das Landmittel des ROHEN Gewichts fällt unter das Regenmittel,
und die Renormierung hebt danach jede Zelle um diesen Faktor an — auch die
gedeckelte. Derselbe Sculpt-Fall mit `meltRunoffWithholdSolid = 1` gemessen:

```
nur Roh-Deckel   max runoffWeight/rainWeight = 2.0123   (Zusage: ≤ 2.0) — verletzt
Deckel danach    max runoffWeight/rainWeight = 2.0000   Normierungs-Skew 1.0061
```

Der Roh-Deckel bleibt zusätzlich stehen (er hält den Normierungs-Divisor selbst
ausreißerfrei). Ohne Einlagerung ist die zweite Klammer nachweislich schlaff —
roh ≥ rain ⇒ Rohmittel ≥ Regenmittel ⇒ roh/Rohmittel ≤ (1 + Deckel)·rainWeight —,
der Produktions-Arm rechnet also unverändert. Wenn sie greift, nimmt sie Wasser
weg statt welches zu erfinden: Σ über Land bleibt ≤ Zellzahl. Im LAUF greift sie
in keinem Arm — die Messreihen §B, §C und §G wurden mit dem nachgezogenen Deckel
neu gefahren und sind Zeile für Zeile identisch (auch die C-Zeilen: ΣAbfluss
weiter exakt 1.0000).
Wächter: `testMeltContributionStaysCappedWithSolidWithholding`.

## I) Rückwirkung auf bestehende Wächter

Drei Wächter hat die Schmelze angefasst; keiner davon ist Mechanik, alle drei sind
Kennzahlen, die an EINER konkreten Realisierung hängen (dieselbe Klasse von
Rückwirkung wie bei #12, s. `docs/lithology-measurements.md` §E):

1. **`ClimateSnow.testDisabledClimateIsBitIdenticalPhysics`** — die Aussage von
   #33 „das Klima rührt keine Physik an" gilt jetzt nur noch ohne die
   Schmelz-Kopplung. Beide Arme laufen deshalb mit `meltRunoffEnabled = false`;
   die Aussage selbst (das Klima SELBST koppelt nicht) ist unverändert geprüft.
2. **`EndorheicEvaporation`** (`cfg()`) — pinnt die Schmelze aus, wie schon
   Lithologie und Höhenbänder. Die #11-Wächter messen an dem größten gedeckelten
   Becken von Seed 1337 (n = 256), und die Schmelze verschiebt, welches Becken das
   ist: mit Schmelze trägt es 0 statt 1098 Krustenzellen, weil es wieder ein
   GESPEISTES Becken ist. Dass die Playa-Bildung intakt bleibt, zählt
   `MeltRunoff.testEndorheicMechanicsSurviveMeltRunoff` inselweit über 4 Seeds:
   ```
   Seed 1337 — an: Kruste>0.5 2030 / >0.9 445 / Becken 5;  aus: 1253 / 1104 / 7
   Seed 42   — an: 0 / 0 / 1                               aus: 0 / 0 / 1
   Seed 2024 — an: 0 / 0 / 8                               aus: 30 / 0 / 8
   Seed 7    — an: 0 / 0 / 6                               aus: 0 / 0 / 5
   ```
   Mit Schmelze crusten auf Seed 1337 also MEHR Zellen als ohne (2030 gegen 1253).
3. **`Lithology.testHardnessContrastHoldsSlopeBreak`** — die Härte enthält die
   stratigraphische Schichtwelle und hängt damit per Konstruktion an `h`; jeder
   Prozess, der gezielt das Hochland steiler macht, hebt deshalb auch den
   Referenzarm, in dem die Härte gar nicht wirkt. Gemessen mit Schmelze: an 1.1950
   gegen aus 1.0995 — die inhaltlichen Zusicherungen (Signal > 1.10, Abstand
   > 0.06) halten, die REINHEITS-Schranke des Referenzarms (|aus − 1| < 0.08)
   nicht. Der Wächter läuft deshalb schmelzfrei, und
   `Lithology.testSlopeBreakSurvivesMeltRunoff` prüft die Mechanik mit Schmelze.

Grün geblieben sind insbesondere: `LongRunCollapse` (100k Jahre),
`DtInvariance` (alle), `RiverDynamicsTests` (Braiding/Mäander),
`WorldSnapshotTests`, `FlattenRegeneration`, `TerrainAging`, `VegetationTests`,
`HeightBandTests`, `StrahlerTests`, `WaterRenderTests`.

## J) Kosten

`testRunoffWeightCostDiagnostic`, n = 832, Seed 1337 (dieser Linux-Host, 4 Kerne):

```
computeRain je Schritt: mit Schmelze 4.60 ms · ohne 1.73 ms (Aufschlag 2.87 ms)
ganzer step():          396.7 ms
```

Der Aufschlag sind **0.7 % des Schritts**. Er steckt in einem sequenziellen Pass
über alle Zellen (Landmittel des rohen Gewichts — feste Summationsreihenfolge ist
die Determinismus-Bedingung, dieselbe Bauform wie in `updateRainWeight`) und ist
speicher- statt rechengebunden: der Pass liest `h`, `rain`, `temperature`, `snow`
und schreibt `runoffWeight`, bei n = 832 rund 27 MB.

Offener, sauberer Weg (nicht Teil dieses Tickets, dieselbe Argumentation wie beim
Histogramm-Fill in `updateHeightBands`): paralleler Bau mit Teilsummen je Chunk und
fester sequenzieller Endsumme. Bit-Identität wäre dann an die Chunk-Aufteilung
gebunden (`Terrain.parallel` skaliert mit der Kernzahl) — das ist eine eigene
Entscheidung über den Determinismus-Vertrag und nichts, was man beiläufig mitnimmt.

Arbeitsspeicher: ein zusätzliches `[Double]` je Zelle, und nur solange die Welt
etwas zu schmelzen hat (sonst bleibt das Feld leer). Der Spielstand wächst
**nicht**: `runoffWeight` ist eine reine Ableitung aus `rain`/`temperature`/`snow`
und steht deshalb nicht im Inventar (`TerrainState`) — das Snapshot-Format bleibt
bei Version 3.

## K) Offene Punkte

1. **Doppelzählung des Festniederschlags** (§E): ohne Eisdynamik unvermeidbar,
   von der Renormierung eingefangen. Mit #35 wird `meltRunoffWithholdSolid = 1`
   der richtige Arm — dann gehört diese Messreihe wiederholt.
2. **Operator-Splitting:** die Gewichtung liest das Schneefeld vom Ende des
   VORIGEN Schritts (`updateClimate` läuft am Schrittende, `computeRain` am
   Anfang). Bei τ ≥ 500 Jahren ist das über einen Schritt kohärent; der Rest ist
   derselbe benannte Rest wie in `docs/dt-invariance-measurements.md`
   (Abflussfeld wird nur einmal je Schritt bestimmt).
3. **Die Generierung bleibt schmelzfrei** (§B): Jahr 0 ist in allen Armen
   identisch, das erste Schmelzwasser fließt im ersten Sim-Schritt. Ein
   Vor-Einschwingen wäre möglich (`updateClimate` vor dem ersten `computeFlow`),
   würde aber die kalibrierte Welt-Erzeugung verschieben — bewusst nicht getan.
4. **`generate` leert seit #36 die Kryo-Felder.** Vorher trug ein `generate` auf
   einem bestehenden `Terrain` (im Spiel: neuer Seed auf demselben Node) den
   Schnee der alten Welt in die neue; das war bis #33 nur ein Farbdetail von
   ~2e-9 SWE (`updateClimate` relaxiert über 10.000 Jahre = 20 τ), mit #36 wäre
   es Physik geworden. Determinismus pro Seed ist eine getestete Invariante,
   deshalb die Zeile.
5. **Nur Schnee, kein Eis:** `Terrain.ice` bleibt leer (#35 füllt es). Die
   Formulierung „schnee-/eisreich" des Tickets ist damit heute „schneereich".
