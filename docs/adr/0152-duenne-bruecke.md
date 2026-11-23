# Die GDExtension ist reines Marshalling

`SimNode` hält nur die Welt-Sitzung (`SimRender.WorldSession`) und reicht ihre Ergebnisse als `Packed*Array` an Godot (PLAN.md §1). Die Physik lebt in `SimCore`, die Render-Aufbereitung samt Zustand im godot-freien Target `SimRender` (Issues #80/#82/#93), und seit Issue #212 auch die Regel der Brücke (vor jedem Zugriff einen laufenden Schritt abwarten, nach jeder Weltänderung die passende `TerrainChange` melden) in der Sitzung. In `SimNode` passiert nur: Aufruf weiterreichen, `[UInt8]`/`[Float]`/`RibbonMesh` als `Packed*Array` zurückgeben.

Config und Einlauf kommen als benannte Werte aus SimCore (`SimConfig.production`, `SimConfig.productionSettleYears`, Issue #97); die Brücke baut keine eigene Fassung. Nur der Produktionspfad läuft ein, die SimCore-Testwelten bleiben unverändert. Wächter: `SimCoreTests/RenderContractTests.swift`.

Seit Issue #214 gibt es keine Einzelschritt-Callables mehr. Wasserfeld, Farben, Material, Masken und Fahnen entstehen nur im Frame (`renderFrame`/`beginStep`, Reihenfolge und Drosseln: `RenderState.frame`) und reisen in dessen `overlays`. Was die Godot-Wächter brauchen, lesen sie aus dem Frame-Dictionary; die Einzelschritte sind `internal` in SimRender und gehören den headless XCTest-Wächtern. Auch das alte `sculpt`-Callable ist mit #214 weg: das Spiel hebt und senkt über den Pinsel, `BrushTool.raise/lower` fährt auf Swift-Seite denselben `terrain.sculpt`-Weg; die Sitzung hält `sculpt` für die headless Wächter in `WorldSessionTests` bereit.

Pinsel: `mode` ist der Rohwert von `BrushTool`, die Werkzeug-Tabelle in `Main.gd` hält dieselbe Reihenfolge (Issue #53). Ein unbekannter Modus meldet `GD.pushError`, statt still nichts zu tun; ein Werkzeug ohne Wirkung sah im Spiel vorher wie ein Physik-Bug aus. Welche Pässe nach einem Strich in welcher Reihenfolge laufen, steht seit #93 bei ihrem Besitzer `Terrain.recomputeFlowAfterEdit`.

Betrifft: `SimNode` (`Extension/Sources/RiverSimGD/SimNode.swift`), `SimNode.session`, `SimNode.brush`, `SimConfig.production`, `SimConfig.productionSettleYears`, `BrushTool`
