# Frame-Protokoll: Reihenfolge und Drosseln leben in SimRender

Seit Issue #94 liefert `RenderState.frame` die Puffer eines Frames; Reihenfolge und Drosseln liegen in SimRender statt in `Main.gd`. Die Reihenfolge Bänder → Wasserfeld → Schutzmaske → Waldmaske ist Vertrag: das Bänder-Ergebnis geht ins Wasserfeld desselben Frames, Schutz- und Waldmaske sehen dessen Wasser und Bänder. Die Wächter prüfen bit-gleich gegen die Zusammensetzung aus den Renderern desselben Standes (intern beobachtet, extern nur der Frame gefahren, #214) und verlangen, dass sich das Feld ohne Bänder unterscheidet, sonst bewiese die Gleichheit nichts.

Drosseln:
- Der 1-Hz-Band-Deckel unterdrückt den Rebuild und lässt ihn nach Ablauf wieder zu; `.settled` und `.stroke` gehen an ihm vorbei. Unter der Delta-Schwelle wird nicht gebaut.
- Nach einem Welt-Eingriff (`.edited`) baut der abschließende `.settled`-Frame die Bänder auch ohne Knoten-Bewegung neu, weil Gelände, Abfluss und Seespiegel in die Bänder eingehen; `.stroke` während des Strichs bleibt bei der Delta-Prüfung, und der Bau verbraucht den Eingriff (Review Neon Nr. 5).
- Die Overlay-Drossel (höchstens alle 0,30 s, mit dem kalibrierten Wasser-Blend) gilt nur im Zeitraffer; alle anderen Auslöser laden sofort und hart.

Ende-zu-Ende über die Sitzung (`Main._finish_stroke`, `Main._load_world`): nach Pinsel und Nachzug ist der Endstand bit-gleich zu dem, den das Laden dieser Welt zeigt (Wald, Schutzmaske, Bänder). Vor dem Fix blieb der Band-Bau des Vor-Pinsel-Stands stehen; gemessen (n = 192, 13 Pinselorte) wichen danach 201–853 Waldzellen ab, auch fern vom Pinsel, weil der Nachzug Abfluss und Seespiegel neu rechnet.

Vertrag mit `Main.gd`: die Auslöser-Konstanten dort tragen die Rohwerte von `FrameTrigger`, die Taktung liegt nicht mehr dort. Seit dem Hintergrund-Schritt (`docs/perf-measurements.md` §L) trägt der Frame auch Höhe, Jahr, Seespiegel, Höhenbänder und das Band-Mesh: der Hauptthread lädt den Stand hoch, den der Job verpackt hat, und fragt die Sim nicht noch einmal. Einzige Ausnahme (#214) ist `ribbon_strip_starts`: die Band-Anfänge gehören zum Mesh, Main malt einen Dreiecks-Supp, aber die Godot-Wächter (`river_ribbons.gd`, `water_geometry.gd`) zählen je Band und lesen sie aus dem Frame.

Betrifft: `RenderState.frame`, `FrameTrigger`, `SimNode.packFrame`, `game/scripts/Main.gd` (`FRAME_*`, `_apply_frame`), `RenderFrameTests`
