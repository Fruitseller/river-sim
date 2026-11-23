# Lithologie: räumlich variable Erodierbarkeit über ein stratigraphisches Gesteinsfeld

Bis Issue #12 war das Gestein überall gleich weich (eine Konstante `kRock` bzw. `outletErode`); Schichtstufen, Mesas, strukturkontrollierte Entwässerung und lithologische Knickpunkte waren damit unmöglich. Seit #12 liegt ein deterministisches, seed-abhängiges Gesteinsfeld unter der Landschaft (`Terrain.buildLithologyField`, `Terrain.updateLithology`):

    Härte           hard[k] ∈ [−1, +1] = (1−Mix)·Schichtwelle + Mix·Provinz + Bias
    Erodierbarkeit  K[k] = 1 − lithContrast · hard[k]        (Mittel ≈ 1)
    Diffusivität    D[k] = 1 − lithDiffusionContrast · hard[k]

Die Schichtwelle ist die stratigraphische Koordinate s = (h − Schichtebene) / lithLayerThickness durch ein glattes Wechselprofil. Weil sie an der aktuellen Höhe hängt, bleibt eine harte Bank auf IHREM Niveau, während die Erosion sie unterschneidet: genau der Mesa-/Schichtstufen-Mechanismus.

Was das Feld liest (Kalibrier-Kaskade):
- `outletIncision` (fluviale Makro-Rate der Produktion) skaliert `kOut` mit K → Knickpunkte im Talnetz.
- `Hydraulic.erode` skaliert nur den FELS-Anteil jedes Abtrags mit K; lockeres Sediment erodiert unverändert (Regolith ist Regolith). Deshalb braucht der Droplet-Pfad keinen zweiten Schwellwert.
- `hillslopeDiffusion` skaliert kappa mit D → harte Bänke behalten ihre Kante (ohne das kein Hangknick, Wächter `Lithology.testHardnessContrastHoldsSlopeBreak`).
- `transportLimited` (Testpfad) skaliert `kRock` mit K.
- Bewusst NICHT beteiligt: `braidPass`, `wavePass`, `meanderCarve`/Bankerosion und die Verlandungs-Pässe. Das sind Sediment-/Ufer-/Küstenprozesse in lockerem Material; die Grenze hält die Braid-/Mäander-Kalibrierung unangetastet.

Gemessen (Wächter `Lithology.swift`, `docs/lithology-measurements.md`):
- Hangknick-Signal (mittlere Makro-Steigung hart gegen weich, lokal gepaart in 16×16-Fenstern, geometrisch gepoolt, n = 192, Seed 1337): AN 0,999 (Jahr 0) → 1,163 (20k), Referenzarm (lithContrast 0) 1,004 → 1,052. Der Knick entsteht erst über die Zeit, 11 Punkte über dem Referenzarm.
- Abtragstiefe hart/weich über 20k: AN 1,24, Referenzarm 5,03; mit Härte wird das Verhältnis um Faktor 4,4 zurückgedrückt.
- Langzeit (n = 160, Seed 1337, 100k, Produktionspfad): weichstes Gestein (`lithHardBias` −1) Relief 0,5363 → 0,3643, maxH 0,6863 → 0,5143 (monoton), See-Anteil 0,053; härtestes (+1) Relief 0,4407, maxH 0,6849 → 0,5907, See-Anteil 0,045. Beide halten den LongRunCollapse-Rahmen (Relief > 0,30, See < 0,30, keine wachsenden Berge).

Rückwirkung auf Wächter (`docs/lithology-measurements.md` §E): die Mechanik-Wächter von #11 (`EndorheicEvaporation`) und der Braiding-A/B (`testBraidingBuildsBars`) pinnen das Feld AUS, weil die Lithologie Becken bzw. Seed-Mehrheit mitentscheidet. Dass die Mechaniken MIT Feld intakt bleiben, ist eigens gemessen (`Lithology.testEndorheicMechanicsSurviveLithology`; Braiding mit Feld: Bank-Fläche 177/106 gegen 132/119 uniform). Offen (§F): Gegenprobe in Produktionsauflösung und über mehrere Seeds; alle Zahlen stammen aus n = 160/192/256.

