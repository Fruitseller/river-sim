# Terrain-Gitter: texelzentrierte Welt→Textur-Abbildung und Normalen-Vorzeichen

Texturkoordinaten werden aus der Weltposition abgeleitet, nicht aus Mesh-UVs, damit sie mit der Zellindizierung des Sim-Kerns und damit mit Flüssen und Wasser deckungsgleich sind. Zelle k liegt bei −world_size/2 + k·world_size/(grid_n − 1) (Mesh, Main.gd) und ist Texel k mit Mitte (k + ½)/grid_n. Bis zum Review zu #174 stand hier (x + world_size/2)/world_size; das traf die Mitte, wich zum Rand hin aber um bis zu einen halben Texel ab (am Rand ~8 m). Alle Shader, die Sim-Texturen in Weltkoordinaten lesen (Ozean, Band, Wolkenkörper, Nebel, Korridor), müssen dieselbe Abbildung benutzen.

Die Vertex-Normale hat dasselbe Vorzeichen wie die Pixel-Normale `n_ws` (hU liegt bei +z): `NORMAL = normalize(vec3(-(hR - hL)·hscale, 2·sw, -(hU - hD)·hscale))`. Licht rechnet die Pixel-Normale, aber Godots Schatten-Normal-Bias liest die Vertex-Normale; mit `-(hD - hU)` zeigte sie an jedem ±z-Hang falsch herum (Review zu #174).

Betrifft: `game/shaders/terrain.gdshader` (`world_uv`, vertex), `game/shaders/ocean.gdshader` (`grid_uv`), `game/shaders/water.gdshader` (`grid_uv`), `game/shaders/cloud_body.gdshader`
