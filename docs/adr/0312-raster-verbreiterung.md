# Verbreiterung großer Raster-Läufe als Scheibe statt Diamant-Dilatation

Große Raster-Läufe ohne Band waren gleichbreite, zellgerade Streifen mit stumpfen Enden, die „Kästen" im Tiefland (Issue #174, `docs/geometry-water-measurements.md` § H): eine Diamant-Dilatation um einen D8/MFD-Pfad. Die Scheibe (`RiverWidening`, `WaterRender` § „Verbreiterung als Scheibe") macht daraus einen Lauf mit Rundung, Breitenschwankung, Mäander-Wiegen und spitzem Kopf.

Die Wächter führen den echten Renderer (`WaterFieldRenderer.bytes`) auf einer Kunstwelt aus und messen die sichtbare Form (R-Kanal ab `riverMaskLo`), nicht Zwischenfelder. Der alte Arm (`legacyWiden`) läuft als Gegenprobe mit: er zeigt, dass das Maß den Kasten erkennt und nicht nur den neuen Lauf lobt.

- Ein schwacher Lauf knapp über der Schwelle bleibt mindestens so breit wie bisher: die Kohärenz-Maske zählt Zellen (`streamGateCells`), und ein schmalerer Lauf riss als Ganzes ab, sobald seine Komponente darunter fiel (gemessen am Küstenbach in Seed 1337).
- Flächenabfluss (viele parallele Linien) verschmolz mit der alten Dilatation zu einer dunklen Fläche über den äußersten Strang hinaus; die Dichte-Regel hält den Rand am Strang.
- Kalibrier-Vertrag: schwache Läufe nicht schmaler als der alte Pass 1 (`widenRadiusAtFirstThreshold` ≥ 1 Zelle), kräftige nicht breiter als der alte Pass 2 (`widenRadiusFull` ≤ 2 Zellen).

Betrifft: `RiverWidening`, `WaterRender.widenRadiusAtFirstThreshold`, `WaterRender.widenRadiusFull`, `WaterRender.streamGateCells`, `WaterFieldRenderer.bytes`, `RiverWideningTests`
