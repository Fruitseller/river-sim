# Strand und Felsküste: Befunde und Schranken der Küstenwächter (#174)

`CoastMaterial` legt Sand (A-Kanal der Makrofarbe) und Küstenfels (G-Kanal der Materialgewichte) aus dem Zusammenhang je Küstenpunkt, nicht aus Höhe und lokaler Steigung (Messreihe `docs/river-coast-render-measurements.md` §E ff.).

Befunde, die die Wächter festhalten:
- Vorher trug eine Insel überall denselben Sandring in einem Stück und gleicher Breite. Jetzt: steiles Rückland ohne Strand, Fels bis ans Wasser; flache Ebene mit Strand; Strände in Buchten statt auf Landzungen; Strand unterbrochen und mit wechselnder Breite; Flussmündungen liefern Sand auch an steiler Küste, aber nur bis `beachSupplyReachCells`.
- Seed 42, Südküste: Eine flache Uferterrasse vor einem Berg wurde über das Rückland-Relief zur Felsküste (dunkles Geröll auf ebenem Boden). Fels gehört an die Kliffwand, nicht auf die Terrasse; ein Kliff direkt an der Wasserlinie bleibt Fels.
- Delta-Insel (#174, Punkt 26): Eine flache Mündungsbarre vor einer Steilküste ist Sand, obwohl sie offen im Meer liegt.
- Review zu #174 C: Die Felsküste füllte den Rest `1 − Vegetation − Halde − Rohboden` und ließ die Kälte aus; unter teilweiser Schneedeckung summierten sich die Gewichte über 1.
- Das Ende einer Sandbank breitet sich radial aus; eine quadratische Distanz gab der diagonalen Probe denselben Sand wie der Achsenprobe.
- Rauschen unterbricht nur, was nicht eindeutig ist: Küstenebene in geschützter Lage behält ihren Strand, steiles Rückland bekommt keinen.

Aufbau und Schranken:
- Testwelten haben einen flachen Schelf: Ein tiefer Absturz an der Wasserlinie läse die Makro-Steigung (±2 Zellen) schon als Steilküste.
- Die Mip-Kette der Fahnen-Textur ist bei n = 720 (2^4 · 45) nur bis Stufe 4 gleichmäßig; der Shader darf nur eine niedrige Stufe lesen (`oceanPlumeLod` ≤ 4).
- Auf der gealterten Testwelt genügt irgendein Sand: Auf dem groben Testgitter (Zelle 1,37 statt 0,156 Welteinheiten) bleiben die weichen Strandsäume meist unter halber Stärke, gemessen Mac max. 143 (4 Zellen über 128), Linux max. 73 (keine), Zellen mit Sand 70 bzw. 37.

Betrifft: `CoastMaterial`, `CoastMaterial.beach`, `TerrainColorRenderer`, `WaterRender.beachSupplyReachCells`, `WaterRender.oceanPlumeLod`, `CoastMaterialTests`
