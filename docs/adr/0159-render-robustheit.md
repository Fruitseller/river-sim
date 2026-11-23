# Robustheit der Render-Aufbereitung: kein Abbruch im Frame

Der Render-Pfad läuft pro Textur-Update in der GDExtension. Ein Abbruch mitten im Frame ist dort ein größerer Schaden als ein leeres oder sichtbar falsches Pixel. Daraus folgen mehrere Regeln.

NaN-sichere Klemmen: Swifts `min`/`max` sind als `y < x ? y : x` bzw. `y >= x ? y : x` definiert und geben bei einem NaN-Operanden den ERSTEN zurück. Deshalb steht die Konstante immer zuerst (`min(1, max(0, …))`), dann fällt NaN auf die Konstante. `clamp01`, `smoothstep` und die Skala der Δ-Karte folgen dem; für endliche Werte ist das bit-identisch zur umgekehrten Schreibweise.

`byte01` ist die EINE Umrechnung 0…1 → Byte für alle RGBA8-Puffer (vorher elfmal ausgeschrieben in `WaterFieldRenderer` und `TerrainDiagnostics`, ein zwölftes Mal privat in `TerrainColorRenderer`). `UInt8(Double)` klemmt nicht, es trappt bei NaN oder ±∞, und die alte Schreibweise `UInt8(min(max(v, 0), 1) * 255)` reichte NaN durch, weil der Wert zuerst stand. Jetzt ist die Funktion total: NaN → 0, ±∞ → 0 bzw. 255, für endliche Werte bit-identisch (Wächter: `RenderByteTests`). Ungültige Zahlen gelten nicht als „kann nicht passieren": `TerrainDiagnostics` zählt sie (`DBG_INVALID`), malt sie in der Δ-Karte magenta, und `Main.gd` warnt.

`smoothstep` ist die eine Fassung aller Render-Rampen (vorher zusätzlich als privater Zwilling in `TerrainColorRenderer` und zweimal ausgeschrieben in `RiverRibbonRenderer`). Vorbedingung `edge0 < edge1` wie in GLSL, nicht erzwungen: bei Gleichheit teilt sie durch 0, umgekehrt läuft sie rückwärts. Die einzige Kante, die nicht Literal oder `WaterRender`-Konstante ist, ist `cfg.renderMinCells` (Default 320); wer sie auf 0 oder negativ setzt, verlässt den Gültigkeitsbereich. Index-Klemmen auf Gittergrenzen bleiben Int-Klemmen, nur fraktionale Gewichte laufen über `clamp01`.

Feldgrößen-Mismatch: `WaterFieldRenderer.validateFields` steht für beide Guards an einer Stelle. Debug bricht laut ab (`assertionFailure`), Release liefert still einen leeren Puffer statt `preconditionFailure`. Die Diagnose-Meldung baut die reine Funktion `fieldSizeMismatchDetail` ohne Trap, weil der Pfad unter `swift test` (Debug) sonst nicht testbar wäre. `TerrainColorRenderer` fordert im Guard nur die direkt gelesenen Felder (`h`, `rain`, `veg`, `saltCrust`); `lithHardness`, `snow`, `ice` und `disturb` sind optionale Feature-Felder mit `[0.0]`-Fallback. Bei Mismatch oder n == 0 gibt es leere Puffer; n == 0 ist der etablierte Vertrag für leere Texturen (#122, #123).

Leere Felder an der LÄNGE erkennen, nicht an `baseAddress`: die ist für ein leeres Array nur unter Darwin nil, unter Linux zeigt sie auf geteilten Leerspeicher (CI las dort über das Ende hinaus).

Betrifft: `clamp01`, `smoothstep`, `byte01` (`RenderSupport.swift`), `WaterFieldRenderer.validateFields`, `WaterFieldRenderer.fieldSizeMismatchDetail`, `TerrainColorRenderer.buffers`, `TerrainDiagnostics.differenceBytes`, `ForestCanopyMask.regrow`
