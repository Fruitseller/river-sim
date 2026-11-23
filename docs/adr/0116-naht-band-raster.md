# Nahtstelle zwischen Band-Geometrie und Raster-Wasser

Seit Issue #34 rendert die Band-Geometrie das bewegte Wasser (Mäander, Deltas, Altarme), das Raster-Feld nur noch das stehende (Seen/Meer über `pond`/Gate) und die dendritischen Zubringer unterhalb der Mäander-Schwelle. Die Grenze ist eine Wassersäule, keine eigene Zahl je Pfad: wo das Band endet, wo das Feld übernimmt und was als Delta gilt, hängt an derselben Schwelle.

`lakeRawWetDepth` (0.03): ab dieser Wassersäule malt das Raster eine Fläche überhaupt als See (`rawWet` in `WaterFieldRenderer`). Seichteres Ponding bleibt dort bewusst trocken („zu viele Seen“); genau darum ist der Wert die Nahtstelle: unterhalb malt nur die Geometrie, oberhalb nur der Raster-See.

`deltaFrontDepth == lakeRawWetDepth`: bis zu dieser Wassersäule gilt eine überflutete Zelle als Delta-Apron, darüber beginnt das offene Becken, wo die Distributär-Arme aufhören. Gemessen (Seed 1337, Jahr 20.000, `docs/geometry-water-measurements.md` §A): an den 14 größten Mündungen liegt die Wassersäule direkt vor der Mündung entweder bei 0.002…0.02 (flacher Ablagerungskörper über mehrere Zellen) oder sofort bei 0.03…0.05 (Steilufer, der Lauf stürzt ins Becken). Eine eigene Zahl dazwischen wäre eine dritte Kalibrierung; so malt die Geometrie exakt den Saum, den das Raster nicht malen kann, und hört auf, wo es übernimmt. Kein Spalt, keine Doppelung.

Strandsee (`lagoonMaxRise` 0.003): abgeschnürtes Wasser mit Boden unter dem Meeresspiegel, dessen Spiegel höchstens so weit über dem Meer liegt, malt das Raster nicht als See; die Ozean-Ebene deckt es. Der Wert ist der doppelte Delta-Scheitel (`SimConfig.deltaTopset` 0.0015): so hoch schüttet das Delta Inseln und Wälle, die eine Rinne abschnüren. Gemessen (Seed 1337, Jahr 20.000, 1000-Jahr-Schritte): bis 62 Lagunenzellen inselweit je nach Schritt, bei 100-Jahr-Schritten 0–2.

Höhen-Versatz über Wasser, in Godot-Welt-Y (wie `RenderContract.riverLift`, nicht Sim-Höhe): Auf Land trägt das Band den vollen `lift`; über Wasser hob genau der es sichtbar aus der Fläche heraus. Deshalb gilt dort:
- See: `ribbonLakeSurfaceLift` 0.04, ein Hauch ÜBER dem Spiegel. Im Apron liegt das Terrain-Gitter noch unter dem Spiegel (der Vertex-Hub des Shaders greift erst ab `geometryLiftLo`), das Band darf dort nicht im Grund verschwinden.
- Meer: `ribbonSeaSurfaceSink` −0.06, knapp UNTER der Wasser-Ebene; dann liest sich das Band als Trübung im Wasser statt als Platte darauf (A/B-Befund, `docs/geometry-water-measurements.md` §C).
Beide müssen deutlich kleiner bleiben als `riverLift` (Wächter in `RenderContractTests`).

Wächter der Naht: `WaterRendererTests` headless und `game/tests/water_geometry.gd` End-to-End.

Betrifft: `WaterRender.lakeRawWetDepth`, `WaterRender.deltaFrontDepth`, `WaterRender.lagoonMaxRise`, `WaterRender.ribbonLakeSurfaceLift`, `WaterRender.ribbonSeaSurfaceSink`, `RenderContract.riverLift`, `SimRender.WaterFieldRenderer`, `SimRender.RiverRibbonRenderer`
