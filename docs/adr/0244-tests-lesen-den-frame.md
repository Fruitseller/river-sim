# Godot-Tests lesen Render-Puffer nur aus dem Frame

Seit #214 hat die Brücke keine Render-Einzelschritte mehr; der Frame (`SimNode.renderFrame`) ist der einzige Weg, derselbe, den `Main.gd` fährt. Die Godot-Tests lesen Wasser, Bänder, Masken, Seespiegel und Bodenbedeckung deshalb aus einem Frame (`FRAME_SETTLED`, ungedrosselt, wie Main am Strich- oder Sprung-Ende). Folgen:

- Ohne Weltänderung zwischen Mains letztem Upload und einem Probe-Frame sind die Puffer bit-gleich zu dem, was Main hochgeladen hat.
- Wasser und Schutzmaske bzw. Wasser und Bänder kommen aus demselben Frame; die Maske sieht das Wasserfeld ihres Frames, das Wasserfeld die `bandChannelFlags` desselben Baus.
- Ohne Knoten-Bewegung über der Rebuild-Schwelle baut der Frame die Bänder nicht neu. Das Band-Mesh darf daher älter sein als der Seespiegel aus dem jüngsten Frame; bis zur Schwelle ist die Geometrie standgleich. Ein Frame ohne `ribbons` hat nicht neu gebaut und sagt nichts über Bandtypen.
- Ob der zweite Frame ohne Bewegung neu baut, prüft kein Godot-Test (ein laufender Übergang darf weiterbauen). Die Delta-0-Seite und der Determinismus-Nachweis (zweiter Bau gleich erstem) liegen in `SimCoreTests/RenderStateTests` direkt am `RiverRibbonRenderer`, weil ein Skript keinen zweiten Bau mehr erzwingen kann.

Sichtbarkeit von Wasser (pickaxe_repro): seit #34 kann Wasser in einer Kerbe aus drei Quellen kommen, geprüft wird die Vereinigung: Fluss-Kanal (R) und See-Kanal (G) des Rasterfelds sowie die Band-Geometrie. Eine tief gekaperte Kerbe füllt sich typischerweise über die See-Schwelle (rawWet 0,03); dann malt der See-Kanal, nicht der Fluss-Kanal (der hält sich an `hf − h ≤ 0,01`). Vor #34 malte der Mäander-Stempel den Lauf zusätzlich in R; nur R zu prüfen hieße, den Stempel zu testen statt der Sichtbarkeit.

Betrifft: `game/tests/canopy.gd`, `game/tests/graphics_study.gd`, `game/tests/pickaxe_repro.gd`, `game/tests/river_ribbons.gd`, `game/tests/water_geometry.gd`, `SimRender.RenderState.frame`
