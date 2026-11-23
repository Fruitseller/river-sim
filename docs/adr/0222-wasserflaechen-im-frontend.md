# Wasserflächen im Frontend: Bänder auf der sichtbaren Fläche, eine Seite malt

Die Band-Geometrie sampelt ihre Höhen von der sichtbaren Oberfläche des Render-Gitters (`SimNode.setRenderGrid`). Auf Sim-Höhen versank sie an Steilstrecken im gröberen Mesh und ragte als blaue Zacken heraus.

Über einem Raster-See blendet das Band per Pixel aus, mit derselben See-Maske, mit der `terrain.gdshader` den See malt; dafür bekommt es dieselben Felder (Höhe, Seespiegel, Wasserfeld) mit denselben Blenden gespiegelt (`FieldTexture.mirror_to`). Beide Band-Generationen der Zeitraffer-Blende brauchen sie. So malt immer nur eine Seite.

Vertex-Kanäle der Bänder (aus `SimNode.packFrame`, Gegenstück `water.gdshader`): `UV2.x` = Typ (Fluss/Delta/Altarm, Issue #34), der Shader färbt danach und schaltet für Altarme die Strömung ab; `CUSTOM0` = Lauf-Größen (Riffel, Weißwasser, Gefälle, Breite; Look-Iteration 14, `RiverRibbonRenderer.flowAttributes`); `CUSTOM1` = Korridor-Profil je Vertex (Look E, #239, `RibbonMesh.profile`).

Meer: Die Ozeanplatte ist `cam.far · 3` groß, ihr Rand liegt selbst bei maximalem Zoom und Pan hinter `cam.far`. Sichtbar bleibt nur die Wasseroberfläche, keine quadratische Modellplatte.

Betrifft: `Main._setup_scene` (Bänder, Ozean), `Main._upload_ribbon_mesh`, `Main.FieldTexture.mirror_to`, `water.gdshader`, `RiverRibbonRenderer`
