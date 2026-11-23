# Sedimentfahne bleibt küstennah und klein

Die Fahne der großen Flüsse (Issue #174, Paket C) liegt als schmaler Streifen höchstens `plumeBandCells` vor der Küste; offenes Meer bleibt klar. Der Rauchfächer des alten Shaders reichte bis zu 32 Zellen hinaus und deckte rund 3000 Zellen sichtbare Fläche (`docs/river-coast-render-measurements.md` §F); die Schranke für eine volle Fahne steht bei 600 Zellen (Anteil der Trübungsfarbe ≥ 10 %). Sie klingt nach `plumeCutoffDecays` Abklinglängen ab und reicht stromab weiter als stromauf. Die Weichzeichnung ist Shader-Sache (`ocean.gdshader`), der Uniform-Vertrag steht in `WaterUniformsTests`.

Betrifft: `SedimentPlume.field`, `WaterRender.plumeBandCells`, `WaterRender.plumeCutoffDecays`, `WaterRender.plumeMinDischargeCells`, `SedimentPlumeTests`
