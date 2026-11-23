# Frame-Protokoll: SimRender entscheidet, Main lädt nur hoch

Ein Render-Frame (Issue #94) ist ein Dictionary aus `SimNode.packFrame`. Was ein Frame liefert, in welcher Reihenfolge es entsteht (Bänder vor dem Wasserfeld) und wie es gedrosselt wird (Overlays 0,30 s, Bänder 1 Hz, Wasser-Blend 0,15, Rebuild-Schwellen), steht in `RenderState.frame`; Main lädt nur hoch, fehlende Schlüssel heißen unverändert. Die Auslöser `FRAME_SETTLED`, `FRAME_JUMP_CHUNK`, `FRAME_TIMELAPSE`, `FRAME_STROKE` sind dieselben Zahlen wie `SimRender.FrameTrigger`.

Folgen in Main:
- Ein Zeitsprung endet mit `FRAME_SETTLED`, damit der Band-Deckel den sichtbaren Endzustand nicht bis zum nächsten Zeitraffer-Tick verzögert (der Sprung endet typischerweise pausiert).
- Schutz- und Waldmaske werden aus demselben Frame hochgeladen: der Wald endet an der Schutzmaske desselben Frames (in SimRender fallen beide gemeinsam, `dropMasks`).
- Alle Puffer kommen als rohe Bytes aus SimNode (Issue #53); `heights()` + `to_byte_array()` kostete je Update eine zusätzliche Kopie von ~2,7 MB.

Betrifft: `Main.FRAME_*`, `Main._render_frame`, `Main._apply_frame`, `Main._upload_heights`, `Main._upload_overlays`, `SimRender.RenderState.frame`, `SimRender.FrameTrigger`
