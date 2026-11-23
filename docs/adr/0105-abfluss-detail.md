# Kosmetische Shader-Rinnen an den echten Abfluss binden

Der Detail-Layer im `terrain.gdshader` allein degenerierte auf der gealterten Welt zu einem uniformen Tapeten-Muster, weil er nirgends an echte Struktur gebunden war (Nutzer-Abnahme 2026-09-02, PR #106). Das R8-Feld `WaterFieldRenderer.flowDetailField` trägt deshalb die log-normierte MFD-Abflussdichte UNTERHALB der Sichtbarkeits-Schwelle des Wassers, und der Shader konzentriert seine Rinnen dort, wo Wasser wirklich abfließt: `mix(flowDetailGainLo, flowDetailGainHi, flow)` auf `detail_strength` (0,3…1,8). Abseits der Bahnen sinkt das Detail unter den bisherigen Uniform-Look, in den Bahnen bündelt es sich. Unter `flowDetailFloorCells` (3) bleibt das Feld 0 (Einzelzellen-Abfluss ist Rauschen); log-normiert bis 1 an der Render-Schwelle, ab dort malt das sichtbare Wasser selbst.

In `flowDetailIntensity` steht die Konstante bewusst zuerst in `max(flowDetailFloorCells * 2, creekCells)`: Swift liefert für `max(c, .nan)` die Konstante, für `max(.nan, c)` NaN. Die Reihenfolge fängt NaN in `creekCells` ab.

Betrifft: `WaterRender.flowDetailFloorCells`, `WaterRender.flowDetailGainLo`, `WaterRender.flowDetailGainHi`, `WaterRender.flowDetailIntensity`, `SimRender.WaterFieldRenderer`, `game/shaders/terrain.gdshader`
