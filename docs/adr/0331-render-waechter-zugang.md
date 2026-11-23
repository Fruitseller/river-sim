# Render-Wächter gehen über den Frame und beobachten Internes nur

Seit Issue #214 ist `RenderState.frame` der eine öffentliche Weg durch den Render-Zustand, mit derselben Reihenfolge und denselben Drosseln wie im Spiel. Die Wächter fahren die Reihenfolge über den Frame und beobachten interne Zwischenergebnisse (Bandabdeckung, nasse Wiese, Gürtel-Material, `riverRibbonMesh`) nur über `@testable`. Die Band-Mechanik prüfen sie direkt am `RiverRibbonRenderer` (derselbe Bau, den der Frame fährt); Reihenfolge und Drosseln prüft der Frame.

`frameOverlays` bricht mit `fatalError` ab statt ein Optional zu liefern: ein ungedrosselter Frame ohne Overlays ist ein Vertragsbruch, der Crash ist die Diagnose.

Einzelschritt-Tests tragen ihre Begründung am Test: die Reinheit des Maskenpfads (er schreibt nie in den Wasserzustand) ist über den Frame nicht prüfbar, weil der Wasser und Maske immer im selben Takt koppelt; ebenso die Maske vor dem ersten Wasser-Upload einer neuen Welt (`.replaced` verwirft `visibleWater`), weil über den Frame die Maske immer nach dem frischen Wasser kommt. Jede Maske ist aus Wasser und Bändern ihres eigenen Frames abgeleitet (die Folge stand vorher von Hand im Test).

Betrifft: `frameOverlays`, `builtRibbons`, `RenderState.frame`, `WaterProtectMaskTests`, `SimCore/Tests/SimCoreTests/TestCalibration.swift`
