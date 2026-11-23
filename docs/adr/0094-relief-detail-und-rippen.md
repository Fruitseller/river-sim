# Feines Rinnen-Detail, Felsrippen und Felsbänke

Das Relief wird auf zwei Wegen verfeinert: ein feines runevision-Detail je Pixel im Terrain-Shader (nur Normale und Schattierung) und gebackene Scharen im Back-Pass (Felsrippen, Felsbänke), die in jeder Entfernung tragen und je Bild nichts kosten.

- Die Zahlen des feinen Details (`detailScale`, `detailShade`, `detailNormal`) standen bis zum Review zu #174 als Literal-Defaults im Shader, `Main.gd` setzte sie nie; seitdem reisen sie über das Register. Die Stärke `detail_strength` fährt `Main.gd` mit dem Geländealter (`terrain_detail_strength`) und behält ihren Jahr-0-Default (RenderContractTests).
- Das Detail rechnet je Pixel seit Look-Iteration 7 nur noch zwei statt drei Oktaven (Bildzeit). Abdunklung (0,20 → 0,26) und Normalen-Anteil (1,0 → 1,35) gleichen die fehlende feinste Oktave aus (Bewerter: „kräftigere Reliefschattierung" am Stand mit drei Oktaven).
- Felsrippen (Look-Iteration 7): zweite, feinere Rinnenschar im Back-Pass mit derselben runevision-Funktion (`ribScale` 0,011 ≈ 8 Sim-Zellen ≈ 120 m). Befund des blinden Bewerters vorher: „glatte Knetlandschaft ohne Felsstruktur". Das feine Pixel-Detail blendet mit der Kameradistanz aus und fehlt in Tal- und Diorama-Ansicht; die gebackene Schar trägt in jede Entfernung.
- Felsbänke: grobe Schichtstufen (`benchSpacing` 0,8 ≈ 80 m) im Back-Pass, nur auf Steilflanken. Je Pixel im Terrain-Shader gerechnet kostete dasselbe gemessen Bildzeit (Zeitraffer-A/B, Look-Iteration 7).

Betrifft: `ReliefRender.detailScale`, `ReliefRender.detailShade`, `ReliefRender.detailNormal`, `ReliefRender.ribScale`, `ReliefRender.benchSpacing`, `Main.terrain_detail_strength`, `game/shaders/relief_bake.gdshader`, `game/shaders/terrain.gdshader`
