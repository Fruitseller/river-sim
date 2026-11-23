# Verbreiterung kräftiger Raster-Läufe als Scheibenstempel

Nur kräftige Läufe verbreitern sich, Bäche bleiben eine Zelle breit. Jede Linienzelle über `widenThresholds[0]` stempelt eine Scheibe mit `WaterRender.widenRadius(intensity:)`, verjüngt am Kopf der Linie, moduliert von Breiten-Rauschen und Mittelpunkts-Versatz (Issue #174, „Kästen"; Begründung, Messreihe und Kalibrierung: `WaterRender` § „Verbreiterung als Scheibe", `docs/geometry-water-measurements.md` § H). Geschrieben wird per Maximum, die Reihenfolge der Stempel ist gleichgültig, das Ergebnis deterministisch.

Das Rauschen ist ein festes Ganzzahl-Gitter-Rauschen, unabhängig vom Welt-Seed: gleiche Linie, gleiche Form, auch nach einem Neu-Generieren; es hängt nur an der Zellposition und flackert im Zeitraffer nicht. Bewusst nicht `SimplexNoise`: pro kräftiger Zelle sind es drei Abfragen, und die Ganzzahl-Fassung braucht keine Sim-Rauschquelle.

Wo viele kräftige Zellen im Umkreis liegen (Flächenabfluss aus parallelen Linien), schrumpft der Radius, damit die Linien als einzelne Stränge lesbar bleiben statt zu einer dunklen Fläche zu verschmelzen.

Die Bank-Toleranz gilt SYMMETRISCH (|Bett − Nachbar-Spiegel| < `widenBarTolerance`, kleiner als `braidBarHeight`). Einseitig („nicht nennenswert darüber") durfte sich Wasser bergab unbegrenzt verbreitern: an Steilwänden liegt jede Zelle unter dem Spiegel des Laufs darüber, die Dilatation fächerte hangabwärts als Dreiecks-Federn aus, und das gröbere Render-Gitter streckte diese Zellen zu großen Splittern (Nutzer-Screenshot Jahr 0, steile Canyons). Physisch steht Wasser nie an einer Wand unter dem Fluss; auf Ebenen ändert die zweite Schranke nichts. Mittelbänke und Talkanten bleiben so trocken; gemessen wird gegen `hf`, damit seichtes Ponding die Breite nicht blockt.

Die alte Diamant-Dilatation (zwei Pässe) bleibt als Messarm (`RS_WIDEN_DIAMOND`, `WaterFieldRenderer.legacyWiden`) für Messläufe und Wächter, die beide Fassungen im selben Build vergleichen (`RectWaterTests`); der Betrieb stempelt immer Scheiben.

Betrifft: `RiverWidening`, `RiverWidening.widen`, `RiverWidening.noise`, `WaterFieldRenderer.legacyWiden`, `WaterRender.widenBarTolerance`
