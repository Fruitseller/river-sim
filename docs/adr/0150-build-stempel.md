# Build-Stempel gegen veraltete Libraries

Godot lädt die Library aus `game/bin/` blind. Deshalb brennt der Build einen Stempel der Quellen (`Extension/Sources` + `SimCore/Sources`, Verfahren: `scripts/build-stamp.sh`) in die Library, und `SimNode.buildStamp()` gibt ihn zurück. `smoke.gd` vergleicht ihn mit dem Arbeitsverzeichnis und bricht bei einer veralteten `.so` laut ab, statt sie still zu benutzen. Das ist real passiert ("Nonexistent function brush").

Betrifft: `SimNode.buildStamp`, `BuildStamp.value`, `scripts/build-stamp.sh`, `game/tests/smoke.gd`
