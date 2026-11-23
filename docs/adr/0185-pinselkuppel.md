# Pinselkuppel: Bänder in Bildschirm-Pixeln mit dunklem Halo, zwei Pässe

Die Pinselkuppel (#174, Paket E, Abnahme-Befund „zu schwer zu erkennen“) war vorher aus 1-px-GL-Linien in blassem Cyan unter Nebel und Tonemapper; auf Sand, Schnee und Wolken und aus der Distanz verschwanden sie, und der Rand zerfiel an jeder Bodenwelle in Striche. Jetzt ist jedes Linienstück ein Band aus vier Ecken, das der Vertex-Shader in BILDSCHIRM-Pixeln aufspannt: die Breite hängt weder am Radius noch an der Kameradistanz. Innen die helle Vertex-Farbe, außen ein dunkler Halo; so liest es sich auf hellem wie auf dunklem Grund. Unlit und ohne Nebel. Unlit-Farben laufen weiter durch den AgX-Tonemapper (Lighting.gd), der Weiß zu Grau drückt; `CORE_GAIN` hebt den Kern wieder ins Weiß.

Das Band steht im Bild flach, das Gelände steigt bei Schrägsicht zur Kamera hin an und schnitte die untere Bandhälfte ab. Die Ecke rückt deshalb um `DEPTH_PULL` × halbe Bandbreite (in Bildhöhen) zur Kamera; die Bildposition bleibt exakt gleich (Skalierung im View-Raum).

Zwei Pässe: `brush_dome_hidden.gdshader` (ohne Tiefentest, gedämpft) läuft VOR dem sichtbaren Pass (`next_pass`), der ihn überall deckt, wo die Kuppel frei liegt; hinter einem Kamm, unter dem Meer oder wo eine Bodenwelle den Rand schneidet, bleibt sie als Schemen lesbar.

Daten je Ecke (Main.gd `brush_bands`, dort Breiten und Farben): VERTEX eigener Endpunkt relativ zur Kuppelmitte; CUSTOM0.xyz anderer Endpunkt, CUSTOM0.w ±1 dreht die Normale, damit beide Enden zur selben Seite aufspannen; UV.x Seite quer (−1…+1), UV.y Kernbreite in px; UV2.x Halo-Breite je Seite in px; COLOR Kernfarbe und Deckkraft. `px_scale` = Geräte-Pixel je logischem Pixel (Retina 2), setzt Main.gd.

Betrifft: `game/shaders/brush_dome.gdshaderinc`, `game/shaders/brush_dome.gdshader`, `game/shaders/brush_dome_hidden.gdshader`, `Main.gd` (`brush_bands`)
