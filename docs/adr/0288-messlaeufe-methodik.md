# Messläufe: frische Welten, interleavtes A/B, eingefrorene Altfassung, Zeitmittel

Methodische Regeln der Diagnose-Läufe in dieser Testgruppe:

- Welten werden frisch mit der Produktions-Config erzeugt und wie die Zeitraffer-Bühne in 1000-Jahr-Schritten gealtert. Keine implizit wiederverwendeten `/tmp`-Snapshots: sie könnten nach einer Physik-Änderung einen alten Stand messen (`RectWaterTests`, `docs/geometry-water-measurements.md` § H).
- Laufzeit-Vergleiche laufen interleavt (alt, neu, alt, neu …; Median) und messen die ganze Funktion, weil das die Größe ist, die der Frame bezahlt (`WaterFieldRenderer.bytes` mit alter und neuer Verbreiterung; Material-Pass alt gegen neu, je 9 Läufe).
- Die Vorher-Fassung des Material-Passes liegt als `LegacyTerrainColor` im Test: der Stand von `TerrainColorRenderer.buffers` vor #174 D (Commit 55323b5), nur die damaligen Puffer. Sie dient nur dem Vorher-Vergleich und dem Laufzeit-A/B, wird nicht gepflegt und nirgends sonst benutzt (Tabelle: `docs/graphics-quality.md` § Material, Schnee, Wolken).
- Kennzahlen des Mäandergürtels werden über Stützstellen ab der Hälfte des Laufs gemittelt (alle 2000 Jahre); ein Einzelzeitpunkt ist chaotisch (`docs/zielbild-measurements.md` § Paket B).

Betrifft: `RectWaterTests`, `MaterialCoverageTests`, `LegacyTerrainColor`, `MeanderBeltCalibration`
