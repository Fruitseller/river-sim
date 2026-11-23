# Delta-Fächer und Typ-Kanal der Bänder

Typ-Kanal: der Vertex-Vertrag trägt den Band-Typ in `UV2.x` (`ribbonKindRiver` 0, `ribbonKindDelta` 0.5, `ribbonKindOxbow` 1.0). `water.gdshader` liest ihn mit zwei Smoothsteps statt einer if-Kaskade, damit der Wert über das Band interpoliert werden darf. Die Fenster (`ribbonDeltaLo/Hi` 0.25…0.5, `ribbonStillLo/Hi` 0.75…1.0) liegen zwischen den Typ-Werten; wer `ribbonKind*` verschiebt, muss sie mitziehen (Wächter `WaterRenderTests`).

Distributär-Arme:
- Längster Arm `deltaMaxArmCells` 10: der Arm endet normalerweise an der Delta-Front; der Deckel begrenzt ihn auf ausgedehnt flachen Aprons. Vor flachen Schelfen lief er sonst über die ganze Bucht (A/B-Screenshot: drei helle Strahlen ins Meer statt eines Fächers).
- Fächerabstand `deltaFanSpacingCells` 3: münden mehrere Kanäle so dicht beieinander, bekommt nur der größte einen Fächer. Vorher lagen an einer Mündung bis zu vier identische Fächer übereinander (Seed 1337, Jahr 230.000) und addierten sich zu einem dunklen Block.
- Mindest-Halbbreite `deltaArmMinHalfWidthCells` 1,5: ein Delta-Arm ist breiter als der Lauf, aus dem er kommt (der Strom verliert an der Mündung seine Tiefe, nicht sein Wasser). Ohne das Mindestmaß wurden aus schmalen Mündungen drei nadeldünne Strahlen (A/B-Screenshot).
- Deckkraft-Deckel `deltaArmOpacity` 0,35, bewusst klein: der Fächer liegt im Wasser des Beckens (am Meer sogar unter dessen Wasser-Ebene) und soll als Trübungsfahne über dem Ablagerungskörper lesen, nicht als zweite Wasserfläche. 0,55 war messbar zu viel, die Arme standen als helle Strahlen auf dem Meer.

Betrifft: `WaterRender.ribbonKindRiver`, `WaterRender.ribbonKindDelta`, `WaterRender.ribbonKindOxbow`, `WaterRender.ribbonStillLo`, `WaterRender.ribbonDeltaLo`, `WaterRender.ribbonDeltaWeight`, `WaterRender.deltaMaxArmCells`, `WaterRender.deltaFanSpacingCells`, `WaterRender.deltaArmMinHalfWidthCells`, `WaterRender.deltaArmOpacity`, `game/shaders/water.gdshader`
