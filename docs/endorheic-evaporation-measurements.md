# Verdunstung in abflusslosen Becken — Messreihe (Issue #11)

Belegt den Becken-Wasserhaushalt aus `Terrain.capEndorheicBasins`: ein
geschlossenes Becken füllt sich nur so weit, wie sein **Zufluss** die
**Verdunstung über der Seefläche** trägt. Kalibrier-Logbuch mit den gewählten
Werten: `SimConfig.endorheicEvaporation` … `endorheicSaltMinDepth`.
Reproduzieren: `RS_MEASURE=1 swift test -c release --package-path SimCore
-Xswiftc -swift-version -Xswiftc 5 --filter <Diagnose>` (die Messreihen sind
`XCTSkip`-geschützte Tests in `Tests/SimCoreTests/EndorheicEvaporation.swift`,
`RS_EVAP_N=832` schaltet die Ratio-Messung auf Produktionsauflösung).

## Bilanz in einer Zeile

    Zufluss  A_zu = max(area) über die Beckenzellen
    Bedarf   D(z) = κ · Σ_{h < z} cellArea · aridity(k)
    Spiegel  = höchster Stand z mit D(z) ≤ A_zu   (sonst: Sill = unverändert)

`area` trägt seit #10 **Abfluss** (niederschlagsgewichtet, auf das
Regen-Landmittel normiert). Deshalb ist κ dimensionslos interpretierbar:

    κ = Seeverdunstung / mittlere Abflusshöhe des Landes
      = das nötige Verhältnis Einzugsgebiet : Seefläche eines abflusslosen Sees

und deshalb ist **κ der Klima-Regler**: die Normierung teilt die absolute Nässe
heraus (ein global doppelt so feuchtes Klima liefert dasselbe `rainWeight`),
„feucht vs. trocken" ist also klein vs. groß κ. Der Regen, der auf den See
selbst fällt, steckt schon in `A_zu` → der Bedarf ist die BRUTTO-Verdunstung.

## §A Welche Verhältnisse hat die Landschaft überhaupt?

`testBasinRatioMeasurementDiagnostic` misst je gefülltem Becken (Verdunstung
aus, Becken also auf Vollstand) `Zufluss / Seefläche` in Zellen — genau die
Größe, gegen die κ antritt. Die zehn größten Becken:

n=256, Jahr 0 → 10k (Seed 1337):

| Becken | Zellen | Ratio | max. Tiefe |
|---|---|---|---|
| J0, größtes   | 2194 | 3.02 | 0.086 |
| J0, 2.        |   93 | 7.73 | 0.023 |
| J0, 3.        |   85 | 86.9 | 0.010 |
| J10k, größtes | 5172 | 1.74 | 0.121 |
| J10k, 2.      |  488 | 11.9 | 0.018 |
| J10k, 3.      |  287 | 2.29 | 0.032 |

n=832 (Produktion), Jahr 5k, Seed 1337: 39996 Z / 1.93 / 0.117 · 20429 Z /
1.63 / 0.151 · 13091 Z / 5.33 / 0.018 · 4823 Z / 0.99 / 0.081 · 4013 Z / 2.20 /
0.017 · 3786 Z / 4.71 / 0.018 …

**Die zentrale Beobachtung:** die Verteilung ist zweigeteilt.

* **Tiefe Becken liegen dicht über 1** (1.63 … 3.0): eine breite Senke ist der
  größte Teil ihres eigenen Einzugsgebiets. Sie sind genau die Becken, die der
  Priority-Flood „einfach voll" macht — der Missstand aus dem Ticket.
* **Flache Pools liegen bei 5 … 800**: sie sitzen IM Flusslauf und bekommen den
  ganzen Trunk-Abfluss. Sie sind per Bilanz unantastbar, egal wie klein sie sind
  (deshalb ist `endorheicMinBasinCells` nur ein Rausch-Deckel, kein Auswahl-
  Kriterium).

Anteil der Ponding-FLÄCHE, die ein gegebenes κ deckeln würde (n=832, J5k):

| κ | 0.75 | 1.0 | 1.25 | 1.5 | 2.0 | 3.0 |
|---|---|---|---|---|---|---|
| Seed 1337 | 8 % | 15 % | 17 % | 22 % | 44 % | 56 % |
| Seed 42   | 7 % | 12 % | 18 % | 22 % | 31 % | 51 % |
| Seed 2024 | 7 % | 12 % | 16 % | 24 % | 35 % | 51 % |

