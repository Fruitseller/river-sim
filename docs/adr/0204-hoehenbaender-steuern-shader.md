# Vegetationsgrenzen und Wolkenbasis folgen den Höhenbändern der Welt

Die Vegetationsgrenzen sind Perzentile der aktuellen Landhöhen (Höhenbänder, Issue #4) und wandern mit der alternden Landschaft. Der Shader darf dafür keine eigenen absoluten Höhenwerte halten; Main reicht die Bänder mit jedem Overlay-Frame durch.

Dasselbe gilt für die Wolkenkörper über dem Kamm (#174 D, `cloud_body.gdshader`): Die Wolkenbasis liegt knapp über dem oberen Felsband der Welt (`HeightBands.rockFull`, über `Lighting.place_clouds`), sichtbar sind die Körper nur über Gelände zwischen `rockStart` und `rockFull`, dort steht der Kamm. Gemessen auf den Matrix-Welten (#174 D, `testMaterialCoverageDiagnostic`): `rockStart` 0,50, `rockFull` 0,57–0,59, Gipfel 0,58–0,66 Sim-Höhe, also Basis bei Welt-Y ≈ 14,5; die höchsten Gipfel stechen durch. Bis zum ersten Höhenband gilt `CLOUD_RIDGE_FALLBACK` (dieselben Werte in Welt-Y). Schatten und Körper lesen dieselbe Basis.

Betrifft: `Main._upload_overlays`, `Lighting.place_clouds`, `Lighting.CLOUD_BASE_ABOVE_RIDGE`, `Lighting.CLOUD_RIDGE_FALLBACK`, `HeightBands`
