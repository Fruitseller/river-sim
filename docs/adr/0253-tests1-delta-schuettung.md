# Delta-Schüttung: Test des Passes allein, dt-Invarianz durch geometrische Obergrenzen

An einer Flussmündung entstehen aus der Fracht Mündungsbarren knapp über dem Meer, zwischen denen die Rinnen als Wasser frei bleiben (#174, Abnahmepunkt 26). Kennzahlen auf den Produktionswelten: `RiverDelta.swift` (`testDeltaBudgetDiagnostic`), Messreihe `docs/zielbild-measurements.md` § Delta.

Der Wächter prüft den Pass allein: ein Kerbtal mündet in eine Meeresrampe mit dem Gefälle der gemessenen Küsten, das Flussnetz kommt aus `computeFlow`, die Fracht wird vorgegeben statt aus der Erosion davor. Dieselbe Fracht in halb so vielen, doppelt so großen Schritten liefert dieselbe Form, weil Barren geometrische Obergrenzen sind und die Füllreihenfolge fest ist.

Betrifft: `Terrain.deltaDeposit`, `SimConfig.deltaTrapFraction`, `DeltaTests`