## §B κ-Sweep in Produktionsauflösung (die Kalibrier-Entscheidung)

n=832, Seed 1337, Produktionspfad. Spalten: See-Anteil am Land / davon
sichtbar (Tiefe > 0.03) / Zahl der verdunstungs-limitierten Becken /
Salzpfannen-Zellen.

| κ | Jahr 0 | Jahr 5k | Jahr 20k |
|---|---|---|---|
| 0 (aus) | 4.99 / 2.61 / 0 / 0 | 13.76 / 9.58 / 0 / 0 | 13.89 / 10.36 / 0 / 0 |
| 1.0 | 4.99 / 2.61 / 4 / 0 | 10.29 / 5.57 / 4 / 2807 | 13.28 / 9.66 / 1 / 3495 |
| 1.25 (gewählt) | 4.99 / 2.61 / 9 / 0 | 13.09 / 5.54 / 6 / 2975 | 13.33 / 10.04 / 2 / 3625 |
| 1.5 | 4.88 / 2.77 / 12 / 0 | 2.43 / 0.51 / 9 / 44211 | — |
| 2.0 | 4.55 / 2.06 / 21 / 0 | 0.85 / 0.00 / 10 / 55154 | — |
| 3.0 | 2.68 / 0.81 / 27 / 0 | 0.76 / 0.00 / 15 / 54590 | — |

Der Sprung zwischen 1.25 und 1.5 ist die Ratio-Verteilung aus §A: ab 1.5 kippen
**alle tiefen Becken gleichzeitig** — sichtbare Seefläche 10.4 → 0.5 %, ein
Viertel des Landes Salzpfanne. Das wäre nicht „endorheische Becken sind
möglich", sondern „es gibt keine Seen mehr", und widerspricht dem Ziel-Look
(ROADMAP: diskrete blaue Seen auf verschiedenen Ebenen). κ = 1.25 trifft die
überfüllten Becken und lässt die gespeisten stehen: sichtbare Seefläche
10.04 gegen 10.36 % (−3 %), dabei 2 abflusslose Becken mit 3625 Salzpfannen-
Zellen (~1 % des Landes). Relief 0.1704 gegen 0.1831 (−7 %), also weit über der
Einebnungs-Schwelle des `LongRunCollapse`-Wächters.

n=256, 10k Jahre, Seeds 1337/42/2024 (dieselben Spalten) — zur Kontrolle, dass
die Wahl nicht an einem Seed hängt:

| κ | 1337 | 42 | 2024 |
|---|---|---|---|
| 0 (aus) | 12.57 / 6.52 / 0 | 1.87 / 0.31 / 0 | 1.28 / 0.16 / 0 |
| ≤ 0.5 | bit-identisch mit „aus" | bit-identisch | bit-identisch |
| 1.5 | 11.24 / 5.29 / 0 | wie aus | 1.24 / 0.17 / 1 |
| 2.0 | 1.41 / 0.13 / 5 | 2.68 / 0.31 / 0 | 1.03 / 0.14 / 3 |
| 3.0 | 1.56 / 0.09 / 5 | 3.00 / 0.31 / 2 | 0.70 / 0.13 / 6 |

## §C Verworfene Wege (gemessen)

**Deckel schon im Breach-Spin-up.** Der Generierungs-Breach
(`breachBasins`) misst seinen Fortschritt am See-Anteil (`lakeStats`). Mit
gedeckelten Spiegeln SIEHT er die Becken nicht mehr, bricht nach der ersten
Runde ab und lässt genau die geschlossenen Becken stehen, die er durchschneiden
soll. Gemessen (n=832, Seed 1337, κ=1.0): **87684 trockengefallene Zellen schon
bei der Generierung** — mehr als die gesamte Ponding-Fläche des gebreachten
Terrains (41648 Zellen); sichtbare Seefläche 2.61 → 1.04 %, 71863 Salz-Zellen.
Der Breach ist deshalb verdunstungs-BLIND (`floodAndRoute(applyBalance: false)`)
und der Deckel kommt erst im abschließenden `computeFlow`. Physisch sind das
zwei Zeitebenen: der Breach ist die antezedente Entwässerungsgeschichte, der
Wasserhaushalt das heutige Klima.

