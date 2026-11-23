# Firn-Grenze des Eises unter 0 °C und Lawinen-Abgang des Firns (Issue #174)

Firn-Rampe `iceFirnColdSpan` 2 K: `f_kalt = clamp((iceFirnTemp − T) / iceFirnColdSpan, 0, 1)`. Eine eigene, kältere Schwelle als die Niederschlagsphase (50 % bei +1 °C), weil Schnee, der fällt, nicht den Sommer überdauert; Gletschereis entsteht nur über der Gleichgewichtslinie. Rampe statt Kante, weil eine Kante im Feld über die Höhenlinie aliast. Bei Γ = 26, T₀ = 11 und `iceFirnTemp = 0` wären das h = 0,573 (Beginn) bis 0,65 (voll).

`iceFirnTemp` −2 °C entkoppelt die Firn-Grenze des Eises von der 0-°C-Isotherme des Dauerschnees (Schnee, Wald und Regenphase bleiben wie in #33 kalibriert). Physik: die ELA eines Gletschers liegt bei einer Jahresmitteltemperatur einige Grad unter 0 °C, typisch −2 … −8 °C (Ohmura et al. 1992: maritime Gletscher nahe −1 °C, kontinentale −8 °C und kälter). Anlass (`docs/glacier-measurements.md` §L): mit dem dt-invarianten Transport trug der Kamm eine geschlossene Eiskappe (oberste 5 % des Landes zu 10,3/6,2/11,1 % flach auf Seeds 1337/42/20, Eis 4,1/2,1/2,6 % des Landes: Hochflächen mit Wänden statt Gräten), weil die Kamm-Großform viel mehr Land über der Firn-Grenze trägt als die #35-Eichwelt (5,17/2,14/3,01 % statt ~1,5 %). Firn-Grenze `h = sea + (climateSeaLevelTemp − iceFirnTemp) / climateLapseRate`. Verworfen: Meeresspiegel-Temperatur auf 13 °C heben; dieselbe Gleichgewichtslinie, aber das ganze Klima wandert (Seed 42 ohne Schnee, Seed 20 fast ohne, Waldgrenze und Regenphase verschoben). 0 °C = Verhalten vor #174 (bit-identisch); Mechanik-Wächter mit Eis an der alten Grenze 0,573 pinnen das (`calibrationIceFirnTemp`). Muss ≤ 0 sein, damit Eis nie wärmer entsteht als Schnee liegt.

Lawinen-Abgang (`docs/glacier-measurements.md` §M): ab Weltsteigung `iceAvalancheSlopeLo` (dy/dx in Welteinheiten mit `RenderContract.heightScale`, über `Terrain.macroSlope` des Betts) bleibt Firn nicht mehr liegen, ab `iceAvalancheSlopeHi` geht er ganz ab, dazwischen smoothstep. Der abgehende Anteil landet massen-erhaltend in der ersten Zelle am Hangfuß mit Steigung unter Lo (steilster Abstieg, höchstens `iceAvalancheMaxRun` Zellen). Hi ≤ 0 = aus, bit-identisch (`simperf --hash`). Anlass: ohne Abgang trägt jede Zelle über der Eis-Firn-Grenze (≈ 0,65) Firn, auch eine 60°-Flanke; das Eis schleift die Gipfel bis knapp unter die Grenze, das Gelände staut sich zu Tafeln (Seed 1337: höchster Punkt 0,670 statt 0,752 ohne Eis, harte Decke bei 0,65–0,66; Seed 20: 0,660 statt 0,727). Real halten Flanken über 35–45° keinen Firn, Hörner und Grate bleiben eisfrei, Lawinen nähren die Kare. Die frühere Variante „Firn-Abgleiten am Steilhang 0,03…0,06“ (§L, bei `iceFirnTemp = 0`) senkte die Zufuhr, ohne sie umzulagern, und ist nicht dieselbe Mechanik.

Gemessen (Produktion, Jahr 20.000, dt 1000; höchster Punkt Seed 1337/20, eisfrei 0,7521/0,7274; Zackigkeit der obersten 5 %, eisfrei 0,00579/0,00529; Eis % des Landes):

    aus                              0,6704 / 0,6598 · 0,00537 / 0,00512 · 2,43 / 1,06
    nur eigene Zelle, 0,7/1,2 … 1,4/2,2 (Seed 20)
                                     0,665 … 0,679 — Gipfel bleiben gekappt
    Reichweite 1, 1,0/1,6            0,7523 / 0,7272 · 0,00741 / 0,00617 · 2,73 / 1,39
    Reichweite 2, 1,0/1,6 (Seed 20)  0,7271 — gleich, aber 13 % weniger Eis
    Reichweite 1, 0,7/1,2            0,752 / 0,727 · 0,00763 / 0,00589 · 1,83 / 0,95
    Reichweite 1, 1,2/1,9            0,7503 / 0,7274 · 0,00729 / 0,00605 · 2,92 / 1,66   ← gewählt
    Reichweite 1, 1,4/2,2            0,7437 / 0,7272 · 0,00684 / 0,00603 · 2,89 / 1,74

1,2/1,9 (≈ 50°/62° in der Darstellung) als Mitte: 1,0/1,6 hielt etwas mehr Land über der Grenze (0,81 %), verlor aber im V→U-Diagnostic mehr (§M); 1,4/2,2 kappt die Gipfel wieder leicht und kommt an die Eisgrenze von 3 % des Landes.

`iceAvalancheReach` 1: Steigung als Maximum der Makrosteigung im Quadrat dieses Radius. 0 (nur eigene Zelle) lässt einen Gipfel, dessen Zentraldifferenz über ±2 Zellen sich aufhebt, Firn tragen, obwohl alles um ihn steil abfällt.

Betrifft: `SimConfig.iceFirnColdSpan`, `SimConfig.iceFirnTemp`, `SimConfig.iceAvalancheSlopeLo`, `SimConfig.iceAvalancheSlopeHi`, `SimConfig.iceAvalancheMaxRun`, `SimConfig.iceAvalancheReach`, `Terrain.updateIce`, `Terrain.macroSlope`
