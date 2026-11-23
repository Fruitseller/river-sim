# byte01, smoothstep und clamp01: bit-identisch und NaN-fest

Die Umrechnung 0…1 → Byte (`byte01`), mit der jeder RGBA8-Render-Puffer endet (Makrofarbe, Materialgewichte, Wasserfeld, Δ-Karte), sowie `smoothstep` und `clamp01` (Kaskaden-Übergabe und Mündungs-Fade der Bänder, Klippen-Gewicht, Abfluss-Rampe, Kanal-Deckkraft, Bilinear-Gewichte, Meeresgrund-Rampe) stehen je einmal in `SimRender/RenderSupport.swift`. Zwei Zusagen gehören zusammen: an der Darstellung ändert sich nichts (bit-identisch zu den ersetzten Schreibweisen), und die Helfer sind total. Fiele die erste weg, wäre die Vereinheitlichung eine stille Render-Änderung; fiele die zweite weg, wäre sie zwecklos.

Der nicht offensichtliche Grund: `min`/`max` liefern bei einem NaN-Operanden den ersten Operanden. `max(v, 0)` reicht NaN durch, `max(0, v)` wischt es weg. Die alte Byte-Zeile schrieb den Wert zuerst, und `UInt8(Double)` bricht bei NaN/±∞ ab; die alte smoothstep-Klemme reichte NaN durch die ganze Rampe. Die neuen Helfer schreiben die Konstante zuerst, ein NaN fällt auf 0.

Ein Abbruch der Extension wäre die schlechtere Antwort als ein sichtbar falsches Pixel: ungültige Zahlen sind ein angezeigter Zustand (`TerrainDiagnostics` zählt sie als `DBG_INVALID` und malt sie magenta).

Die alten Schreibweisen (zwölfmal in `TerrainColorRenderer`, `TerrainDiagnostics`, `WaterFieldRenderer`; smoothstep in `RiverRibbonRenderer` und als Zwilling in `TerrainColorRenderer`) stehen bewusst nur noch in den Tests, als Referenz für die Bit-Gleichheit. Reine Rechen-Wächter ohne Terrain, Mikrosekunden, deshalb in der Pflichtsuite.

Betrifft: `byte01`, `smoothstep`, `clamp01`, `SimRender/RenderSupport.swift`, `RenderByteTests`, `RenderRampTests`
