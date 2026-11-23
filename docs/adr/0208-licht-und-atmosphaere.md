# Licht und Atmosphäre: eine Quelle, feste Welt-Sonne, abgenommene Werte

`Lighting.gd` ist die eine Quelle für Sonne, Himmel, Umgebungslicht, Tonemapping, Nebel und Wolkenschatten der normalen Darstellung (#151), übernommen aus dem abgenommenen Hebel `light` der Flusstal-Studie (#116, `docs/graphics-quality.md`). `Main.gd` und die Studie lesen beide nur hier (Wächter `game/tests/lighting.gd`, Marke `LIGHTING_OK`). Rein visuell: nichts berührt Sim-Felder oder die Wasser-Kalibrierung; die Wasser-Optik kommt weiter über die Brücke aus `SimRender.CalibrationRegistry`, der Himmel ändert nur, was das Wasser spiegelt.

Feste Welt-Sonne (entschieden 2026-10-08): eine Richtung, die aus allen Kamerarichtungen trägt; die Schatten wandern beim Drehen nicht mit. Azimut in der Kamera-Konvention von `Main._update_camera` (Yaw = Azimut der Kameraposition um das Ziel; Yaw = Azimut heißt Sonne im Rücken, Yaw = Azimut ± 180° Gegenlicht). −50° hält die Startkamera (Yaw 0,7) im Seitenlicht wie in der Studie.

Sonnenhöhe 30° (Look-Iterationen 9/10). #151 hatte 38° aus einem Vergleich von 28°, 38° und 48° (`docs/graphics-quality.md` § Licht). Die tiefere, warme Sonne legt lange Schatten in Täler und hinter Grate und modelliert das Relief auch in der Totalen (Referenz d). Die Schwäche von 28° in #151, schwarze Flanken im Gegenlicht, fängt heute das kühlere, offenere Himmelslicht ab; die Energie gleicht den flacheren Einfall auf Ebenen aus.

Himmel: Die Horizontfarbe ist zugleich die Farbe der Luftperspektive, damit die Ferne ohne Kante in den Himmel übergeht. Look-Iteration 10: tiefes Blau oben, Horizont hell und klar. Ein beiger Horizont wurde verworfen: das Wasser spiegelt bei tiefer Sonne vor allem den Horizont und wurde milchig. Die Wärme der Ferne kommt stattdessen aus der Sonnenstreuung des Dunsts (`FOG_SUN_SCATTER`).

Umgebungslicht: Himmelslicht allein färbt Schattenseiten blau (Fels las sich in der Studie als Schnee), daher ein Drittel neutrales Licht dagegen. Look-Iteration 10: Himmelsanteil 0,65 → 0,80, neutral statt warm, damit warme Sonnenseiten gegen blau-offene Schatten stehen. Energie 0,48 (knapp unter #151 mit 0,5): Iteration 9 mit 0,42 ließ lange Schatten fast schwarz zulaufen, ein Zwischenstand mit 0,55–0,62 machte das Bild flau und milchig (verworfen, A 4 B 5). Der neutrale Anteil bleibt, sonst liest sich Fels im Schatten wieder als Schnee.

Tonemapping (Iterationen 9/10): AgX entsättigt und verflacht; mehr AgX-Kontrast und Sättigung nehmen den Grauschleier, ohne Schnee auszubrennen. Das Wiesengrün im Terrain-Shader ist dafür etwas blauärmer (satter) gestellt.

Luftperspektive: Nebeldichte 0,0016 → 0,0011, damit die Übersicht nicht milchig wird; die Ferne staffelt trotzdem, zur Sonne hin warm gestreut (`FOG_SUN_SCATTER` 0,12 → 0,40). Dichterer Dunst (0,0024) machte die Totale flau und verlor im Urteil. Der Himmel nimmt nur einen Teil des Dunsts an (`FOG_SKY_AFFECT`), sonst überdeckt die Nebelfarbe den Blauverlauf über dem Horizont (Iteration 9).

Wolkenschatten: Alle Materialien (Terrain, Ozean, Bänder, Korridor, Wolkenkörper) bekommen dieselben Werte, sonst hätte der Schatten am Ufer eine Kante oder läge neben seiner Wolke. Unter der Wolkenbasis läuft der Schatten über `CLOUD_BASE_FADE` weich aus, statt hart abzuschneiden; Gipfel, die die Basis durchstoßen, trügen sonst eine Helligkeitsstufe als Höhenlinie. Die Blende ist breiter als die Körnung der Deckung und schmaler als der Ebenen-Abstand `CLOUD_LAYER_STEP` der Wolkenkörper.

Qualitätsstufen, gemessen im maximierten Fenster (`docs/graphics-quality.md` § Licht): `performance` spart Schatten-Auflösung, Kaskaden und die Wolkenschatten; `balanced` und `quality` tragen das abgenommene Bild der Studie.

Betrifft: `Lighting.gd` (`SUN_AZIMUTH_DEG`, `SUN_ELEVATION_DEG`, `SKY_TOP`, `SKY_HORIZON`, `AMBIENT_ENERGY`, `AMBIENT_SKY_CONTRIBUTION`, `TONEMAP_*`, `FOG_DENSITY`, `FOG_SUN_SCATTER`, `FOG_SKY_AFFECT`, `CLOUD_BASE_FADE`, `QUALITY`, `apply_clouds`)
