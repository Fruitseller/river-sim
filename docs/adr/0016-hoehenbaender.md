# Höhenbänder aus Perzentilen der aktuellen Landhöhen (Issue #4)

Schnee-, Hochfels- und Vegetations-Höhengrenzen kommen aus Perzentilen der AKTUELLEN Landhöhenverteilung (`HeightBands.fromLandHeights`, angewandt in `Terrain.heightBands`; Begründung und Mechanik in `HeightBands.swift`).

Kalibrier-Messung (n = 832, Seed 1337, Produktions-Defaults; `docs/height-band-measurements.md`), Landhöhen-Quantile:

               p10    p50    p88    p91    p92    p95    p98.5  p99.5  p99.9  max
    Jahr 0   0.2346 0.3415 ~0.478 0.4986 0.5050 0.5279 0.5699 0.6018 0.6395 0.7457
    30k      0.2520 0.3552 ~0.481 0.4900 0.4962 0.5196 0.5596 0.5833 0.6026 0.6372

Die alten absoluten Schwellen lagen bei: 0,50 (veg voll) = p91,2 → p92,6; 0,58 (Graurampe) = p98,9 → p99,4; 0,68 (veg aus) = p99,99 → p100; 1,05 (Schnee) = nie erreicht; 0,26/0,48 (Nadelbaum-Band) = p17,1/p87,8 → p11,4/p89,1. Die Perzentile sind genau darauf gesetzt: Vegetation und Nadelband bleiben praktisch auf ihrer alten Höhe (Kalibrier-Kaskade, `veg` geht über `vegDamp` in die Erosion), Fels und Schnee rücken in den vorher leeren oberen Bereich.

- `bandVegFullPercentile` 0,91 = die alte 0,50 (p91,2 bei der Generierung), bewusst deckungsgleich, damit die Vegetations-Physik sich nicht verschiebt.
- Obere Vegetationsgrenze = vegFull + `bandVegRampSpanFactor` · (p95 − p50), eine robuste Relief-Spanne breit (dasselbe Quantilpaar wie `landReliefRobust`). Kein zweites Perzentil, weil die alte Obergrenze 0,68 bei p99,99 lag: ein Perzentil dort hinge an den obersten paar Zellen (bei n = 160 an 2), und jedes robustere (p99,9 = 0,6395) macht die Rampe SCHMALER. Gemessen (n = 192, Seed 1337, 20k): die schmalere Rampe kostete 2 % mittleres veg und 1,1 % Relief und kippte zwei knapp gepinnte #12-Wächter (`testHardnessContrastHoldsSlopeBreak`, `testEndorheicMechanicsSurviveLithology`); schon 0,18 → 0,17 Rampe verschob das Referenzarm-Signal 1,0517 → 1,0791 gegen die 0,08-Schranke. Faktor 1,0: Rampe bei der Generierung 0,1864 breit (gegen alte 0,18, +3,6 %), schrumpft mit der alternden Landschaft mit (0,1644 nach 30k).
- `bandRockPercentile` 0,92: war p98,9 (1,1 % des Landes, Kern der Issue-Beobachtung „99 % im schmalen Farbband“); p92 gibt den obersten 8 % einen sichtbaren Fels-Verlauf, ohne unter die Vegetationsgrenze (p91) zu rutschen. `bandRockFullPercentile` 0,995: alt 0,98 absolut lag jenseits von maxH, die Rampe kam real nie über 41 %.
- `bandConiferLowPercentile` 0,15 / `bandConiferHighPercentile` 0,88 entsprechen den alten 0,26 und 0,48.
- `bandMinRampWidth` 0,004: eine (fast) ebene Insel hat identische Quantile, ohne Untergrenze würde aus dem Verlauf eine harte Kante.
- Schnee-Perzentile sind seit Issue #33 nur noch Rückfall bei `climateEnabled = false` (dann bit-identisch zu vor #33). `bandSnowPercentile` 0,985 = oberste 1,5 % des Landes (n = 832: ~7200 Zellen in der Rampe); alt 1,05 absolut = 0 Zellen. Gesetzt, nicht gemessen: gemessen ist nur, dass der Anteil über den Lauf steht (1,51 % → 1,49 %). Enger (p99,5 = 0,5 %) wäre Streusel, weiter (p95) würde ganze Kammlinien weißen.
- `heightBandsOverride`: feste Bänder statt der Ableitung, in Produktion `nil`. Für Wächter, die an einem konkreten Becken/Lauf hängen und ihre alte Kalibrierung pinnen (dieselbe Doktrin wie `meanderCfg()` und `lithologyEnabled = false` in den #11-Wächtern). Mit `HeightBands.legacyAbsolute` läuft die Vegetation exakt wie vor #4.

Betrifft: `SimConfig.bandVegFullPercentile`, `SimConfig.bandVegRampSpanFactor`, `SimConfig.bandRockPercentile`, `SimConfig.bandRockFullPercentile`, `SimConfig.bandSnowPercentile`, `SimConfig.bandConiferLowPercentile`, `SimConfig.bandConiferHighPercentile`, `SimConfig.bandMinRampWidth`, `SimConfig.heightBandsOverride`, `HeightBands`
