# Kronendach je Pixel: Voronoi-Kronen, Kosten-Abkürzungen und geglättete Anhebung

Das Kronendach (#152, aus der Flusstal-Studie) zeichnet Wald als Voronoi-Kronen je Pixel, je Zelle eine Krone mit Zufallsversatz und -radius; ohne Einzelbäume (#236) hebt es das Dach an. WO Wald steht, sagt allein `forest_tex`. Farben, Radien und Neigungen sind Optik des Shaders, die Schwellen kommen über die Brücke (SimCore.CanopyRender). Ab etwa einer Krone je Pixel nur noch der Mittelwert, sonst flimmert es.

Form und Aussehen:
- Krone steht nur, wo die Waldmaske ihre eigene Schwelle übertrifft (am Rand dünnt der Wald kronenweise aus), gelesen an der KRONENMITTE: je Pixel schnitt die Schwelle Randkronen mitten durch (eckige Splitter). Die Schwelle streut nur zum kleineren Teil je Krone, zum größeren mit dem Bestands-Rauschen (~180 m): am Rand stehen geschlossene Gruppen statt verstreuter Einzelkronen.
- Bestände (Look-Iteration 6): zwei grobe Rauschskalen (~180 m, ~770 m) mischen Nadel- und Laubbestände unabhängig von der Höhe, setzen gelbgrüne Laubinseln und tragen in der Übersicht die Farbvariation. Die Höhe schiebt nur die Mischung (Nadelwald zur Baumgrenze). Das Bestands-Rauschen läuft je Vertex (~15 m genügt), je Pixel kostete es messbar Bildzeit; ohne Wald am Vertex neutral 0,5 statt gerauscht (spart die Aufrufe auf dem Großteil des Netzes und in jedem Schatten-Pass).
- Auch Nadelkronen als abgeflachte Kuppel statt Kegel: der Kegel teilte jede Krone in eine helle und eine fast schwarze Hälfte mit harter Kante (zackige Dreiecke in der Nahsicht).
- Dunkles Tannengrün (Referenz f); heller (Look-Iteration 6, Versuch) las sich der Wald flach und gleichförmig, der Bewerter zog die dunklen Kronenschatten vor.
- Die Maske ist je Dreieck linear, Fenster darauf hätten gerade Kanten; ein feines Rauschen (~25 m) verwackelt sie zu Buchten und blendet in der Ferne mit aus.

Kosten (gemessen, Zeitraffer-A/B):
- Das Kronendach läuft ZUERST (Look-Iteration 6); wo es voll deckt (`canopy_amount ≥ 0,9999`, `mix` trifft 1 nicht exakt, der Rest liegt unter einer 8-Bit-Stufe), entfallen Bodenmaterial und Erosionsdetail. Das hält die verdoppelte Waldfläche ohne Bildzeit-Einbuße. Die ungestörte Makro-Normale wird vorher gesichert; die Kronen neigen sich gegen sie, ohne Mikro-Rauschen (Review zu #121).
- Unter vollem Dach kein Erosionsdetail: es neigte nur noch die Makro-Normale, im Bild nicht zu sehen (Differenz unter dem Rauschen zweier Läufe), spart ~0,4 ms je Bild in der Nahsicht.
- Frühausstieg unter dem Deckungs-Fenster (dort deckt der Wald nichts, ohne Kronen ist `fw == f`); ohne ihn kostete der breite lichte Saum (seit Look-Iteration 6) Bildzeit.
- Die Kronenschleife hält nur ihr Ergebnis (Höhe, Neigung, Ton, Art); mit den Farben in der Schleife ~1 ms je Bild mehr (Registerdruck).
- Nur die 2×2 Zellen, deren Mitten das Pixel einklammern: jede andere Kronenmitte liegt ≥ 1 − 0,28 = 0,72 Zellen entfernt, kein Radius ist größer. Gegenüber 3×3 die halbe Arbeit, sonst +1 ms je Bild.
- Die Maske an der Kronenmitte folgt aus Wert und Gradient am Pixel (`f_grad`) statt aus einem Texturabgriff je Krone (~0,6 ms je Bild).

Anhebung: das Dach hebt nach der GEGLÄTTETEN Maske an (vier bilineare Abgriffe im Abstand `canopy_lift_smooth_texels` = 1,5 Texel, Mittel über etwa 4×4 Zellen). Je Sim-Zelle angehoben zog es Zeltspitzen und steile Dreieckswände hoch, schwarze Splitter in der Nahsicht. `Main._forest_lift_at` rechnet dieselbe Anhebung für Raycast, Pinselkuppel und Kameraziel nach (Wächter `tests/canopy.gd`). Unter `canopy_lift_lo` keine Abgriffe (das Minimum kann nur kleiner werden); der Vertex-Shader läuft in jedem Schatten-Pass mit.

Betrifft: `game/shaders/terrain.gdshader` (`canopy`, `crown_hash`, vertex, `canopy_full`), `SimCore.CanopyRender`, `Main._forest_lift_at`, `SimRender.ForestCanopyMask`
