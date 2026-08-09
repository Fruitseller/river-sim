# Lithologie-Feld — Mechanik und Messreihe (Issue #12)

Räumlich variable Erodierbarkeit statt eines global konstanten `kRock`. Diese Datei
hält fest, **was gemessen wurde**, **wie** gemessen wurde und **was offen bleibt**.
Die Kalibrier-Begründung je Konstante steht wie üblich im Logbuch in
`SimCore/Sources/SimCore/Config.swift` (Abschnitt „Lithologie"); die Wächter stehen in
`SimCore/Tests/SimCoreTests/Lithology.swift`.

## A. Mechanik

Zwei fixe Felder je Seed (`Terrain.buildLithologyField`, eigener Noise-Zweig
`seed ^ 0x1170`, damit die Lithologie **nicht** mit Relief oder Tektonik korreliert):

* `lithBed` — Referenzhöhe der Schichtebene: geneigte Ebene (Streichrichtung und
  Fallen je Seed gewürfelt, Betrag `lithDip · [0.4 … 1.6]`) plus fBm-**Faltung**
  (`lithWarp`, Wellenlänge ~ halbe Karte).
* `lithProvince` — großräumige Härte-Provinzen (−1 … 1, fBm ~ halbe Karte, gedehnt
  und geklemmt): Batholith gegen Sedimentbecken.

Daraus je Zeitschritt (`Terrain.updateLithology`, datenparallel, per-Zelle
unabhängig → bit-identisch zur sequenziellen Schleife):

```
s     = (h − lithBed) / lithLayerThickness        stratigraphische Koordinate
Welle = 2·smoothstep(|2·frac(s) − 1|) − 1         −1 Bandmitte … +1 Bandgrenze
hard  = (1 − Mix)·Welle + Mix·Provinz + Bias      geklemmt auf [−1, 1]
K     = max(0.05, 1 − lithContrast · hard)        Erodierbarkeit, Mittel ≈ 1
D     = max(0.05, 1 − lithDiffusionContrast·hard) Hangdiffusivität
```

**Warum `s` an der aktuellen Höhe hängt (und nicht an der Zelle):** so bleibt eine
harte Bank auf *ihrem Höhenniveau* liegen, während die Erosion das weiche Gestein
darunter ausräumt — die Kante verlegt sich seitwärts zurück (Schichtstufen-/
Mesa-Mechanismus). Ein zellfestes Härtefeld kann das nicht: dort erodiert die weiche
Zelle einmal tief und ist fertig.

**Wer das Feld liest:**

| Pass | Rolle | Kopplung |
| --- | --- | --- |
| `outletIncision` | fluviale Makro-Rate der Produktion | `kOut · K` |
| `Hydraulic.erode` (`dig`) | Droplet-Textur | **Fels-Anteil** × `K`; Sediment unverändert |
| `hillslopeDiffusion` | Bodenkriechen | `kappa · D` |
| `transportLimited` | Nicht-Droplet-**Testpfad** | `kRock · K` |
| `braidPass`, `wavePass`, `meanderCarve`/-Bankerosion, Verlandung | Sediment-/Ufer-/Küstenprozesse | **bewusst nicht** — lockeres Material, kein Fels-Abtrag |

Das Polynom-Profil (Dreieck + Smoothstep) statt `sin` ist reine Performance: der Pass
läuft je Schritt über alle Zellen (n=832 → 692k), 692k `sin` kosten ~14 ms Frame-Budget.
Form (Mittel 0, weiche Kontakte) ist dieselbe.

## B. Kennzahl „Hangknick-Signal" — und warum sie geschichtet sein muss

**Definition:** mittlere Makro-Steigung (±2 Zellen) auf hartem gegen weiches Gestein
(Härte-Kern `|hard| > 0.33`, nur trockenes Land), **lokal gepaart** in 16×16-Fenstern
(je Fenster ≥ 20 Zellen pro Klasse), gepoolt als **geometrisches** Mittel der
Fenster-Verhältnisse. 1.0 = kein Zusammenhang. Physikalische Erwartung: im
Fließgleichgewicht ist S ∝ (U/K)^(1/n), hartes Gestein trägt also die steile Stufe.

Die beiden Korrekturen sind nicht Kosmetik — beide wurden gemessen, indem der
**Referenzarm** (`lithContrast = 0`: Feld wird gerechnet, wirkt aber nicht) durch
dieselbe Kennzahl geschickt wurde. Er *muss* 1.0 liefern; tat er zunächst nicht:

| Variante der Kennzahl | AN (20k) | Referenzarm (20k) |
| --- | --- | --- |
| global, arithmetisch | 1.214 | **1.141** |
| nach Höhenbändern geschichtet, arithmetisch | 1.218 | **1.160** |
| lokal gepaart (16×16), arithmetisch | 1.225 | **1.122** |
| lokal gepaart, geometrisch (**verwendet**) | **1.163** | **1.052** |

(Die ersten drei Zeilen wurden während der Entwicklung gemessen, vor dem
Bit-Identitäts-Fix in `Hydraulic.dig` — s. §E; der verschiebt den Referenzarm um
~0.007. Die Reihenfolge und die Größenordnung der Verzerrung sind davon unberührt.)

*Ursache 1 (räumliche Klumpung):* die Provinz-Komponente klumpt die Härteklassen
räumlich, und die Erosionsrate schwankt zwischen Küste, Luv und Lee um mehr als der
Härtekontrast — sichtbar an der **Abtragstiefe** hart/weich über 20k Jahre, die im
Referenzarm bei **5.03** liegt (mit Härte: 1.24). Deshalb wird lokal gepaart.
*Ursache 2 (Quotienten-Verzerrung):* das arithmetische Mittel von Quotienten ist nach
oben verzerrt, wenn der Nenner klein werden kann (Fenster, in denen eine flache Ebene
komplett in die weiche Klasse fällt). Das Log-Mittel ist symmetrisch — hart/weich
getauscht liefert exakt den Kehrwert, reines Rauschen also 1.0.

## C. Ergebnisse

Alle Läufe Produktionspfad, Seed 1337, `dt = 500`.

**Hangknick über 20.000 Jahre** (n=192, Abnahmekriterium 3):

| | Jahr 0 | 20k Jahre |
| --- | --- | --- |
| AN (Defaults) | 0.999 | **1.163** |
| Referenzarm (`lithContrast = 0`) | 1.004 | 1.052 |

Der Knick ist bei Jahr 0 nicht da (das Feld hatte noch keine Zeit) und wird über den
Lauf aufgebaut — er wird also nicht wegerodiert/wegdiffundiert, sondern *entsteht* aus
dem Härtekontrast. Der Referenzarm zeigt mit derselben Partition +5.2 % Rest-Bias; der
Wächter fordert deshalb AN > 1.10 **und** AN ≥ Referenz + 0.06 **und** |Referenz − 1| < 0.08.

**Anteil des Diffusions-Kontrasts:** kein messbarer. Signal bei 20k mit
`lithDiffusionContrast = 0.45`: **1.163**, mit `0`: **1.180**. Der Knick kommt aus der
fluvialen Rate. Die Kopplung bleibt trotzdem (Abnahmekriterium 2 „Diffusivität liest
daraus" + physikalisch Standard), aber sie ist als *unbelegt* dokumentiert statt als
Notwendigkeit behauptet — Wächter `testDiffusionContrastEffectIsMeasured` hält beide
Zahlen fest.

**Extremgestein, Langlauf** (n=160, 100k Jahre, Abnahmekriterium 4 — dieselben
Schwellen wie `LongRunCollapse`: Relief > 0.30, See-Anteil < 0.30, maxH wächst nicht):

| Arm | Relief 0 → 100k | maxH 0 → 100k | See-Anteil | reliefRobust |
| --- | --- | --- | --- | --- |
| weichstes Gestein (`lithHardBias = −1`, K ≥ 1.0 überall, bis 1.6) | 0.5363 → **0.3643** | 0.6863 → 0.5143 | 0.053 | 0.1060 |
| härtestes Gestein (`lithHardBias = +1`, K ≤ 1.0 überall, ab 0.4) | → **0.4407** | 0.6849 → 0.5907 | 0.045 | — |

Beide Extreme halten den Rahmen, in der erwarteten Richtung (weich erodiert mehr
Relief weg, hart weniger) und ohne Runaway. Zum Vergleich: der Default-Lauf desselben
Setups liegt bei Relief ≈ 0.39 (Tabelle in `Config.swift`, Abschnitt „Abklingende
Hebung").

**Determinismus** (Abnahmekriterium 1): gleicher Seed → `lithHardness`/`lithErodeK`
elementweise gleich, anderer Seed → verschieden; ein 3000-Jahre-Lauf ist zweimal
bit-identisch. Zusätzlich: `lithContrast = 0` ist **bit-identisch** zu
`lithologyEnabled = false` (Generierung und nach 3000 Jahren, `h` und `rock`) — die
Grundlage aller A/B-Messungen hier.

## D. Rendering

`SimNode.terrainColorBytes` färbt die Bänder dezent (hart dunkler/wärmer, ±0.05 auf
RGB), damit Schichtstufen und Härtekanten auch dort ablesbar sind, wo die Kante flach
angeschnitten ist. Amplitude bewusst klein: das Biom-Signal (Fels/Moos/Schnee) bleibt
dominant.

## E. Rückwirkung auf bestehende Wächter

Das Feld ist in Produktion **an** — damit läuft jeder Wächter, der die
Produktionsdefaults fährt, auf variablem Gestein. Vier Tests haben dabei angeschlagen;
Diagnose und Behandlung:

**1. `Hydraulic.dig` war nicht bit-identisch (echter Bug, gefixt).** Der erste Entwurf
rechnete `h -= take + bed` statt `h -= d`. Bei uniformem Gestein ist
`take + (d − take)` in IEEE-754 **nicht** bit-genau `d` — der Braiding-A/B (30k Jahre,
16 Seeds) driftete dadurch selbst mit abgeschaltetem Feld weg (Bank-Fläche 185/104
statt 132/119). Der Faktor wird jetzt **vor** dem unveränderten Ablauf auf `amount`
gerechnet und nur angefasst, wenn er ≠ 1 ist. Gegengeprüft gegen einen sauberen
`main`-Worktree: mit ausgepinntem Feld liefert der Braiding-Wächter exakt die
`main`-Zahlen (132/119, Seeds 8:2, Inseln 61/42, Splits 3379/3132).

**2. `testBraidingBuildsBars` (Seed-Mehrheit 7:6 statt ≥ Abstand 3).** Gemessen, 16
Seeds, 30k Jahre:

| Arm | Bank-Fläche an/aus | Seeds dafür:dagegen | Inseln | Splits |
| --- | --- | --- | --- | --- |
| uniformes Gestein | 132 / 119 (1.11×) | 8 : 2 | 61 / 42 | 3379 / 3132 |
| mit Lithologie | 177 / 106 (1.67×) | 7 : 6 | 61 / 51 | 3570 / 3064 |

Der Pass wird also **nicht** schwächer — der Bank-Flächen-Kontrast steigt sogar. Was
reißt, ist die geforderte Seed-Mehrheit: die Bank-Fläche hängt an der Bett-Tiefe des
Reaches, und mit variablem Gestein liegen die Braid-Reaches je Seed in unterschiedlich
hartem Fels. Behandlung wie beim Wasserhaushalt in #11: der Wächter **pinnt das Feld
aus** (`cOn.lithologyEnabled = false`) und trägt die Messung im Kommentar.

**3./4. `EndorheicEvaporation.testDriedBedIsRenderedAsPlaya` und
`testBasinLevelIsRateLimited`.** Beide prüfen die #11-Mechanik am *größten* abflusslosen
Becken von Seed 1337 bei n=256 — und welches Becken das ist, entscheidet die Lithologie
mit. Gemessen (κ=6, 10×200 Jahre, an gegen aus):

| Seed | Krustenzellen > 0.5 (an / aus) | davon voll > 0.9 | Becken (an / aus) |
| --- | --- | --- | --- |
| 1337 | 510 / 1098 | 469 / 137 | 6 / 8 |
| 42 | 0 / 0 | 0 / 0 | 2 / 1 |
| 2024 | 0 / 0 | 0 / 0 | 7 / 8 |
| 7 | 0 / 0 | 0 / 0 | 5 / 4 |

Inselweit crusten mit Lithologie **510** Zellen (davon 469 voll — mehr als die 137 ohne
Feld); im *größten* Becken dagegen nur 10, weil das mit Lithologie ein gespeistes ist,
das gar nicht trockenfällt. Die Playa-Bildung ist also intakt, die Bindung des Wächters
an „largestEndorheicBasin" nicht. Beim Bilanz-Spiegel: max Sprung τ=500 **0.00429**
gegen 0.00026 ohne Feld (Wächter-Schwelle 0.002), bei τ=0 0.00703 — die Ratenbegrenzung
wirkt weiter (limitiert < instantan), aber das **Ziel** wandert schneller: mit variablem
Gestein kippen mehr Becken zwischen gedeckelt und offen, und ein Rollenwechsel setzt den
Spiegel per Konstruktion instantan (`capEndorheicBasins`). Das ist eine bestehende Kante
von #11, die die Lithologie nur häufiger trifft.

Behandlung: die #11-Wächter pinnen das Feld aus (`cfg()` in `EndorheicEvaporation`), und
umgekehrt hält `Lithology.testEndorheicMechanicsSurviveLithology` fest, dass die
#11-Mechanik **mit** Feld intakt bleibt (Playa-Seeds an ≥ aus, Ratenbegrenzung wirksam).

## F. Offene Punkte

* **Produktionsauflösung ungemessen.** Alle Zahlen hier stammen aus n=160/192. Die
  Gegenprobe bei n=832 (Relief, reliefRobust, Kanalzellen, See-Anteil, aus → an, bei
  0/5k/20k/50k Jahren) fehlt — bei #10/#11 war genau diese Tabelle der Nachweis, dass
  keine Konstante nachgezogen werden muss. Hier stützt sich dieselbe Aussage nur auf
  „Härte-Mittel ≈ 0, also K-Mittel ≈ 1" plus die Testauflösungs-Läufe.
* **Multi-Seed fehlt.** Alle Messungen auf Seed 1337; das Hangknick-Signal sollte über
  ≥ 3 Seeds gepoolt werden (bei #9 hat die Seed-Streuung mehrfach Vorzeichen gedreht).
* **Kein Parameter-Sweep** für `lithLayerThickness` (0.03/0.06/0.12),
  `lithDip`, `lithWarp`, `lithProvinceMix` und `lithContrast` (0.3/0.9). Die Werte
  kommen aus der Geometrie (Bankzahl über die Reliefspanne) und der Physik, nicht aus
  einer Messreihe.
* **Screenshot:** Stand dieses PRs siehe PR-Beschreibung — die GDExtension musste dafür
  aus leerem `.build` gebaut werden (auf diesem Linux-Host 20+ min).
* **Schichtstufen-Rückverlegung nicht direkt gemessen.** Belegt ist der Steigungs-
  Kontrast; die *Wanderung* einer Stufenkante (Rückverlegungsrate in Zellen/10k Jahre)
  wäre die schärfere Kennzahl.
* `wavePass` (Küsten-Talus) ignoriert die Härte — reale Küsten bilden aber genau dort
  Klippen, wo hartes Gestein ansteht.
