# Band-Geometrie für Mäander-Hauptläufe, Raster für Zubringer, Seen und Saum

Mäander-Hauptläufe rendern als Band-Geometrie entlang der Mäander-Zentrumslinien statt über Stempel → Raster → Render-Gitter (Doppelquantisierung). Reine Optik, null Sim-Rückwirkung. #31 hat die Bänder hinter einem A/B-Schalter eingeführt, #34 sie zum Standard gemacht und die Übergänge geschlossen: Mündungen laufen IN die Wasserfläche hinein statt davor zu enden, Delta-Distributäre fächern über den Ablagerungskörper auf, Altarme sind Stillwasser-Bänder statt eines Raster-Overlays. Mit #53 ist der Pfad aus `SimNode` nach `SimRender` gezogen.

Bewusst Raster (`WaterFieldRenderer`) bleiben (Begründung und Messung: `docs/geometry-water-measurements.md` §D):
- die dendritischen Zubringer unter der Mäander-Schwelle (Stream-Map × MFD-Abfluss): sie haben keine Zentrumslinien-Entität, aus der sich ein Band bauen ließe, tragen aber den größten Teil der Talzeichnung;
- Seen und Meer (Gate + Per-Pixel-Uferkontur aus #32): dort ist das Raster dem Band überlegen, die Kontur kommt pixelgenau aus der Wassersäule;
- der Nass-Saum (`shore`) um beides, inklusive des Korridor-Halos unter den Bändern.

Altarm-Parameter, Band-Breiten und Enden-Taper stehen seit #51 vollständig im Kalibrier-Vertrag `WaterRender`, gemeinsam mit dem Raster-Pfad. Sie müssen dieselben sein: das Wasserfeld nimmt genau die Zellen aus dem See-Kanal, die die Geometrie malt. Driften die Filter, entsteht doppeltes Wasser oder ein Loch.

Betrifft: `RiverRibbonRenderer`, `RibbonMesh`, `WaterFieldRenderer`, `WaterRender`
