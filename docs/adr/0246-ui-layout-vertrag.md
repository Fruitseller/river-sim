# Vertragstest der Bedienung

`game/tests/ui_layout.gd` (#174, Paket E) prüft, was ohne Auge prüfbar ist; ob es aussieht wie Vorlage B/C, entscheidet der Projekteigner am Bild (Abnahmebogen #174, Punkte 41–45).
- Layout: oben links Titel/Jahr/Tempo und Werkzeugpalette, oben rechts die Zeitsprünge, unten rechts Diagnose/Welt/Kamera/Seed, unten Mitte die Tastenhilfe; jede Spalte `UI_MARGIN` von ihrem Rand. Im Grundzustand überlappt keine, auch im kleinen Standardfenster. Überlappung wird nur im Grundzustand geprüft, weil die aufgeklappte Diagnose im kleinen Fenster höher ist als der freie Platz unter der Zeitsprung-Leiste. Die Diagnose klappt auf und zu, ohne einen leeren Streifen zu hinterlassen.
- Ein gemeinsames Theme, keine Overrides an einzelnen Controls.
- Weichzeichner hinter jedem Glas-Panel: jedes Panel sitzt in einem Rahmen, dessen erstes Kind das Weichzeichner-Rechteck ist; Form, Radius, Abdunklung und Eckenradius kommen aus dem Theme; das Rechteck deckt das Glas exakt, fängt keine Maus und verschwindet mit seinem Rahmen. Headless ist nur die Verdrahtung prüfbar.
- Werkzeug-Icons, Taste 1–6 hebt den aktiven Knopf hervor, Tempo-Leiste.
- Kamera-Presets F1–F3 (auch weich angefahren): Diorama rahmt das Land und sitzt mittig (in Schrägsicht ist die nahe Kante größer als die ferne, ein Ziel auf der Mitte der Land-Box ließ die Insel unten sitzen, Folgebefund #176); Tal und Nah zielen auf den größten Lauf, nie aufs Meer, und bleiben schräg talaufwärts mit freier Sichtlinie.
- Pinselkuppel: Rand auf der Fläche, Scheitel im Profil (1 − d²)^p, gezeichnet als Bildschirm-Bänder.

Testfenster: headless ist das Fenster 64 × 64 Pixel; geprüft wird das Layout im kleinsten Fenster, das ein Spieler sieht (Godots Standardgröße), über die Größe der Vollbild-Ebene `hud`.

Auslass des größten Laufs ist Küste oder Kartenrand: ohne Randabstand (#175) läuft der größte Lauf mancher Welt über den Rand ab (so die CI-Welt). Empfänger liegen im D8-Netz auch diagonal im Meer; nur die vier Seiten-Nachbarn zu prüfen verwarf gültige Küstenzellen.

Die Kuppel-Baukosten werden nur protokolliert, nicht zugesichert (gebaut wird nur bei Änderung, `Main.brush_key`); eine Leistungsbehauptung bräuchte eine Messung nach Projektregel.

Betrifft: `game/tests/ui_layout.gd`, `game/scripts/Main.gd` (`CAMERA_PRESETS`, `camera_preset_view`, `sight_block`, Pinselkuppel), `game/ui/glass_theme.tres`
