# Flussband: Vertex-Vertrag und Querprofil als Wasser im Gelände

Die Band-Geometrie (Issues #31/#34) malt Mäander-Hauptläufe, Delta-Distributäre und Altarme. Sie kommt aus `RiverRibbonRenderer` über den Frame (früher `SimNode.buildRiverRibbons`, seit #214 nur noch Frame-Schlüssel `ribbon_*`). Vertex-Vertrag:
- COLOR.rg Fließrichtung (kodiert dir·0,5 + 0,5; genau 0 = Stillwasser), COLOR.b Strahler-Rang/6, COLOR.a Deckkraft.
- UV.x Querlage 0…1, UV.y Bogenlänge (Welt).
- UV2.x Typ (0 Fluss · 0,5 Delta-Arm · 1 Altarm) == `WaterRender.ribbonKind*`; UV2.y signierte Bogenstärke −1…+1 (`MeanderState.bendStrength`, #174 C2): + = Linksbogen, Prallhang bei UV.x = 0; 0 = symmetrisch.
- CUSTOM0 Lauf-Größen (Look-Iteration 14, `RiverRibbonRenderer.flowAttributes`): x Riffel (0 Kolk … 1 Riffel), y Weißwasser, z Gefälle, w Breite (Welt). Damit wechselt der Fluss ENTLANG des Laufs statt als einfarbige Folie zu liegen.
- CUSTOM1 Korridor (Look E, #239, `RibbonMesh.profile`): x Anteil 0…1, y Deckel-Höhe (ohne Korridor die eigene Vertex-Höhe, dann bleibt die Tiefe unverschoben), z Wasser-Halbbreite (Welt), w reserviert.

Querprofil (Befund #174 „hässlich“): kein halbtransparenter Schlauch mehr, der über die äußeren 35 % ins Gras ausfedert (las sich als aufgemalter Dunst), sondern Bandkante → nasses Ufer (`water_ribbon_bank_*`) → Wasserlinie (`water_ribbon_waterline`, um Rauschen versetzt, damit sie nicht als Lineal parallel zur Mittellinie läuft, nach Pixelgröße geglättet) → Flachwasser über dem Bett → tiefe Rinne.

Entscheidungen im Profil:
- Typ-Gewichte aus UV2.x als weiche Fenster statt if-Kaskade: die Werte werden über das Band interpoliert, an Bandgrenzen gibt es keine harte Kante.
- Die Deckkraft des Vertex-Vertrags (Taper, Abfluss-Rampe, Übergaben, `fadeUphill` #187) wirkt als SCHMALERES Band, nicht als Transparenz; ein halbdurchsichtiges Band mit scharfer Wasserlinie las sich als Glasrohr. Seit dem Review zu #174 schrumpft der GANZE Querschnitt (Ufer und Wasser); vorher blieb das nasse Ufer voll breit und lag bei ausgeblendeten Bändern als leere dunkle Rinne im Gelände. Das Fenster ist eine Optik-Zahl dieses Shaders.
- Mündung ins Meer (#174): ab der Wasserlinie blendet das Band über wenige Zellen in Meeresfarbe und Deckkraft 0 aus (im Meer linear mit `presence`, an Land schrumpft die Breite), statt mit gerader Kante über dem Schelf abzubrechen; der Ufersaum entfällt im Meer.
- Bandbreite je Einheit UV.x kommt je Stützpunkt aus dem Band-Bau (`RibbonMesh.flows.w`, Review Neon Nr. 8). Vorher entstand sie je Pixel als Jacobi-Spalte ∂Welt/∂UV.x aus Bildschirm-Ableitungen: je Dreieck konstant und an Dreieckskanten verrauscht.
- Mit Korridor endet das Wasser an DESSEN Uferlinie (`CorridorProfile.section`, Uniforms `water_corridor_shore*`: Anteil der Wasser-Halbbreite, im Bogen am Prallhang außen, am Gleithang innen). Vorher reichte es bis 92 % der Bandbreite bei einer Korridor-Uferlinie von 65 %: Wasserfilm über der trockenen Böschung, „Fluss im Fluss“ (Gremium, Befund 1).
- Tiefe ∝ Strahler-Rang, aber fast gleichmäßig tief bis an die Wasserlinie; ein durchlaufender Tiefenverlauf (erst recht ein heller Flachwasser-Saum) las sich als Rohr mit dunkler Mittellinie. Die Asymmetrie Prallhang/Gleithang trägt das Bogenprofil (`WaterRender.ribbonOutward`). Delta-Arme sind Flachwasser, Altarme trübes grünliches Stillwasser, Delta als hellere Sedimentfahne.
- Kiesbank am Gleithang nur als schmale, unterbrochene Kante an der Wasserlinie; über die halbe Bandbreite lag sie als milchiger Schleier auf dem Fluss.

Betrifft: `game/shaders/water.gdshader`, `SimRender.RiverRibbonRenderer`, `RibbonMesh.flows`, `RibbonMesh.profile`, `CorridorProfile`, `WaterRender.ribbonKind*`, `WaterRender.ribbonOutward`
