# Welt-Sitzung: die Regel der Brücke steht einmal

`WorldSession` (Issue #212) besitzt `Terrain`, `RenderState` und den `BackgroundJob`; `SimNode` hält nur die Sitzung. Die Regel der Brücke steht damit genau einmal:
- Jeder Zugriff wartet zuerst einen laufenden Hintergrund-Schritt ab (`world`/`render`). Sein Ergebnis bleibt liegen; abholen muss der Aufrufer (`finishStep`), sonst zeigte Godot einen anderen Stand als den, den `RenderState` für sichtbar hält.
- Jede Weltänderung meldet die passende `TerrainChange`. Eine Änderung ohne Invalidierung lässt sich nicht schreiben: die Welt verlässt die Sitzung nie, nach außen gibt es nur benannte Änderungen und gelesene Werte. Das gespeicherte Terrain wird direkt nur in `beginStep` (Übergabe an den Job) und `load` (Ersetzen nach dem Abwarten) angefasst.

Bis #212 stand beides an jeder Methode der Brücke, geprüft nur per Quelltext-Grep und ausführbar nur in CI; jetzt prüft es `SimCoreTests/WorldSessionTests.swift` headless. Generisch über `Packed` (in Godot das Frame-Dictionary), damit der Hintergrund-Job selbst verpackt und die Sitzung godot-frei bleibt. Vertrag wie `BackgroundJob`: ein Besitzer-Thread ruft alle Methoden.

Der Job erfasst nur Welt und Render-Zustand, nie die Sitzung. Deshalb ist auch die Invalidierung statisch. Hielte der Job die Sitzung, liefe ihr `deinit` beim Freigeben des Knotens erst nach dem Job, und die Freigabe kehrte zurück, während er noch rechnet (Review #216). So läuft `deinit` sofort und wartet den Job ab; das ist nötig, weil Godot beim Beenden danach die Library entlädt, deren Code der Job ausführt (Wächter: `WorldSessionTests.testReleasingTheSessionWaitsForTheRunningStep`). `lastChange` setzt deshalb der Besitzer-Thread.

Der Produktions-Einlauf (`settleYears`) ist ein Argument, weil alle Brücken-Wege ihn fahren, Testwelten nicht. Der Render-Zustand ist seit #214 von außen nicht mehr injizierbar; die Sitzung baut ihn selbst mit dem `RS_WATER_STAMP`-Default (nur die headless Wächter injizieren über `@testable`).

Betrifft: `WorldSession`, `WorldSession.deinit`, `WorldSession.beginStep`, `WorldSession.invalidate`, `WorldSession.init(config:seed:settleYears:)`
