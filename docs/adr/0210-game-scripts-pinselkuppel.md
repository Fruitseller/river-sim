# Pinselkuppel zeigt das echte Pinselgewicht auf der sichtbaren Fläche

Der Pinsel ist eine Gitterkuppel statt eines flachen Rings (#174, Paket E). Die Kuppel liegt auf der sichtbaren Fläche (Sim-Höhe plus Verschiebung #153 plus Kronendach) und ist um das Gewichtsprofil des Pinsels angehoben, w(d) = (1 − d²)^p mit d = Abstand zum Zentrum / Radius. p = 2 ist das Gewicht aller Werkzeuge (`Terrain.forEachBrushCell`), die Spitzhacke quadriert es (p = 4, `Terrain.pickaxe`, Feld `falloff_power`). Wächter: `ToolContractTests.testBrushDomeFollowsTheBrushFalloff` (Profil gegen die gemessene Wirkung von Anheben und Spitzhacke).

96 Segmente je Breitenkreis statt 48: der Rand liegt auf der Fläche, und eine Sehne über 2πr/48 tauchte bei r = 10 alle ~8 Zellen ins Gelände.

Die Linien sind Bänder in logischen Bildschirm-Pixeln (`brush_dome.gdshaderinc`). `VIEWPORT_SIZE` ist im 3D-Shader die skalierte Renderauflösung (`RenderScale`); `px_scale` enthält deshalb den Skalierfaktor, damit die Linien gleich breit bleiben.

Betrifft: `Main.BRUSH_FALLOFF_POWER`, `Main.BRUSH_DOME_SEGMENTS`, `Main.brush_weight`, `Main.brush_dome`, `shaders/brush_dome.gdshaderinc`
