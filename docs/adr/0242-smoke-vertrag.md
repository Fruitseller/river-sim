# Smoke-Test der GDExtension: Render-Puffer, Spielstand, Geometrie-Sperre, Hintergrund-Schritt

`game/tests/smoke.gd` prüft neben Registrierung, Feldgrößen und Pinsel folgende Verträge:

Render-Puffer: Makrofarbe und Materialgewichte sind je ein RGBA8-Texel pro Sim-Zelle. Ein fehlender Kanal fiele erst als schwarzes Terrain auf der GPU auf; geprüft werden Größe und tatsächliches Materialsignal, seit #214 über den Frame.

Speichern/Laden (#8): die Bit-Identität des Weiterlaufs prüft SimCore (`WorldSnapshotTests`); hier geht es um den Brücken-Vertrag: Datei entsteht, Zustand kommt zurück, eine Datei mit fremder Formatversion (Bytes 8..11 des Kopfs) wird abgelehnt, ohne die laufende Welt anzutasten. Die Vorprüfung der Geometrie liest nur Kopf und Config, nicht die Felder; beide Werte müssen zur laufenden Welt passen.

Geometrie-Sperre (`Main._world_geometry_mismatch`): eine Welt-Datei darf nur geladen werden, wenn Auflösung und Weltgröße zur Sitzung passen, sonst liefe die Simulation in anderen Weltkoordinaten als Darstellung, Kamera und Werkzeuge. Die Funktion ist reine Entscheidungslogik und wird ohne Szene geprüft (Skript instanziiert, nie in den Baum gehängt, kein `_ready`).

Der Werkzeugstrich besitzt die Uhr: während eines Strichs entwickelt der globale Sim-Schritt dieselben Höhen nicht weiter. Das gewählte Tempo bleibt erhalten und läuft nach dem Loslassen weiter; nur die periodischen Schritte setzen aus.

Hintergrund-Schritt (`docs/perf-measurements.md` §L): ohne Job gibt `finishStep` nichts; ein Aufruf, der die Welt braucht, wartet den Job ab und lässt dessen Ergebnis liegen (der Aufrufer muss es noch hochladen); ein zweiter Start, solange einer unterwegs ist, startet nichts; das Frame-Dictionary trägt Auslöser, Jahr und Höhen; derselbe Schritt synchron ergibt dieselben Höhen, Seespiegel und dasselbe Wasser (volle Frames vergleicht `BackgroundJobTests`). Beide Seiten starten nach `loadWorld` vom gespeicherten Stand, weil `.replaced` die Band-Übergänge (Geisterarme, Einwachsen) beendet; sonst erbte der Hintergrund-Schritt Übergänge aus der Sitzungs-Historie, die die synchrone Gegenprobe nicht hat. Die Übergänge selbst pinnt `TimelapseTransitionTests`.

Betrifft: `game/tests/smoke.gd`, `Main._world_geometry_mismatch`, `SimNode.loadWorld`, `SimNode.worldFileGridSize`, `SimNode.beginStep`/`finishStep`
