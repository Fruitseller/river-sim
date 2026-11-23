# Großform: ein Gebirgskamm, ruhiges Tiefland, Randabstand; altes Relief bleibt für die Wächter

Seit #174 erzeugt `generateRangeRelief` einen Kamm entlang der langen Inselachse (`RangeSkeleton`) statt Grate über die ganze Fläche; beim Archetyp Küste läuft er parallel zur Küste im Hinterland. Daneben sanfte Vorberge (dieselben Grate, niedriger), dahinter eine flache Ebene, Täler schneiden vom Kamm zur Küste. Jeder Seed bekommt eigene Makro-Parameter (Form, Relief, Grat/Rundhügel, Archetyp Insel/Küste/Archipel), deterministisch über Mulberry32.

Zentrum und Ausdehnung sind enger als vorher (vorher ±0,17 n Versatz, fStart 0,58–0,88, Ellipse über die kurze Achse normiert, also bis zu 1,8-fache lange Halbachse; jetzt ±0,06 n und fStart 0,55–0,70): die Insel soll als Ganzes im Gitter liegen, sonst schneidet der Randabstand gerade, steile Küsten parallel zum Rand. Der Zug, der früher `mBias` lieferte, bleibt als `_ = gr.next()` stehen; er hält die Positionen der folgenden Züge im Zufallsstrom und damit deren Werte je Seed.

Ebenenhöhe 0,20 über einem Meer bei 0,15: die Küstenlinie liegt bei falloff = 0,75 im oberen, flachen Teil der Smoothstep, das Küstengefälle der Ebene (0,20 · 1,125 / (0,30 · 360 Zellen) ≈ 0,002 je Zelle) bleibt unter der Mäander-Schwelle (0,02 · cellSize ≈ 0,003). Daher auch `fWidth ≥ 0,30`.

Randabstand relativ zu n (bei 720: 24 Zellen Rand, 72 Zellen Rampe, ±14 Zellen Rauschen); in absoluten Zellen fraß er den Testwelten (n = 96…256) einen Großteil des Landes. Kein Land am Gitterrand, sonst endet die Insel in einer geraden Kante und das Heightfield zeigt seine senkrechte Unterseite; verrauscht, damit die Küste nicht parallel zum Rand läuft.

Tektonik (`upliftBase`) ist fix je Terrain und ridged: Hebung konzentriert sich auf Grate statt auf einen glatten Blob. Das ist entscheidend gegen Langzeit-Degradation; die Erosion läuft sonst ins glatte Hebungsfeld (runde Kuppeln), ein gratiges Feld trägt langfristig gratige Berge. Das Feld ist positiv vorgespannt, weil detachment-limited Stream-Power Material ins Meer austrägt (nicht massenerhaltend) und die Tektonik die Landmasse netto tragen muss; sonst erodiert die Insel über 100k+ Jahre zu Graten weg. Seit #174 nur im Gebirgsgürtel: `applyUplift` und der Relief-Servo heben ausschließlich über den positiven Teil, Ebenen und Täler bleiben tektonisch ruhig, sonst höbe der Servo das Tiefland über Jahrtausende wieder zu Hügeln.

`generateLegacyRelief` (Grate über die ganze Landfläche, Massiv-Rauschen nur als Höhe) bleibt unverändert und bit-identisch erhalten, weil die Mechanik-Wächter der Suite ihre Testwelt darauf kalibriert haben (`cfg.rangeLandform = false`, `calibrationRangeLandform` in `SimCoreTests/TestCalibration.swift`).

Betrifft: `Terrain.generateRangeRelief`, `Terrain.generateLegacyRelief`, `Terrain.upliftBase`, `Terrain.applyUplift`, `RangeSkeleton`, `SimConfig.rangeLandform`
