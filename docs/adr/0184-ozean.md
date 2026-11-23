# Offenes Meer: Tiefenfarbe über dem Schelf, glatte Schelf-Abfrage, Brandung an der Küstenlinie

Das Meer (#155, aus dem Studien-Hebel `frame`) färbt nach der Wassertiefe über dem Sim-Schelf, mit Brandungssaum und Rausch-Wellen ohne Sinus-Streifen, und bleibt opak (sonst scheint bei flacher Kamera die Unterseite des Heightfields durch). Begründung der Werte: SimCore `WaterRender.ocean*`. Abseits der Küste und der Mündungen ist die Tiefe die einzige Quelle der Wasserfarbe; außerhalb des Sim-Quadrats ist das Meer tief.

- Schelf-Farbe und -Neigung über einen kubischen B-Spline aus vier bilinearen Abgriffen (Sigg/Hadwiger, GPU Gems 2, Kap. 20), glättet über ±1,5 Zellen: bilinear traten die Zellstufen einer blockigen Küstenlinie als Treppen in der Tiefenfarbe hervor (Befund #174). Die Küstenlinie selbst (discard) bleibt bilinear wie im Terrain.
- Brandung: Saum an der scharfen Küstenlinie (Nr. 8), zwei vorgelagerte Brecher folgen dem Schelf mit ungleichmäßiger Breite und Lücken.
- Sedimentfahne (#174 C): fertige Trübungsdichte je Meereszelle aus SimRender.SedimentPlume (Float32 mit Mip-Kette, Main.gd `_update_plume`); der Shader liest sie nur, leicht weichgezeichnet über die Mip-Stufe. Ohne Bindung schwarz = keine Fahne.

Betrifft: `game/shaders/ocean.gdshader` (`bspline_weights`, `sediment_plume`, Brandung), `WaterRender.ocean*`, `SimRender.SedimentPlume`
