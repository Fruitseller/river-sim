# Hintergrund-Job des Zeitraffers: höchstens einer, ein Ergebnisplatz

Im Zeitraffer rechnet die Welt-Sitzung Sim-Schritt und Frame-Aufbereitung auf einem Hintergrund-Thread, damit der Hauptthread weiter zeichnet und nur fertige Puffer hochlädt (`docs/perf-measurements.md` §L). `BackgroundJob` ist die ganze Nebenläufigkeit dabei und godot-frei, damit sein Vertrag headless prüfbar bleibt (Wächter: `SimCoreTests/BackgroundJobTests.swift`).

Vertrag: EIN Besitzer-Thread (in Godot der Hauptthread) ruft `start`, `wait` und `take`; nur die Arbeit läuft woanders.
- Ein Job ist unterwegs von `start` bis `take`: er rechnet, oder sein Ergebnis liegt und ist nicht abgeholt.
- Solange er rechnet, gehören die Objekte, die er anfasst, ihm allein; wer sie anfassen will, ruft `wait()`. Danach sieht der Aufrufer jeden Schreibzugriff des Jobs, weil das Fertig-Signal über Sperre und Gruppe läuft (beides Speicherbarrieren).
- `start`, während ein Job unterwegs ist, startet nichts (Rückgabe `false`): das liegende Ergebnis ginge sonst verloren, und mit ihm etwa ein Band-Bau, den der Render-Zustand schon für ausgeliefert hält.
- `isReady` blockiert nie. `wait` und `take` blockieren, solange der Job rechnet, und zählen diese Zeit (`waits`, `waitedSeconds`). Das ist die Messgröße „Hauptthread hat auf die Sim gewartet" (`SimNode.stepWaitMilliseconds`); im Zeitraffer soll sie nicht wachsen.
- Determinismus: der Job rechnet genau `step` + Frame, nur auf einem anderen Thread, und niemand sonst fasst die Welt dabei an.

Swift 6 (Issue #201): `@unchecked Sendable`, weil der Typ selbst die Nebenläufigkeit ist; `running`/`finished`/`output` stehen unter der Sperre, `waits`/`waitedSeconds` gehören laut Vertrag dem Besitzer-Thread. Die Arbeit bleibt eine nicht-`@Sendable`-Closure: sie erfasst bewusst nicht-`Sendable`-Objekte (Welt, Render-Zustand), die der Vertrag dem Job exklusiv überträgt; das kann das Typsystem ohne Besitzer-Disziplin nicht ausdrücken. Es gibt EINE zentrale `nonisolated(unsafe)`-Erfassung in `start`, dieselbe Bauform wie `Terrain.parallel`: wer ein Rennen einbaut, baut es durch diesen Engpass.

Test-Haken `willBlock`: läuft auf dem Besitzer-Thread unmittelbar bevor `wait` tatsächlich blockiert. Wächter geben damit einen am Tor gehaltenen Job genau dann frei, wenn der Zugriff nachweislich wartet, statt das aus einer Verzögerung abzuleiten (Review #216). Produktion setzt ihn nie.

Betrifft: `BackgroundJob`, `BackgroundJob.start`, `BackgroundJob.willBlock`, `WorldSession.beginStep`, `SimNode.stepWaitMilliseconds`
