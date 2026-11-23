# Schwellen der Wasser-Schutzmaske

`SimRender.WaterProtectMask` (Issue #154) sperrt Kronendach und Render-Verschiebung an Wasser. „Sichtbar“ heißt dort dasselbe wie im Shader: die Fluss- und See-Schwellen SIND die unteren Smoothstep-Kanten von `riverMask` und `lake_gate_at` (`riverMaskLo`, `lakeGateLo`), keine eigene Kalibrierung. Gepinnt in `WaterRenderTests`.

Band-Schwelle 0.01 statt 0: `bandCoverage` ist ein Maximum über Alpha-Verläufe, und die auslaufenden Enden (Alpha → 0) sind unsichtbar. 0.01 ≈ 3/255 liegt unter jeder darstellbaren Deckkraft eines 8-Bit-Ziels.

Saum 2 Zellen (Chebyshev), weil (a) #154 „etwa zwei Zellen“ verlangt (Ufer dürfen nicht über ein Band wachsen) und (b) die Rohbytes des `RS_WATER_GPU`-Pfads ungeblurt sind: der See-Kanal wird CPU-seitig zweimal geblurt (`blurMax`, eine Zelle je Pass), der Saum deckt genau das. Der Shader (`protect.gdshaderinc`) legt keinen zweiten Saum darüber.

Betrifft: `WaterRender.protectRiverThreshold`, `WaterRender.protectLakeThreshold`, `WaterRender.protectBandThreshold`, `WaterRender.protectSeamCells`, `SimRender.WaterProtectMask`, `game/shaders/protect.gdshaderinc`
