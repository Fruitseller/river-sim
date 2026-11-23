# Offenes Meer: Rausch-Wellen und Farbe aus der Schelftiefe

Übernommen aus dem abgenommenen Hebel `frame` der Flusstal-Studie (#121, Issue #155). Vorher bauten drei Sinuswellen und ein Sinus-Schimmer die Normalen; aus der Übersicht wurde daraus ein regelmäßiges Streifenmuster bis zum Horizont, und die Insel las sich als Modell auf einem Tisch. Jetzt: Rausch-Wellen, die mit ihrer Pixelgröße ausblenden, und Farbe aus der echten Wassertiefe über dem Sim-Schelf mit gebrochenem Brandungssaum. Fresnel, Himmels-Spiegelung und Glanz bleiben die gemeinsame Wasser-Optik. Nur `ocean.gdshader` liest die `ocean*`-Werte.

Jede Rausch-Oktave blendet über `Pixelgröße · Frequenz` (Rausch-Zellen je Pixel, Fenster `oceanWaveFadeLo/Hi` 0,2…0,8) aus; ohne dieses Fenster flimmern feine Oktaven in der Ferne und bilden Moiré. Die Fluss-Kräuselung teilt Oktaven-Folge und Pixel-Ausblendung mit dem Ozean.

Betrifft: `WaterRender.oceanDepthSpan`, `WaterRender.oceanWaveFrequency`, `WaterRender.oceanWaveFadeLo`, `WaterRender.oceanWaveFadeHi`, `WaterRender.oceanSurfDepth`, `game/shaders/ocean.gdshader`
