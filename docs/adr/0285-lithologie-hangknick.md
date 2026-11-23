# Lithologie-Wächter: lokal gepaartes Hangknick-Signal gegen einen Referenzarm

Das Gesteinsfeld (#12, `Terrain.buildLithologyField`/`updateLithology`, Logbuch bei `SimConfig.lithologyEnabled`) macht Erodierbarkeit und Hangdiffusivität räumlich variabel. Abnahmekriterien und Wächter: deterministisch je Seed (`testFieldIsDeterministicPerSeed`), beide Raten lesen das Feld (`testBothRatesReadTheField`, getrennt je Kopplung, damit kein Kriterium an der Summe hängt), ein Härtekontrast hält einen Hangknick ≥ 20k Jahre (`testHardnessContrastHoldsSlopeBreak`), kein Einebnen oder Runaway (`testSoftestRockDoesNotFlatten`, `testHardestRockDoesNotRunAway`).

Referenzarm: `lithContrast = 0`, das Feld wird gerechnet, wirkt aber auf keine Rate. Beide Arme partitionieren dieselben Zellen nach derselben Härte, der Unterschied kann nur aus der Wirkung kommen. Dieser Arm muss bit-identisch zum abgeschalteten Feature sein (Grundlage aller A/B-Messungen, dieselbe Doktrin wie `RainWeightedFlow.testUniformRainWeightIsBitIdentical`). Das Feld hat Mittel nahe 0, damit K im Mittel ≈ 1 ist und die globale Rate kalibriert bleibt.

Kennzahl `slopeBreakSignal`: mittlere Makro-Steigung auf harten gegen weiche Zellen (im Fließgleichgewicht S ∝ (U/K)^(1/n)); 1.0 heißt kein Zusammenhang. Sie ist LOKAL gepaart (Fenster 16×16, Verhältnis je Fenster). Global gemittelt ist sie konfundiert und zeigt auch im Referenzarm ein Signal (n = 192, Seed 1337, 20k J.: 1.16 statt 1.00; mittlere Abtragstiefe hart/weich dort sogar 5.4). Ursache ist die Provinz-Komponente: sie klumpt die Härteklassen räumlich, und die Erosionsrate schwankt zwischen Küste, Luv und Lee um mehr als den Härtekontrast. Im Fenster sind Lage, Klima und Höhenband praktisch konstant, über hart/weich entscheidet die Schichtebene (Fallen + Faltung), genau der Kontakt eines lithologischen Knicks. Gepoolt wird als geometrisches Mittel der Fenster-Verhältnisse, gewichtet mit min(hart, weich): das arithmetische Mittel von Quotienten ist bei kleinem Nenner nach oben verzerrt (hob den Referenzarm allein auf 1.12), das Log-Mittel ist symmetrisch (Tausch gibt den Kehrwert, Rauschen 1.0). Gezählt wird nur trockenes Land (Seeböden haben Steigung ≈ 0) und nur der Härte-Kern |hard| > 0.33.

Schmelzwasser (#36) und Gletscher (#35) sind im Wächter in BEIDEN Armen ausgepinnt. Grund ist die Kennzahl, nicht die Mechanik: die Härte enthält die stratigraphische Schichtwelle und hängt per Konstruktion an `h`; jeder Prozess, der das Hochland steiler macht, hebt auch den Referenzarm. Gemessen (n = 192, Seed 1337, 20k J., `docs/glacier-measurements.md` §J):

| | Eis aus | Eis an |
|---|---|---|
| Schmelze aus | an 1.1781 / aus 1.0282 | an 1.1423 / aus 1.0843 |
| Schmelze an | an 1.1950 / aus 1.0995 | an 1.1853 / aus 1.0710 |

Die inhaltlichen Zusicherungen (Signal > 1.10, Abstand zum Referenzarm > 0.06) halten in allen vier Feldern, die Reinheits-Schranke des Referenzarms (|aus − 1| < 0.08) nur im eis- und schmelzfreien. Die Gegenprobe `testSlopeBreakSurvivesMeltRunoff` fährt volle Produktionsphysik (an 1.1853 gegen aus 1.0710, 406 vergletscherte Zellen) und prüft nur die inhaltlichen Zusicherungen; Testaufbau-Prüfungen stellen sicher, dass der Arm Schmelze und Eis wirklich fährt (deshalb `calibrationIceFirnTemp`), sonst liefe die Gegenprobe still leer.

Der Diffusions-Kontrast trägt zum Knick nichts Messbares bei: mit `lithDiffusionContrast = 0` ist das Signal bei 20k praktisch gleich (`docs/lithology-measurements.md` §C). Die Kopplung bleibt, weil sie Abnahmekriterium 2 ist und physikalisch Standard (härteres Gestein liefert weniger Regolith); der Wächter hält fest, dass der Knick nicht an ihr hängt.

Grenzarme: `lithHardBias = −1` verschiebt die Härte auf der ganzen Karte in die weiche Hälfte (`hard ∈ [−1, 0]`, K ≥ 1.0 überall bis 1.6, Diffusivität ≥ 1.0 bis 1.45); Relief darf nicht einebnen, Berge nicht wachsen, der See-Anteil nicht wuchern. `lithHardBias = +1` spiegelbildlich (K ≤ 1.0, bis 0.4); kein Relief-Runaway, Becken müssen entwässern.

Betrifft: `Lithology.uniformCfg`, `Lithology.slopeBreakSignal`, `testHardnessContrastHoldsSlopeBreak`, `testSlopeBreakSurvivesMeltRunoff`, `testDiffusionContrastEffectIsMeasured`, `testZeroContrastIsBitIdenticalToDisabled`, `testSoftestRockDoesNotFlatten`, `testHardestRockDoesNotRunAway`
