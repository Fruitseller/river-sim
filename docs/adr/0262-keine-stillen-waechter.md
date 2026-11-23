# Kein Wächter schaltet sich unbemerkt selbst ab

Fehlt einem Wächter seine Voraussetzung (ein Becken, ein Restsee, genug Bewegung), wird er rot, statt still zu überspringen. Seed, Auflösung und Konfiguration sind gepinnt, die Voraussetzung ist damit keine Umgebungs-Eigenschaft, sondern Teil des Wächters. Dieselbe Doktrin trägt `MeasurementGate`.

Anlass: In `testBalanceLevelIsFramerateIndependent` stand `try? XCTSkipIf(…)`; das `try?` verschluckte den Skip, bei zu kleinem Becken lief der Vergleich weiter, bei 0 Zellen auf NaN. Jetzt `XCTFail` bei weniger als 50 Zellen (gemessen 765, n = 160, κ = 6, Seed 1337), weit vom Ist-Zustand und damit kein neuer Pin. In `testDriedBedIsRenderedAsPlaya` stand `if submerged.count > 20 { … }`; mit der Auswahl über die größte Pfanne hätte ein Becken ohne Restsee die Abnahme still übersprungen. Jetzt ist der Restsee eine Zusicherung; er ist zudem genau der Sachverhalt der Abnahme (trockene Pfanne gegen benetzten Boden im selben Becken).

Betrifft: `EndorheicEvaporation.testBalanceLevelIsFramerateIndependent`, `EndorheicEvaporation.testDriedBedIsRenderedAsPlaya`, `MeasurementGate`
