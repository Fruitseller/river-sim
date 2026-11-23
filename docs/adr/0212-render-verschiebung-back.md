# Render-Verschiebung: Back-Pass je Terrain-Update, Render-Gitter in Sim-Auflösung

Die Render-Verschiebung von Rinnen und Graten (#153) backt ein Float-SubViewport einmal je Terrain-Update (`_bake_relief`, `UPDATE_ONCE`); der Terrain-Shader liest nur. Kein Update, kein Back-Pass: der Zeitraffer bleibt ruhig, und das Standbild kostet nur das Lesen der Textur. Das SubViewport muss `transparent_bg` haben, sonst verwirft es den Alpha-Kanal (Rinnen/Rippen).

Auflösung: Die Backtextur hat die doppelte Sim-Auflösung (`RELIEF_BAKE_FACTOR` 2), damit die Pixel-Stufe Steigung und Rinnen aus der feineren Textur liest und ihr Detail nicht an der Mesh-Dichte hängt (Flusstal-Studie #116). Das Render-Gitter selbst ist in `balanced` und `quality` das volle Sim-Gitter, in `performance` 256: erst das Sim-Gitter trägt die Silhouette der Verschiebung; ein doppelt so dichtes Gitter kostete in der Studie doppelt so viel ohne sichtbaren Gewinn (die Dreiecke liegen in der Übersicht unter einem Pixel), Normalen und Rinnen kommen ohnehin aus der feineren Backtextur. Messreihe: `docs/graphics-quality.md`, Abschnitt #153.

Überblenden: Zwei Back-Ziele im Wechsel. Im Zeitraffer blendet der Terrain-Shader über einen Sim-Takt vom alten zum neuen Stand (`relief_mix`), statt viermal je Sekunde zu springen; sonst (Pinsel, Sprung, Laden) gilt der neue sofort. Kommt mitten in der Blende ein zweiter Auftrag (Band-Bau im selben Takt), backt das neue Ziel erneut, und die Blende läuft weiter, statt auf den alten Stand zurückzuspringen.

CPU-Rücklesen: Pinselkuppel und Kameraziel liegen auf der sichtbaren Fläche; dafür liest `_relief_cpu` die Backtextur zurück. Der Rückweg ist ein GPU-Sync (gemessen 22 ms bei n = 720, M4 Max), deshalb lazy und nie während eines Strichs: lesbar erst nach dem gezeichneten Back-Frame, im Strich bleibt der Stand vom Strich-Beginn (die Sim-Höhe darunter ist immer aktuell), im Zeitraffer wird nichts gelesen. Headless (Dummy-Renderer) bleibt der Puffer leer, die sichtbare Fläche ist dann die Sim-Fläche.

Betrifft: `Main.RELIEF_BAKE_FACTOR`, `Main.terrain_grid_for`, `Main._setup_relief`, `Main._bake_relief`, `Main._relief_cpu`, `shaders/relief_bake.gdshader`
