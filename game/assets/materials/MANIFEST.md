# Scan-Materialien (#237): Herkunft, Lizenz, Prüfsummen

Fünf gescannte PBR-Sätze, gepackt zu zwei Textur-Arrays
(`scripts/look/pack_scan_materials.py`, Ebenen-Reihenfolge = `SCAN_*` in
`game/shaders/scan_material.gdshaderinc`). Die Quelldateien liegen nicht im
Repo; wer neu packt, lädt sie von den Download-URLs und prüft die SHA-256
unten.

Lizenz aller Quellen: CC0 1.0 Universal (Public Domain Dedication).
Poly Haven: „CC0 1.0 Universal - public domain dedication, no attribution
required“ (https://polyhaven.com/license). ambientCG: „Creative Commons CC0
1.0 Universal License“ (https://ambientcg.com/license).

| Ebene | Rolle | Quelle | Asset | Seite |
| ---: | --- | --- | --- | --- |
| 0 | Fels mit Bankung (großer Maßstab) | Poly Haven | dark_rock_02 | https://polyhaven.com/a/dark_rock_02 |
| 1 | Fels zerklüftet (Detail-Maßstab) | ambientCG | Rock030 | https://ambientcg.com/a/Rock030 |
| 2 | Schutt | ambientCG | Rocks006 | https://ambientcg.com/a/Rocks006 |
| 3 | Kies (Flussbank) | Poly Haven | ganges_river_pebbles | https://polyhaven.com/a/ganges_river_pebbles |
| 4 | Sand (Strand) | Poly Haven | aerial_beach_02 | https://polyhaven.com/a/aerial_beach_02 |

Download: Poly Haven 1K-PNG je Karte unter
`https://dl.polyhaven.org/file/ph-assets/Textures/png/1k/<asset>/<asset>_<karte>_1k.png`
(`diff`, `nor_gl`, `rough`, `disp`); ambientCG als ZIP
`https://ambientcg.com/get?file=<Asset>_1K-PNG.zip` (`Color`, `NormalGL`,
`Roughness`, `Displacement`).

## Gepackte Dateien (im Repo)

| Datei | Inhalt | SHA-256 |
| --- | --- | --- |
| `scan_albedo.png` | RGB Albedo (sRGB, Helligkeit normiert), A Höhe | `7480a8f98be30e8b74d05743842f912aadbabbfae16e754f375c484c4bfc3251` |
| `scan_normal.png` | RG Normale (OpenGL), B Rauheit | `7ba45a4da700a1a42906c4159e8714ea9a40e872c03241855bb74c2e5080ceff` |

## Quelldateien

| Datei | SHA-256 |
| --- | --- |
| `dark_rock_02_diff_1k.png` | `4249c88b9d6855860322a1c5a2589f2c456439b9191a226858fc351be9d4d669` |
| `dark_rock_02_nor_gl_1k.png` | `9da27da9e2ac660a329ee98bd8ca541ef9b39333d830539efa382e6dbe3f09d0` |
| `dark_rock_02_rough_1k.png` | `e996a257da3dc0419c9c18d38d4a26a0d93bbaef2253778d67cae4e136080660` |
| `dark_rock_02_disp_1k.png` | `11521ad6832842f183c90c22741a5a71cd938c4edafa8f145e513fb10ade0980` |
| `Rock030_1K-PNG_Color.png` | `b223d2e16e368a44a45dbd728b0420f82937cda1405d370ebbe5484755f9441e` |
| `Rock030_1K-PNG_NormalGL.png` | `99aa9436f1672e5615bc79a121ebfb86f61d40d8d14b27780543dfa7937ddf8d` |
| `Rock030_1K-PNG_Roughness.png` | `4b68b1731f312bb0c292361f0a69cc4322ae140433ec2b9ebcf91ca7184bf737` |
| `Rock030_1K-PNG_Displacement.png` | `53210c4182b8b20b35a9fde53fd368309af72e1a8bb155215fbf3a814373cec2` |
| `Rocks006_1K-PNG_Color.png` | `d965e97d32bc45769abf65c3587937de4ae4021191b3df721d1d2bf351868c96` |
| `Rocks006_1K-PNG_NormalGL.png` | `e7d540b2df2213cce9a9f603577078e139590e2b97b8bb94fd1470ed698b2db5` |
| `Rocks006_1K-PNG_Roughness.png` | `50b4d37b10e774e0188b423072aed805734e9b89212498e0ac05d0d74956e292` |
| `Rocks006_1K-PNG_Displacement.png` | `f1e0ea2b66cf5425d98386c1391125e12f3d891f21ce6867e344b1588f7e7d40` |
| `ganges_river_pebbles_diff_1k.png` | `9d265db6d12000cc57ae6b6f9e5bbdc4b8e892a4f2c1b094561cdc7b3c49797e` |
| `ganges_river_pebbles_nor_gl_1k.png` | `7faee6864c894826bfe9c5668e5712600f95b44d16f5c69a1b7c46eeeff20c1c` |
| `ganges_river_pebbles_rough_1k.png` | `e507431447671c460f3f484e84efb0163db522cc040566d195ddd613aba08c3f` |
| `ganges_river_pebbles_disp_1k.png` | `b45255ae53b2946b9f3e18ba3d1295179f3bed37776007bca2569eb5c4d9f5cb` |
| `aerial_beach_02_diff_1k.png` | `8a30e238dde67cee2d98b83f9d9faafd6459f0a7f14563520a153b247a19d4d8` |
| `aerial_beach_02_nor_gl_1k.png` | `0f0c3ab8cd848feffe0fa973f1205c11598ac855e8c8e38c1a33cf35485331dd` |
| `aerial_beach_02_rough_1k.png` | `38f0d0507934678cac6d71509bcf149a590e7429a3be74e80468ea10e306e295` |
| `aerial_beach_02_disp_1k.png` | `47c41fc52ad5c81405faa41eb678f1b4c93ae3dd331d0aef72d98985385e6710` |
