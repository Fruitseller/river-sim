# Kreuzprodukt von Hand statt `simd_cross`

Die Normalen des Korridor-Meshes werden mit einem ausgeschriebenen Kreuzprodukt berechnet. `simd_cross` stammt aus Apples `simd`-Modul und fehlt auf Linux (CI-Runner, Agent-Host); die Swift-Standardbibliothek bietet für `SIMD3` kein Kreuzprodukt. Wer auf dem Mac auf `simd_cross` umstellt, bricht den Linux-Build.

Betrifft: `CorridorBandBuilder.emit`
