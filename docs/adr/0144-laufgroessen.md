# Lauf-Größen je Stützpunkt aus der Geometrie des Laufs

Woraus das Wasser entlang und quer zum Lauf wechselt, kommt aus der Geometrie des Laufs statt aus gleichmäßigem Rauschen (Look-Iteration 14, `RibbonMesh.flows`, gelesen von `water.gdshader`):

- Riffel (x, 0 Kolk…1 Riffel): Kolke liegen im Bogenscheitel, Riffel (Furten) im Übergang zwischen zwei Bögen, wo die Bogenstärke klein ist (`ribbonRiffleBendLo/Hi`). Auf geraden Strecken ohne Bogen in Reichweite wechseln Kolk und Riffel im Abstand von `ribbonRiffleSpacingWidths` Bandbreiten (Leopold-Wolman: 5–7 Gerinnebreiten). Steile Strecken sind Riffel.
- Weißwasser (y): Gefällestufen (`ribbonWhiteSlopeLo/Hi`), Engstellen (Halbbreite schrumpft gegen den Lauf oberhalb, `ribbonConstrictionLo/Hi`) und Zusammenflüsse (das Ende eines Zubringers, das unter dem Hauptlauf ausblendet). Den Außenbogen färbt der Shader selbst aus der Bogenstärke.
- Gefälle (z): Sim-Höhe je Zelle entlang der Zentrumslinie, über ±`ribbonSlopeWindowCells` (Fenster in Welt-Bogenlänge) gemittelt, normiert über `ribbonSlopeLo/Hi`; treibt Kräuselung und Strömungstempo.
- Breite (w): gemalte Bandbreite in Welteinheiten.

Stillwasser, Delta-Arme und Meeresmündungen: alles 0 bis auf die Breite.

Betrifft: `RiverRibbonRenderer.flowAttributes`, `RibbonMesh.flows`, `WaterRender.ribbonRiffle*`, `WaterRender.ribbonWhite*`, `WaterRender.ribbonConstriction*`, `WaterRender.ribbonConfluence*`, `WaterRender.ribbonSlope*`, `game/shaders/water.gdshader`
