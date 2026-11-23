# Langzeit-Wächter: kein Runaway, keine wachsenden Berge, kein Einebnen

Vor dem Fix wuchs das Produktions-Terrain über ~100k Jahre monoton weg: Relief 0.82 → 1.10, Wasseranteil 21 % → 39 %, maxH bis an den Hebungs-Clamp. `isoHighClamp = 0.90` pinnt das Terrain aufs junge, gratige Gleichgewicht. Der Wächter läuft auf Produktions-Defaults (nur `n` gesenkt), also ohne `basinFill` (stand historisch hier, ist seit `basinFill = false` nicht Teil des Pfads).

Zusicherungen: Berge wachsen nicht (Anforderung des Nutzers; ohne aktive Tektonik erodiert das Terrain), maxH am Ende höchstens 0.02 über dem Start (Toleranz fürs erste Settling der Noise-Oberfläche). Relief bleibt über 0.30: mit Hebung 0 sinkt es über 100k deutlich, das ist Alterung, kein Regress; die Schwelle fängt nur echtes Einebnen. See-Anteil unter 0.30 (vor dem Fix ~2× auf 39 %); deckeln müssen das Auslass-Inzision und Diffusion, `basinFill` ist bewusst aus.

Betrifft: `LongRunCollapse.testLongRunDoesNotRunAway`, `SimConfig.isoHighClamp`
