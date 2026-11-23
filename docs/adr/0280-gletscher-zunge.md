# Zungen-Wächter: die Reichweite hängt am Fließen, nicht an der Bilanz

Kern von #35: Eis liegt UNTER der Firn-Grenze, wo es nicht entstehen kann, also muss es hingeflossen sein. Ohne Transport hätte das Eisfeld genau die Form seiner Massenbilanz. Oberhalb der Firn-Grenze ist die Zufuhr exakt 0 (`f_kalt = clamp(−T/span, 0, 1)`), der Gegentest mit `iceFlowK = 0` zeigt deshalb, dass die Reichweite am Fließen hängt.

Dass die Zunge nach 30k Jahren wieder schrumpft, ist kein Fehler, sondern die alternde Insel: `maxH` sinkt (0.726 → 0.625 bei n = 384), das Nährgebiet wird kleiner, und die glaziale Erosion sägt zusätzlich daran (Buzzsaw, `SimConfig.iceErodeK`; Messreihe §B von `docs/glacier-measurements.md`). Geprüft wird deshalb Aufbau (frühe gegen späte Zunge) und Bestand, nicht Monotonie.

Im Gegentest laufen BEIDE Arme ohne glaziale Erosion: sonst senkt der Abtrag das Bett unter schon liegendem Eis unter die Firn-Grenze, und der Wächter zählt eine gesunkene Zelle als geflossenes Eis (gemessen 180 Zellen). Auch dann ist der Arm ohne Fluss nicht exakt 0: das Bett sinkt weiter (Hangdiffusion und Hebung sind nicht gegatet, am dünnen Saum unter `iceMinThickness` auch die fluvialen Pässe), gemessen 63 von 968 Zellen. Kriterium ist deshalb der Vergleich (mindestens Faktor 5), nicht die Null.

Betrifft: `testTongueReachesBelowTheFirnLine`, `testWithoutFlowThereIsNoTongue`