Parameter:
- `lithLayerThickness` 0,06: Höhen-Periode eines Schichtpakets (hart + weich); bei einer Landreliefspanne von ~0,5 knapp 8 Bänke über den Hang. Aus der Geometrie gesetzt, nicht gesweept (offener Sweep 0,03/0,06/0,12, §F).
- `lithDip` 0,22: Höhenversatz der Schichtebene über die Kartenbreite (Richtung und Betrag je Seed). 0 gäbe einen Terrassen-Ring um jeden Berg; 0,22 verschiebt die Bankfolge um gut 3 Pakete → Cuestas mit wechselnder Höhe. Nicht gesweept.
- `lithWarp` 0,05: Amplitude der Schicht-Faltung (fBm über ~halbe Karte) ≈ eine Paketdicke. Faltung ≫ Dicke ließe benachbarte Zellen in verschiedenen Paketen liegen → Flecken statt Bänke.
- `lithProvinceMix` 0,35: Anteil der großräumigen Härte-Provinzen (Batholith gegen Sedimentbecken). Genug für strukturkontrollierte Entwässerung, Schichtstufen bleiben dominant. 1,0 = reines Noise-Gestein ohne Stufen, 0,0 = reine Schichtfolge.
- `lithContrast` 0,6: K ∈ [0,4; 1,6], weich:hart = 4:1. Das Mittel von K bleibt 1 (Härte-Mittel |mean| < 0,15, Wächter `testFieldIsDeterministicPerSeed`), der Kontrast verschiebt die globale Rate nicht. Real sind Spannen größer (Granit:Schiefer ≈ 1:10); 0,6 ist konservativ, weil der weiche Arm beschleunigt und der Relief-Wächter Marge braucht: im Extremfall `lithHardBias = −1` Relief nach 100k 0,3643 gegen Schwelle 0,30. Sweep 0,3/0,9 offen. `lithContrast = 0` ist der Referenzarm aller Messungen (bit-identisch zu `lithologyEnabled = false`, Wächter `Lithology.testZeroContrastIsBitIdenticalToDisabled`).
- `lithDiffusionContrast` 0,45: bewusst schwächer als der fluviale Kontrast, Kriechen hängt real an Boden und Klima. Auf den Hangknick hat die Kopplung KEINEN messbaren Einfluss (Signal bei 20k mit 0,45 = 1,163, mit 0 = 1,180; Wächter `Lithology.testDiffusionContrastEffectIsMeasured`); der Knick kommt aus der fluvialen Rate. Sie bleibt, weil sie Abnahmekriterium 2 des Tickets und physikalisch Standard ist (härteres Gestein liefert weniger Regolith). Kandidat für spätere Kalibrierung, keine belegte Notwendigkeit.
- `lithHardBias` 0: globale Härte-Verschiebung, danach auf [−1, 1] geklemmt. Existiert, damit die Extreme messbar sind: bei −1 ist die ganze Karte mindestens so weich wie das Referenzgestein (K ≥ 1,0, bis 1 + lithContrast), Abnahmekriterium 4 (Wächter `Lithology.testSoftestRockDoesNotFlatten`); +1 ist die spiegelbildliche Gegenprobe.

Betrifft: `SimConfig.lithologyEnabled`, `SimConfig.lithLayerThickness`, `SimConfig.lithDip`, `SimConfig.lithWarp`, `SimConfig.lithProvinceMix`, `SimConfig.lithContrast`, `SimConfig.lithDiffusionContrast`, `SimConfig.lithHardBias`, `Terrain.buildLithologyField`, `Terrain.updateLithology`
