# Relief-Servo regelt auf ein robustes Signal statt auf max − min

Bis Issue #3 regelte der Relief-Servo auf `landRelief()` = max − min über Land. Weil das Minimum per Definition knapp über `sea` liegt, war das Signal faktisch die Höhe der höchsten Zelle: eine einzelne Nadel oder ein Sculpt-Strich steuerte die Hebung der ganzen Insel. Seitdem liest der Servo `landReliefRobust()`.

Gemessen mit einer künstlich auf Maximalhöhe gezogenen Einzelzelle: max − min springt von 0.5097 auf 1.2500 (+145 %), das robuste Signal bleibt bei 0.16211. Die exakte Verschiebung (+0.019 %, sortiert gerechnet 0.161965 → 0.161995) liegt unter der Bin-Breite 0.000488 der Histogramm-Auswertung. Die Schranke im Wächter steht trotzdem bei 1 %, damit er die Aussage prüft und nicht an der Quantisierung klebt. Gegenprobe: echte Einebnung (halbes Relief) bewegt das Signal, sonst könnte der Servo nie anspringen.

`reliefServoRate` ist die einzige Quelle der Servo-Formel. Die Diagnose-Anzeige zieht Regelsignal, Talseite und Servo aus einem Histogramm-Pass und reicht das Signal an die Variante mit schon gemessenem Signal durch; beide Wege müssen am Ist-Signal bit-gleich sein (accuracy 0), sonst zeigte das Panel etwas anderes, als in `step()` wirkt. Die Rampe läuft linear über `reliefServoBand` und ist bei `reliefServoPer100y` gedeckelt.

Das Signal ist praktisch auflösungsunabhängig (die verworfene Fenster-Variante war es nicht, s. Config-Logbuch bei `reliefTarget`). Darauf stützt sich die Kalibrier-Behauptung, dass Testkonfigs mit kleinerem n auf dasselbe `reliefTarget` regeln wie die Produktion; die Reihe im Wächter geht deshalb bis zur Produktionsauflösung (`SimConfig().n`, gelesen statt genannt; war 832, seit Aug 2026 720). Gemessen (Seed 1337, frisches Terrain): 0.16504 (n=80), 0.17822 (160), 0.18311 (320), 0.18457 (640), 0.18506 (832), Spanne 11 %, ab n=160 nur 3,7 %.

Betrifft: `Terrain.landReliefRobust`, `Terrain.reliefServoRate`, `SimConfig.reliefTarget`, `SimConfig.reliefServoBand`, `SimConfig.reliefServoPer100y`, `ReliefSignal`
