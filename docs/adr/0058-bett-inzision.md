# Hydraulische Bett-Inzision auf Gleichgewichtstiefe

Auf ausreichend feinen Gittern hält `channelCarve` die Betten des Abflussnetzes auf hydraulischer Gleichgewichtstiefe (Issue #108, Ansatz 2): ein aktiver Fluss verlandet im Alter nicht, sondern räumt sein Bett gegenüber den Talflanken auf eine definierte Tiefe aus, abgestimmt auf `RenderContract.riverLift` (0.35 Welt-Y). Die Auflösungsgrenze steht bei `channelTargetDepth`; `channelTargetDepth = 0` schaltet den Pass aus.

Das feine Querprofil (`maximumCellSize`, `depthMultiplier`, `relaxationYears` …) ist feste Kalibrierung ohne neue Spielstand-Felder; Messreihe und Grenzen: `docs/channel-incision-measurements.md` §G. Bei n = 720 (dx ≈ 0.156) ist das Wasserband 3 bis 6 Zellen breit, das Querprofil stützt es an den Flanken ab; grobe Gitter sind am Einstieg ausgeschlossen.

`lakeMarginDepth = 0.026`: bis zu dieser Wassersäule darf der Lauf seinen flachen Anschluss an den See räumen. Gemessen: 0.020 ließ am Raster-Übergang nur 0.00482 Band-Deckkraft übrig, 0.025 noch 0.01241; 0.026 ergibt 0.02483 und liegt unter der Obergrenze 0.045. 0.030 öffnete auch tiefe Seezellen und erzeugte mit 0.15744 echtes Doppelwasser.

Abgrenzung zu anderen Pässen:
- Gürtelzellen sind ausgenommen, ihre Sohle gehört dem Gürtel-Stempel (#174). Ein Tieflandlauf mit Gürtel bekommt keine Rinne von `channelTargetDepth` (≈ 35 m): ein Mäanderfluss liegt bankfull in seiner Aue. In der Rinne hielt die Querneigung jede Schlinge fest, der Lauf blieb gemessen gerade und konnte die Rinne auch nicht seitlich ausräumen.
- Die Auslass-Schwelle eines Sees schneidet `outletIncision`, nicht dieser Pass; Zellen mit Seekontakt werden übersprungen.

Betrifft: `Terrain.channelCarve`, `SimConfig.channelTargetDepth`, `RenderContract.riverLift`, `docs/channel-incision-measurements.md`
