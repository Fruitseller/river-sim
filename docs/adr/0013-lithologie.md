# Lithologie: Härte hängt an der Höhe, nicht an der Zelle

Das Gesteinsfeld (Issue #12) liefert je Zelle ein Härte-Signal `lithHardness` (−1 weichstes … +1 härtestes Gestein) und daraus die relative Erodierbarkeit `lithErodeK = 1 − lithContrast · hard`. Es wird je Schritt in `updateLithology` aus der aktuellen Höhe neu abgeleitet:

    s     = (h − lithBed) / lithLayerThickness     stratigraphische Koordinate
    Welle = glattes Wechselprofil über s           −1 Bandmitte … +1 Bandgrenze
    hard  = (1−Mix)·Welle + Mix·Provinz + Bias     geklemmt auf [−1, 1]
    K     = max(0.05, 1 − lithContrast·hard)

Dass `s` an `h` hängt, ist der Mechanismus: die harte Bank bleibt auf ihrem Höhenniveau, während die Erosion das weiche Gestein darunter ausräumt; die Kante wandert seitwärts (Schichtstufen-Rückverlegung), nicht nach unten. Ein an die Zelle geheftetes Feld kann das nicht, dort erodiert die weiche Zelle einmal tief und ist fertig. Ergebnis: Schichtstufen, Mesas, lithologische Knickpunkte. Das Mittel von K liegt bei ≈ 1, damit die globale Kalibrierung stehen bleibt. Die Untergrenze 0.05 verhindert unerodierbaren Fels auch bei `lithContrast > 1`.

Fix je Seed sind nur die geneigte, gefaltete Schichtebene `lithBed` und die Härte-Provinzen `lithProvince` (Batholith gegen Sedimentbecken, strukturkontrollierte Entwässerung über ganze Landstriche). Sie nutzen einen eigenen Noise-/PRNG-Zweig (`seed ^ 0x1170`), damit die Lithologie nicht mit Relief (`seed`) oder Tektonik (`seed ^ 0x5eed`) korreliert; sonst läge jede harte Bank auf einem Grat und das Feld wäre nur eine zweite Lesart der Topografie. Wächter: `Lithology.testFieldIsDeterministicPerSeed`.

Das Wellenprofil ist polynomial (Dreieck + Smoothstep) statt `sin`: bei n=832 (692k Zellen) kosteten die `sin`-Aufrufe ~14 ms je Schritt, die Polynom-Variante nichts Messbares; Form gleich (Mittel 0, weiche Bandgrenzen). Der Pass ist je Zelle unabhängig und damit datenparallel bit-identisch.

Der Faktor wirkt in allen Pfaden nur auf den Fels-Anteil (`outletIncision`, `Hydraulic.erode`, `transportLimited`, glaziale Abrasion): lockeres Sediment weiß nicht, welches Gestein darunter liegt. In der Gletscher-Abrasion wird er nur angefasst, wenn er ≠ 1 ist; sonst liefe eine andere Gleitkomma-Reihenfolge und der Lauf driftete um 1 ulp (dieselbe Falle wie in `Hydraulic.dig`, dort ausgemessen).

Ohne `cfg.lithologyEnabled` bleiben alle Felder leer und alles rechnet bit-identisch zum Stand vor #12. Herleitung und Kalibrierung: `SimConfig.lithologyEnabled`.

Betrifft: `Terrain.lithHardness`, `Terrain.lithErodeK`, `Terrain.buildLithologyField`, `Terrain.updateLithology`, `Terrain.iceFlowSubStep`, `Terrain.transportLimited`, `SimConfig.lithologyEnabled`
