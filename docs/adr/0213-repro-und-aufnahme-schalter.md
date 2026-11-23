# RS-Schalter für Repro und Aufnahmen: Reihenfolge und Sichtbarkeit

`RS_FLATTEN` ebnet zuerst ein, danach simuliert `RS_STEP`. Nur in dieser Reihenfolge ist der Repro aus Issue #26 (großflächige Einebnung, dann Zeitraffer) abbildbar. Eingeebnet wird gekachelt über die ganze Karte mit den UI-Grenzwerten (Radius 30, Stärke 3), derselbe Aufbau wie `FlattenRegeneration` im SimCore-Test; danach wird der Diagnose-Vergleichspunkt gesetzt, weil nur die Entwicklung ab der flachen Fläche interessiert.

Autonome Screenshots (`RS_SHOT`) zeigen die Landschaft ohne Bedienleiste: sie verdeckt sonst die halbe linke Bildhälfte, und genau dort liegen in der A/B-Serie die Mündungen. Die Diagnosewerte stehen ohnehin im Log. `RS_SHOT_UI` behält die Bedienung für Aufnahmen der Bedienung selbst.

Betrifft: `Main._ready` (`RS_FLATTEN`, `RS_STEP`, `RS_SHOT`, `RS_SHOT_UI`), `Main._setup_ui`, `SimCoreTests/FlattenRegeneration.swift`
