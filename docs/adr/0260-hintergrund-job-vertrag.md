# Hintergrund-Schritt: ein Job, Ergebnis genau einmal, Abholen vor jedem Weltzugriff

Der Zeitraffer rechnet Sim-Schritt und Frame-Aufbereitung über `WorldSession.beginStep` auf einem eigenen Thread (`docs/perf-measurements.md` §L). Die ganze Nebenläufigkeit steckt in `BackgroundJob` (godot-frei, damit headless prüfbar); `Main.gd` holt das Ergebnis ab. Abwarten, Ein-Schritt-zur-Zeit und Bit-Gleichheit Hintergrund ↔ synchron prüft seit #212 `WorldSessionTests` an der Sitzung.

Vertrag von `BackgroundJob`:
- Ein fertiges, nicht abgeholtes Ergebnis blockiert den nächsten Start. Sonst ginge sein Frame verloren und mit ihm ein Band-Bau, den der Render-Zustand schon für ausgeliefert hält.
- `isReady` ist die Abfrage des Zeitraffers je Frame und darf nie auf einen rechnenden Job warten. Als Wartezeit (Messgröße „Hauptthread wartet") zählt nur echtes Warten in `wait`/`take`.
- Der Job läuft nicht auf dem Aufrufer-Thread. Nach `wait` sieht der Aufrufer alle Schreibzugriffe des Jobs; Gruppe und Sperre sind die Barrieren, ohne sie wäre `terrain` nach dem Abholen ein Datenrennen.

Gegenseite in `Main.gd` (Quelltext-Vertrag): Der Zeitraffer beginnt Schritte im Hintergrund und holt sie nur fertig ab, kein synchroner Schritt und kein synchroner Frame in `_process`. Jede Funktion, die die Welt ändert oder ihren aktuellen Stand liest, ruft vorher `_settle_sim`, sonst käme der ältere Stand des laufenden Schritts nach dem neueren an. Ausnahmen mit Grund: `_ready` (vor dem ersten Frame gibt es keinen Schritt) und die Diagnose-Helfer, die nur `_refresh_debug` aufruft. `_process` wartet auch für den Pinsel nicht: solange ein Schritt rechnet, setzt der Strich aus. `sim.sculpt` steht seit #214 nicht mehr in der Liste der Weltaufrufe, weil es aus der Brücke gefallen ist (das Spiel hebt über den Pinsel; die Sitzung hält `sculpt` nur für die Wächter).

Betrifft: `BackgroundJob`, `WorldSession.beginStep`, `game/scripts/Main.gd` (`_settle_sim`, `_process`), `BackgroundJobTests`
