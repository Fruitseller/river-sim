# Adaptive Kamera-Presets, feste Ziele nur in der Matrix

Die Kamera-Presets der Vorlagen (#174, Paket E), Tasten F1–F3 in Tabellen-Reihenfolge: Diorama = ganze Insel schräg (Vorlage C), Tal = Blick über die Aue bis zum Horizont (B), Nah = Schrägsicht auf Hang, Fluss und Küste (A). Die Tasten-Presets sind adaptiv, beim Drücken für die laufende Welt gerechnet:
- Diorama (`fill`): Landzellen mittig im Bild, in der knapperen Richtung bis `fill`, aus FOV und Seitenverhältnis; Yaw bleibt.
- Tal und Nah (`upstream`): Ziel ist die Zelle des größten Laufs (D8), `upstream` Welteinheiten oberhalb seiner Küstenmündung, Kamera auf der Meerseite mit Blick talaufwärts. Das Ziel ist damit immer eine Landzelle, nie offenes Meer. Verdeckt Gelände die Sichtlinie (Talbiegung, Kamera im Hang), steigt der Pitch, bis sie frei ist. Die Sichtprobe beginnt bei t = 0,25 der Strecke Ziel → Auge: die nahe Umgebung des Ziels (Ufer, Kronendach am Fluss) ist das, worauf die Kamera blickt, kein Hindernis. Außerhalb des Gitters liegt nur Meer, sonst zöge die Rand-Klemme des Samplings das Randgelände endlos weiter.

Pitch (alle) und Distanz (Tal, Nah) sind dieselben wie bei den Matrix-Kameras gleicher `id`; die Matrix (`scripts/graphics-matrix.sh`) hält dagegen feste Ziele und Distanzen je Seed, damit Abnahmebilder reproduzierbar bleiben (Wächter `GraphicsMatrixTests.testCameraPresetsMatchTheMatrix`).

Diorama-Rahmung: Bis zum Folgebefund zu #176 stand das Ziel auf der Mitte der Land-Box. In Schrägsicht projiziert die nahe Kante größer als die ferne; die Insel saß unten und füllte nur ~60 % der Höhe (unten 0,84, oben 0,38). Heute je Bildrichtung in der Ebene: Punkte (x, y), Auge (c, D), Kegel-Steigung k; ein Punkt liegt in der Kante, wenn ±(x − c) ≤ k·(D − y), also a±(k) = max(±x + k·y) ≤ ±c + k·D. Beide Kanten knapp: D(k) = (a+ + a−)/(2k), c(k) = (a+ − a−)/2. Die Richtung mit dem größeren D(k_voll) begrenzt, die andere sucht per Bisektion das k mit D(k) = D und ist damit ebenfalls mittig. a± laufen nur über die konvexe Hülle. k_voll = fill·tan(fov/2) (vertikal, Godot `KEEP_HEIGHT`), horizontal mal `aspect`.

Das Diorama rahmt nach dem Seitenverhältnis. Auf dem Referenz-Mac hat das Fenster mit `--maximized` schon in `_ready` die Endgröße (gemessen 3456×2104); greift das Maximieren anderswo später, folgt ein per `RS_CAMERA` gesetztes Preset bis zur ersten Eingabe jeder Größenänderung. `RS_SHOT` zeigt so dasselbe wie F1–F3.

Kleinster Kamera-Abstand 20 Einheiten: bis #174 standen 30 als Zahl an jeder Zoom-Stelle; „Tal“ und „Nah“ brauchen näher heran, aus 60 zeigte „Tal“ die ganze Insel und das Tal war klein.

Betrifft: `Main.CAMERA_PRESETS`, `Main.CAM_DIST_MIN`, `Main.camera_preset_view`, `Main.frame_land`, `Main.river_view`, `Main._clear_pitch`, `Main.sight_block`, `GraphicsMatrixTests`
