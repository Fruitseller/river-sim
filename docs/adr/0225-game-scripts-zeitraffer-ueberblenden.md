# Zeitraffer-Überblenden: eine Blende je Upload-Takt

Im Zeitraffer gleiten die Texturen von Stand zu Stand, statt im Takt der Uploads zu springen (#172). Pinsel, Sprung, Laden und Neugenerieren zeigen den neuen Stand sofort.

Jede Blende gehört zu genau einem Upload-Takt: die Höhe im Sim-Takt (`height_blend`), alles Gedrosselte (Farbe, Material, Rinnen-Detail, Seespiegel, Wald, Raster-Wasser, Sedimentfahne) im Overlay-Takt (`overlay_blend`), die Bänder in einem dritten Takt (`ribbon_blend`). Eine geteilte Blende über zwei Takte ließ den Wald an jedem Takt ohne neue Maske auf den alten Stand zurückspringen (#170); deshalb blendet die Waldmaske mit der Overlay-Blende und nicht mit `bake_blend` (die Verschiebung backt jeden Sim-Takt, die Maske kommt nur mit den Overlays). Jeder Upload startet seine Blende neu und dauert so lange wie der Abstand zum vorigen; bei gleichmäßigem Takt gleitet die Fläche ohne Halt, statt erst zu springen und dann zu stehen.

Geblendet wird nur ein Zeitraffer-Takt (Auslöser `FRAME_TIMELAPSE`), nicht schon ein laufender Zeitraffer: Neugenerieren pausiert ihn nicht, und die neue Welt glitt sonst aus der alten herein.

Bänder: Der vorige Band-Bau bleibt als zweites Mesh stehen und löst sich über `ribbon_fade` in den neuen auf, statt im Takt der Band-Bauten (~1 s) zu springen; beide Stände teilen sich die optische Dicke (Begründung in `water.gdshader`, `ribbon_blend`). Die Dauer ist der Band-Deckel selbst (`RenderState.ribbonRebuildSeconds`, 1 s): im Zeitraffer liegen zwei Bauten nie dichter, die Blende endet also immer vor dem nächsten Bau, und kein halb aufgelöster Stand wird verworfen. Das ausblendende Mesh wird sofort sichtbar geschaltet, nicht erst im nächsten `_process`, sonst fehlte für ein Bild der alte Stand, während der neue noch bei Blende 0 steht.

Sedimentfahne: Auch sie hat einen Vorgängerstand (`plume_prev_tex`) und blendet mit der Overlay-Blende; die Weichzeichnung über die Mip-Kette allein glättete den Sprung nicht (#174).

Thread-Sicherheit: Jeder neue Stand bekommt ein eigenes `Image`. Der alte bleibt damit unverändert, auch wenn der Renderer die Bytes erst später auf dem separaten Render-Thread liest.

Betrifft: `Main.FieldTexture`, `Main.Crossfade`, `Main.RIBBON_FADE_SECONDS`, `Main._timelapse_fading`, `Main._update_forest_mask`, `Main._update_plume`, `Main._upload_ribbon_mesh`
