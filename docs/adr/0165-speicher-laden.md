# Speichern und Laden über die Brücke

`saveWorld`/`loadWorld` geben einen String zurück: leer heißt Erfolg, sonst ist es die Fehlermeldung für den Dialog. Godot kennt keine Swift-Fehler; ein String ist der ehrlichste Vertrag über die Brücke (verworfene Alternative: Bool plus separates `lastError()`). Pfade sind Betriebssystem-Pfade, GDScript schickt `user://…` vorher durch `ProjectSettings.globalize_path()`.

Laden ersetzt die aktuelle Welt; die Datei bringt ihre eigene Config mit (Issue #8). Bei Erfolg ist der Zustand sofort vollständig (Seespiegel, Höhenbänder, Flüsse), der Aufrufer zieht nur seine Texturen neu und erzwingt keinen Sim-Schritt. Im Fehlerfall bleibt die aktuelle Welt unangetastet. Die Sitzung meldet danach `.replaced`, dieselbe Politik wie beim Generieren (s. `RenderState.invalidate`).

Das Frontend baut Texturen und Meshes je Sitzung für EIN `n`. `worldFileGridSize` und `worldFileWorldSize` lesen `n` und `world` ohne die Felder (−1 = nicht lesbar), damit eine Welt mit abweichender Geometrie abgelehnt werden kann, bevor die alte ersetzt ist. `n` allein genügt nicht: Mesh-Größe, Kamera-Distanz, Raycast-Skala und die Welt→Zelle-Umrechnung der Werkzeuge hängen an `world`. Bei gleicher Auflösung, aber anderer Weltgröße liefe die Simulation sonst in anderen Weltkoordinaten als Darstellung und Pinsel. `n` und `world` gehören in diesem Projekt zusammen, die Datei garantiert das aber nicht.

Betrifft: `SimNode.saveWorld`, `SimNode.loadWorld`, `SimNode.worldFileGridSize`, `SimNode.worldFileWorldSize`, `WorldSession.load`, `WorldSnapshot.peekConfig`
