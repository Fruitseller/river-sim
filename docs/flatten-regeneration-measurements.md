# Messreihen: Regeneration nach großflächiger Einebnung (Issue #26)

Alle Zahlen aus `SimCore/Tests/SimCoreTests/FlattenRegeneration.swift`
(Produktionsdefaults, nur `n = 96` gesenkt; `world` bleibt bei 130, damit der
Pinselradius in Welteinheiten dieselbe Bedeutung hat wie im Spiel). Die
Einebnung läuft über die **echte** `Terrain.flatten()`-API mit den UI-Grenzwerten
(Radius 30 Welteinheiten, Stärke 3), gekachelt über die ganze Karte auf
`sea + 0.25` — der Aufbau aus dem Issue.

Reproduzieren:

```sh
RS_MEASURE=1 swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 --filter testFlattenMeasurementDiagnostic
RS_SWEEP=1   swift test -c release --package-path SimCore \
    -Xswiftc -swift-version -Xswiftc 5 \
    --filter 'testDisturbanceSweepDiagnostic|testRegenerationTrajectoryDiagnostic|testMeanderStateDiagnostic'
```

## Kennzahlen

| Spalte | Bedeutung |
|---|---|
| `max-min` | `landRelief()` — hängt an zwei Extremzellen, nur Anzeige |
| `p95-Med.` | **Hochseitenrelief** `landReliefHigh()` (= Regelsignal des Servo-Bodens) |
| `Med.-p05` | **Talseitenrelief** `landReliefLow()` (neu, Issue #26 Kriterium 6) |
| `Makro-S.` | mittlere Makro-Steigung über ±2 Zellen (die Größe, die Vegetation und Biom-Farbe lesen) |
| `Wald` | Anteil der Landzellen mit `veg > 0.45` (ab da Waldfarbe + Baum-Instanzen) |
| `Rinnen` | Anteil der Zellen, die ≥ 0.005 unter dem Mittel ihrer ±2-Umgebung liegen |
| Innenfläche | Rand von 16 Zellen weggeschnitten (s. u.) |

**Warum „nur Innenfläche"**: der Weltrand ist Basisniveau Meer. Dort schneidet
die Auslass-Inzision auch ohne jede Regeneration eine Schlucht — die
unbehandelte Platte kommt allein dadurch auf `max-min ≈ 0.21` nach 3.000 Jahren,
während die Fläche selbst unberührt flach bleibt. Die Frage von Issue #26 ist,
ob sich die **Fläche** differenziert.

## 1. Repro (Stand vor dem Fix)

Ganze Karte, Seed 1337 — reproduziert die Tabelle aus dem Issue:

| Jahr | `max-min` | p95-Med. | Med.-p05 | Makro-S. | Wald |
|---:|---:|---:|---:|---:|---:|
| 0 | 0.0000 | 0.00000 | 0.00049 | 0.00000 | 18.0 % |
| 3.000 | 0.2117 | 0.00586 | 0.00391 | 0.00066 | 91.8 % |
| 10.000 | 0.2819 | 0.01660 | 0.01709 | 0.00189 | 91.8 % |
| 50.000 | 0.3328 | 0.04248 | 0.12256 | 0.00611 | 88.1 % |

Kontrolle (dasselbe Terrain, **kein** Eingriff): `max-min 0.5084`,
`p95-Med. 0.16553`, `Makro-S. 0.01739`, Wald 60.2 % bei Jahr 3.000.

Der Wald steht bei Jahr 0 schon zu 18 % — das ist der Bestand der ALTEN
Landschaft, den die frische Platte unverändert übernimmt. Nach 3.000 Jahren ist
die Fläche zu 92 % Wald bei praktisch null Relief: die Waldtapete des Reports.

## 2. Nach dem Fix — dieselbe Messreihe

| Jahr | `max-min` | p95-Med. | Med.-p05 | Makro-S. | Wald |
|---:|---:|---:|---:|---:|---:|
| 0 | 0.0000 | 0.00000 | 0.00049 | 0.00000 | 0.4 % |
| 3.000 | 0.3392 | 0.06201 | 0.09863 | 0.00531 | 87.7 % |
| 10.000 | 0.3265 | 0.06250 | 0.12256 | 0.00618 | 90.2 % |
| 50.000 | 0.3449 | 0.09277 | 0.14990 | 0.00821 | 84.9 % |

Bei Jahr 0 steht kein Wald mehr (0.4 % Restsaum am Kartenrand außerhalb des
Pinsels): der Bestand der alten Topografie ist weg. Nach 3.000 Jahren ist das
Hochseitenrelief 10,6× und das Talseitenrelief 25× so groß wie vorher — und
zwar auf einem Niveau, das die unbehandelte Platte erst nach ~50.000 Jahren
erreicht.

## 3. Innenfläche: Pfad aus gegen ein (drei Seeds, Jahr 3.000)

| Pfad | Seed | p95-Med. | Med.-p05 | Makro-S. | Rinnen | Netzstabilität |
|---|---:|---:|---:|---:|---:|---:|
| aus | 1337 | 0.00488 | 0.00439 | 0.00051 | 0.0 % | 0.778 |
| aus | 4242 | 0.00586 | 0.00293 | 0.00049 | 0.0 % | 0.716 |
| aus | 777 | 0.00732 | 0.00195 | 0.00050 | 0.0 % | 0.741 |
| **an** | 1337 | 0.05322 | 0.08008 | 0.00546 | 32.0 % | 0.864 |
| **an** | 4242 | 0.07129 | 0.01514 | 0.00375 | 15.8 % | 0.869 |
| **an** | 777 | 0.03320 | 0.03174 | 0.00331 | 19.5 % | 0.873 |

`Netzstabilität` = Anteil der Landzellen, die über 250 Jahre denselben
Abfluss-Nachbarn behalten. Die unbehandelte Platte hat kein Netz, sondern
würfelt den Abfluss je Schritt neu (0.72–0.78); nach dem Fix steht ein Netz
(0.87), das seinen Lauf hält.

Welche Hälfte des Reliefs wächst, hängt vom Seed ab (bei 1337 die Talseite, bei
4242 die Hochseite): die Setzung folgt der begrabenen Struktur, und ob die
mehrheitlich unter oder über dem Median liegt, ist Terrain-Sache. Genau deshalb
misst der Wächter **beide Hälften zusammen** — und genau deshalb zeigt die
Diagnose sie ab jetzt getrennt an (Kriterium 6).

## 4. Zeitverlauf (Innenfläche, Seed 1337)

| Jahr | p95-Med. | Med.-p05 | Makro-S. | Wald | kahl / Gras / Wald / Auwald | Rinnen |
|---:|---:|---:|---:|---:|---|---:|
| 0 | 0.00000 | 0.00049 | 0.00000 | 0.5 % | 44.5 / 27.8 / 13.5 / 14.3 | 0.0 % |
| 500 | 0.02002 | 0.02979 | 0.00210 | 20.3 % | 0.0 / 59.7 / 16.3 / 24.0 | 8.9 % |
| 1.000 | 0.03320 | 0.04932 | 0.00346 | 84.4 % | 0.0 / 17.0 / 58.8 / 24.2 | 20.1 % |
| 2.000 | 0.04736 | 0.07080 | 0.00492 | 95.4 % | 2.0 / 6.1 / 65.4 / 26.5 | 29.3 % |
| 3.000 | 0.05273 | 0.08008 | 0.00546 | 98.3 % | 1.4 / 3.9 / 70.3 / 24.4 | 31.4 % |
| 10.000 | 0.05127 | 0.08789 | 0.00519 | 99.5 % | 0.5 / 3.6 / 72.9 / 23.0 | 29.4 % |

Das ist die gewünschte **Sukzession**: kahler Rohboden → nach ~500 Jahren Gras
(60 %) mit ersten Rinnen → nach ~1.000 Jahren Wald, während sich das Rinnennetz
weiter einschneidet. Vor dem Fix stand bei Jahr 0 bereits der alte Wald und bei
Jahr 3.000 waren es 0 % Rinnen.

## 5. Mäander-/Altarmzustand (Seed 1337, 15.000 Jahre gealtert, dann eingeebnet)

| Pfad | Altarme vor → nach | mittlere Sinuosität vor → nach |
|---|---:|---:|
| aus | 14 → 14 | 1.665 → 1.622 |
| **an** | 14 → **0** | 1.665 → **1.274** |

Ohne Pfad schreibt die Sim die Schlingen und Altarme der alten Landschaft über
die frische Platte fort. Mit Pfad fallen sie weg, und die Läufe werden aus der
neuen Entwässerung frisch getrasst (Sinuosität zurück auf Trassierungs-Niveau).

## 6. Kalibrierung

Gemessen wurde die Innenfläche bei Jahr 3.000, Seed 1337 (Auszüge; die volle
Matrix ist mit `RS_SWEEP=1` reproduzierbar). Die Sweeps stammen aus der
Kalibrier-Phase, also vor der letzten Feinjustage der Abschaltschwellen —
Abweichungen zu den Tabellen oben liegen in der letzten Stelle (z. B. settle
0.35: Talseitenrelief 0.0796 hier gegen 0.0801 final).

**Setzungsanteil `disturbanceSettle`** (τ = 1200 J.):

| settle | p95-Med. | Med.-p05 | Makro-S. |
|---:|---:|---:|---:|
| 0.00 | 0.00732 | 0.00537 | 0.00065 |
| 0.10 | 0.01562 | 0.02295 | 0.00166 |
| 0.25 | 0.03809 | 0.05713 | 0.00392 |
| **0.35** | 0.05273 | 0.07959 | 0.00547 |
| 0.50 | 0.07666 | 0.11279 | 0.00778 |

0.5 differenziert am stärksten, nimmt dem Werkzeug aber die halbe Wirkung
zurück; 0.25 lässt die Fläche zu lange steril. 0.35 ist der Kompromiss: das
Plateau bleibt als Plateau erkennbar, bekommt aber wieder Tiefenlinien.
Wiederholtes Nachziehen konvergiert geometrisch (der zweite Strich bewegt nur
noch das gesetzte Material, also 35 % von 35 %).

**Abkling-Zeitkonstante `disturbanceRecoveryYears`** (settle 0.35):

| τ | p95-Med. | Med.-p05 | Makro-S. | Wald |
|---:|---:|---:|---:|---:|
| 800 | 0.05615 | 0.08496 | 0.00581 | 90.6 % |
| **1200** | 0.05273 | 0.07959 | 0.00547 | 97.3 % |
| 2000 | 0.04492 | 0.06738 | 0.00465 | 92.3 % |

τ = 1200 J.: nach 3.000 Jahren (2,5 τ) sind 92 % der Regeneration eingetragen —
die Wirkung liegt im beobachtbaren Fenster, danach übernimmt die normale Physik.

**Mikro-Relief `disturbanceReliefAmp`** (ohne Setzung gemessen, ganze Karte):
0.012 → p95-Med. 0.0083 · 0.030 → 0.0137 · 0.060 → 0.0249. Der Effekt ist
schwach, weil die Hangdiffusion kurzwelliges Rauschen wieder wegräumt — als
alleiniger Hebel reicht er nicht. Er bleibt trotzdem drin und bewusst klein
(0.012): er ist der Symmetriebruch für Flächen, die schon VOR dem Eingriff eben
waren; dort ist die Setzung uniform und erzeugt kein Gefälle. Ab ~0.02 wirkt die
frische Fläche körnig statt eben.

**VERWORFEN — Erodierbarkeits-Bonus auf gestörten Zellen** (`kErode ×
(1 + boost·disturb)` in `outletIncision`, Begründung „frisches Material ist
unverdichtet"): ohne Setzung half er (Med.-p05 0.0068 → 0.048 bei boost 12,
ganze Karte), mit Setzung ist er im Rauschen (0.0796 → 0.0806 bei boost 6). Ein
13-facher Erodierbarkeits-Faktor plus Zweig im Hot-Loop für +1 % Wirkung —
wieder ausgebaut.

**VERWORFEN — globale Servo-Verstärkung**: macht exakt die Alterung aus
Issue #13 rückgängig (dort gemessen: Relief lief nach 30k wieder hoch) und
wirkt auf der ganzen Karte statt auf der Baustelle. Der Servo bleibt
unverändert Notboden.

## 7. Was NICHT betroffen ist

`testUntouchedAgingIsBitIdentical`: ohne Pinsel-Eingriff sind `h`, `veg` und
`streamMap` nach 3.000 Jahren **bit-identisch** zum Lauf mit abgeschaltetem
Pfad. Der Regenerations-Pfad ist ausschließlich Folge eines Eingriffs; die
100k-Alterung (`TerrainAging`, `LongRunCollapse`) läuft unverändert.