**Zufluss auf dem gedeckelten Netz messen.** Erste Fassung: Pass 1 lief mit den
Becken-Rollen des VORIGEN Schritts. Dann sind die Seeflächen schon terminal, die
Akkumulation kommt an der Auslasszelle nie an, der gemessene Zufluss ist zu
klein — und senkt den Spiegel im nächsten Schritt weiter (Hysterese). Jetzt
löscht `floodAndRoute` die Rollen vor der Messung; Pass 1 ist immer die
vollständige, verdunstungs-freie Entwässerung.

**Salzkruste = jede trockengefallene Zelle.** Der Priority-Flood flutet den
ganzen flachen Beckenboden; von 9788 trockengefallenen Zellen (n=256, Seed 1337)
stand auf der großen Mehrheit nie mehr als ein Millimeter Wasser. Als Salzweiß
gemalt wäre das die halbe Insel. Die Kruste braucht deshalb eine Mindest-
Vollstand-Tiefe (`endorheicSaltMinDepth` = 0.03 = die Render-Seetiefe).

**κ ≥ 8** (frühe Messung, n=256): 23 Becken bei Seed 1337, jede Auen-Pfütze
fällt trocken, See-Anteil 0.37 %. Die Bilanz greift dann in die Fluss-Auen,
statt Becken zu unterscheiden.

## §D Ratenbegrenzung

`endorheicResponseYears` = 500 J. (EWMA in Sim-Zeit, dt-invariant). Der
Zielstand springt, wenn ein Becken kippt (Deposition hebt die Sill → andere
Seefläche → anderes Budget); ohne Begrenzung flackerte der Spiegel zwischen
Sill und Bilanzstand. Der DARSTELLUNGS-Spiegel (`lakeLevelResponseYears` = 250)
hängt in Serie dahinter. Wächter:
`EndorheicEvaporation.testBasinLevelIsRateLimited` (max. Sprung des mittleren
Beckenspiegels je 20-Jahres-Schritt, mit Kontrollarm τ=0),
`testBalanceLevelIsFramerateIndependent` (50 × 20 J. = 1 × 1000 J.) und der
bestehende `LakeLevelStability`.

## §E Offene Punkte

* Die J5k/J20k-Zeilen in §B sind vor dem Zufluss-Fix aus §C entstanden. Der Fix
  erhöht den gemessenen Zufluss, deckelt also weniger — die Wahl κ = 1.25 liegt
  damit auf der sicheren Seite, aber die Spätphase gehört nachgemessen
  (Jahr-0-Zeilen sind unberührt: bei der Generierung startet die Maske leer).
* **Wechselwirkung mit dem Braiding.** `testBraidingBuildsBars` (Bank-FLÄCHE über
  16 Seeds, an/aus) fällt mit eingeschaltetem Wasserhaushalt von an=160 / aus=81
  (Seeds dafür 9 / dagegen 3) auf an=124 / aus=84 (6 / 5) — der Pass baut weiter
  mehr Bänke als ohne, aber die Seed-Mehrheit reißt die geforderte Schranke.
  Ursache-Kandidat: Bänke wachsen bis knapp über `hf` (`braidBarHeight`), und in
  den Braid-Plains fällt Ponding je Seed unterschiedlich trocken. Der Wächter
  pinnt den Wasserhaushalt deshalb AUS (dieselbe Doktrin wie `meanderCfg()`);
  die Kalibrierung Braiding × Verdunstung gehört eigens gemessen.
* Sediment-Haushalt der Playa: ein trockengefallenes Becken ist von der
  Pfützen-Verlandung ausgenommen (`fillShallowPonds`), und seine Sill wird nicht
  mehr eingeschnitten (kein Abfluss → kein A^m). Real füllt eine Playa mit
  Evaporiten und Schwemmfächern auf; bei uns tun das nur die Droplet-Deltas.
* `endorheicAridity` (Klima-Kopplung der Verdunstung ans Regenfeld) ist
  mechanisch belegt, aber nicht seed-breit gemessen: offen ist eine Luv/Lee-
  Messreihe wie in `docs/rain-weighted-flow-measurements.md` §E.
