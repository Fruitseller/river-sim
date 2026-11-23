# Swift-6-Modus und die zentrale unsichere Erfassung in den Parallel-Helfern

Die Extension `RiverSimGD` kompiliert wie die SimCore-Targets im Swift-6-Sprachmodus (Issue #201). SwiftGodot deklariert seine eigenen Targets als `.v5`; das bleibt dessen Sache und gilt nur dort.

`parallelChunks` (SimRender) verteilt Arbeit datenparallel über disjunkte Index-Bereiche und ist nur für Pässe gedacht, deren Zellen unabhängig sind (jede schreibt ausschließlich ihren eigenen Index). Das Ergebnis ist damit bit-identisch zur sequenziellen Schleife; dieselbe Idee wie `Terrain.parallel` in SimCore. Sonst läuft die Render-Aufbereitung auf dem aufrufenden Thread.

Unter Swift 6 steht dort dieselbe zentrale `nonisolated(unsafe)`-Erfassung wie bei `Terrain.parallel`: Die Aufrufer-Closures arbeiten bewusst auf rohen Zeigern der Puffer, die Disjunktheit der Bereiche ist Projektregel und wird von den Bit-Identitäts-Wächtern der Renderer geprüft. Die Signatur bleibt bewusst nicht-`@Sendable`, damit die Aufrufstellen unverändert bleiben. Wer Nebenläufigkeit ändert, ändert diesen Engpass.

Betrifft: `Extension/Package.swift` (`swiftSettings`), `parallelChunks` in `SimCore/Sources/SimRender/RenderSupport.swift`, `Terrain.parallel`
