# Render-Verschiebung von Rinnen und Graten: Begrenzung und Kodierung

Die gebackene Render-Verschiebung (#153) darf das Bild nicht zerreißen und keinen Talboden unter ein Flussband drücken.

- Gratschärfung (`sharpen` 2,2) wirkt nur auf den positiven Teil von „Höhe minus Ringmittel" (Ring `sharpenRadiusCells`): nur Kuppen und Grate werden angehoben, Mulden bleiben, damit sinkt kein Talboden unter ein Flussband. Auf Graten bis etwa +1 Welteinheit (≈ 100 m).
- Weicher Deckel `cap · tanh(x / cap)` mit `ridgeCap` 0,8: ohne ihn hob die Schärfung auf jungem, steilem Relief (Jahr 0) einzelne Gipfel um bis 3,6 Einheiten (Projekteigner: „viel zu spiky"); mit 0,8 bleibt es dort bei 1,0, das bei Jahr 20.000 abgenommene Bild ändert sich kaum (p99 der Anhebung 0,54 → 0,50, Maximum 1,17 → 0,89). 0,5 drückte auch die reifen Grate sichtbar (Maximum 0,71).
- Alters-Einblendung (`geometryAgeYears` 20.000, Smoothstep ab Jahr 0): Schattierung und Normalen wirken von Anfang an voll, die Vertex-Verschiebung erst mit dem Alter. Auf jungem Relief zog jede Verformung die Grate zu Sägezähnen (Projekteigner, 10. Oktober 2026). Weder kleinerer Gratdeckel noch schwächere Rinnen noch weichere Abtastung halfen, jeder der beiden Anteile allein reichte schon. Bei 20.000 Jahren steht das abgenommene Studienbild unverändert. Vorbild: das feine Shader-Detail blendet ebenso mit dem Alter ein (`Main.terrain_detail_strength`).
- Kodierung der Backtextur: Kanal = Wert × Code + 0,5, damit kein Kanal negativ wird. `heightCode` 0,2 stellt ± 2,5 Welteinheiten dar (bis Look-Iteration 7 ± 2 mit 0,25; die Felsrippen brauchen den Platz, Wächter `testHeightCodeCoversTheDisplacement`); `slopeCode` 0,015 stellt dh/duv ± 33 dar (vorher ± 25 mit 0,02, die Felsrippen steilen die Flanken zusätzlich auf).

Betrifft: `ReliefRender.sharpen`, `ReliefRender.ridgeCap`, `ReliefRender.geometryAgeYears`, `ReliefRender.heightCode`, `ReliefRender.slopeCode`, `game/shaders/relief_bake.gdshader`
