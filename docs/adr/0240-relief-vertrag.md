# Vertragstest der Render-Verschiebung

`game/tests/relief.gd` (#153) prüft das äußere Verhalten an den Vertragsgrenzen, nicht das Muster:
- Back-Pass und Terrain-Shader kompilieren; jede `relief_*`-Zahl kommt über die Brücke (`SimCore.ReliefRender`), ist default-frei deklariert und auf beiden Materialien gesetzt.
- Back-Kadenz: im Standbild ohne Terrain-Update nie, im Zeitraffer mit jedem Sim-Schritt (Höhen-Upload), höchstens doppelt (zusätzlich ein Band-Bau), dort weich übergeblendet; beim Pinsel sofort.
- Pinselkuppel und Kameraziel liegen auf der sichtbaren Fläche (Sim-Höhe plus Verschiebung), der Pinsel ändert die Sim-Zelle unter dem Treffer.
- Die Verformung blendet mit dem Geländealter ein; auf junger Welt liegt die sichtbare Fläche auf der Sim-Höhe.
- Ein Strich, der beginnt, während ein Hintergrund-Schritt rechnet (`docs/perf-measurements.md` §L), wartet nicht: er setzt aus, bis der Schritt abgeholt und hochgeladen ist, und malt dann auf dem neuen Stand.
- Neugenerieren mitten im Zeitraffer zeigt die neue Welt sofort, statt sie aus der alten einzublenden (Review #173).

Testaufbau: der Dummy-Renderer zeichnet den Back-Pass nicht; für die Flächen-Prüfung bekommt Main eine bekannte Verschiebung (+1 Welteinheit). Der Zeigerstrahl ist fest und schräg (`RAY_DIR`): senkrecht fiele der Treffer mit und ohne Verschiebung auf dieselbe Zelle. Alles andere (Raymarch, Ring, Pinsel) ist der Produktionspfad. Die Overlay-Drossel läuft auf der echten Uhr (0,30 s), die kurzen Test-Frames schaffen das nicht sicher; der Test legt deshalb einen Frame mit Overlays während des Zeitraffers direkt an, um die Overlay-Blende zu prüfen.

Betrifft: `game/tests/relief.gd`, `game/scripts/Main.gd` (Back-Kadenz, `_raycast_terrain`, `_settle_sim`)
