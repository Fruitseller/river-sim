# Mündungsbarren-Delta aus der Fracht der großen Mündungen (Issue #174, Abnahmepunkt 26)

`Terrain.deltaDeposit` legt die Fracht der Flüsse als Mündungsbarren vor der Mündung ab. Vorher kam im Meer vor den großen Mündungen fluvial praktisch nichts an (Seed 1337, Jahr 20.000, größte Mündung: Einzugsgebiet −7,9 Zellen·Höhe je 1000 J. über `outletIncision`, ins Meer davor −0,1 … +0,1): die Inzision ist detachment-begrenzt, ihr Abtrag lag nirgends, und an keiner Mündung der drei Matrix-Seeds stand eine Sandinsel. Messreihe und Verworfenes: `docs/zielbild-measurements.md` § Delta.

Kennzahl: `DeltaMetrics.shape`, Distributäre = 1 + größte Zahl Inseln, die ein Bogen um die Mündung quert. Gezählt werden große Mündungen (≥ 5000 Zellen) mit ≥ 3 Distributären und Sandinsel, Seeds 1337 · 20 · 42, je Jahr 2000/20.000/100.000:

    aus (Integrationsstand 3bc20cc):          0/0/0 · 0/0/0 · 0/0/0
    Wahl, Schrittweite 1000:                   5/3/7 · 1/1/4 · 0/5/1
    Wahl, Schrittweite 100:                    4/1/6 · 3/3/4 · 2/3/2
    (auf 6a0dfde: 4/2/6 · 1/5/3 · 1/3/2 bzw. 5/4/3 · 4/4/4 · 0/2/2)
    Erste Fassung (Kreisbarren rad 0,75, 2 Generationen, Fracht als D8-Summe je Zelle,
    Mündungen ab 2000), e2574d1:               6/4/10 · 2/1/5 · 1/4/1 — Inseln 13–145 Zellen, alle Sand
    dto., Mündungen ab 320 Zellen:             5/3/3 · 3/4/3 · 1/4/3
    dto. plus Erosionsbasis sea − 0,002:       9/2/5 · 1/0/3 · 2/1/0
    Stand 0fec08b (vor #187), Mündungen ab 320:
      trap 0.5, dist 3, rad 1:                 1/0/4 · 0/0/2 · 0/0/1
      trap 0.5, dist 2, rad 0.75:              3/3/6 · 0/2/3 · 0/2/2
      trap 1.0, dist 2, rad 0.75:              5/5/7 · 3/5/2 · 3/2/1

Parameter:
- `deltaTrapFraction` 1,0: Anteil der Fracht einer Mündung (Einzugsgebiet × mittlerer Abtrag von `outletIncision` + `channelCarve` je Landzelle im Schritt), der als Barre liegen bleibt; was die Barren nicht fassen, geht als Schweb ins Meer. Mit 0,5 tauchten die Barren auf Seed 20 und 42 bis Jahr 2000 nicht auf: der Schelf fällt mit ~0,003 je Zelle ab, eine Barre zwei Rinnenbreiten voraus steht in 0,03–0,04 Tiefe. Gürtel und Tropfen liefern nichts zu. 0 = Pass aus (bit-identisch).
- `deltaMinCells` 4000: mit 320 (`channelFlowMinCells`) setzten auch Bäche Barren-Sprenkel vor die Küste, und der Baum-Teil kostete mehr (0,2 statt 0,5–1,0 ms je Schritt, simperf, erste Fassung). 2000 (`meanderBeltMinCells`) gab noch Sprenkel vor mittleren Flüssen und kostete `deltaDeposit` 0,60 statt 0,50 ms; 4000 liegt knapp unter der großen Mündung der Kennzahl (5000).
- `deltaTopset` 0,0015: Scheitel der Barre über dem Meer (≈ 3,6 m bei `heightScale` 24), die Sandinsel. Unter `waveTalus` (0,002) gewählt, damit die Wellen eine Rinne neben der Insel höchstens auf sea − 0,0005 zuschütten; sie bleibt Wasser.
- `deltaBarDistanceWidths` 2,0: Abstand der Barre vor dem Strahlanfang in Rinnenbreiten (Edmonds & Slingerland 2007). 3 legte die Barren in tieferes Wasser (Endstand Jahr 20.000: 4/2/1 statt 4/1/4 Deltas).
- `deltaBarRadiusWidths` 0,9: Inselradius quer und stromauf (Fuß beim doppelten Radius). Mit 1 überlappten Fuß und Mündungsrinne. 0,75 (erste Fassung) gab Inseln von 13–145 Zellen, alle Sand; 0,9 mit Streckung 2 (Jahr 20.000, Seeds 1337/42/20) 3/4/3 Deltas, beste Inseln 95–162 Zellen mit Bewuchs, gegen 4/3/2 mit 0,75 und Streckung 1,5.
- `deltaBarElongation` 2,0: Mündungsbarren sind Tropfen in Fließrichtung; stromauf bleibt der Radius, sonst reichte die Barre bei 2 in die Mündungsrinne zurück.
- `deltaBifurcationAngle` 1,2 rad (≈ 69°): Deltas verzweigen gemessen um ~70° (Coffey & Shaw 2017, GRL 44).
- `deltaMinHalfWidth` 1,2 Zellen: ohne Untergrenze gaben drei Generationen Enkel-Rinnen von ~2 Zellen Breite, an der Auflösungsgrenze.

Betrifft: `SimConfig.deltaTrapFraction`, `SimConfig.deltaMinCells`, `SimConfig.deltaTopset`, `SimConfig.deltaBarDistanceWidths`, `SimConfig.deltaBarRadiusWidths`, `SimConfig.deltaBarElongation`, `SimConfig.deltaBifurcationAngle`, `SimConfig.deltaMinHalfWidth`, `Terrain.deltaDeposit`, `DeltaMetrics`
