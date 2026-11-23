# Lauf-Größen der Flussbänder je Vertex

`RibbonMesh.flows` (Look-Iteration 14) trägt je Vertex Kolk ↔ Riffel, Weißwasser, Gefälle und Breite. Die Breite ist die gemalte Bandbreite, also der Abstand des Kantenpaars; `water.gdshader` skaliert damit die Kräuselung quer (Review Neon Nr. 7/8) und liest sie aus dem Kanal, statt sie je Pixel aus Bildschirm-Ableitungen zu schätzen (Review Neon Nr. 8: der Kanal war vorher tot).

Weißwasser darf kein Saum über ganze Läufe sein, die Schranke steht aber bei der Hälfte der Fluss-Vertices statt bei einem Drittel: die steilere Linux-Welt (glibc-libm) trägt zu Recht auf 402 von rund 1200 Fluss-Vertices Weißwasser (Gefällestufen). Ein Saum über ganze Läufe läge nahe 100 %.

Betrifft: `RibbonMesh.flows`, `game/shaders/water.gdshader`, `RibbonFlowTests`
