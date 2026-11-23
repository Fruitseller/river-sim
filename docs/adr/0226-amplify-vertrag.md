# Vertragstest der Gelände-Verfeinerung

`game/tests/amplify.gd` (#238) prüft die Verträge der Verfeinerung, nicht ihr Aussehen. Die Verfeinerung rechnet auf dem RenderingDevice; headless, im Compatibility-Renderer und in CI gibt es keins. Dort prüft der Test nur, dass Main ohne Verfeinerer beim Back-Pass bleibt, und überspringt den Rest mit Meldung. Bindung und Stabilität laufen lokal mit Fenster (`"$GODOT" --path game --script res://tests/amplify.gd`).

Geprüft:
- Bindung an die Sim: feste Schranke, null in der Schutzmaske (Wasser, Bänder, Saum) und am Küstensaum, wo Wasser steht nie über dem Spiegel, kein großräumiges Abweichen (Fenstermittel); in der strengen Fassung (`mean_window = 0`) bleibt das Mittel jeder freien Zelle erhalten. Exakt nur dort, wo die Schranke nicht greift, denn sie gilt nach dem Abziehen des Mittels und geht vor; deshalb p99 eng und Maximum weit.
- Stabilität: gleicher Eingang gibt bit-gleichen Ausgang; eine kleine Änderung gibt eine kleine Antwort in fester Reichweite; verteilt über mehrere Bilder kommt dasselbe heraus wie in einem Zug.
- Sichtbare Fläche: Main liest für Pinselkuppel, Raycast und Kameraziel dieselben Werte, die der Vertex-Shader liest (Mip-Stufe des Netzes).

Schwellen: Störung `NUDGE = 2e-4` Sim-Höhe, so groß wie ein kräftiger Zeitraffer-Takt (p99 gemessen ≈ 3e-4, `docs/look/d-amplify`). `MAX_GAIN = 16`: gemessen ≈ 6 im Maximum über alle Zellen, der alte Back-Pass lag im p99 bei 5 (`docs/graphics-quality.md` § Render-Verschiebung). `REACH_CELLS = 72`: Schritte beider Stufen, Fenster des Mittels, Maske und Hochskalieren, mit Reserve; außerhalb bit-gleich.

Kodierung der Puffer: das feine Feld ist RG16F (r Abweichung in Welteinheiten, g Maske), `lift` das kodierte Zellmittel (n²).

Betrifft: `game/tests/amplify.gd`, `game/scripts/TerrainAmplifier.gd`, `.github/workflows/ci.yml` (Schritt Gelände-Verfeinerung)
