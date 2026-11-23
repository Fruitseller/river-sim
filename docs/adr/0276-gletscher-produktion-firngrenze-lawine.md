# Produktions-Wächter: Kar- und Talgletscher statt Eiskappe, Gipfel bleiben stehen

Nach der Nachkalibrierung der Firn-Grenze (#174, `docs/glacier-measurements.md` §L) liegt auf der Produktions-Welt (Seed 1337, Einlauf der Brücke, dt 1000 wie der `RS_STEP`-Vorlauf) bei der Generierung wieder etwa der Landanteil von #35 über der Grenze, und nach 20.000 Jahren trägt der Kamm Kar- und Talgletscher statt einer Eiskappe. Gemessen: 1,23 % des Landes über der Grenze, Eis 1,39 % des Landes, flach 2,7 % der obersten 5 % (mit 11 °C: 5,2 % / 4,1 % / 10,3 %, die Kappe).

Lawinen-Abgang des Firns (#174, §M): ohne Abgang steht auf jedem Gipfel über der Grenze Firn, das Eis schleift ihn bis knapp darunter, und das Gelände staut sich zu Tafeln (Seed 1337: Maximum 0,670 statt 0,752 im eisfreien Arm, harte Decke bei 0,65; Seed 20: 0,660 statt 0,727). Mit Abgang liegen beide Seeds beim eisfreien Arm (0,7525 / 0,7273). Gemessen wird gegen den eisfreien Arm derselben Welt (Maximum und Landanteil über der Grenze), Produktion, 20 × 1000 Jahre; ohne Abgang 86 / 88 % und 31 / 27 %.

Die Schranken beider Wächter haben reichlich Luft: sie trennen die beiden Zustände, sie sind kein Präzisionsmaß.

Der Abgang selbst muss Masse erhalten: auf einer steilen Rampe (Weltsteigung ≈ 1,6, Produktions-Zellgröße) mit ebenem Fuß, überall kalt genug für volle Umwandlung, liegt die Zufuhr ohne Abgang in der Rampe, mit Abgang am Fuß, und die gesamte Eismasse bleibt gleich. Das prüft Quelle −/Ziel + und das Zurücksetzen des Scratch zwischen den Aufrufen.

Betrifft: `testProductionCrestCarriesGlaciersNotACap`, `testProductionPeaksStandAboveTheFirnLine`, `testAvalancheMovesFirnSupplyWithoutLosingIt`, `SimConfig.iceFirnTemp`
