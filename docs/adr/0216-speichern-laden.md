# Speichern und Laden: ein Platz, Geometrie-Prüfung, Fehlertext aus SimCore

Ein fester Speicherplatz (`user://saves/welt.rsworld`) statt Dateidialog: das Spiel führt genau eine Welt, und eine Welt ist groß (n = 832 → ~109 MB, das ganze Zustands-Inventar). Mehrere Slots oder Namen sind eine eigene UI-Frage (ROADMAP), nicht Teil von #8.

Nach dem Laden ist der Zustand vollständig: der Seespiegel kommt aus der Datei und schwingt nicht ein (#8). Es genügt, die Texturen neu zu ziehen; ein Sim-Schritt ist ausdrücklich nicht nötig.

Geometrie: Die Sitzung ist in `_ready` auf eine Geometrie festgelegt. Texturen und `h_cache` haben N × N Einträge; Mesh-Größe, Kamera-Distanz, Wasserebene, Pinselkuppel und die Welt→Zelle-Umrechnung von Raycast und Werkzeugen hängen an `world_size`. Beides wird vor dem Laden geprüft, solange die laufende Welt noch steht; `n` allein genügt nicht, bei gleicher Auflösung und anderer Weltgröße liefe die Simulation in anderen Weltkoordinaten als Darstellung und Pinsel (Zellgröße = world/(n−1)). Dass `n` und `world` nur zusammen geändert werden, ist eine Konvention für den Quellcode; eine Datei kann jede Kombination mitbringen (die Datei-Config ist beim Laden autoritativ, `WorldSnapshot`). Ablehnen statt umbauen ist bewusst: alle abhängigen Render- und Interaktionsstrukturen neu aufzubauen wäre ein zweiter, nur mit fremden Dateien erreichbarer Aufbaupfad neben `_setup_scene`, mehr Code und mehr Bruchfläche, als der Fall wert ist (`docs/world-save-format.md`). −1 heißt „nicht lesbar“; die Meldung dazu liefert dann `loadWorld`.

Fehler: Speichern und Laden können echt scheitern (alte Formatversion, beschädigte oder fremde Datei, volle Platte). Die Meldung im Dialog kommt wörtlich aus SimCore (`SnapshotError`), kein zweiter Text, der auseinanderlaufen kann.

Betrifft: `Main.SAVE_PATH`, `Main._save_world`, `Main._load_world`, `Main._world_geometry_mismatch`, `WorldSnapshot`, `SnapshotError`
