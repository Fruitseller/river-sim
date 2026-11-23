# Diagnose-Kennzahlen: Index-Vertrag zwischen SimRender und Main.gd

Über die Brücke geht ein namenloser `PackedFloat32Array` (`SimNode.debugTerrainStats` → `TerrainDiagnostics.stats`). Was an welchem Index steht, ist Konvention und steht doppelt: als ausführbarer `[Float]`-Puffer in `SimRender` und als `DBG_*`-Indizes plus `DEBUG_STATS_COUNT` in `Main.gd`. Der Wächter führt den Renderer direkt aus und hält die GDScript-Tabelle als Quelltext-Vertrag; er verhindert, dass ein Wert im Renderer angehängt, eingefügt, entfernt oder umgestellt wird, ohne `Main.gd` mitzuziehen. Die semantische Belegung der Indizes prüft `SimRenderTests`.

Die Doppelung selbst ist als #274 erfasst.

Betrifft: `TerrainDiagnostics.stats`, `SimNode.debugTerrainStats`, `game/scripts/Main.gd` (`DBG_*`, `DEBUG_STATS_COUNT`), `DiagStatsContractTests`
