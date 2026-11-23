# Höhenbänder als Perzentile, einmal je Schritt aus den finalen Höhen

Vegetations-, Fels- und Schneegrenzen sind Perzentile der aktuellen Landhöhen statt absoluter Werte (Issue #4). `updateHeightBands` leitet sie am Anfang von `updateVegetation` ab, also nach der letzten Höhenänderung des Schritts und vor jedem Konsumenten. Sie sind die einzige Quelle für die Vegetation im Sim-Kern und die Biomfärbung im Render (heute `SimRender.TerrainColorRenderer`).

Die Schneegrenze kommt seit #33 aus dem Schneefeld: `snowAreaFractions` misst, wie viel Land das Klima beschneit, und projiziert den Anteil zurück auf ein Höhenquantil. Der Aufruf muss deshalb nach `updateClimate` liegen. Ohne Klima liefert `snowAreaFractions` `nil` und die Perzentile (`bandSnowPercentile`) greifen.

Kosten gemessen (n=832, Mittel über 200 Durchläufe): dieser Pass 1.38 ms, der Servo-Pass (`landReliefRobust`) 1.42 ms. Sie laufen zusätzlich zueinander und müssen es: der Servo liest die Höhen am Schrittbeginn (`applyUplift` → `reliefServoRate`), die Bänder die finalen Höhen. Ein gemeinsamer Pass wäre andere Physik. Issue #4 kostet damit ~1.4 ms je `step()`, bei 60 fps Echtzeit-Zeitraffer rund 8 % des 16.7-ms-Budgets.

Verworfen: ein Dirty-Flag auf `h` (müsste jede Mutation in jedem Erosionspass mitziehen, und im Zeitraffer ist `h` ohnehin jeden Frame schmutzig) und Neuableiten nur alle N Jahre (bricht die getestete dt-Invarianz). Offen ist ein paralleler Histogramm-Fill (s. #271).

Betrifft: `Terrain.heightBands`, `Terrain.updateHeightBands`, `Terrain.snowAreaFractions`, `HeightBands.fromLandHeights`
