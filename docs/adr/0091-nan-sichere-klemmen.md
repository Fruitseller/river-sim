# NaN-sichere Klemmen und Abbrüche

Mehrere Klemmen und Schleifenabbrüche sind bewusst so formuliert, dass ein NaN in einen sicheren Wert fällt. Die Reihenfolge der Operanden ist Teil der Semantik und darf beim Aufräumen nicht umgestellt werden.

- `min(1, max(0, x))` mit der Konstante zuerst: `max(0, NaN)` liefert 0, die äußere Klemme bleibt 0. In der Gegenreihenfolge liefert `min(1, NaN)` fälschlich 1 (voller Fels bzw. voller Schnee). So in `HeightBands.rockAmount` und `HeightBands.snowAmount`; `RiverChannel.clampToWorld` faltet ungültige Knotenkoordinaten auf dieselbe Weise zu 0.
- Die beiden Abbrüche der Tropfenschleife in `Hydraulic.erode` (z. B. `guard len >= 1e-9 else { break }`) sind so geschrieben, dass ein NaN sie auslöst (jeder Vergleich mit NaN ist falsch). Vorher lief ein NaN bis zum `Int(px)` im nächsten Schritt und brach dort mit einem Trap ab. Für endliche Werte gleichwertig, ohne zusätzliche Prüfung je Schritt.

Betrifft: `HeightBands.rockAmount`, `HeightBands.snowAmount`, `RiverChannel.clampToWorld`, `Hydraulic.erode`
