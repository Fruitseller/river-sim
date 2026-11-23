# Talnebel: Lagen über dem tiefsten Gelände, unbeleuchtet, am Kameraabstand gekoppelt

Talnebel (#237) soll nur in Tälern und flach über dem Meer liegen, in Sonnenfarbe. Kein gleichmäßiger Schleier: die Look-Iterationen 9 und 17 verloren mit dichterem bzw. tieferem Dunst gegen „milchig“ (Kontrastverlust überall, auch in der Nahsicht; `docs/look-hillclimb-log.md`).

Bauform: wenige transparente Lagen über der Insel. Jede Lage liegt eine feste Schichtdicke über dem TIEFSTEN Gelände der Umgebung (5×5-Minimum der Höhe über ~1,4 km bzw. ±22 Zellen, im Vertex-Shader aus `height_tex`), über dem Meer knapp über dem Spiegel. Sichtbar wird sie nur, wo das Gelände unter ihr liegt, und umso dichter, je tiefer es darunter liegt; Hänge und Grate stehen darüber. Die erste Fassung legte die Lage auf das MITTEL der Umgebung; auf breiten Talböden lag sie dann im Boden, Nebel gab es nur als Saum an den Talflanken. Die Dicke der Luftschicht rechnet das Fragment aus derselben Höhe, die Kante ist damit weich ohne Tiefenpuffer; Rauschen bricht die Lage in Schwaden. Außerhalb der Karte gilt offenes Meer (wie im Ozean), nicht der Randtexel der Höhenkarte.

Unbeleuchtet: beleuchtet las sich die Lage im Talschatten als brauner Schmutzfilm (erste Fassung); Dunst streut das Sonnenlicht auch im Schatten.

Stärke koppelt am Kameraabstand (Atmosphere.gd): in der Nahsicht fast null, damit `nah` keinen Kontrast verliert; in der Totalen staffelt der Nebel die Tiefe (hinter dem Fokuspunkt dichter, davor dünner, `fog_ref_dist`). Nahe der Kamera aus. Die Lagen-Ebene ist 1,6 × world_size groß; vor ihrem Rand läuft der Meeresdunst aus, statt als Rechteck zu enden (Kopplung an Atmosphere.gd, s. #263).

Betrifft: `game/shaders/valley_fog.gdshader`, `game/scripts/Atmosphere.gd` (`make_valley_fog`)
