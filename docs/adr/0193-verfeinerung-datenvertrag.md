# Gelände-Verfeinerung: Texturen, Ausgabevertrag und Push-Constants

Die Compute-Shader unter `game/shaders/amplify/` werden zur Laufzeit übersetzt; der Ordner trägt `.gdignore` (kein Godot-Import). TerrainAmplifier.gd setzt `common.glsl` vor jeden Pass und das `FORMAT`-Makro vor `mip.glsl`.

Zustand je Texel:
- Höhe (RG32F): r Höhe in Welteinheiten (Sim-Höhe × Überhöhung), g Höhe einen Schritt davor (für die Abfluss-Anteile, s. [ADR 0194](0194-verfeinerung-nacherosion.md)).
- Fluss (RGBA16F): r Abfluss DURCH das Texel (Einzugsfläche oberhalb in Texeln der feinsten Stufe, ein Durchfluss), g Kehrwert der Abfluss-Normierung zu Höhe.g, b Sediment in Transport, a Gefälle der Sim-Fläche (fest je Auftrag). Abfluss und Sediment sind auf 60000 gedeckelt (Halb-Float).
- Begleitfeld (RGBA16F): r abgetragen, g abgelagert, b Schutt (thermisch erhalten), a Härte-Rauschen aus der Position.
- Bindung (`dst_offset`, RG16F): r Abweichung, g Maske.

Ausgabe (`encode.glsl`):
- `dst_relief` (RGBA16F) im Vertrag der Backtextur von `relief_bake.gdshader`: R Höhenzuschlag, GB Steigungszuschlag dh/duv (in Sim-Höhe je UV wie `coarse_slope` im Terrain-Shader), A Rinne (−) / Rippe (+), je mit Versatz 0,5. Terrain-Shader, Pinselkuppel, Raycast und Kameraziel lesen sie unverändert.
- `dst_maps` / `amplify_tex` (RGBA8, mit Mip-Kette): R Abtrag, G Ablagerung, B Abfluss, A Schutt, je 0…1; an Wasser, Bändern und Küstensaum null. Strang C (#237) liest dieselbe Textur als Material-Eingang.
- Mip-Stufen als 2×2-Mittel: die Texelmitte der Zielstufe liegt auf der Ecke von 2×2 Quelltexeln, ein linearer Abgriff ist ihr Mittel.

Push-Constant-Belegung (bis die Felder benannt sind, s. #265):
- `bind`: size = (Größe xy, Überhöhung, Meeresspiegel in Sim-Höhe); bound = (Schranke unten, oben in Welteinheiten, Stärke, Tümpeltiefe in Sim-Höhe); steep = (Stärke an Steilwänden, Gefälle von, bis, Wellenlänge der Gebiete in Sim-Zellen); region = (Stärke in ruhigen Gebieten als Anteil, Sim-Gitter n).
- `step`: size = (Größe xy, Texelweite in Welteinheiten, Eigenfläche); ero = (Stärke, Abfluss-Exponent, Verteil-Exponent, Härte-Hub); thermal = (Rate, Schüttwinkel tan, frei, Abfluss-Mittelung); ero2.x = Schüttwinkel als Vielfaches des Sim-Gefälles; dep = (Transportkraft, Hangkriechen, Rate, Deckel je Schritt als Anteil der Texelweite).
- `ingest`: size = (Zielgröße xy, Sim-Gitter n, Überhöhung); flow = (Eigenfläche je Texel, Sim-Zellweite in Welteinheiten); hard_freq/hard_weight = Härte-Rauschen, Frequenz (1/Zellen) und Gewicht (Summe 1) je Oktave. `refine` ebenso, size.z = Texel je Sim-Zelle.
- `encode`: size = (Größe xy, Überhöhung, Tiefe für volle Rinne/Rippe); code = (Höhen-Code, Steigungs-Code); maps = (Abtrag-, Ablagerungs-, Schutt-Maß, Abfluss-Sättigung).
- `mask`: size = (Sim-Gitter n, Meeresspiegel); `mean`: size = (n, Texel je Zelle, Überhöhung); `mean_solve`: size = (n, σ in Zellen, 0 = streng).

Betrifft: `game/shaders/amplify/*.glsl`, `game/shaders/amplify.gdshaderinc`, `game/scripts/TerrainAmplifier.gd`, `game/shaders/relief_bake.gdshader`
