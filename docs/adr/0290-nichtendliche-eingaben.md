# Nicht-endliche Höhen in Bändern und Diagnose: Testaufbau, der beide Guards trifft

Höhenbänder und Diagnose-Kennzahlen müssen NaN und ±inf überstehen. Zwei Stellen im Testaufbau sind nicht beliebig.

NaN-Faltung in den Rampen: die Konstante steht zuerst in `min(1, max(0, …))`. So faltet sich ein NaN auf 0 statt durchzurutschen; eine NaN-Höhe darf keinen Fels und keinen Schnee ausweisen. Wer die Operanden tauscht, bricht das.

Injektion: `setBedForTests` erlaubt in `h` nur NaN, weil ±inf die Konsistenz-Precondition `abs(h − (rock + sed)) < 1e-12` verletzt; ±inf kommen über `restore`. Das NaN sitzt bewusst auf Index 20 (j = 1, i = 4): die Vorgängerzellen 17–19 lesen dabei h[1] (+inf) und h[2] (−inf) als obere Nachbarn, bevor der Zentrums-Guard an Zelle 20 das NaN verwirft. So sind Zentrums- und Nachbar-Guard je echt getroffen. NaN auf 17 würde die ±inf-Nachbarn kurzschließen (die Zelle verlässt die Schleife im Zentrums-Guard, bevor Nachbarn gelesen werden); Randzellen (Index 0–15 und letzte Reihe) besucht die Schleife nie.

Betrifft: `HeightBands.rockAmount`, `testHeightBandEvaluationWithNonFiniteHeights`, `testLandReliefHandlesNonFiniteHeightsAndEmptyTerrain`, `testDiagnosticMetricsHandleNonFiniteValuesAndEmptyTerrain`
