# Eis-dt-Invarianz: Schrittpaare aus einem Zustand statt langer Läufe

Der Wächter `testIceIsFramerateIndependent` lässt aus EINEM Zustand (Jahr 5000, volle Physik, `cfg`) 1000 Jahre als 1 × 1000, 10 × 100 und 64 × 15,625 (Zeitraffer-Takt) laufen, auf drei Seeds, und vergleicht Eismasse, Fläche und Bett-Absenkung.

Warum nicht lange Läufe (der Wächter bis #174): über 20.000 Jahre laufen zwei Schrittweiten auch ohne Fehler auseinander (Tropfen-Splitting, `docs/dt-invariance-measurements.md` §5), und die Eismasse hängt an der Gipfelhöhe über der Firn-Grenze und verstärkt jede Reliefabweichung. Der alte Wächter musste 15 % zulassen und lag auf seiner Welt zufällig ruhig, während die Produktion um Faktor 2,5 auseinanderlief. Ein Abschnitt aus demselben Zustand kann nicht chaotisch divergieren; was abweicht, ist Operator-Splitting im Eis-Pfad selbst, auf jedem Seed gleichsinnig.

Warum `cfg` statt `quietCfg`: zwei der drei Ursachen lagen in der Kopplung an den Rest des Schritts (die Pfützen-Verlandung füllte den Schliff wieder auf, die Temperatur stand auf dem Schrittanfang); `quietCfg` schaltet die Verlandung ab und hätte sie nie gesehen.

Gemessen (`docs/glacier-measurements.md` §L, n = 256, Jahr 5000, Spanne über die drei Arme): vor dem Fix Absenkung 51–76 %, Masse 3,2–4,7 %; der Sprung schliff nur 25–50 % dessen, was der Zeitraffer schliff. Danach Absenkung 2,0–3,7 %, Masse 0,5–1,7 %. Die Schranken liegen dazwischen. In der Produktion mit Lawinen-Abgang (Jahr 5000 und 15.000, drei Seeds): Masse 0,5 … 0,8 %, Fläche 0,3 … 0,5 % (ohne Abgang Masse 0,5 … 1,3 %, Fläche 0,06 … 0,6 %; §M).

Dickes Eis auf flachem Bett lief bis #174 instabil: die Sub-Taktung richtete sich nur nach dem steilsten Oberflächen-Abfall, auf einer fast ebenen Platte lief ein Teilschritt mit `kappa·I` weit über 1/4, und der Schachbrett-Modus wuchs je Teilschritt um `|1 − 8·kappa·I|`. In der Produktion schliff das aufgeschaukelte Gefälle bei dt = 1000 im Mittel 0,065 unter dem Eis in einem Schritt (§L). Der Wächter dafür nutzt n = 64, ebenes Bett über der Firn-Grenze (T = −4,6 °C, keine Schmelze), 1.0 Eis mit ±0.001-Schachbrett, keine Zufuhr und Erosion: 2000 Jahre als ein Aufruf gegen 20 × 100 müssen übereinstimmen, und das Muster muss abklingen.

Betrifft: `testIceIsFramerateIndependent`, `testIceIsFramerateIndependentInProduction`, `testThickIceTransportIsStableForLargeSteps`, `testIceStepPairDiagnostic`, `Terrain.iceFlowSubStep`
