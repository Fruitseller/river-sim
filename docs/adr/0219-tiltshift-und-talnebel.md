# Tilt-Shift-Tiefenschärfe und Talnebel an Kameraabstand gekoppelt

Der Miniatur-Eindruck kommt aus der Optik: eine scharfe Tiefen-Schicht um den Fokuspunkt, davor und dahinter Bokeh (Godots Nah- und Fern-Unschärfe zusammen, `CameraAttributesPractical`). Der Fokus liegt auf dem Pinselpunkt, wenn die Kuppel steht, sonst auf dem Kameraziel in der Bildmitte; beide liegen auf der sichtbaren Fläche. Rein visuell, nichts davon berührt die Sim (#237).

Kopplung: Die scharfe Schicht ist ein Anteil des Fokusabstands. Die Stärke wächst mit dem Kameraabstand (Totale = Modell auf dem Tisch, Nahsicht nur ein Hauch) und mit flacherem Blick; steil von oben gibt es kaum Tiefe, deshalb wird die Schicht dort breiter, damit nicht das halbe Bild verschwimmt. Die Werte sind Geschmackswerte, abgenommen am Bild (`docs/look/c-materials/`). Der Fokusabstand wird über 0,15 s geglättet, weil der Pinsel sonst an jeder Kante zwischen Grat und Tal springt.

Kosten: Box-Bokeh in niedriger Qualität ohne Jitter. Hexagon in mittlerer Qualität mit Jitter kostete gemessen 3,2 ms je Bild bei 3456×2104 (Zeitraffer, Detail-Kamera). In `performance` gibt es keine Tiefenschärfe, weil Bokeh ein eigener Vollbild-Pass ist.

Talnebel (`valley_fog.gdshader`): Lagen über dem geglätteten Gelände, sichtbar nur, wo das Gelände darunter abfällt (Täler, Becken, Meer). Die Stärke folgt dem Kameraabstand und ist in der Nahsicht aus, damit `nah` keinen Kontrast verliert; die Look-Iterationen 9 und 17 verloren mit Dunst überall.

Betrifft: `Atmosphere.gd` (`dof_for`, `enabled`, `FOCUS_SMOOTH_SECONDS`, `make_valley_fog`, `update`)
